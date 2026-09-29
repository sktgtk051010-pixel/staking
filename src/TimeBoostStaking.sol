// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BoostCredential} from "./BoostCredential.sol";

/// @title TimeBoostStaking
/// @notice 质押 STAKE 代币，按周期预算获得 RT 奖励；锁仓时间越长奖励倍率越高；
///         持有早期 ERC1155 凭证的用户额外获得奖励加成。
/// @dev 多笔质押模型：每个用户可同时持有多笔独立质押，每笔独立选档位、独立解锁时间。
contract TimeBoostStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable STAKE_TOKEN;
    IERC20 public immutable REWARD_TOKEN;
    BoostCredential public immutable BOOST_CREDENTIAL;

    struct LockTier {
        uint256 lockDuration; // 锁仓秒数
        uint256 rewardMultiplier; // 奖励倍率（1e18 = 1.0x）
    }
    LockTier[] public lockTiers;

    struct UserStake {
        uint256 amount; // 这笔质押本金
        uint256 rewardDebt; // 这笔上次结算基点
        uint256 unlockTime; // 这笔解锁时间戳
        uint256 lockMultiplier; // 这笔的锁仓倍率
    }

    uint256 public nextStakeId = 1; // 全局自增质押 id
    mapping(uint256 => UserStake) public stakes; // stakeId → 质押详情
    mapping(uint256 => address) public stakeOwner; // stakeId → 持有人
    mapping(address => uint256[]) public userStakeIds; // 用户 → 他所有的 stakeId 列表

    // ========== 奖励周期（Synthetix 模型） ==========
    uint256 public rewardRate; // 每秒奖励量（wei）
    uint256 public rewardsDuration; // 周期秒数
    uint256 public periodFinish; // 当前周期结束时间
    uint256 public lastUpdateTime; // 上次结算时间
    uint256 public rewardPerTokenStored; // 累计每单位质押份额的奖励（放大 1e18）

    uint256 public totalStaked;

    // ========== 凭证加成 ==========
    uint256 public boostMultiplier = 1.2e18; // 凭证额外加成 1.2x
    uint256 public earlyMintDeadline; // 早期凭证窗口截止时间戳（部署后 7 天）

    // ========== 事件 ==========
    event Staked(address indexed user, uint256 indexed stakeId, uint256 amount, uint256 tierIndex);
    event Unstaked(address indexed user, uint256 indexed stakeId, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 amount, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event LockTierUpdated(uint256 indexed index, uint256 duration, uint256 multiplier);
    event BoostMultiplierUpdated(uint256 newMultiplier);
    event EarlyMintDeadlineUpdated(uint256 newDeadline);

    constructor(address _stakeToken, address _rewardToken, address _boostCredential) Ownable(msg.sender) {
        STAKE_TOKEN = IERC20(_stakeToken);
        REWARD_TOKEN = IERC20(_rewardToken);
        BOOST_CREDENTIAL = BoostCredential(_boostCredential);

        rewardsDuration = 30 days;

        // 早期凭证窗口：部署后 7 天内质押的用户可自动获得凭证
        earlyMintDeadline = block.timestamp + 7 days;

        // 预设锁仓档位：0/7/30/90 天，倍率 1.0/1.05/1.15/1.3
        lockTiers.push(LockTier({lockDuration: 0 days, rewardMultiplier: 1e18}));
        lockTiers.push(LockTier({lockDuration: 7 days, rewardMultiplier: 1.05e18}));
        lockTiers.push(LockTier({lockDuration: 30 days, rewardMultiplier: 1.15e18}));
        lockTiers.push(LockTier({lockDuration: 90 days, rewardMultiplier: 1.3e18}));
    }

    // ============================================================
    //                        用户侧
    // ============================================================

    /// @notice 质押本金，选择锁仓档位（创建新的一笔，不影响已有质押）
    /// @param stakeAmount 质押数量
    /// @param tierIndex 档位下标（0=不锁 1=7天 2=30天 3=90天）
    /// @return stakeId 新创建的质押 id
    function stake(uint256 stakeAmount, uint256 tierIndex) external nonReentrant returns (uint256 stakeId) {
        require(stakeAmount > 0, "Zero amount");
        require(tierIndex < lockTiers.length, "bad tier");

        rewardPerTokenStored = rewardPerTokenStored + _freshRewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();

        LockTier memory tier = lockTiers[tierIndex];

        // 创建新质押笔
        stakeId = nextStakeId++;
        stakes[stakeId] = UserStake({
            amount: stakeAmount,
            rewardDebt: (stakeAmount * rewardPerTokenStored) / 1e18,
            unlockTime: block.timestamp + tier.lockDuration,
            lockMultiplier: tier.rewardMultiplier
        });
        stakeOwner[stakeId] = msg.sender;
        userStakeIds[msg.sender].push(stakeId);

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), stakeAmount);
        totalStaked += stakeAmount;

        // 早期窗口内：没领过凭证的用户自动铸一张
        if (block.timestamp < earlyMintDeadline && !BOOST_CREDENTIAL.hasMinted(msg.sender)) {
            BOOST_CREDENTIAL.mintBoostCredential(msg.sender);
        }

        emit Staked(msg.sender, stakeId, stakeAmount, tierIndex);
    }

    /// @notice 领取当前累计奖励（结算所有质押笔，不影响本金）
    function getReward() external nonReentrant {
        _getReward(msg.sender);
    }

    /// @notice 解锁后取回指定质押笔的本金
    /// @param stakeId 要取回的质押 id
    function unstake(uint256 stakeId) external nonReentrant {
        require(stakeOwner[stakeId] == msg.sender, "not owner");
        UserStake storage s = stakes[stakeId];
        require(s.amount > 0, "no stake");
        require(block.timestamp >= s.unlockTime, "still locked");

        // 先结算所有笔的奖励
        _getReward(msg.sender);

        // 从用户列表移除这笔
        _removeStakeId(msg.sender, stakeId);

        uint256 amount = s.amount;
        totalStaked -= amount;
        delete stakes[stakeId];
        delete stakeOwner[stakeId];

        STAKE_TOKEN.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, stakeId, amount);
    }

    // ============================================================
    //                      查询侧（view）
    // ============================================================

    /// @notice 现在可领取的奖励合计（所有笔，已乘锁仓倍率和凭证加成）
    function earned(address account) external view returns (uint256) {
        return _earned(account);
    }

    /// @notice 查询用户所有的质押 id
    function getUserStakeIds(address account) external view returns (uint256[] memory) {
        return userStakeIds[account];
    }

    function _earned(address account) internal view returns (uint256 totalReward) {
        uint256 currentRpt = rewardPerTokenStored + _freshRewardPerToken();
        uint256[] storage ids = userStakeIds[account];

        for (uint256 i = 0; i < ids.length; i++) {
            totalReward += _calcStakeReward(stakes[ids[i]], currentRpt);
        }

        // 凭证加成全局乘一次
        if (totalReward > 0 && BOOST_CREDENTIAL.userHasBoost(account)) {
            totalReward = (totalReward * boostMultiplier) / 1e18;
        }
    }

    // ============================================================
    //                     管理员侧（onlyOwner）
    // ============================================================

    /// @notice 注入新周期奖励（msg.sender 需先 approve rewardToken）
    function notifyRewardAmount(uint256 amount) external onlyOwner {
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        if (block.timestamp >= periodFinish) {
            rewardRate = amount / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (leftover + amount) / rewardsDuration;
        }

        require(rewardRate <= REWARD_TOKEN.balanceOf(address(this)) / rewardsDuration, "rate too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardNotified(amount, periodFinish);
    }

    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(newDuration);
    }

    function setLockTier(uint256 index, uint256 duration, uint256 multiplier) external onlyOwner {
        lockTiers[index] = LockTier({lockDuration: duration, rewardMultiplier: multiplier});
        emit LockTierUpdated(index, duration, multiplier);
    }

    function setBoostMultiplier(uint256 newMultiplier) external onlyOwner {
        boostMultiplier = newMultiplier;
        emit BoostMultiplierUpdated(newMultiplier);
    }

    function setEarlyMintDeadline(uint256 newDeadline) external onlyOwner {
        earlyMintDeadline = newDeadline;
        emit EarlyMintDeadlineUpdated(newDeadline);
    }

    // ============================================================
    //                        内部函数
    // ============================================================

    /// @notice 结算用户所有笔的奖励并打款（getReward / unstake 前调用）
    function _getReward(address user) internal {
        // 先刷新全局 rpT
        rewardPerTokenStored = rewardPerTokenStored + _freshRewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();

        uint256 currentRpt = rewardPerTokenStored;
        uint256 totalReward;

        uint256[] storage ids = userStakeIds[user];
        for (uint256 i = 0; i < ids.length; i++) {
            UserStake storage s = stakes[ids[i]];
            totalReward += _calcStakeReward(s, currentRpt);
            // 每笔 rewardDebt 推到此刻
            s.rewardDebt = (s.amount * currentRpt) / 1e18;
        }

        if (totalReward > 0) {
            if (BOOST_CREDENTIAL.userHasBoost(user)) {
                totalReward = (totalReward * boostMultiplier) / 1e18;
            }
            REWARD_TOKEN.safeTransfer(user, totalReward);
            emit RewardPaid(user, totalReward);
        }
    }

    /// @notice 计算单笔质押到此刻的奖励（不含凭证加成）
    function _calcStakeReward(UserStake storage s, uint256 currentRpt) internal view returns (uint256) {
        if (s.amount == 0) return 0;
        uint256 base = (s.amount * currentRpt) / 1e18 - s.rewardDebt;
        return (base * s.lockMultiplier) / 1e18;
    }

    /// @notice 从用户的 stakeId 列表中移除指定 id（交换到末尾再 pop）
    function _removeStakeId(address user, uint256 stakeId) internal {
        uint256[] storage ids = userStakeIds[user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == stakeId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }
    }

    function _lastTimeRewardApplicable() internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function _freshRewardPerToken() internal view returns (uint256) {
        if (totalStaked == 0) return 0;
        return ((_lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }
}
