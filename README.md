# DeFi Staking Protocol

一个基于 Foundry 的 ERC20 质押挖矿协议：**质押 STAKE 代币，按周期预算获得 REWARD 代币奖励；支持多笔独立质押，每笔自选锁仓档位；持有早期 ERC1155 凭证的用户额外获得奖励加成。**

---

## 目录

- [一、项目架构图](#一项目架构图)
- [二、项目结构树](#二项目结构树)
- [三、核心合约说明](#三核心合约说明)
- [四、核心机制说明](#四核心机制说明)
  - [4.1 周期预算制奖励](#41-周期预算制奖励)
  - [4.2 多笔独立质押与锁仓档位](#42-多笔独立质押与锁仓档位)
  - [4.3 ERC1155 早期参与凭证](#43-erc1155-早期参与凭证)
  - [4.4 奖励计算公式](#44-奖励计算公式)
- [五、参数表](#五参数表)
- [六、用户操作示例（Work Example）](#六用户操作示例work-example)
- [七、管理员功能](#七管理员功能)
- [八、安全分析](#八安全分析)
- [九、开发环境与使用](#九开发环境与使用)
- [十、参考与依据](#十参考与依据)
- [十一、项目状态](#十一项目状态)

---

## 一、项目架构图

```
                        ┌─────────────────────┐
                        │   项目方 (Owner)     │
                        └──────────┬──────────┘
                                   │ notifyRewardAmount(10000 RT)
                                   ▼
┌──────────┐    stake()     ┌──────────────────────┐    mint()     ┌──────────────────┐
│   用户    │ ─────────────▶│  TimeBoostStaking    │ ─────────────▶│  BoostCredential  │
│ (Wallet) │ ◀─────────────│  (核心质押合约)       │ ◀─────────────│  (ERC1155 凭证)   │
└──────────┘    getReward() └──────────┬──────────┘   userHasBoost └──────────────────┘
                       unstake(stakeId) │
                                        │ transferFrom / transfer
                          ┌─────────────┴─────────────┐
                          ▼                           ▼
                  ┌───────────────┐          ┌───────────────┐
                  │  StakeToken   │          │  RewardToken  │
                  │   (ST, ERC20) │          │   (RT, ERC20) │
                  └───────────────┘          └───────────────┘
```

**数据流**：
1. 项目方向合约注入周期奖励（RT）
2. 用户质押 ST，合约创建独立质押笔，早期用户自动获得 ERC1155 凭证
3. 时间流逝，奖励按 `份额占比 × rewardRate × 锁仓倍率 × 凭证加成` 累积
4. 用户随时 `getReward()` 领取奖励，或 `unstake(stakeId)` 取回指定笔的本金

---

## 二、项目结构树

```
staking/
├── src/
│   ├── StakeToken.sol           # 质押本金代币 (ERC20, "ST")
│   ├── RewardToken.sol          # 奖励代币 (ERC20, "RT")
│   ├── BoostCredential.sol      # 早期参与凭证 (ERC1155, tokenId=0)
│   └── TimeBoostStaking.sol     # 核心质押合约（多笔质押 + 锁仓倍率 + 凭证加成）
├── script/
│   └── Deploy.s.sol             # 部署脚本（待完成）
├── test/
│   └── *.t.sol                  # Foundry 单元测试（待完成）
├── foundry.toml                 # Foundry 配置
├── remappings.txt               # 依赖路径映射
└── README.md                    # 本文档
```

---

## 三、核心合约说明

| 合约 | 职责 | 关键函数 | 依赖 |
|------|------|---------|------|
| `StakeToken.sol` | 质押本金代币，符号 ST，可 mint 用于测试 | `mint(to, amount)` | OpenZeppelin ERC20 |
| `RewardToken.sol` | 奖励代币，符号 RT，可 mint 用于测试 | `mint(to, amount)` | OpenZeppelin ERC20 |
| `BoostCredential.sol` | 早期参与凭证，ERC1155，tokenId=0，每地址最多铸一张，可转让 | `mintBoostCredential(addr)`, `userHasBoost(addr)`, `hasMinted(addr)` | ERC1155 + Ownable |
| `TimeBoostStaking.sol` | 核心质押合约：多笔质押、锁仓倍率、周期奖励、凭证加成 | `stake()`, `unstake(stakeId)`, `getReward()`, `earned()`, `notifyRewardAmount()` | SafeERC20 + Ownable + ReentrancyGuard |

### TimeBoostStaking 数据结构（多笔模型）

```solidity
struct UserStake {
    uint256 amount;         // 这笔质押本金
    uint256 rewardDebt;     // 这笔上次结算基点
    uint256 unlockTime;     // 这笔解锁时间戳
    uint256 lockMultiplier; // 这笔的锁仓倍率
}

uint256 public nextStakeId;                    // 全局自增 id
mapping(uint256 => UserStake) public stakes;    // stakeId → 质押详情
mapping(uint256 => address) public stakeOwner;  // stakeId → 持有人
mapping(address => uint256[]) public userStakeIds; // 用户 → 他所有的 stakeId
```

**每个用户可同时持有多笔独立质押**，每笔独立选档位、独立解锁时间、独立结算。

---

## 四、核心机制说明

### 4.1 周期预算制奖励

**思路**：项目方每个周期划定固定奖励预算，均摊到每秒（`rewardRate = 预算 / 周期秒数`），用户按质押份额比例分得奖励；周期结束后管理员重新注入奖励开启下一周期。

**为什么用这个方案**：
1. **成本精确可控**——每周期奖励总量固定，发完即止，避免无限增发
2. **周期轮换便于运营**——每 30 天根据市场情况决定加码或收缩
3. **实现简单安全**——周期结束奖励自动停止，天然避免"奖励池枯竭"边界问题

**核心状态变量**：

| 变量 | 含义 |
|------|------|
| `rewardRate` | 每秒奖励量 = 周期预算 / 周期秒数 |
| `periodFinish` | 当前周期结束时间戳 |
| `lastUpdateTime` | 上次结算时间戳 |
| `rewardPerTokenStored` | 累计每单位质押份额对应的奖励（放大 1e18） |

**奖励会计模型**：采用 Synthetix StakingRewards 的 `rewardPerTokenStored + rewardDebt` O(1) 模型——全局 rpT 持续累加，每笔质押记录自己的 rewardDebt（上次结算基点），结算时做差即可算出这段时间的增量，无需遍历所有用户。

### 4.2 多笔独立质押与锁仓档位

**思路**：用户每次调用 `stake()` 都创建一笔新的独立质押，自选锁仓档位；锁得越久，该笔的奖励倍率越高；锁仓期内该笔不能提取本金。

**锁仓档位表**：

| 档位下标 | 锁仓时长 | 奖励倍率 |
|---------|---------|---------|
| 0 | 不锁 | 1.0x |
| 1 | 7 天 | 1.05x |
| 2 | 30 天 | 1.15x |
| 3 | 90 天 | 1.3x |

> 倍率在合约内以 1e18 为精度存储（`1.0x = 1e18`，`1.3x = 1.3e18`）。

**多笔模型的优势**：
- 用户可同时持有"7 天灵活仓"和"90 天高倍率仓"
- 追加存款直接开新笔，不影响已有笔的档位和解锁时间
- `unstake(stakeId)` 只取指定笔，其他笔不受影响

**为什么这样设档位**：
1. **90 天封顶、最高 1.3x，温和不激进**——参考 Convex vlCVX 的"16 周封顶"逻辑
2. **分档而不是线性衰减**——用户一眼看懂"锁越久赚越多"
3. **演示友好**——7 天档在测试中用 `vm.warp()` 跳时间即可验证

### 4.3 ERC1155 早期参与凭证

**思路**：项目早期（部署后前 7 天）新质押的用户自动获得 1 张 ERC1155 凭证（每个地址最多 1 张）；持有凭证的用户所有质押笔奖励**额外 ×1.2**。

**"早期"的定义：部署后前 7 天（合约按时间戳自动判断）**
- 部署时合约自动设定 `earlyMintDeadline = block.timestamp + 7 days`
- 这 7 天内新质押的用户，没领过凭证的，`stake()` 时自动获得一张
- **7 天到点后合约自动停止铸凭证**，无需人工操作
- 管理员可用 `setEarlyMintDeadline` 应急调整截止时间
- 已发出的凭证永久有效、可转让

**凭证设计：可转让**（权益凭证，非身份凭证）
- 凭证本质是权益资产，早期参与者可转让给后来者，形成二级市场
- ERC1155 默认即可转让，实现成本低
- 加成按**当前持有者**判定（`balanceOf(user, 0) >= 1`），凭证转给他人后原持有者不再享受加成

**凭证合约关键函数**：

| 函数 | 权限 | 说明 |
|------|------|------|
| `mintBoostCredential(address)` | onlyOwner | 铸造凭证，一个地址最多一张 |
| `userHasBoost(address)` | view | 查询用户是否持有凭证（按当前余额判断） |
| `hasMinted(address)` | view | 查询用户是否曾经铸过凭证（防重复铸造） |

### 4.4 奖励计算公式

```
单笔奖励 = 该笔金额 × (当前rpT - 该笔rewardDebt) / 1e18 × 该笔锁仓倍率

用户总奖励 = Σ(每笔奖励) × (有凭证 ? 1.2 : 1)
```

其中 `rpT`（rewardPerTokenStored）是全局累计指数，每秒增量 = `rewardRate / totalStaked`。

---

## 五、参数表

| 参数 | 数值 | 设定逻辑 |
|------|------|---------|
| Solidity 版本 | 0.8.24 | 稳定版本，内置 overflow 检查 |
| `rewardsDuration` | 30 天（2,592,000 秒） | 主流周期长度，兼顾演示与运营 |
| 初始周期预算示例 | 10,000 RT | `rewardRate ≈ 3.86 × 10^15 wei/秒`（约 0.0039 RT/秒） |
| 锁仓档位 | 0/7/30/90 天 | 倍率 1.0/1.05/1.15/1.3x，90 天封顶 |
| `boostMultiplier` | 1.2x（1.2e18） | 凭证额外加成 |
| `earlyMintDeadline` | 部署后 7 天 | 早期凭证窗口，到点自动关闭 |
| 凭证 tokenId | 0 | ERC1155 单一种类凭证 |
| 精度 | 1e18 | 所有倍率与奖励计算均放大 1e18 防精度丢失 |

---

## 六、用户操作示例（Work Example）

以下演示一个完整的用户交互流程（假设已部署并注入奖励）。

### 步骤 1：用户质押（创建第一笔，选 30 天档）

```solidity
// 用户批准 ST 给合约后调用
uint256 stakeId1 = staking.stake(1000 ether, 2); // 存 1000 ST，档位 2（30天，1.15x）
// 返回 stakeId1 = 1
// 若在早期窗口内，自动获得 ERC1155 凭证
```

### 步骤 2：用户再质押（创建第二笔，选 90 天档）

```solidity
uint256 stakeId2 = staking.stake(500 ether, 3); // 存 500 ST，档位 3（90天，1.3x）
// 返回 stakeId2 = 2
// 两笔独立：第一笔 30 天后解锁，第二笔 90 天后解锁
```

### 步骤 3：查询用户有哪些质押笔

```solidity
uint256[] memory ids = staking.getUserStakeIds(user);
// 返回 [1, 2]
```

### 步骤 4：查询当前可领取奖励

```solidity
uint256 pending = staking.earned(user);
// 返回所有笔的奖励合计（已乘各自倍率和凭证加成）
```

### 步骤 5：领取奖励（不影响本金）

```solidity
staking.getReward();
// 结算所有笔的奖励，RT 转到用户钱包
// 本金仍在合约中继续产生奖励
```

### 步骤 6：30 天后，取回第一笔本金

```solidity
staking.unstake(stakeId1); // 只取回 stakeId=1 的 1000 ST
// stakeId=2 的 500 ST 仍在质押中，继续享受 1.3x 奖励
```

### 步骤 7：90 天后，取回第二笔本金

```solidity
staking.unstake(stakeId2); // 取回 stakeId=2 的 500 ST
```

---

## 七、管理员功能

| 函数 | 说明 |
|------|------|
| `notifyRewardAmount(uint256)` | 注入周期奖励，开启/续接奖励周期；内置防超发检查 |
| `setRewardsDuration(uint256)` | 设置周期长度（默认 30 天） |
| `setLockTier(uint256, uint256, uint256)` | 调整锁仓档位（下标、时长、倍率） |
| `setBoostMultiplier(uint256)` | 调整凭证加成倍率（默认 1.2e18） |
| `setEarlyMintDeadline(uint256)` | 调整早期凭证窗口截止时间 |

> 部署时需将 `BoostCredential` 的 owner 转给 `TimeBoostStaking`，否则 `stake()` 中自动铸凭证会因权限失败。

---

## 八、安全分析

### 风险 1：奖励超发（Reward Over-distribution）

**描述**：如果 `notifyRewardAmount` 注入的奖励量超过合约实际持有的 RT 余额，或 `rewardRate` 设置过高，可能导致用户领取奖励时合约余额不足，转账失败。

**防护措施**：
- `notifyRewardAmount` 内置检查：`require(rewardRate <= balanceOf(this) / rewardsDuration, "rate too high")`
- 周期结束后奖励自动停止（`_lastTimeRewardApplicable` 卡在 `periodFinish`）
- 项目方注入奖励时需先 `approve`，合约通过 `safeTransferFrom` 转入，确保注入量与声明量一致

**残留风险**：如果上一周期有未领取的奖励，管理员在周期未结束时再次注入，`rewardRate` 会将剩余部分并入新周期。这是设计行为，但管理员需注意不要重复注入导致余额被锁定。

### 风险 2：重入攻击（Reentrancy）

**描述**：`stake()`、`getReward()`、`unstake()` 中都有外部代币转账（`safeTransfer` / `safeTransferFrom`），如果 ST 或 RT 是恶意代币（在转账回调中重入合约），可能导致状态不一致。

**防护措施**：
- 所有用户侧函数均加 `nonReentrant` 修饰符（ReentrancyGuard）
- 遵循"Checks-Effects-Interactions"模式：先更新状态（`rewardDebt`、`totalStaked`、`stakes`），再执行外部转账
- `unstake()` 中先 `delete stakes[stakeId]` 再转账，确保重入时该笔已清零

**残留风险**：`ReentrancyGuard` 只能防止同一合约的重入，无法防止跨合约重入（如恶意代币在回调中调用其他协议）。学生项目中 ST/RT 为标准 ERC20，无回调风险。

### 其他安全设计

| 风险 | 防护 |
|------|------|
| 非标准 ERC20 转账陷阱 | `SafeERC20` 包装所有转账 |
| 精度丢失 | 奖励与倍率均放大 1e18 计算 |
| 提前提款 | 每笔独立校验 `block.timestamp >= unlockTime` |
| 凭证刷量 | `hasMinted` 限制每地址最多铸 1 张；加成按当前持有者 `balanceOf >= 1` 判断 |
| 整数溢出 | Solidity 0.8.x 内置 overflow/underflow 检查 |

---

## 九、开发环境与使用

### 环境要求
- Foundry（forge 1.x）
- Solidity 0.8.24

### 安装依赖
```bash
forge install foundry-rs/forge-std
forge install openzeppelin/openzeppelin-contracts
forge remappings > remappings.txt
```

### 编译
```bash
forge build
```

### 测试
```bash
forge test -vvv
# 覆盖率
forge coverage --ir-minimum
```

### 部署（Sepolia 示例）
```bash
source .env
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url sepolia --broadcast --verify --slow
```

> 需在 `.env` 中配置 `SEPOLIA_RPC_URL` 与 `ETHERSCAN_API_KEY`，并在 `foundry.toml` 中声明对应 `[rpc_endpoints]` 与 `[etherscan]` 配置。

---

## 十、参考与依据

- **Synthetix StakingRewards**：`rewardRate + periodFinish` 周期预算模型与 `rewardPerTokenStored + rewardDebt` O(1) 会计模型出处
  https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
- **SushiSwap MasterChef**：按区块/周期发放奖励、多池质押机制参考
  https://github.com/sushiswap/sushiswapV1/blob/master/sushiswap/contracts/MasterChef.sol
- **Curve veCRV**：时间加权收益模型、不可转让治理凭证（作为对比参考）
  https://docs.curve.finance/
- **Convex vlCVX**：分档/封顶锁仓设计（16 周封顶）
  https://docs.convexfinance.com/
- **Velodrome veNFT / cvxCRV**：权益型凭证可转让/可流通的参考
  https://cryptogloss.io/glossary/ve-tokenomics/

---

## 十一、项目状态

- [x] 设计定稿（本 README）
- [x] 合约实现（src/：StakeToken / RewardToken / BoostCredential / TimeBoostStaking）
- [x] 多笔质押模型重构
- [ ] Foundry 单元测试（test/）
- [ ] 部署脚本（script/，含"将 BoostCredential owner 转给 TimeBoostStaking"）
- [ ] Sepolia 部署 + Etherscan 源码验证
- [ ] README 覆盖率数据补充
