#!/usr/bin/env node
/**
 * 节点池修复 + 依赖安装无交互 回归测试
 *
 * 验证:
 *   1) 默认节点池不含已失效的 dataseed/binance 官方节点
 *   2) 探测用独立短超时 PROBE_TIMEOUT_MS，且 probe 实际用它
 *   3) rotate 并行探测(Promise.all)，不再串行 for+await
 *   4) 币价来自 DEX pair 储备，不读市场挂单价；买卖走 market
 *   5) sh/ps1 的 npm install 都带 --yes + CI=1 + npm_config_yes
 *
 * 用法: node test/node-and-install.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const core = fs.readFileSync(path.join(ROOT, 'src', 'core.js'), 'utf8');
const sh = fs.readFileSync(path.join(ROOT, 'templates', 'autofts.sh.tpl'), 'utf8');
const ps = fs.readFileSync(path.join(ROOT, 'templates', 'autofts.ps1.tpl'), 'utf8');
let pass = 0, fail = 0;
const check = (n, c, d) => { if (c) { pass++; console.log('  ✅ ' + n); } else { fail++; console.log('  ❌ ' + n + (d ? ' -> ' + d : '')); } };

// 1) 节点池
const bad = ['bsc-dataseed.bnbchain.org', 'bsc-dataseed1.bnbchain.org', 'bsc-dataseed2', 'bsc-dataseed3', 'bsc-dataseed4', 'bsc-dataseed1.binance.org'];
for (const b of bad) check('默认池不含失效节点 ' + b, !core.includes("'https://" + b + "'"));
for (const g of ['bsc-mainnet.public.blastapi.io', 'bsc-rpc.publicnode.com', 'bsc.rpc.sentio.xyz', 'rpc-bsc.48.club', 'bsc.publicnode.com']) {
  check('默认池含正常节点 ' + g, core.includes("'https://" + g + "'") || core.includes('https://' + g));
}

// 1b) meowrpc 半残节点已剔除
check('默认池不含 meowrpc(不支持队列eth_call)', !core.includes("'https://bsc.meowrpc.com'"));

// 2) 探测超时
check('有 PROBE_TIMEOUT_MS 配置项', /PROBE_TIMEOUT_MS:\s*cfgNum/.test(core));
const probeFn = core.slice(core.indexOf('async probe(url)'), core.indexOf('async pickBest()'));
check('probe 用 PROBE_TIMEOUT_MS 探测 getBlockNumber', probeFn.includes('CFG.PROBE_TIMEOUT_MS') && probeFn.includes('getBlockNumber'));
check('probe 用 PROBE_TIMEOUT_MS 探测 eth_call', probeFn.includes('CFG.PROBE_TIMEOUT_MS') && probeFn.includes('eth_call'));
check('probe 额外探测队列合约 roomCount()', probeFn.includes('0xdf93a4e3') && probeFn.includes('CFG.QUEUE_ADDR'));
check('有 isNodeCallUnsupported 识别函数', /function isNodeCallUnsupported/.test(core));
check('探测识别不支持eth_call的半残节点', /eth_call is not supported/.test(core));
check('mgr.rpc 把节点故障纳入transient', /nodeBroken/.test(core) && /isNodeCallUnsupported\(lastErr\)/.test(core));
check('节点故障时冷却5分钟', /nodeBroken \? 300000/.test(core));

// 3) rotate 并行
const rotateFn = core.slice(core.indexOf('async _rotate()'), core.indexOf('async rpc(fn'));
check('rotate 用 Promise.all 并行探测', rotateFn.includes('Promise.all'));
check('rotate 不再串行 for await probe', !/for\s*\(let i[\s\S]*await this\.probe/.test(rotateFn));

// 4) 币价链路
const priceFn = core.slice(core.indexOf('async function getFtsSpotPrice'), core.indexOf('async function scanMarketOrders'));
check('查价走 market.pair()', priceFn.includes('market.pair()'));
check('查价走 pair.getReserves()', priceFn.includes('pair.getReserves()'));
check('查价不读市场挂单价', core.includes('从 DEX pair 储备算 USDT/FTS，不读市场挂单价'));
check('买卖走 market.createOrder/fillOrder', core.includes("method: 'createOrder'") && core.includes("method: 'fillOrder'"));

// 4b) selftest 合约对象随节点轮换重建
check('selftest 有 bindSelftest 重绑函数', /function bindSelftest\(p\)/.test(core));
check('selftest 注册了 onRotate 重绑', /mgr\.onRotate\(bindSelftest\)/.test(core));
check('selftest probe 每次重试重绑 provider', core.includes('bindSelftest(p); return withTimeout(fn()'));
check('selftest 无固化 const qRead/uRead', !/const qRead = new ethers\.Contract/.test(core));

// 5) npm 无交互
const shNpm = sh.split('\n').filter(l => l.includes('npm install --yes'));
check('sh npm install 带 --yes', shNpm.length > 0);
check('sh npm install 带 CI=1', shNpm.some(l => l.includes('CI=1')));
check('sh npm install 带 npm_config_yes', shNpm.some(l => l.includes('npm_config_yes=true')));
const psNpm = ps.split('\n').filter(l => l.includes('.Source install --yes'));
check('ps1 npm install 带 --yes', psNpm.length > 0);
check('ps1 设 CI=1', ps.includes("$env:CI = '1'"));
check('ps1 设 npm_config_yes', ps.includes("$env:npm_config_yes = 'true'"));
check('ps1 用 try/finally 恢复环境变量', ps.includes('finally') && ps.includes('$env:CI = $oldCI'));

console.log('');
if (fail === 0) { console.log('✅ 全部通过 (' + pass + ' 项)'); process.exit(0); }
console.log('❌ ' + fail + ' 项失败 / 共 ' + (pass + fail) + ' 项'); process.exit(1);
