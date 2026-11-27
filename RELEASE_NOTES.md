# v1.7.1 — 安全加固与文档/发行一致性修复

> 本版本是对 v1.7.0 的一次**安全修补**，不含新玩法功能。修改依据是对 v1.7.0 tag 源码与 Release 附件的逐行审查（共 6 个附件、SHA-256 与官方 digest 6/6 一致）。
> 升级后请重新核对 `config.json`：`WEB_AUTO_SYNC`、`AUTO_UPDATE` 两个自动入口现在默认关闭，需要你显式打开。

## 1. 资金安全（高危）

1. **网页合约同步不再能污染授权对象**。旧版在 RPC 不可用时 `valid={}`，`valid[k] !== false` 恒为 true，网页上任意地址都会被写回 `config.json`，随后成为 USDT `approve` 的 spender。现在：
   - 链上校验必须**显式返回 true** 才接受；RPC 不可用 / 校验失败时**一个地址都不写回**；
   - `QUEUE_ADDR` / `USDT_ADDR` / `MINER_QUEUE_ADDR` / `MARKET_ADDR` 作为资金相关字段**默认冻结**，需显式设置 `WEB_SYNC_ALLOW_FUNDS_KEYS: true`；
   - ABI 文本启发式的识别结果只用于提示，**绝不写回**；
   - `WEB_AUTO_SYNC` 默认改为 `false`，`--sync-web` 会打印每个被拒绝字段及原因；
   - 移除了 `FTS_ADDR` / `PAIR_ADDR` 两个永远没人读的死配置键（现货价本来就从市场合约的 `fts()` / `pair()` 读取）。
2. **取消"填 0 = 授权钱包全部 USDT 余额"**。旧版 `[15] 授权额度` 填 0 会把当前全部余额授权给队列合约，与 README「不做无限授权」直接冲突。现在：
   - 填 0 一律回落到「按 1 场票价」；
   - 按场数模式最多 3 场、按 U 数模式最多 100 U；
   - 余额不足一轮票价时直接跳过，不再发起注定无意义的 `approve`；
   - 文案修正：`approve` 不锁定资金，减小的是 **spender 可划走的上限**，不是「资金占用」。
3. **强制更新不再打断抢单**。旧版等满 2 小时后 `force=true` 会跳过 `isBusyForRestart()`，在交易在途时下载替换并 `exit 90`。现在无论推迟多久都先判断忙碌状态，超时只提示手动执行 `--update`；`isBusyForRestart()` 也补上了「抢位窗口内 / 结算开轮中」两个时点。
4. **自动更新开关与 token 解绑**。旧版向导把 `AUTO_UPDATE` 写成 `UPDATE_TOKEN.length > 0`，公开仓库用户跑完 `--init` 后自动更新其实全程关闭。现在 `[10]` 独立询问开关，公开仓库无需 token 即可更新；401/403 会区分「需要 token」与「API 限流」，限流时退避而不是每 10 秒刷一次 API；下载改用 `browser_download_url` 而不是易触发 403 的 API asset 端点。

## 2. 更新链与依赖供应链（中危）

- `SHA256SUMS.txt` 现在由 `build/build.py` 统一生成，并用 GitHub Release API 返回的 `digest` 做**交叉校验**（脚本本体与校验和文件都核对），不再只信任同源的校验和文本；Windows 覆盖前保留带时间戳的多份备份。
- 校验和行改为精确匹配文件名，预发布版本号（如 `1.8.0-beta`）在 `cmpVer()` 中正确低于正式版。
- 发版工作流改为 **tag 触发**（`v*`）+ 手动触发，不再「任何 push 到 main 就自动发版」；同版本号再次构建会 `--clobber` 覆盖附件而不是静默跳过；Release 正文统一读取仓库里的 `RELEASE_NOTES.md`。
- `ethers` 固定为 `6.15.0`、`ws` 固定为 `8.18.0`，安装带 `--ignore-scripts --save-exact`，装完校验 `require('ethers').version`；**移除第三方 npm 镜像自动回退**，Windows 版不再自动用 winget 安装 Node.js。
- 向导 `[7] 添加账号` 在明文私钥落盘前即时校验「私钥是否对应该地址」，不匹配直接拒绝写入。
- `cmdEncrypt()` 删除了无效的 `raw && (()=>{})()` 空操作，并如实说明 JS 字符串无法可靠清零。
- `UPDATE_TOKEN` 明文写入 `config.json` 一事在 README 与向导里明确提示。

## 3. 功能 bug

- **FTS 自动卖出**：新增「已有自己的活跃挂单不重复挂」「冷却 `TRADE_SELL_COOLDOWN_MS`（默认 5 分钟）」「累计上限 `TRADE_SELL_MAX_ORDERS`（默认 1）」三道闸门，修掉条件持续满足时无限重复 `createOrder` 的问题。
- **FTS 自动买入**：`今日已花费` 落盘到 `trade-state.json`（按自然日、保留 7 天），重启不再清零。
- **现货价**：`token0` 既不是 FTS 也不是 USDT 时返回 `null`，不再用错储备算出错误价格去挂单。
- **多账号**：挂单扫描过滤所有自有账号，不再只比较 `instances[0]`。
- **ABI 兜底**：上下文窗口从 6000 字符收紧到 600 字符，候选地址不唯一时一律放弃识别。

## 4. 文档、注释与一致性

- README 里 3 处 `shishengh/FTS-Queue-Bot` 改为实际仓库 `0041995/FTS-Queue-Bot`；修正「启动时不会检查更新 / 启动即检测更新」自相矛盾、两处「不做无限授权」冲突、「没有任意转账能力」「无后台服务」等不实陈述。
- 如实列出全部外联域名：BSC RPC/WSS 节点、`fatris.fans`、`api.github.com`、`registry.npmjs.org`、`1rpc.io`（推荐人识别）、`nodejs.org`（仅文档链接）。
- 「全站扫描」改为准确描述：有上限抽样（完整扫描最多 15 页 / 40 个 JS / 2 轮 chunk，启动轻量扫描最多 8 个 JS），不再声称「全部」「实测 27 个」。
- 引擎日志版本 `2.2-v8` 统一为发行包版本 `1.7.1`；`core.js` 里「不在启动时查」的过时注释全部更正。
- CI 回归测试补上原先漏跑的 `test/web-sync.js`、`test/trade.js`，并新增 `test/safety-guards.js`、`test/update-vercmp.js`、`test/release-consistency.js`。
- `dist/` 发行版产物入库，`VERSION`、`README.md`、`RELEASE_NOTES.md`、两个启动器模板、示例配置、`SHA256SUMS.txt` 全部对齐到 1.7.1。

## 5. 已知限制（请务必阅读）

- `SHA256SUMS.txt` 与脚本仍来自**同一个 GitHub Release**，没有离线签名或固定公钥作为独立信任根；API `digest` 交叉校验只是多一层一致性检查。能发布 Release 的人理论上仍可同时替换两者。最稳妥的做法是自行 `python3 build/build.py` 重建并比对。
- 公共 RPC 返回的状态没有多节点交叉验证，被篡改/滞后的节点数据仍可能影响入场判断。
- 未实盘连接 BSC 验证合约；本版本的所有测试都是本地桩测试，不涉及链上资金。
- 这是链上资金游戏，中奖由 Chainlink VRF 决定，脚本不保证盈利；请只用亏得起的小额资金与专用小号。

## 6. 校验方式

```bash
python3 build/build.py          # 重建 dist/ 并生成 SHA256SUMS.txt
cd dist && sha256sum -c SHA256SUMS.txt
bash -n dist/autofts.sh
node --check src/core.js && node --check src/probe.js && node --check src/update.js
```

首次使用仍按 `--probe → --init → --selftest → --dry-run → --run` 走一遍。
