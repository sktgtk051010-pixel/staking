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
  - [4.5 奖励随时领取（锁仓只约束本金）](#45-奖励随时领取锁仓只约束本金)
- [五、参数表](#五参数表)
- [六、用户操作示例（Work Example）](#六用户操作示例work-example)
- [七、管理员功能](#七管理员功能)
- [八、安全分析](#八安全分析)
- [九、开发环境与使用](#九开发环境与使用)
- [十、当前部署地址（Sepolia）](#十当前部署地址sepolia)

---

## 一、项目架构图

```
                        ┌─────────────────────┐
                        │   项目方 (Owner)     │
                        └──────────┬──────────┘
                                   │ notifyRewardAmount(100000 RT)
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
2. 用户质押 ST，合约创建独立质押笔，早期用户（仅 EOA，见 §4.3）自动获得 ERC1155 凭证
3. 时间流逝，奖励按 `有效份额占比 × rewardRate` 累积（锁仓倍率已折算进份额），持有凭证再 ×1.2
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
│   └── Deploy.s.sol             # 部署脚本（部署 4 合约 + 注入奖励）
├── test/
│   ├── base/BaseTest.t.sol      # 测试基类（部署 + 初始化）
│   ├── StakingTest.t.sol        # 质押/取回/奖励单元测试
│   ├── MultiStakeTest.t.sol     # 多笔质押模型测试
│   ├── BoostTest.t.sol          # ERC1155 凭证测试
│   ├── AdminTest.t.sol          # 管理员函数测试
│   └── fork/ForkTest.t.sol      # 主网 Fork 集成测试
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
    uint256 rewardDebt;     // 这笔上次结算时已赚的奖励数（= 有效份额 × 当时rpT / 1e18，不是 rpT 指数，见 §4.4）
    uint256 unlockTime;     // 这笔解锁时间戳
    uint256 lockMultiplier; // 这笔的锁仓倍率
}

uint256 public nextStakeId = 1;                    // 全局自增质押 id（从 1 开始）
mapping(uint256 => UserStake) public stakes;       // stakeId → 质押详情
mapping(uint256 => address) public stakeOwner;     // stakeId → 持有人
mapping(address => uint256[]) public userStakeIds; // 用户 → 他所有的 stakeId

uint256 public constant MAX_STAKES_PER_USER = 50;  // 单地址最大活跃质押笔数（防止 gas 随笔数无限增长，见 §4.2）
```

**每个用户可同时持有多笔独立质押**，每笔独立选档位、独立解锁时间、独立结算。

---

## 四、核心机制说明

### 4.1 周期预算制奖励

**思路**：项目方每个周期划定固定奖励预算，均摊到每秒并按凭证加成折算（`rewardRate = 预算 / 周期秒数 / boostMultiplier`），用户按**有效份额**（本金×锁仓倍率）比例分得奖励；周期结束后管理员重新注入奖励开启下一周期。

**为什么用这个方案**：
1. **成本可控**——全池奖励支出严格不超过每周期预算上限（实际发放随持证率在预算的 83%~100% 之间，见 §八 风险 3），有助于控制增发节奏
2. **周期轮换便于运营**——每 30 天根据市场情况决定加码或收缩，奖励发放成为运营杠杆
3. **机制透明可审计**——奖励速率公开可查，用户可自行计算预期收益

**核心状态变量**：

| 变量 | 含义 |
|------|------|
| `rewardRate` | 每秒奖励量 = 周期预算 / 周期秒数 / boostMultiplier（已折算凭证加成） |
| `periodFinish` | 当前周期结束时间戳 |
| `lastUpdateTime` | 上次结算时间戳 |
| `rewardPerTokenStored` | 累计每单位质押份额对应的奖励（放大 1e18） |
| `totalStaked` | 有效质押总量 = Σ(每笔本金 × 锁仓倍率)，rpT 每秒增量 = rewardRate × 1e18 / totalStaked（放大 1e18 存储） |

**奖励会计模型**：采用 Synthetix StakingRewards 的 `rewardPerTokenStored + rewardDebt` O(1) 模型——全局 rpT 持续累加，每笔质押记录自己的 rewardDebt（上次结算时已赚的奖励数，见 §4.4），结算时做差即可算出这段时间的增量，无需遍历所有用户。

### 4.2 多笔独立质押与锁仓档位

**思路**：用户每次调用 `stake()` 都创建一笔新的独立质押，自选锁仓档位；锁得越久，该笔的奖励倍率越高；锁仓期内该笔不能提取本金。

**单地址最大活跃笔数：50 笔**
- 为防止 gas 随笔数无限增长（领取/取回需遍历所有笔），单地址最多同时持有 50 笔活跃质押
- 取回本金（`unstake`）后会释放名额，可继续开新笔

**锁仓档位表**：

| 档位下标 | 锁仓时长 | 奖励倍率 |
|---------|---------|---------|
| 0 | 不锁（灵活存取） | 1.0x |
| 1 | 30 天 | 1.2x |
| 2 | 90 天 | 1.6x |
| 3 | 180 天 | 2.0x |

> 倍率在合约内以 1e18 为精度存储（`1.0x = 1e18`，`2.0x = 2e18`）。

**多笔模型的优势**：
- 用户可同时持有"30 天灵活仓"和"180 天高倍率仓"
- 追加存款直接开新笔，不影响已有笔的档位和解锁时间
- `unstake(stakeId)` 只取指定笔，其他笔不受影响

### 4.3 ERC1155 早期参与凭证

**思路**：项目早期（部署后前 7 天），新质押的 **EOA（普通钱包）用户**自动获得 1 张 ERC1155 凭证（每个地址最多 1 张）；持有凭证的用户所有质押笔奖励**额外 ×boostMultiplier（默认 1.2x）**。

**"早期"的定义：部署后前 7 天（合约按时间戳自动判断）**
- 部署时合约自动设定 `earlyMintDeadline = block.timestamp + 7 days`
- 这 7 天内新质押的 EOA 用户，没领过凭证的，`stake()` 时自动获得一张
- 合约钱包（多签、智能钱包等）不会自动获得凭证，原因见下方"已知限制"

- **7 天到点后合约自动停止铸凭证**，无需人工操作
- 管理员可用 `setEarlyMintDeadline` 应急调整截止时间
- 已发出的凭证永久有效、可转让

**已知限制：仅 EOA 自动铸造（合约钱包需手动获取）**
- 早期窗口内自动铸造凭证时，仅对 EOA（普通钱包）生效
- 合约钱包在早期窗口内质押**不会自动获得凭证**（因为合约可能不支持 ERC1155Receiver 接口，铸造会导致整个 stake revert）
- 合约钱包用户可以正常质押，只是拿不到早期加成；凭证可转让，合约钱包用户可通过购买/受让方式获得凭证
- 7 天后停止的只是"自动铸造"这一行为；已发出的凭证永久有效，有凭证与无凭证的加成差异**持续存在**，不会自动消失

**凭证设计：可转让**（权益凭证，非身份凭证）
- 凭证本质是权益资产，早期参与者可转让给后来者，凭证本身具备流动性和市场价值
- 可转让让早期参与者的贡献可以变现，也让后来者有机会通过购买凭证获得加成
- 加成按**当前持有者**判定（`balanceOf(user, 0) >= 1`），凭证转给他人后原持有者不再享受加成，权益跟着凭证走

### 4.4 奖励计算公式

```
有效份额 = 该笔本金 × 该笔锁仓倍率 / 1e18
单笔奖励 = 有效份额 × 当前rpT / 1e18 - 该笔rewardDebt

用户总奖励 = Σ(每笔奖励) × (有凭证 ? boostMultiplier : 1)
```

**说明：**
- `rpT`（rewardPerTokenStored）是全局累计指数，每秒增量 = `rewardRate × 1e18 / totalStaked`（放大 1e18 存储）
- `totalStaked` 是**有效质押总量**（Σ每笔本金 × 锁仓倍率），不是名义本金
- `rewardDebt` 存的是**上次结算时这笔质押已赚的钱数**（= 有效份额 × 当时rpT / 1e18），不是 rpT 的值
- 所以计算时不能直接拿 rpT 减 rewardDebt，要先乘有效份额再减
- `boostMultiplier` 默认 1.2x，管理员可调（上限 2x）；`rewardRate` 已除以它折算预算，保证全池总支出不超预算

### 4.5 奖励随时领取（锁仓只约束本金）

**思路**：锁仓约束的是**本金取回**，奖励不设锁——用户随时可调用 `getReward()` 领取已产生的奖励；领取后本金继续留在合约中计息，无需重新质押。

**为什么这么设计**：
1. 奖励按秒累计、即时结算，用户能持续看到收益到账，参与动力更强
2. 锁仓档位的约束力集中在本金上（提前取回本金需要等解锁到期），与奖励分离，职责清晰
3. 领取奖励不影响任何锁仓状态：已解锁和未解锁的质押笔都可以领奖，只有 `unstake(stakeId)` 取回本金时才校验 `block.timestamp >= unlockTime`

**领取流程**：
- `getReward()`：结算该用户所有质押笔的奖励并转入钱包，不检查锁仓
- 领取后每笔的 `rewardDebt` 更新为「当前 rpT × 该笔有效份额 / 1e18」（即这笔已累计的奖励数），从此继续累计新奖励
- 奖励领取是独立操作，本金始终在合约中按原档位继续产生奖励

---

## 五、参数表

| 参数 | 数值 | 设定逻辑 |
|------|------|---------|
| `rewardsDuration` | 30 天（2,592,000 秒） | 主流周期长度 |
| 初始周期奖励 | 100,000 RT / 30 天 | 部署时调用 `notifyRewardAmount(100000 ether)` 注入；`rewardRate ≈ 3.215 × 10^16 wei/秒`（约 0.032 RT/秒，已除以 1.2 折算凭证加成） |
| 锁仓档位 | 0/30/90/180 天 | 倍率 1.0/1.2/1.6/2.0x，默认 180 天封顶（管理员可调：时长须 > 0，倍率限 1.0x~5x） |
| `boostMultiplier` | 默认 1.2x（1.2e18） | 凭证额外加成（管理员可调，限 1.0x~2x；调整须在周期结束后，下次注入按新倍率折算） |
| `earlyMintDeadline` | 部署后 7 天 | 早期凭证窗口，到点自动关闭（管理员调整仅可设未来时间） |
| 单地址最大活跃笔数 | 50 笔 | 防止 gas 随笔数无限增长（领取/取回需遍历所有笔），见 §4.2 |
| 凭证 tokenId | 0 | ERC1155 单一种类凭证 |
| 精度 | 1e18 | 所有倍率与奖励计算均放大 1e18 防精度丢失 |

---

## 六、用户操作示例（Work Example）

以下演示一个普通用户从零开始的完整操作流程（假设项目已上线、奖励池已注入 100,000 RT）。

### 第 1 步：首次质押（选 30 天档）

用户发起一笔质押交易，选择 30 天档，质押 1000 ST，在钱包确认。

**系统做了什么**：
- 将 1000 ST 从用户钱包转入质押合约
- 创建一笔独立质押（编号 #1），30 天后解锁，享受 1.2x 奖励倍率
- 如果此时在项目上线前 7 天的「早期窗口」内，系统自动向用户发放 1 张早期参与凭证（后续所有质押奖励额外 +20%，即默认 1.2x；仅限 EOA，合约钱包不自动发放，见 §4.3）

### 第 2 步：追加质押（选 90 天档，创建第二笔）

过了几天，用户再发起一笔质押交易，选择 90 天档，质押 500 ST。

**系统做了什么**：
- 创建另一笔独立质押（编号 #2），90 天后解锁，享受 1.6x 奖励倍率
- **两笔完全独立**：第 1 笔仍在 30 天后解锁，第 2 笔 90 天后解锁，互不影响
- 用户已经领过早期凭证，不会重复发放

### 第 3 步：查询自己的质押情况

用户调用合约查询接口，可以看到：
- 质押 #1：1000 ST，30 天档，剩余解锁时间 X 天
- 质押 #2：500 ST，90 天档，剩余解锁时间 Y 天
- 当前可领取奖励：Z RT（已自动结算：锁仓倍率已计入份额，持有凭证再 ×1.2）

### 第 4 步：领取奖励（不影响本金）

用户发起领取奖励交易。

**系统做了什么**：
- 结算所有质押笔从上次领取到现在累积的奖励
- 将 RT 转入用户钱包
- 本金仍在合约中继续产生奖励，无需重新质押

### 第 5 步：30 天后，取回第一笔本金

第 1 笔到期后，用户发起取回交易，指定取回质押 #1。

**系统做了什么**：
- 先结算该用户所有笔的奖励并发放
- 将第 1 笔的 1000 ST 本金退回用户钱包
- **第 2 笔的 500 ST 仍在质押中**，继续享受 1.6x 奖励，不受影响

### 第 6 步：90 天后，取回第二笔本金

第 2 笔到期后，用户发起取回交易，指定取回质押 #2，500 ST 本金退回，所有奖励结算完毕。

---

**整个流程的核心特点**：
- 每笔质押独立选档位、独立解锁时间
- 奖励可以随时领取，不影响本金
- 取回时只取指定的那一笔，其他笔继续产生奖励

---

## 七、管理员功能

| 函数 | 说明 |
|------|------|
| `notifyRewardAmount(uint256)` | 注入周期奖励，开启/续接奖励周期（amount 须 > 0）；rewardRate 已按凭证加成折算，全池总支出不超预算 |
| `setRewardsDuration(uint256)` | 设置周期长度（默认 30 天） |
| `setLockTier(uint256, uint256, uint256)` | 调整锁仓档位（下标、时长、倍率；时长须 > 0，倍率限 1.0x~5x） |
| `setBoostMultiplier(uint256)` | 调整凭证加成倍率（默认 1.2e18，限 1.0x~2x；仅可在周期结束后调整，防止中途调整打破预算平衡） |
| `setEarlyMintDeadline(uint256)` | 调整早期凭证窗口截止时间（仅可设未来时间） |

> 部署时需将 `BoostCredential` 的 owner 转给 `TimeBoostStaking`，否则 `stake()` 中自动铸凭证会因权限失败。

---

## 八、安全分析

### 风险 1：奖励超发（Reward Over-distribution）

**描述**：如果 `notifyRewardAmount` 注入的奖励量超过合约实际持有的 RT 余额，或 `rewardRate` 设置过高，可能导致用户领取奖励时合约余额不足，转账失败。

**已采取的措施**：
- `rewardRate` 按凭证加成折算：`rewardRate = 预算 × 1e18 / (周期秒数 × boostMultiplier)`，全池总支出严格不超过注入预算（全员持证时恰好等于预算），倍率/凭证加成不会放大支出
- `totalStaked` 按有效份额加权，锁仓倍率已计入份额，不存在"倍率事后相乘"造成的超发路径
- 周期结束后奖励自动停止（`_lastTimeRewardApplicable` 卡在 `periodFinish`）
- 项目方注入奖励时需先 `approve`，合约通过 `safeTransferFrom` 转入，有助于保证注入量与声明量一致

**残留风险**：如果上一周期有未领取的奖励，管理员在周期未结束时再次注入，`rewardRate` 会将剩余部分并入新周期。

### 风险 2：重入攻击（Reentrancy）

**描述**：`stake()`、`getReward()`、`unstake()` 中都有外部代币转账（`safeTransfer` / `safeTransferFrom`），如果 ST 或 RT 是恶意代币（在转账回调中重入合约），可能导致状态不一致。

**已采取的措施**：
- 所有用户侧函数均加 `nonReentrant` 修饰符（ReentrancyGuard）
- 遵循"Checks-Effects-Interactions"模式：`stake()`/`getReward()`/`unstake()` 中所有状态更新（`rewardDebt`、`totalStaked`、`stakes` 删除）均先于外部转账执行；奖励与本金转账统一在状态修改完成后沉底执行

**残留风险**：`ReentrancyGuard` 只能降低同一合约的重入风险，无法完全防止跨合约重入（如恶意代币在回调中调用其他协议）。本项目使用标准 ERC20 代币作为 ST 和 RT，恶意回调风险较低。

### 风险 3：空池期与预算沉淀（资金效率，不影响用户收益）

**描述**：
- 注入奖励后无人质押期间（`totalStaked == 0`），`_freshRewardPerToken()` 的除零保护直接返回 0，该段预算的奖励增量在 rpT 中不再累积，沉淀在合约中，本周期内不会发放
- `rewardRate` 按凭证加成折算预留（`÷ boostMultiplier`），实际持证率不足 100% 时发放低于名义预算，剩余部分沉淀累积，且 `leftover` 按折算后速率计算，不回收历史沉淀

**影响**：资金效率低于名义预算（0% 持证时约发放预算的 83%）；不影响任何用户收益——空池期本就无质押者，沉淀作为余额缓冲永久留存于合约：不自动结转进后续周期预算（`leftover` 不回收沉淀），合约当前也无提取沉淀的函数；如需回收需新增管理员提取功能（属后续改进，暂未实现）。

**说明**：这是"预算制 + 防超发"设计的固有权衡：为保证全员持证（最坏情况）也不超发，必须以 1.2 折算预留；不回收沉淀是为了避免将历史缓冲加速放出导致后续超发。属设计取舍，非漏洞。

### 其他安全设计

| 风险 | 已采取的措施 |
|------|------------|
| 非标准 ERC20 转账陷阱 | `SafeERC20` 包装所有转账 |
| 精度丢失 | 奖励与倍率均放大 1e18 计算 |
| 提前提款 | 每笔独立校验 `block.timestamp >= unlockTime` |
| 凭证重复铸造 | `hasMinted` 限制每地址最多铸 1 张；加成按当前持有者 `balanceOf >= 1` 判断 |
| 整数溢出 | Solidity 0.8.x 内置 overflow/underflow 检查 |

### 管理员信任假设

- 部署者（EOA）持有 `TimeBoostStaking` 全部管理员权限：`notifyRewardAmount`、`setRewardsDuration`、`setLockTier`、`setBoostMultiplier`、`setEarlyMintDeadline`，同时是 ST/RT 的 minter
- **单点信任**：无多签、无时间锁。管理员密钥泄露 = 可注入/调整奖励参数、增发代币，直接影响系统运行
- **建议**：生产部署前将 owner 转移至多签钱包（或治理合约）；本项目为演示/教学用途，保留 EOA 单点，使用者应知悉该信任假设

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
# 全部测试（含主网 Fork 集成测试，需配置 MAINNET_RPC_URL，见下方说明）
source .env && forge test -vvv

# 仅单元测试（日常开发推荐，跳过 Fork 测试）
forge test -vvv --no-match-contract ForkTest
```

> 结构树中的 `test/fork/ForkTest.t.sol` 是主网 Fork 集成测试，运行时需要主网 RPC。
> 请在 `.env` 中配置 `MAINNET_RPC_URL`（与 `SEPOLIA_RPC_URL` 同级），并在 `foundry.toml` 的 `[rpc_endpoints]` 中声明 `mainnet = "${MAINNET_RPC_URL}"`（项目已配置好）。
> 未配置该变量时，请使用 `--no-match-contract ForkTest` 跳过 Fork 测试，否则 `forge test` 会在 Fork 测试处失败。

### 测试覆盖率

运行 `forge coverage` 生成覆盖率报告（Fork 测试需主网 RPC，覆盖率统计时已排除）：

```bash
forge coverage --no-match-contract ForkTest
```

当前覆盖率（`forge coverage` 输出摘要）：

| 文件 | 行覆盖率 | 语句覆盖率 | 分支覆盖率 | 函数覆盖率 |
|------|---------|-----------|-----------|-----------|
| `script/Deploy.s.sol` | 0.00% (0/22) | 0.00% (0/27) | N/A (0/0) | 0.00% (0/1) |
| `src/BoostCredential.sol` | 100.00% (8/8) | 100.00% (7/7) | 100.00% (2/2) | 100.00% (3/3) |
| `src/RewardToken.sol` | 100.00% (3/3) | 100.00% (1/1) | N/A (0/0) | 100.00% (2/2) |
| `src/StakeToken.sol` | 100.00% (3/3) | 100.00% (1/1) | N/A (0/0) | 100.00% (2/2) |
| `src/TimeBoostStaking.sol` | 100.00% (122/122) | 98.46% (128/130) | 95.65% (44/46) | 100.00% (17/17) |
| `test/base/BaseTest.t.sol` | 70.00% (14/20) | 66.67% (12/18) | N/A (0/0) | 100.00% (2/2) |
| **Total** | **84.27% (150/178)** | **80.98% (149/184)** | **95.83% (46/48)** | **96.30% (26/27)** |

> `script/Deploy.s.sol` 为部署脚本，不参与业务逻辑测试，覆盖率 0% 属正常

### 部署（Sepolia 示例）
```bash
source .env
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url sepolia --broadcast --verify --slow
```

> 需在 `.env` 中配置 `PRIVATE_KEY`（部署者私钥，不带 0x 前缀）、`SEPOLIA_RPC_URL` 与 `ETHERSCAN_API_KEY`，并在 `foundry.toml` 中声明对应 `[rpc_endpoints]` 与 `[etherscan]` 配置。

---

## 十、当前部署地址（Sepolia）

| 合约 | 地址 |
|------|------|
| `StakeToken` (ST) | `0x883C776249c222FB64E9e8AF3b73d347d3bb2C62` |
| `RewardToken` (RT) | `0x6232bBf8a28f79c6d3DD79Af5FAaaD740a0B77EF` |
| `BoostCredential` | `0x20b6C425b483251571d2dcC607Bf064Edb901Da2` |
| `TimeBoostStaking` | `0xA9123f73Fa2068bDc5BB690bE35f0BF94C7b619F` |

- 初始奖励：100,000 RT 已注入，`rewardRate ≈ 3.215 × 10^16 wei/秒`（约 0.032 RT/秒，已除以 1.2 折算凭证加成）
- 源码验证：待后续完成
