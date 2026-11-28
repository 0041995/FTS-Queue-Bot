# v1.8.5 — 修复半残节点 eth_call 不支持导致的读轮次失败

基于 v1.8.4。修复"房间读取当前轮次失败: missing revert data | The method eth_call is not supported."

**诊断**：不是没有轮次，是节点 `bsc.meowrpc.com` 的半残行为——读 USDT decimals 能过，读队列合约却明确返回 "The method eth_call is not supported."。它被选中后，每轮读轮次都失败。

1. **剔除 meowrpc**：从默认节点池移除（探测/实测均证实其队列 eth_call 不可用）。
2. **探测加严**：节点探测除了读 USDT decimals，再读队列合约 `roomCount()`（selector `0xdf93a4e3`，正常返回 4）。只读 USDT 能过但读队列失败的半残节点，在探测阶段就被筛掉。
3. **运行时自动冷却换节点**：新增 `isNodeCallUnsupported()`，把 "eth_call is not supported" 识别为节点故障（不是业务 revert）。`mgr.rpc` 遇到这类错误会**冷却该节点 5 分钟并立即切换重试**，不再一直打废节点刷 CALL_EXCEPTION。
4. 顺带把网络类错误（`isNetworkErr`）也纳入同样的冷却切换路径。

**验证**：新增测试覆盖（37 项），18 个测试文件全过。实测 `--run` 60 秒：5/5 节点健康，`eth_call is not supported` **0 次**，读轮次失败 **0 次**。

---

# v1.8.4 — 修复 selftest 节点超时 / 依赖安装无交互

基于 v1.8.3。修复你遇到的 selftest 卡在"合约存在性"后 TIMEOUT 退出：

1. **剔除失效节点**：官方 dataseed 系列 eth_call 实测 8~13s 超时，全部从默认池移除；换成 6 个实测正常节点（blastapi / meowrpc / publicnode×2 / 48club / sentio）。兜底节点也改掉。
2. **探测短超时**：新增 `PROBE_TIMEOUT_MS`（默认 5s），探测节点用短超时，坏节点快速淘汰；正式 RPC 仍用 12s。
3. **rotate 并行探测**：原来串行逐个等 12s，现在一次并行探测所有候选取最快可用。
4. **修复 selftest 真正的 bug**：selftest 的合约对象固化在旧 provider 上，切换节点后仍打失效节点。现在每次重试都重绑到当前 provider，换节点真正生效。
5. **依赖安装无交互**：`--install` 加 `CI=1` + `npm_config_yes=true` + `--yes`，杜绝 y/n 提示卡住自动化（stdin 关闭也能装成功）。

**货币价格说明**：买卖挂单/吃单走市场合约 `createOrder`/`fillOrder`；查币价不走市场挂单价，而是通过 `market.pair()` 拿 DEX 交易对地址、读 `getReserves()` 储备算真实 USDT/FTS 价。逻辑未改，保持正确。

新增 `test/node-and-install.js`（32 项），18 个测试文件全过。实测 selftest 23 秒完成、零超时告警。

---

# v1.8.3 — 依赖安装完全自动化 / 国内多镜像 / 新增 --install

> 基于 v1.8.2：
> 1. **完全自动化的依赖安装**：不再只是检测提醒，缺失即自动安装；`ethers`/`ws` 固定版本、禁安装脚本、装完校验。
> 2. **只用国内公开镜像**（实测三个全部可用）：npmmirror → 华为云 → 腾讯云，依次自动切换；**官方源禁用**。可用 `FTS_NPM_REGISTRIES` 覆盖。
> 3. **新增 `--install` 参数**：仅安装/修复依赖，装完退出，不做链上操作、不需要钱包。命令共 8 个。
> 4. 新增 `test/dep-install.js`（18 项），共 17 个测试文件全过。

---

# v1.8.2 — 命令精简为 7 个 / 探测并入 probe / 加密可选自动化

> 基于 v1.8.1：
> 1. **命令精简为 7 个**：`--settings` 合并进 `--init`（改设置重跑 `--init`）；删除 `--encrypt` 和 `--stop`（停止用 Ctrl+C）。保留 `--probe`/`--init`/`--selftest`/`--dry-run`/`--run`/`--update`/`--help`。
> 2. **`--probe` 开头先探测网页合约**（sync-web），再链上只读探测；失败不阻断。
> 3. **加密可选+自动**：设了 `FTS_WALLET_PASSWORD` 时，`--init` 保存账号后、以及运行 `--selftest`/`--dry-run`/`--run` 前自动加密；没设则保持明文不阻断。密码只从环境变量读。
> 4. 新增 `test/auto-encrypt.js`（4 项），共 16 项测试全过。

---

# v1.8.1 — 修复加密启动 / 网页同步可配 / 每日场次限制

> 基于 v1.8.0，三项改动：
> 1. **修复**：加密 `wallets.json` 后，`--selftest`/`--run` 等官方入口会报"wallets.json 无效或为空"而退出。外壳校验遇到 `encrypted:true` 现在跳过，交由引擎解密后再校验（sh/ps1 都修）。
> 2. **网页合约同步开关**：`WEB_AUTO_SYNC` / `WEB_SYNC_ALLOW_FUNDS_KEYS` 不再被向导强制写死为 false，init 新增 [16] 可配置。开启资金字段写回后，网页换队列/USDT/市场合约能自动更新。默认仍关闭。
> 3. **每日场次限制**：init 新增 [17] 全局上限（默认 0=关闭），账号管理 [3] 可为单账号单独设。计数按本地日期、写入 `entry-counter.json`，重启不清零；入场成功后计数，dry-run 不计。
>
> 新增 `test/daily-limit.js`（11 项），共 14 项测试全通过。

---

# v1.8.0 — 零行为变化的资源占用优化

> **本版的约束：优化不得让脚本变不稳定，不得漏掉场次 / 领取，不得抬高入场延迟；关键数据严格按 v1.7.1 原样。**
> 因此本版只保留「不改变任何链上请求时序、不改变任何判定结果」的四处资源占用改动，其余早期性能优化方案**全部放弃**。
> 基于 v1.7.1 tag（`37ee59f`）逐字节基线重建，可用 `git diff v1.7.1 v1.8.0` 逐行核对。

---

## 0. 关键数据对照表（左列全部与 v1.7.1 一致，未改）

| 项目 | v1.7.1 | v1.8.0 | 为什么不动 |
|---|---|---|---|
| HTTP 轮询间隔 `POLL_INTERVAL_MS` | **1500ms** | **1500ms** | 改成 30s 心跳会在 WS 假连接 / 丢块时抬高入场延迟，可能漏掉抢位窗口与场次 |
| WS stale 判据 `WS_STALE_MS` | 45000ms | 45000ms | 原样 |
| `currentRound` 读取 | 每次实时读链 | 每次实时读链 | 加 2s 缓存会让领取轮次判断滞后，可能错过领取窗口 |
| `TRADE_BUY_SCAN_N` | **200** | **200** | 缩到 60 会漏掉较早挂出的低价单 |
| 买单扫描 | 每轮实时全表扫 | 每轮实时全表扫 | 加 8s 结果缓存会基于过期挂单做决策 |
| 卖单 `scanMyActiveOrders` | 独立扫描 | 独立扫描 | 复用买单扫描会漏掉自有挂单，破坏 v1.7.1 的「不重复挂单」闸门 |
| nonce 自愈巡检 | 串行 latest/pending | 串行 | 并行化改动请求时序，牵涉 nonce 正确性 |
| 矿机产出领取巡检 | 串行逐金库 | 串行 | 用户明确要求「不能漏掉领取」，不动 |
| 启动器写引擎文件 | **每次启动重写** | **每次启动重写** | 原版「每次重写」是发行包与运行时文件一致的保障，跳过写盘会让被篡改/损坏的文件一直留着 |
| 网页合约探测 JS 下载 | 各阶段各自 fetch | 各阶段各自 fetch | 不动资金相关字段的识别链路 |
| 并发默认值 `RPC_MAX_CONCURRENT` | 12 | 12 | 原样（仅修正注释笔误） |
| 授权 / 抢位 / 资金字段冻结 / 自动更新开关 | 全部 v1.7.1 逻辑 | 全部 v1.7.1 逻辑 | 一行未改 |

**结论：抢单、领取、授权、轮询、更新这五条主链路，本版与 v1.7.1 逐字节等价。**

---

## 1. 本版实际改动（四项，均不改变业务结果）

### 1.1 `withTimeout()` 清理超时定时器
`Promise.race` 不会取消落败分支：RPC 正常返回后，那个 12s 的超时 `setTimeout` 仍会挂到到点，高频调用下累积大量「已完成但仍待触发」的 Timeout 句柄。现在用 `finally { clearTimeout(timer) }` 清理。

- 正常 resolve 的返回值、超时时的抛错时机与 `code: 'TIMEOUT'` 错误对象**完全一致**；
- 本地实测：1000 次立即 resolve 的调用，活跃 Timeout 句柄 **1000 → 0**；
- 同仓库 `fetchText()` 与 `update.js` 的 `api()` 本来就是这么写的，这里只是补齐。

### 1.2 `errSeen` 加容量上限与 TTL
`errOnce` / `warnOnce` 的节流 key 归一化只替换十进制数字，tx.hash 这类长十六进制串会不断产生新 key，`errSeen` 是 v1.7.1 里唯一没有上限的 Map，长期挂机内存单调增长。现在：

- 长十六进制串整体归一化为 `HEX`（顺序在十进制归一化之前，避免 hash 被先切碎）；
- 容量上限 2000、TTL 5 分钟淘汰；
- 节流 key 仍带 `addr`，不会把不同账号的告警合并。

**只影响「同一条告警是否重复打印」，不参与任何交易 / 领取 / 入场判定。**

### 1.3 `NodePool.pick()` 线性化
原先每次 RPC 都 `filter` + `slice` + `sort`（两份临时数组 + O(n log n)）。改为一次线性扫描找 `(load, latency)` 最小者，零临时分配。

- 新增回归测试用 **200 组随机负载 / 延迟 / 冷却状态**与旧 `sort` 实现对比，选节点结果**逐项一致**；
- 节点池、分层并发闸门、冷却判定、重试逻辑全部原样。

### 1.4 `fts-*.log` 按大小滚动
外壳对 `console-*.log` 有 20MB 滚动，但引擎自己写的 `fts-YYYYMMDD.log` 只有按天分文件、无大小上限。现在按 `FTS_LOG_MAX_MB`（默认 20）切到 `fts-YYYYMMDD.N.log` 序号文件。用「切新文件」而非 rename，避开 `stream.end()` 异步与同名重建的竞态。`console.log` 保留（外壳 `tail -f` 依赖它做实时展示）。

### 1.5 纯文档 / 测试
- 修正注释「默认并发=8」的笔误（代码默认 12，8 是单测注入的边界值）；
- README 新增 `ROOMS` 示例值为何是 `[0]` 的 FAQ（**不改示例值**：改成 `[0,1,2]` 会让复制配置的人多跑两个房间、多花资金）；
- 新增 `test/perf-guards.js`；CI 回归测试从 13 项增至 14 项；
- `VERSION` / README / RELEASE_NOTES / `core.js` 回落版本 / 发行产物 / SHA256SUMS 全部对齐 1.8.0。

---

## 2. 主动放弃的优化（及放弃原因）

| 方案 | 放弃原因 |
|---|---|
| WS 健康时 HTTP 轮询降为 30s 心跳 | **会抬高入场延迟**；WS 连着但不推块、或丢块时，1.5s 轮询是最后的兜底。省下的请求不值得拿漏场次冒险 |
| `currentRound` 复用共享状态 / 2s 短缓存 | 领取轮次判断可能滞后，命中「不能漏掉领取」 |
| 买单扫描窗口 200→60 + 8s 结果缓存 | 属于关键数据变更，且可能基于过期挂单决策 |
| Multicall 聚合 `orders(id)` | 需引入未经核验的外部聚合合约地址，新增信任根；且要验证公共节点响应体上限 |
| 事件驱动维护活跃挂单集合 | 新状态机 + 重启后重建，需实盘压测 |
| 三个后台巡检合并成全局单例协程 | 改变请求时序，牵涉 nonce 自愈正确性 |
| `Semaphore.acquire()` 把最小间隔改成提交时刻节流 | 这是防 429 的保护，改动必须压测确认不触发限流 |
| 启动器 `.new` + `cmp` 跳过写盘 | 破坏「每次启动重写引擎文件」的一致性保障；且 Node 24 下 `--check xxx.new` 会报 `ERR_UNKNOWN_FILE_EXTENSION`，是实测踩过的坑 |
| 两次 BOM 清理合并成一次 node 冷启动 | 收益极小，且属于启动链改动，一并放弃 |
| Windows 启动链同等优化 | PowerShell 5.1/7 兼容层语法不同，沙盒无 pwsh 可做等价验证 |

---

## 3. 升级注意

- **`config.json` 无需任何改动**，新增字段为零；所有默认值与 v1.7.1 相同。
- 唯一新增可选环境变量是 `FTS_LOG_MAX_MB`（日志滚动阈值，默认 20），不设也完全一样。
- `fts-*.log` 可能出现 `.1` / `.2` 后缀的滚动文件，外壳 7 天清理的 glob `fts-*.log` 仍能覆盖。
- 升级后仍建议按 `--probe → --init → --selftest → --dry-run → --run` 走一遍。

---

## 4. 验证方式

```bash
python3 build/build.py                 # 重建 dist/ 并生成 SHA256SUMS.txt
cd dist && sha256sum -c SHA256SUMS.txt
bash -n dist/autofts.sh
node --check src/core.js && node --check src/probe.js && node --check src/update.js && node --check dist/update.js
node test/perf-guards.js               # 定时器 / 节流表 / 节点选择等价性 / 关键数据未被改动
node test/release-consistency.js       # 版本、产物、校验和一致性
# 其余 12 项 v1.7.1 原有回归测试全部原样保留并通过
```

另外可直接核对稳定性基线：

```bash
git diff v1.7.1 v1.8.0 -- src/core.js     # 应只有 4 处资源改动 + 版本/注释
git diff v1.7.1 v1.8.0 -- config.example.json templates/   # 应为空
```

---

## 5. 已知限制（继承 v1.7.1，仍然成立）

- `SHA256SUMS.txt` 与脚本仍来自**同一个 GitHub Release**，没有离线签名或固定公钥作为独立信任根；API `digest` 交叉校验只是多一层一致性检查。能发布 Release 的人理论上仍可同时替换两者。最稳妥的做法是自行 `python3 build/build.py` 重建并比对。
- 公共 RPC 返回的状态没有多节点交叉验证，被篡改/滞后的节点数据仍可能影响入场判断。
- 未实盘连接 BSC 验证合约；本版本的所有测试都是本地桩测试，不涉及链上资金，也未做 24 小时真实多账号压测。
- 这是链上资金游戏，中奖由 Chainlink VRF 决定，脚本不保证盈利；请只用亏得起的小额资金与专用小号。
