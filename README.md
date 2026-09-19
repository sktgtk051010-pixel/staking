# DeFi Staking Protocol

一个基于 Foundry 的 ERC20 质押挖矿协议：**质押 STAKE 代币，按时间产出 REWARD 代币奖励；锁仓时间越长奖励倍率越高；持有早期 ERC1155 凭证的用户额外获得奖励加成。**

---

## 一、核心设计（本项目的三个重点）

### 设计一：周期预算制奖励分配

**思路**：项目方每个周期划定固定奖励预算，把预算均摊到每秒，用户按质押份额比例分得奖励；周期结束后由管理员重新注入奖励开启下一周期。

**为什么用这个方案**：
1. **成本精确可控**——每周期奖励总量固定，发完即止，避免无限增发的通胀失控
2. **周期轮换便于市场监控**——项目方每 30 天根据市场情况决定下个周期加码或收缩，奖励发放成为运营杠杆
3. **实现简单安全**——周期结束奖励自动停止，天然避免"奖励池枯竭"边界问题

**核心状态变量**：

| 变量 | 含义 |
|------|------|
| `rewardRate` | 每秒奖励量 = 周期预算 / 周期秒数 |
| `periodFinish` | 当前周期结束时间戳 |
| `lastUpdateTime` | 上次结算时间戳 |
| `rewardPerTokenStored` | 累计每单位质押份额对应的奖励（放大 1e18 防精度丢失） |

**核心函数**：

| 函数 | 权限 | 说明 |
|------|------|------|
| `notifyRewardAmount(uint256)` | onlyOwner | 注入新周期奖励，计算 `rewardRate = 数量 / duration`，设定 `periodFinish = now + duration`；内置"奖励速率不超过合约余额"的防超发检查 |
| `setRewardsDuration(uint256)` | onlyOwner | 设置周期长度（默认 30 天），设置后有锁定期保护 |
| `stake(uint256, uint256)` | 用户 | 选择锁仓档位并质押 |
| `unstake()` | 用户 | 锁仓到期后取回本金并领取全部奖励 |
| `getReward()` | 用户 | 随时领取已累积奖励（不影响本金与锁仓） |
| `earned(address)` / `pendingReward(address)` | view | 查询待领取奖励 |

**参数定稿**：

| 参数 | 数值 | 设定逻辑 |
|------|------|---------|
| `rewardsDuration` | 30 天（2,592,000 秒） | 主流周期长度，兼顾演示与运营节奏 |
| 初始周期预算 | 10,000 REWARD | 则 `rewardRate ≈ 10,000 × 10^18 / 2,592,000 ≈ 3.86 × 10^15 wei/秒`（约 0.0039 REWARD/秒） |

> "**先定周期总预算 → 均摊到每秒**"，参考 Synthetix StakingRewards 的 `rewardRate + periodFinish` 模型。奖励预算可计算、可审计、可监控，是 DeFi 中最经典的奖励发放模式。

---

### 设计二：锁仓档位与奖励倍率（时间加权激励）

**思路**：用户在质押时自选锁仓档位，锁得越久，单位时间获得的奖励倍率越高；锁仓期内不能提取本金。

**参数定稿**：

| 档位 | 锁仓时长 | 奖励倍率 |
|------|---------|---------|
| 0 | 不锁 | 1.0x |
| 1 | 7 天 | 1.05x |
| 2 | 30 天 | 1.15x |
| 3 | 90 天 | 1.3x |

> 倍率在合约内以 1e18 为精度存储（`1.0x = 1e18`，`1.3x = 1.3e18`）。

**为什么这样设**：
1. **90 天封顶、最高 1.3x，温和不激进**——参考 Convex vlCVX 的"16 周封顶"逻辑，避免用户资金被锁过久；1.3x 是"温和激励"区间，经济模型好解释
2. **分档而不是线性衰减**——参考 Convex 的分档设计（对比 Curve veCRV 的线性衰减），用户一眼看懂"锁越久赚越多"
3. **演示友好**——7 天档在测试中用 `vm.warp()` 跳时间即可验证，无需真实等待
4. **对齐市场**——Curve 的 LP 奖励加成现实中位 boost 约 1.87x（且需锁满 4 年），本项目 90 天封顶 1.3x 属于合理区间

**规则**：
- 质押时选定档位，`unlockTime = now + lockDuration`
- **锁仓期内不能提取本金**（不设计提前解锁惩罚，保持逻辑简洁；惩罚机制作为生产环境扩展项）

---

### 设计三：ERC1155 早期参与凭证（可转让的权益加成）

**思路**：项目早期（管理员控制开关），新质押用户自动获得 1 张 ERC1155 凭证（每个地址最多 1 张）；持有凭证的用户在质押时奖励**额外 ×1.2**。早期窗口关闭后不能再铸造。

**凭证设计：可转让**（对应本项目的定位是"权益凭证"而非"身份凭证"）。

**为什么可转让**：
1. **凭证本质是权益资产**——早期参与者可以把凭证转让给迟到的人，凭证本身有流动性和价值（参考 Convex cvxCRV 可流通、Velodrome veNFT 有二级市场）
2. **实现成本一样**——ERC1155 默认即可转让；不可转让反而要 override 转账函数（多写代码）
3. **规律对齐市场**——代表"身份/治理权"的凭证不可转让（veCRV、SBT），代表"权益/资产"的凭证可转让（cvxCRV、veNFT）；本项目凭证属于后者

**加成判定规则**：**按当前持有者判断**（`balanceOf(msg.sender) > 0`）。凭证转给他人后，原持有者不再享受加成，新持有者享受——权益跟着凭证走，市场自然定价。

**最终奖励计算公式**：

```
用户奖励 = 质押份额占比 × 流逝时间 × rewardRate × 锁仓倍率 × 凭证加成(1.2x，若有)
```

**凭证合约**：

| 函数 | 权限 | 说明 |
|------|------|------|
| `mintBoostCredential(address)` | onlyOwner | 铸造凭证，一个地址最多一张 |
| `userHasBoost(address)` | view | 查询用户是否持有凭证 |
| `BOOST_TOKEN_ID` | - | 凭证 tokenId = 0 |

---

## 二、业务流程图

```
① 项目方调用 notifyRewardAmount() 注入周期奖励
② 用户选择锁仓档位，stake() 质押 STAKE 代币
       │
       ├─ 早期用户 → 额外获得 ERC1155 凭证（+20% 加成）
       │
③ 时间流逝 → 按 份额占比 × rewardRate × 锁仓倍率 × 凭证加成 累积奖励
④ 用户随时 getReward() 领取已累积奖励（不影响本金）
⑤ 锁仓到期 → unstake() 取回本金 + 最后一次奖励
⑥ 周期结束 → 管理员重新注入奖励，开启下一周期
```

---

## 三、合约架构

| 合约 | 职责 | 依赖 |
|------|------|------|
| `StakeToken.sol` | 质押本金代币（ERC20，可 mint 用于测试/演示） | OpenZeppelin ERC20 |
| `RewardToken.sol` | 奖励代币（ERC20） | OpenZeppelin ERC20 |
| `BoostCredential.sol` | 早期凭证（ERC1155，tokenId=0，每地址一张） | OpenZeppelin ERC1155 + Ownable |
| `TimeBoostStaking.sol` | 核心质押合约：质押/领取/取回/锁仓倍率/凭证加成 | SafeERC20 + Ownable + ReentrancyGuard + BoostCredential |

```
src/
├── BoostCredential.sol      # ERC1155 早期凭证
├── RewardToken.sol          # 奖励代币
├── StakeToken.sol           # 质押代币
└── TimeBoostStaking.sol     # 核心质押挖矿合约
```

---

## 四、管理员功能（onlyOwner）

| 函数 | 说明 |
|------|------|
| `notifyRewardAmount(uint256)` | 注入周期奖励，开启/续接奖励周期 |
| `setRewardsDuration(uint256)` | 设置周期长度（默认 30 天） |
| `setLockTier(uint256, uint256, uint256)` | 调整锁仓档位（时长、倍率） |
| `mintBoostToUser(address)` | 给早期用户铸造 ERC1155 凭证 |
| `setBoostMultiplier(uint256)` | 调整凭证加成倍率（默认 1.2e18） |
| `toggleEarlyMint(bool)` | 开/关早期凭证铸造窗口 |
| `setRewardRate(uint256)` | 调整每秒奖励速率（备用） |

---

## 五、安全设计

| 风险 | 防护 |
|------|------|
| 重入攻击 | `ReentrancyGuard` 防重入锁 |
| 非标准 ERC20 转账陷阱 | `SafeERC20` |
| 精度丢失 | 奖励与倍率均放大 1e18 计算 |
| 奖励超发 | `notifyRewardAmount` 内置余额检查（rewardRate 不超过合约可支付余额） |
| 提前提款 | 锁仓时间强制校验 `block.timestamp >= unlockTime` |
| 凭证刷量 | 每地址最多 1 张凭证；加成按当前持有者判定 |

---

## 六、设计取舍（答辩要点）

1. **单用户单笔质押**（简化版）：代码清晰、好审计、gas 省；生产环境可扩展为多笔质押数组
2. **凭证可转让**：权益型凭证允许流通，与 SBT 身份型凭证形成对比
3. **锁仓期不可提前退出**：不做惩罚扣款，保持逻辑最简；惩罚机制作为扩展项
4. **奖励会计 O(1) 复杂度**：用 `rewardPerTokenStored + rewardDebt` 累计模型，不遍历所有用户，用户越多越省 gas

---

## 七、参考与依据

- **Synthetix StakingRewards**：`rewardRate + periodFinish` 周期预算模型出处
  https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
- **SushiSwap MasterChef**：按区块/周期发放奖励、奖励阶段机制
  https://github.com/sushiswap/sushiswapV1/blob/master/sushiswap/contracts/MasterChef.sol
- **Curve veCRV**：时间加权投票/收益模型、不可转让治理凭证（作为对比参考）
  https://docs.curve.finance/
- **Convex vlCVX**：分档/封顶锁仓设计（16 周封顶）
  https://docs.convexfinance.com/
- **Velodrome veNFT / cvxCRV**：权益型凭证可转让/可流通的参考
  https://cryptogloss.io/glossary/ve-tokenomics/

---

## 八、开发环境与使用

### 环境要求
- Foundry（forge 1.x）
- Solidity 0.8.24

### 安装依赖
```bash
forge install foundry-rs/forge-std --no-commit
forge install openzeppelin/openzeppelin-contracts --no-commit
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

## 九、测试计划

| 测试文件 | 覆盖内容 |
|---------|---------|
| `test/StakingTest.t.sol` | 质押/领取/取回主流程、周期机制（跳时间验证）、锁仓时间校验 |
| `test/BoostTest.t.sol` | 凭证铸造（每人一张）、加成计算、凭证转让后加成跟随持有者 |
| `test/AdminTest.t.sol` | 管理员权限、防超发检查、档位调整 |
| `test/InvariantTest.t.sol` | 不变量：总质押量守恒、合约奖励余额不低于已累计待发 |

---

## 十、项目状态

- [x] 设计定稿（本 README）
- [ ] 合约实现（src/）
- [ ] Foundry 单元测试（test/）
- [ ] 部署脚本（script/）
- [ ] Sepolia 部署 + Etherscan 源码验证
- [ ] README 覆盖率数据补充
