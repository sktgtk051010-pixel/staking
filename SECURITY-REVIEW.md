# TimeBoostStaking 安全自查报告

> 文件名：`SECURITY-REVIEW.md`
> 项目：TimeBoostStaking（Foundry 质押激励协议）
> 代码版本：`1634ba1e752f626ccc307b61ac541ff54750b0e1`（2026-11-05，`fix: 修改文档`）
> 报告日期：2026-11-07
> 性质：**自查（Self-Review）**，非第三方审计

## 目录

1. [范围与方法](#1-范围与方法)
   - [1.1 审查对象](#11-审查对象)
   - [1.2 方法与工具](#12-方法与工具)
   - [1.3 未覆盖范围](#13-未覆盖范围)
2. [架构与资产流](#2-架构与资产流)
   - [2.1 合约关系](#21-合约关系)
   - [2.2 资产流（每条路径的状态更新顺序）](#22-资产流每条路径的状态更新顺序)
   - [2.3 权限矩阵](#23-权限矩阵)
3. [发现清单](#3-发现清单)
4. [Slither 工具输出裁决](#4-slither-工具输出裁决)
   - [4.1 扫描概况](#41-扫描概况)
   - [4.2 Medium（4 条，同一根因）逐条裁决](#42-medium4-条同一根因逐条裁决)
   - [4.3 Low / Informational / Optimization 分组归并](#43-low--informational--optimization-分组归并)
   - [4.4 工具局限（必须说明）](#44-工具局限必须说明)
5. [风险维度索引](#5-风险维度索引)
6. [测试证据](#6-测试证据)
   - [6.1 测试清单](#61-测试清单)
   - [6.2 关键性质 → 测试映射](#62-关键性质--测试映射)
   - [6.3 复现命令](#63-复现命令)
   - [6.4 覆盖率快照](#64-覆盖率快照)
   - [6.5 独立手算核对（连续操作）](#65-独立手算核对连续操作)
7. [结论与建议](#7-结论与建议)
   - [7.1 总体结论](#71-总体结论)
   - [7.2 是否需要重新部署](#72-是否需要重新部署)
   - [7.3 待办分级](#73-待办分级)

---

## 1. 范围与方法

### 1.1 审查对象

| 类别 | 文件 |
|---|---|
| 核心合约 | `src/TimeBoostStaking.sol` |
| 代币 | `src/StakeToken.sol`、`src/RewardToken.sol` |
| 凭证 | `src/BoostCredential.sol` |
| 测试 | `test/AdminTest.t.sol`、`test/BoostTest.t.sol`、`test/StakingTest.t.sol`、`test/MultiStakeTest.t.sol`、`test/base/BaseTest.t.sol` |
| Fork 测试 | `test/fork/ForkTest.t.sol` |

`src/` 共 4 个业务合约、339 行；`test/` 共 6 个文件、884 行。

### 1.2 方法与工具

1. **静态分析**：Slither 0.11.5 + solc 0.8.24 + Foundry 1.7.1，全量扫描 `src/`（`--filter-paths "lib/" --exclude-dependencies`）。分析 29 个合约 / 101 个 detector，输出 **17 条结果：0 High、4 Medium、9 Low、3 Informational、1 Optimization**。
2. **人工复核**：按 detector 分组复核，逐条判定误报 / 已缓解 / 真实缺陷；判据包括权限修饰器、可达性、定点数截断方向、CEI 顺序、重入锁。
3. **权限链梳理**：从 owner、minter、凭证铸造者、用户四个角色出发，还原"谁能动什么"（见 §2.3）。
4. **测试验证**：现有 Foundry 测试 78 个（本地 69 + 主网 Fork 9，全部通过）+ 关键安全性质映射（见第 6 章）；覆盖率口径见 §6.4。

### 1.3 未覆盖范围

- 部署脚本（`script/`）、第三方依赖（`lib/`）、前端与脚本工具；
- 经济攻击的组合场景（MEV、跨协议组合操纵；本协议不依赖外部价格预言机）；
- 形式化验证、模糊测试的深度覆盖（仅有不变量测试）

---

## 2. 架构与资产流

### 2.1 合约关系

```
StakeToken (ST, ERC20)          RewardToken (RT, ERC20)
      │  用户 approve + 质押            │  owner 注入奖励
      ▼                                ▼
┌─────────────────────────────────────────────┐
│           TimeBoostStaking                  │
│  Ownable + ReentrancyGuard                  │
│  immutable: STAKE_TOKEN / REWARD_TOKEN /    │
│             BOOST_CREDENTIAL                │
└─────────────────────────────────────────────┘
      │ owner 调用 mintBoostCredential
      ▼
BoostCredential (ERC1155, id=0)  ← owner 已在部署时转给 Staking
```

- `TimeBoostStaking` 通过 `immutable` 持有三个外部合约引用（`src/TimeBoostStaking.sol` L17-19），部署后不可更换——即使 owner 被攻破也无法把资金导向恶意代币合约。
- `BoostCredential` 的 owner 在部署脚本中转移给 `TimeBoostStaking`，凭证只能由 Staking 在 `stake()` 内部按条件铸造。

### 2.2 资产流（每条路径的状态更新顺序）

资产在**用户、TimeBoostStaking、三个代币/凭证合约**之间流动：

```
用户 ──approve(ST) + stake(amount, tier)──▶ TimeBoostStaking
                                                │
              ┌─────────────────────────────────┼─────────────────────────────────┐
              ▼                                 ▼                                 ▼
      _accrueReward                     写状态：stakes[stakeId]           ST.safeTransferFrom
 （结算 rpT / lastUpdateTime）          totalStaked / userStakeIds        用户 → Staking（拉本金）
              │                                                                   │
              └────────────────────────────┬──────────────────────────────────────┘
                                           ▼
                    〔早期窗口 + 单笔 ≥ 1000 ST + tx.origin == msg.sender + 未铸过〕
                                           ▼
                     BoostCredential(id=0).mint ──▶ 用户（ERC1155，可转让）
```

**领奖路径**：`getReward()` ──▶ `_accrueReward`（只记账，不动本金）──▶ `RT.safeTransfer`（Staking → 用户）

**撤回路径**：`unstake(stakeId)` ──▶ 校验归属/存在/已解锁 ──▶ `_accrueReward` ──▶ 删 `stakes[stakeId]` + 扣 `totalStaked` + `_removeStakeId` ──▶ RT 奖励 + ST 本金 → 用户

**注入路径**：owner `notifyRewardAmount(amount)` ──▶ `_accrueReward` ──▶ `RT.safeTransferFrom`（owner → Staking）──▶ 重算 `rewardRate` / `periodFinish`

**凭证加成路径**：用户持仓凭证 ──▶ 后续 `stake` 的 `lockMultiplier` ×`boostMultiplier` 生效 ──▶ 积分段表按新倍率 push 新页（不改历史页）

| 路径 | 入口 | 状态更新 → 外部交互 | 位置 |
|------|------|---------------------|------|
| 质押 | 用户 `approve` ST 后调 `stake(amount, tier)` | 先结算 rpT/lastUpdateTime → 写入 `stakes` / `totalStaked` / `userStakeIds` → 最后 `safeTransferFrom` 拉入本金 → 条件满足时铸造凭证 | L96-127 |
| 领奖 | `getReward()` | `_accrueReward` 只记账（更新 rpT、每笔 `rewardDebt`）→ 记账完成后 `safeTransfer` RT | L130-136、L276-289 |
| 取本金 | `unstake(stakeId)` | 校验归属/存在/解锁 → 记账 → 删除记录、扣减 `totalStaked` → 最后转 RT 奖励 + 转 ST 本金 | L140-161 |
| 注入奖励 | owner `notifyRewardAmount(amount)` | 结算 rpT → `safeTransferFrom` 拉入 RT → 计算 `rewardRate`/`periodFinish` | L194-212 |
| 凭证铸造 | `stake()` 内部 | 早期窗口 + 金额 ≥ 1000 ST + `tx.origin == msg.sender` + 未铸造过 → `mintBoostCredential` | L119-124 |

关键点：三条用户路径都遵循严格 CEI（所有状态修改在外部转账之前），且均带 `nonReentrant`；`notifyRewardAmount` 也带 `nonReentrant` 并先拉币后改速率，不存在"改完速率但币没到账"的窗口。

### 2.3 权限矩阵

| 角色 | 可调用 | 能力 | 单点风险 |
|------|--------|------|----------|
| owner | `notifyRewardAmount` | 注入奖励、决定 `rewardRate` 与周期起点 | 可停止/改变奖励发放节奏 |
| owner | `setRewardsDuration` | 改周期长度（仅周期结束后） | 影响下一周期预算折算 |
| owner | `setLockTier` | 改档位时长与倍率（1.0x~5x） | 不影响历史质押（每笔倍率在质押时快照进 `lockMultiplier`） |
| owner | `setBoostMultiplier` | 改凭证加成（1.0x~2x，仅周期结束后） | 仅影响调整后新增奖励（分段记账） |
| owner | `setEarlyMintDeadline` | 延长/缩短凭证窗口 | 影响凭证发放范围 |
| owner | ST/RT `mint` | **无限增发两种代币** | 最大中心化风险：可凭空增发 RT 注入或 ST 稀释 |
| owner（经 Staking 转发） | `mintBoostCredential` | 发凭证 | 受 `hasMinted` 限制，每地址一张 |
| 任意用户 | `stake` / `getReward` / `unstake` | 存取本金、领奖 | 无权限门槛 |

**信任假设**：owner 为单一 EOA，无多签、无时间锁。管理员密钥泄露 = 可增发代币、改奖励参数。这是本项目最大的中心化风险（详见 §3 SR-05 与 README §八"管理员信任假设"）。

---

## 3. 发现清单

| ID | 严重性 | 标题 | 位置 | 状态 |
|---|---|---|---|---|
| SR-01 | Info（设计） | 同切点覆盖末页的分段记账 | `TimeBoostStaking.sol#L84-85`、`#L246-255` | 已确认 |
| SR-02 | Low | 段数随周期数线性增长，结算 gas 上升 | `TimeBoostStaking.sol#L309-319` | 接受 |
| SR-03 | Low（设计） | 空池期预算沉淀，误转入资产不可提取 | `TimeBoostStaking.sol#L202`、`#L342` | 接受 |
| SR-04 | Info（设计） | 凭证门槛依赖 `tx.origin`，合约钱包拿不到 | `TimeBoostStaking.sol#L47`、`#L119-124` | 已确认 |
| SR-05 | Medium（设计） | owner 为单一 EOA，可增发并改全部参数 | `StakeToken.sol`、`RewardToken.sol`、`TimeBoostStaking.sol`（管理面） | 接受 |
| SR-06 | Low | 定点数先除后乘，单笔误差 ≤ 2 wei | `TimeBoostStaking.sol#L107-112`、`#L287`、`#L300-310` | 接受 |
| SR-07 | Low（设计） | 凭证转让按实时持有者判定，未结算区间加成作废 | `TimeBoostStaking.sol#L281`、`BoostCredential.sol#L31-33` | 接受 |

### SR-01 同切点覆盖末页的分段记账

- **位置**：`TimeBoostStaking.sol#L84-85`、`#L246-255`
- **代码**：
  ```solidity
  // 构造函数：锁定初始页，承载周期 1 的 rpT 起点
  cutRpt.push(0);
  cutBoost.push(boostMultiplier);

  // setBoostMultiplier：末页切点等于当前 rpT 时覆盖，否则追加新页
  if (cutRpt.length > 0 && cutRpt[cutRpt.length - 1] == rewardPerTokenStored) {
      cutBoost[cutBoost.length - 1] = newMultiplier;
  } else {
      cutRpt.push(rewardPerTokenStored);
      cutBoost.push(newMultiplier);
  }
  ```
- **描述**：凭证加成以"切点 rpT + 该段倍率"分段计息。owner 只能在周期结束后调倍率，调整前先把 rpT 结算到当前；若末页切点恰好等于结算后的 rpT（周期已结束、无新增奖励），就直接覆盖末页倍率，不追加新页。
- **影响链**：构造函数 push 的 `(0, 1.2e18)` 是零宽初始页 → 它固定了历史页的起点，后续任何 push 都不会把新倍率倒灌进历史 rpT 区间 → 历史奖励永不被覆盖；同切点覆盖又使段表不随反复调整膨胀。
- **建议**：维持现状。3 个守护测试：`test_SetBoostMultiplier_CoverKeepsHistoricalRewards`、`test_SetBoostMultiplier_NewPeriod_PushesNewPage`、`test_SetBoostMultiplier_RepeatedAfterEnd_CoversLastPage`。
- **状态**：已确认正确。

### SR-02 段数随周期数线性增长

- **位置**：`TimeBoostStaking.sol#L309-319`
- **代码**：
  ```solidity
  uint256 total = 0;
  for (uint256 i = 0; i < cutBoost.length; i++) {
      uint256 segEnd = (i + 1 < cutBoost.length) ? (effectiveAmount * cutRpt[i + 1]) / 1e18 : type(uint256).max;
      if (prevPos >= segEnd) continue;
      if (prevPos >= nowPos) break;
      ...
  }
  ```
- **描述**：正常运营（每个周期结束后最多调一次倍率）下，每次调整追加一页，30 天周期约 12 段/年。持证用户每次结算从自己的结算起点遍历到当前页。
- **影响链**：段数 → 循环次数 → 单次领奖 gas。每页只是少量 SLOAD 与算术，数百段时 gas 明显上升但仍在可执行范围；这是**效率边界，不是安全漏洞**。
- **建议**：记录为已知边界；若段数达数百，把结算起点改为二分定位（README §4.4 已留门，本次不实现）。
- **状态**：接受。

### SR-03 空池期预算沉淀

- **位置**：`TimeBoostStaking.sol#L202`、`#L342`
- **代码**：
  ```solidity
  // 空池时 rpT 增量返回 0，该段时间的预算不累积
  function _freshRewardPerToken() internal view returns (uint256) {
      if (totalStaked == 0) return 0;
      return ((_lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
  }
  ```
- **描述**：三处资金效率取舍：① `totalStaked == 0` 时 rpT 增量为 0，空池期预算留在合约；② `rewardRate` 按 `boostMultiplier`（初始 1.2x）折算预留，持证率不足时全池实发低于名义预算（0% 持证时约 83%）；③ 误转入合约的 ST 与质押本金混存，无单独提取入口。
- **影响链**：不影响任何用户应得收益（"先按最大加成预留"消除了超发风险），只降低资金利用率；沉淀部分无法回收。
- **建议**：属"防超发"的固有权衡，接受；若要回收沉淀，需新增管理员提取函数，且要重新设计记账以免破坏预算守恒。
- **状态**：接受（README §八 风险 3）。

### SR-04 凭证门槛依赖 tx.origin

- **位置**：`TimeBoostStaking.sol#L47`、`#L119-124`
- **代码**：
  ```solidity
  if (
      block.timestamp < earlyMintDeadline && stakeAmount >= MIN_STAKE_FOR_CREDENTIAL && tx.origin == msg.sender
          && !BOOST_CREDENTIAL.hasMinted(msg.sender)
  ) {
      BOOST_CREDENTIAL.mintBoostCredential(msg.sender);
  }
  ```
- **描述**：凭证门槛 = 早期窗口（部署后 7 天）+ 单笔 ≥ 1000 ST + `tx.origin == msg.sender` + 每地址一次。
- **影响链**：`tx.origin` 判断挡掉了"一个 EOA 反复部署合约批量刷号"，但同时让智能合约钱包（多签、AA 钱包）无法获得凭证——属于**有意的防女巫取舍**，误伤是已知代价。
- **建议**：维持；若未来要支持合约钱包，改为白名单或签名凭证。
- **状态**：设计确认。

### SR-05 owner 为单一 EOA

- **位置**：`StakeToken.sol`、`RewardToken.sol`（`mint`）、`TimeBoostStaking.sol`（全部 `onlyOwner` 函数）
- **权限面**：
  - ST / RT 的 `owner` 可无限 `mint`；
  - Staking 的 `owner` 可 `notifyRewardAmount` / `setRewardsDuration` / `setLockTier` / `setBoostMultiplier` / `setEarlyMintDeadline`。
- **描述**：部署者 EOA `0xfD56…d7A` 同时是三个合约的管理员，无多签、无时间锁。
- **影响链**：密钥泄露或作恶 → 可凭空增发 RT 注入奖励、增发 ST 稀释份额、改档位与凭证倍率改变后续收益结构 → 用户对本金安全与代币供给的信任完全依赖单一私钥。
- **建议**：生产部署前把 owner 转多签/治理合约，并对参数变更加时间锁。演示用途保留 EOA 并明示。
- **状态**：接受（演示用途，README §八 管理员信任假设）。

### SR-06 定点数先除后乘

- **位置**：`TimeBoostStaking.sol#L107-112`、`#L287`、`#L300-310`
- **代码**：
  ```solidity
  // stake：有效份额 × rpT，两步除法
  rewardDebt: ((stakeAmount * tier.rewardMultiplier / 1e18) * rewardPerTokenStored) / 1e18,

  // _calcStakeReward：两处同口径截断
  uint256 effectiveAmount = (s.amount * s.lockMultiplier) / 1e18;
  uint256 nowPos = (effectiveAmount * currentRpt) / 1e18;
  ```
- **描述**：Slither 检出 4 处 `divide-before-multiply`（对应 §4.1 的 4 条 Medium），全部同一根因：1e18 定点数先除后乘。
- **影响链**：每层除法截断 < 1 wei，单笔单次误差 ≤ 2 wei（< 2×10⁻¹⁸ RT）；`stake` 与 `_accrueReward` 的 `rewardDebt` 公式完全同口径，两侧同时向下取整、差额不系统性放大；方向由用户承担，合约不超发。
- **建议**：详见 §4.2 裁决；当前规模无需改 `Math.mulDiv`。
- **状态**：接受。

### SR-07 凭证转让按实时持有者判定

- **位置**：`TimeBoostStaking.sol#L281`、`BoostCredential.sol#L31-33`
- **代码**：
  ```solidity
  // _accrueReward：每次结算现查凭证余额
  bool boosted = BOOST_CREDENTIAL.userHasBoost(user);
  ```
- **描述**：加成资格不按"持有区间"记账，而是在每次结算时按**当前**余额判定；`rewardDebt` 只记位置、不含加成。
- **影响链**：持证用户未结算就转让 → 下次结算时 `boosted = false` → 转让前那段本应 1.2x 的区间被按 1.0x 重算。实测见 `test_CredentialTransfer_UnsettledBoostLost`：1000 ST 不锁仓质押、持证 10 天后未结算即转让，损失为该 10 天基础奖励的 20%；先 `getReward()` 再转让则无损失（`test_CredentialTransfer_AfterSettle_NoLoss`）。
- **建议**：前端/文档提示"先领奖、再转让凭证"；彻底修复需在 ERC1155 转账回调里触发结算或按持有区间记账，成本高于收益，本次不做。
- **状态**：接受（用户可主动规避，不改变全池预算上限）。

---

## 4. Slither 工具输出裁决

### 4.1 扫描概况

| 项 | 值 |
|----|----|
| 工具版本 | Slither 0.11.5（solc 0.8.24，Foundry 1.7.1 构建） |
| 命令 | `slither . --filter-paths "lib/" --exclude-dependencies --json slither-report.json` |
| 分析规模 | 29 contracts / 101 detectors |
| 结果总数 | 17 条 |
| 严重性分布 | High **0** / Medium **4** / Low **9** / Informational **3** / Optimization **1** |
| 原始输出 | `slither-report.json`、`slither-console.txt`（项目根） |

| Detector | Impact / Confidence | 条数 | 位置摘要 |
|----------|--------------------|------|----------|
| `divide-before-multiply` | Medium / Medium | 4 | `stake` L107-112、`_accrueReward` L287、`_calcStakeReward` L300-301、L300+L310 |
| `timestamp` | Low / Medium | 9 | `stake` L120、`getReward` L132、`unstake` L143-155、`notifyRewardAmount` L201、`setRewardsDuration` L218、`setBoostMultiplier` L239/246、`setEarlyMintDeadline` L265、`_calcStakeReward` L312-315、`_lastTimeRewardApplicable` L337 |
| `naming-convention` | Informational / High | 3 | `STAKE_TOKEN` L17、`REWARD_TOKEN` L18、`BOOST_CREDENTIAL` L19 |
| `cache-array-length` | Optimization / High | 1 | `_calcStakeReward` 循环条件 L309 |

### 4.2 Medium（4 条，同一根因）逐条裁决

4 条 `divide-before-multiply` 全部来自同一设计：奖励计算使用 1e18 定点数，先算"有效份额 = 本金 × 倍率 / 1e18"，再乘 rpT。

| # | 位置 | Slither 指控 | 裁决 | 依据 |
|---|------|-------------|------|------|
| 1 | `stake` L107-112 | `((stakeAmount * tierMultiplier / 1e18) * rpt) / 1e18` 先除后乘 | **可接受（误报级）** | 截断只发生在两层除法，每层误差 < 1 wei；`rewardDebt` 记为向下取整值 |
| 2 | `_accrueReward` L287 | `rewardDebt` 更新同结构 | **可接受（误报级）** | 与 `stake` 的 `rewardDebt` 公式**完全同口径**，两侧同时向下取整，差额不会系统性放大 |
| 3 | `_calcStakeReward` L300-301 | `effectiveAmount` 与 `nowPos` 两层截断 | **可接受（误报级）** | 误差上界：< 2 wei（折合 < 2×10⁻¹⁸ RT）/ 笔·次，无可累积路径 |
| 4 | `_calcStakeReward` L300+L310 | `segEnd = (effectiveAmount * cutRpt[i+1]) / 1e18` 与 `nowPos` 同口径截断 | **可接受（误报级）** | 分段边界与位置用同一公式计算，边界比较（L312-315）不会因单侧误差错位超过 1 wei |

**量化结论**：对任意单笔质押的任意一次结算，截断造成的奖励差 ≤ 2 wei（1e18 缩放后 2×10⁻¹⁸ RT），且方向一致向下、由用户承担（合约不超发）。不存在"用截断差额累积套利"的可利用路径。

**可选改进（不必须）**：若追求零 dust，可改用 OZ `Math.mulDiv` 合并为单次乘除；代价是额外 gas 与代码复杂度。当前规模与精度要求下不改。

### 4.3 Low / Informational / Optimization 分组归并

**`timestamp`（9 条，Low）—— 裁决：可接受，业务必需**

- 协议本身以时间为记账轴：锁仓到期（L144）、周期结束（L201/L218/L239）、凭证窗口（L120/L265）、积分时间差（L337）。离开 `block.timestamp` 无法实现。
- 矿工/验证者可小幅偏移时间戳（PoS 下约秒级），影响范围：解锁时间提前/延后数秒、周期边界判定偏移数秒。**不改变预算守恒**——奖励总量由 `rewardRate × 实际时长` 决定，任何人在任意时点结算都不改变全池总支出上限。
- 边界行为已被测试覆盖：`test_RewardStopsAfterPeriod`、`test_Unstake_RevertWhen_StillLocked`、`test_SetBoostMultiplier_RevertWhen_PeriodNotFinished`。
- 结论：设计必需，无需修改；若未来接入 L2 需注意其时间戳语义（仍由 sequencer 提供，偏移风险类似）。

**`naming-convention`（3 条，Informational）—— 裁决：有意为之**

- `STAKE_TOKEN` / `REWARD_TOKEN` / `BOOST_CREDENTIAL` 是 `immutable` 的部署期常量，采用 UPPER_CASE 是 Solidity 社区表达"不可变常量"的惯例。纯风格项，不影响行为与安全。

**`cache-array-length`（1 条，Optimization）—— 裁决：记录，本次不修**

- `_calcStakeReward` 循环条件 `i < cutBoost.length`（L309）每次迭代读取 storage 数组长度（SLOAD）。缓存到局部变量可省少量 gas。
- 影响的只是持证用户领奖的 gas，不构成安全或正确性问题；且该循环的 gas 增长主因是段数（SR-02），缓存 length 只省常数项。与 SR-02 的二分优化一并评估，不在本次修。

### 4.4 工具局限（必须说明）

Slither 是模式匹配型静态分析，**不检查业务语义与经济不变量**。本项目最关键的三个性质——预算不超发、历史奖励不被新倍率覆盖、多笔质押互不干扰——Slither 都无法验证，只能靠人工走查（§3 SR-01）与测试（第 6 章）证明。因此"Slither 0 High"不能单独作为安全结论，必须与测试证据联合阅读。

---

## 5. 风险维度索引

本报告不复制风险正文，按维度指向 README §八 对应小节：

| 风险维度 | README 位置 | 本报告对应 |
|----------|-------------|-----------|
| 奖励超发（Reward Over-distribution） | §八 风险 1（L314-325） | SR-01、§4.2 |
| 重入攻击（Reentrancy） | §八 风险 2（L327-335） | §2.2 CEI 顺序 + `nonReentrant` |
| 空池期与预算沉淀 / 误转入资产滞留 | §八 风险 3（L337-346） | SR-03 |
| 其他安全设计（SafeERC20 / 精度 / 提前提款 / 凭证去重 / 溢出） | §八"其他安全设计"（L348-356） | SR-04、SR-06 |
| 管理员信任假设（单点 EOA） | §八"管理员信任假设"（L358-362） | SR-05 |
| 凭证加成资格变化（未结算转让） | §八"其他安全设计"（L348-356） | SR-07 |

---

## 6. 测试证据

### 6.1 测试清单

| 套件 | 测试数 | 覆盖重点 |
|------|--------|----------|
| `AdminTest.t.sol` | 28 | 通知奖励、周期、档位、倍率、凭证窗口、倍率变更经济性、全周期预算平衡 |
| `StakingTest.t.sol` | 21 | 质押/领奖/取回、锁仓、多笔上限、空池、预算守恒 |
| `BoostTest.t.sol` | 15 | 凭证铸造/转让/加成、女巫门槛、分段覆盖语义、转让结算边界 |
| `MultiStakeTest.t.sol` | 5 | 多笔独立解锁、多用户多笔、奖励核算隔离 |
| `ForkTest.t.sol` | 9 | 主网 Fork 基本流程验证（部署→质押→领奖→取回→凭证→到期，本次 9/9 通过） |
| **合计（本地）** | **69** | 全部通过（`forge test --no-match-contract ForkTest`） |
| **合计（含 Fork）** | **78** | Fork 9 条已单独跑通（`forge test --match-contract ForkTest`） |

### 6.2 关键性质 → 测试映射

| 安全性质 | 守护测试 | 位置 |
|----------|----------|------|
| 全池总支出 ≤ 注入预算 | `test_TotalPayout_NeverExceedsBudget` | `StakingTest.t.sol` L273 |
| 倍率调整不超发、不锁死 | `test_BoostChange_SingleUser_NoOverpay_NoLock` | `AdminTest.t.sol` L200 |
| 两用户场景下倍率调整不超发 | `test_BoostChange_TwoUsers_NoOverpay_NoLock` | `AdminTest.t.sol` L220 |
| 降倍率不静默吞奖励 | `test_BoostChange_Downgrade_NoSilentLoss` | `AdminTest.t.sol` L243 |
| 全周期：改倍率 + 重新注入后预算仍平衡 | `test_FullCycle_BoostChange_Reinject_BudgetBalanced` | `AdminTest.t.sol` L294 |
| 覆盖末页不损坏历史奖励 | `test_SetBoostMultiplier_CoverKeepsHistoricalRewards` | `BoostTest.t.sol` L175 |
| 新周期 push 新页 | `test_SetBoostMultiplier_NewPeriod_PushesNewPage` | `BoostTest.t.sol` L192 |
| 周期结束后反复调整不膨胀段表 | `test_SetBoostMultiplier_RepeatedAfterEnd_CoversLastPage` | `BoostTest.t.sol` L152 |
| 合约钱包/构造期调用不获凭证（防女巫） | `test_ContractWallet_Stake_MintsCredential`、`test_ConstructorStake_MintsCredential` | `BoostTest.t.sol` L114、L126 |
| 锁仓未到期不可取回 | `test_Unstake_RevertWhen_StillLocked` | `StakingTest.t.sol` L150 |
| 空池后可继续质押 | `test_Stake_AfterEmptyPool_Works` | `StakingTest.t.sol` L260 |
| 周期结束后奖励停止累计 | `test_RewardStopsAfterPeriod` | `StakingTest.t.sol` L239 |
| 多笔质押奖励核算互不串账 | `test_MultipleStakes_RewardAccountingIsolated` | `MultiStakeTest.t.sol` L76 |
| 凭证未结算即转让的加成损失（设计边界） | `test_CredentialTransfer_UnsettledBoostLost` | `BoostTest.t.sol` L215 |
| 先结算再转让凭证无损失 | `test_CredentialTransfer_AfterSettle_NoLoss` | `BoostTest.t.sol` L238 |

### 6.3 复现命令

```bash
# 全部本地测试（排除 Fork）
forge test --no-match-contract ForkTest

# 主网 Fork（forge 自动加载 .env，从中读 MAINNET_RPC_URL）
forge test --match-contract ForkTest

# 单条关键测试
forge test --match-test test_TotalPayout_NeverExceedsBudget -vvv
forge test --match-test test_SetBoostMultiplier_ -vvv

# 覆盖率
forge coverage --no-match-contract ForkTest
```

### 6.4 覆盖率快照

行覆盖率 **84.73% (172/203)**、语句 82.71% (177/214)、分支 96.36% (53/55)、函数 96.67% (29/30)。逐文件明细见 README §九"测试覆盖率"表（同一口径）。`script/Deploy.s.sol` 0% 属正常（部署脚本不参与业务测试）。

### 6.5 独立手算核对（连续操作）

不依赖合约内部实现，只用原始输入（预算、周期、倍率、质押额、时间）另算一遍，与合约 `earned()` 逐点比对。参数取 `BaseTest` 口径：预算 10,000,000 RT / 30 天、`boostMultiplier` = 1.2、无凭证。

手算公式（不读取 `rewardPerToken`、`earned`、`totalStaked`）：

```
每秒全池产出 = 10,000,000 ÷ (30 × 86,400) ÷ 1.2 = 3.2150205761 RT/s
某地址应得   = 每秒产出 × 区间秒数 × 该地址有效份额 ÷ 全池有效份额
```

场景：第 0 天 alice 质押 1000 ST（不锁仓，1.0x）；第 10 天 bob 质押 1000 ST（90 天档，1.6x，有效份额 1600）；第 20 天 alice 领奖。

| 核对点 | 手算应有 (RT) | 合约实得 (RT) | 差值 (wei) | 相对误差 |
|--------|---------------|---------------|-----------|----------|
| 第 10 天 `earned` | 2,777,777.777777777777777777 | 2,777,777.777777777777088000 | 689,777 | 2.48×10⁻¹⁹ |
| 第 20 天 `earned` | 3,846,153.846153846153846154 | 3,846,153.846153846152891000 | 955,154 | 2.48×10⁻¹⁹ |
| 领奖到账 | 3,846,153.846153846153846154 | 3,846,153.846153846152891000 | 955,154 | 2.48×10⁻¹⁹ |

**差值来源**：`notifyRewardAmount` L202 的 `rewardRate = (amount * 1e18) / (rewardsDuration * boostMultiplier)` 先做整数除法，每秒截掉约 0.8 wei；该偏差被 864,000 秒线性放大，两段各贡献数十万 wei。方向恒为"合约少于理论值"，与 §4.2 对 `divide-before-multiply` 的"向下、不超发"判定一致。

**判定**：绝对差随周期线性放大，故判据取相对误差 ≤ 1×10⁻¹⁵；本次 2.48×10⁻¹⁹，通过。领奖前后的 `earned` 与到账金额完全相等（3,846,153,846,153,846,152,891,000 wei），确认 `getReward` 无二次截断。

**取数方式**：用临时测试打印三个时间点的 `earned` 与到账额；复现按本节公式手算即可。

---

## 7. 结论与建议

### 7.1 总体结论

- **无 Critical / High 级问题**；Slither 17 条结果中 4 条 Medium 均为同根因的定点数截断提示，经量化裁决为可接受（误差 ≤ 2 wei/笔·次）；
- 3 个核心业务不变量（预算不超发、历史奖励不被覆盖、多笔独立）分别有专项测试守护，且 78 个测试全绿（本地 69 + 主网 Fork 9）；
- Sepolia 部署与双通道源码验证完成，链上字节码与本地源码一致。

### 7.2 是否需要重新部署

**不需要。** 所有 Medium 级为精度提示而非缺陷，修复收益低于重新部署的成本与风险（重新部署会更换全部地址并重置周期）。

### 7.3 待办分级

| 级别 | 事项 | 触发条件 |
|------|------|----------|
| **P1** | 生产部署前把 owner 转多签/治理合约（消除 SR-05 单点信任） | 从演示转为真实资产托管时 |
| **P1** | 把 ForkTest 纳入 CI（配置 `MAINNET_RPC_URL` secret） | 需要链上回归时 |
| **P2** | 段表结算改二分定位（SR-02），仅当累计段数达数百 | 长期运营后 |
| **P2** | 精度改用 `Math.mulDiv`（SR-06）、缓存循环 length（§4.3） | 有 gas/精度优化需求时 |
| **P2** | 沉淀资产回收函数（SR-03） | 产品需要回收空池沉淀时（需重新设计记账，避免破坏预算守恒） |
| **P2** | 前端提示“先领奖再转让凭证”（SR-07）；README §4.3 与 §八 已写明，剩余前端入口 | 有前端交互入口时 |

---
