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
/// @dev 奖励会计采用 Synthetix StakingRewards 模型（rewardPerTokenStored + rewardDebt，O(1)）。
contract TimeBoostStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== 不可变代币地址 ==========
    IERC20 public immutable STAKE_TOKEN;
    IERC20 public immutable REWARD_TOKEN;
    BoostCredential public immutable BOOST_CREDENTIAL;

    // ========== 锁仓档位 ==========
    struct LockTier {
        uint256 lockDuration; // 锁仓秒数
        uint256 rewardMultiplier; // 奖励倍率（1e18 = 1.0x）
    }
    LockTier[] public lockTiers;

    // ========== 用户质押记录（单用户单笔质押） ==========
    struct UserStake {
        uint256 stakedAmount; // 质押本金
        uint256 rewardDebt; // 上次结算基点 = staked * rewardPerTokenStored / 1e18
        uint256 unlockTime; // 解锁时间戳
        uint256 lockMultiplier; // 该笔质押的锁仓倍率（1e18 = 1.0x）
    }
    mapping(address => UserStake) public userStakes;

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
    event Staked(address indexed user, uint256 amount, uint256 tierIndex);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
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

    /// @notice 质押本金，选择锁仓档位
    /// @param amount 质押数量
    /// @param tierIndex 档位下标（0=不锁 1=7天 2=30天 3=90天）
    function stake(uint256 amount, uint256 tierIndex) external nonReentrant {
        require(amount > 0, "Zero amount");
        UserStake storage user = userStakes[msg.sender];

        // 已有质押：先把历史奖励兑现，防止追加质押时吞掉奖励
        if (user.stakedAmount > 0) {
            uint256 pending = _earned(msg.sender);
            _updateReward(msg.sender);
            if (pending > 0) {
                REWARD_TOKEN.safeTransfer(msg.sender, pending);
                emit RewardPaid(msg.sender, pending);
            }
        } else {
            _updateReward(msg.sender);
            // 首次质押：按所选档位锁定
            require(tierIndex < lockTiers.length, "bad tier");
            LockTier memory tier = lockTiers[tierIndex];
            user.lockMultiplier = tier.rewardMultiplier;
            user.unlockTime = block.timestamp + tier.lockDuration;
        }

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        user.stakedAmount += amount;
        totalStaked += amount;
        user.rewardDebt = (user.stakedAmount * rewardPerTokenStored) / 1e18;

        // 早期窗口（block.timestamp <= earlyMintDeadline）内：新质押且未领过凭证的用户自动铸一张
        if (block.timestamp <= earlyMintDeadline && !BOOST_CREDENTIAL.hasMinted(msg.sender)) {
            BOOST_CREDENTIAL.mintBoostCredential(msg.sender);
        }

        emit Staked(msg.sender, amount, tierIndex);
    }

    /// @notice 领取当前累计奖励（不影响本金和锁仓）
    function getReward() external nonReentrant {
        uint256 reward = _earned(msg.sender);
        _updateReward(msg.sender);
        if (reward > 0) {
            REWARD_TOKEN.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice 锁仓到期后取回本金并领取全部奖励
    function unstake() external nonReentrant {
        UserStake storage user = userStakes[msg.sender];
        uint256 amount = user.stakedAmount;
        require(amount > 0, "no stake");
        require(block.timestamp >= user.unlockTime, "still locked");

        uint256 reward = _earned(msg.sender);
        _updateReward(msg.sender);

        totalStaked -= amount;
        delete userStakes[msg.sender];

        STAKE_TOKEN.safeTransfer(msg.sender, amount);
        if (reward > 0) {
            REWARD_TOKEN.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
        emit Unstaked(msg.sender, amount, reward);
    }

    // ============================================================
    //                      查询侧（view）
    // ============================================================

    /// @notice 现在可领取的奖励（已乘锁仓倍率和凭证加成）
    function earned(address account) external view returns (uint256) {
        return _earned(account);
    }

    function _earned(address account) internal view returns (uint256) {
        UserStake storage user = userStakes[account];
        if (user.stakedAmount == 0) return 0;

        // 当前累计每份额奖励（含本次结算到此刻的增量）
        uint256 currentRpt = rewardPerTokenStored + _freshRewardPerToken();
        // 基础奖励 = staked * (currentRpt - rewardDebt) / 1e18
        uint256 base = (user.stakedAmount * currentRpt) / 1e18 - user.rewardDebt;

        // 叠加倍率：锁仓倍率 × 凭证加成
        uint256 mult = user.lockMultiplier;
        if (BOOST_CREDENTIAL.userHasBoost(account)) {
            mult = (mult * boostMultiplier) / 1e18;
        }
        return (base * mult) / 1e18;
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
            // 上一周期还没结束：把剩余未发的部分并入新周期
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (leftover + amount) / rewardsDuration;
        }

        // 防超发：rewardRate 不能高到合约余额支付不起
        require(rewardRate <= REWARD_TOKEN.balanceOf(address(this)) / rewardsDuration, "rewardRate too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardNotified(amount, periodFinish);
    }

    /// @notice 设置奖励周期长度
    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(newDuration);
    }

    /// @notice 修改锁仓档位
    function setLockTier(uint256 index, uint256 duration, uint256 multiplier) external onlyOwner {
        lockTiers[index] = LockTier({lockDuration: duration, rewardMultiplier: multiplier});
        emit LockTierUpdated(index, duration, multiplier);
    }

    /// @notice 修改凭证奖励加成
    function setBoostMultiplier(uint256 newMultiplier) external onlyOwner {
        boostMultiplier = newMultiplier;
        emit BoostMultiplierUpdated(newMultiplier);
    }

    /// @notice 修改早期凭证窗口截止时间（可延长/提前结束，仅 owner）
    function setEarlyMintDeadline(uint256 newDeadline) external onlyOwner {
        earlyMintDeadline = newDeadline;
        emit EarlyMintDeadlineUpdated(newDeadline);
    }

    // ============================================================
    //                        内部函数
    // ============================================================

    /// @notice 本周期内、到此刻为止可计奖励的时间点
    function _lastTimeRewardApplicable() internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice 自上次结算以来，新产生的每份额奖励增量
    function _freshRewardPerToken() internal view returns (uint256) {
        if (totalStaked == 0) return 0;
        return ((_lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }

    /// @notice 更新全局 rpT 和用户 rewardDebt（stake/getReward/unstake 前调用）
    function _updateReward(address account) internal {
        require(account != address(0), "Zero address");

        rewardPerTokenStored = rewardPerTokenStored + _freshRewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();

        userStakes[account].rewardDebt =
            (userStakes[account].stakedAmount * rewardPerTokenStored) / 1e18;
    }
}
