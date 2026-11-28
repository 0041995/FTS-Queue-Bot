#!/usr/bin/env node
/**
 * v1.8.0 资源占用护栏 + 稳定性基线回归测试
 *
 * 本版承诺：优化不得改变抢单 / 领取 / 轮询 / 授权的任何时序与关键数据。
 * 覆盖:
 *   1) withTimeout 清理超时定时器，且返回值 / 超时错误对象与原版一致
 *   2) errSeen 容量上限 + 长十六进制整体归一化（只影响日志节流）
 *   3) NodePool.pick 线性化后与 v1.7.1 的 sort 实现选节点逐项一致（200 组随机）
 *   4) 【稳定性断言】关键数据严格保持 v1.7.1：1.5s 轮询、200 扫描窗口、
 *      实时 currentRound、启动器每次重写、无降频 / 无缓存 / 无并行化改动
 *   5) 日志按大小滚动
 *
 * 做法与现有测试一致：从 core.js 抽取源码段，用 new Function 注入可控桩。
 * 用法: node test/perf-guards.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const text = fs.readFileSync(path.join(ROOT, 'src', 'core.js'), 'utf8');
const tpl = fs.readFileSync(path.join(ROOT, 'templates', 'autofts.sh.tpl'), 'utf8');
const example = JSON.parse(fs.readFileSync(path.join(ROOT, 'config.example.json'), 'utf8'));

function ex(a, b) {
  const i = text.indexOf(a), j = text.indexOf(b, i);
  if (i < 0 || j < 0) throw new Error('抽取标记缺失: ' + a);
  return text.slice(i, j);
}
const errors = [];
const assert = (c, m) => { if (!c) errors.push(m); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  // ---- 1) withTimeout：行为不变，只清句柄 ----
  const wtSrc = ex('function withTimeout(p, ms, label) {', '// ---------------- ABI');
  const withTimeout = new Function(wtSrc + '\nreturn withTimeout;')();
  const timeouts = () => typeof process.getActiveResourcesInfo === 'function'
    ? process.getActiveResourcesInfo().filter(x => x === 'Timeout').length : -1;
  const base = timeouts();
  const vals = await Promise.all(Array.from({ length: 1000 }, (_, i) => withTimeout(Promise.resolve(i), 12000, 'perf')));
  await new Promise(r => setImmediate(r));
  const after = timeouts();
  assert(vals[999] === 999, '正常 resolve 的返回值必须原样透传');
  if (base < 0) {
    assert(/clearTimeout\(timer\)/.test(wtSrc), 'withTimeout 源码必须 clearTimeout');
  } else {
    assert(after <= base + 2, `withTimeout 应清理定时器: 基线 ${base} -> ${after}`);
    console.log(`✅ withTimeout: 1000 次快速调用后 Timeout 句柄 ${base} -> ${after}`);
  }
  let timedOut = false, errCode = '';
  try { await withTimeout(new Promise(() => { }), 20, 'x'); }
  catch (e) { timedOut = true; errCode = e.code; }
  assert(timedOut && errCode === 'TIMEOUT', '超时分支仍须抛 code=TIMEOUT 的错误');
  assert(vals.every((v, i) => v === i), '1000 次调用结果必须全部正确');

  // ---- 2) errSeen 容量上限（只影响日志，不参与判定）----
  const errSrc = ex('const errSeen = new Map();', '// ---------------- 错误详情');
  const em = new Function('log', 'C', errSrc + '\nreturn {errSeen, errOnce, warnOnce, normErrKey};')(
    () => { }, { g: '', y: '', r: '', b: '', d: '' });
  const alpha = i => {
    let s = '', n = i;
    do { s += String.fromCharCode(97 + (n % 26)); n = Math.floor(n / 26); } while (n > 0);
    return s;
  };
  for (let i = 0; i < 5000; i++) em.errOnce('acct', 'boom ' + alpha(i), 0);
  assert(em.errSeen.size <= 2000, `errSeen 应 <=2000，实际 ${em.errSeen.size}`);
  assert(em.normErrKey('tx 0xabcdef0123456789abcdef0123456789abcdef01 failed') === 'tx HEX failed',
    '长十六进制串应被整体归一化');
  assert(em.normErrKey('超时 12000ms') === '超时 #ms', '十进制数字仍应归一化');
  console.log(`✅ errSeen: 5000 个不同 key 后容量 = ${em.errSeen.size} (上限 2000)`);

  // ---- 3) NodePool.pick 与 v1.7.1 sort 实现等价 ----
  const semSrc = ex('class Semaphore {', 'const rpcGate =');
  const poolSrc = ex('function nodeTier(url) {', 'const nodePool = new NodePool');
  const CFG = { CHAIN_ID: 56, NODE_POOL_ENABLED: true, NODE_TIER_CONCURRENCY: { fast: 14, slow: 12 }, RPC_MIN_SPACING_MS: 0 };
  const ethersStub = { JsonRpcProvider: class { constructor(u) { this.url = u; } } };
  const Semaphore = new Function('CFG', 'sleep', semSrc + '\nreturn Semaphore;')(CFG, sleep);
  const rpcGate = { run: async fn => fn() };
  const { NodePool } = new Function('CFG', 'ethers', 'Semaphore', 'rpcGate', 'sleep',
    poolSrc + '\nreturn {nodeTier, NodeConn, NodePool};')(CFG, ethersStub, Semaphore, rpcGate, sleep);
  const pool = new NodePool([
    'https://a.bnbchain.org', 'https://b.bnbchain.org',
    'https://c.publicnode.com', 'https://d.publicnode.com'
  ]);
  // v1.7.1 原始实现（逐字抄录，用于对比）
  const oldPick = preferred => {
    const healthy = pool.nodes.filter(n => n.available);
    const p = healthy.length ? healthy : pool.nodes;
    if (preferred && preferred.available && preferred.load < 0.9) return preferred;
    return p.slice().sort((a, b) => (a.load - b.load) || (a.latency - b.latency))[0];
  };
  let mismatch = 0;
  for (let it = 0; it < 200; it++) {
    for (const n of pool.nodes) {
      n.ok = Math.random() > 0.25;
      n.cooldownUntil = Math.random() > 0.8 ? Date.now() + 60000 : 0;
      n.gate.n = Math.floor(Math.random() * (n.gate.max + 1));
      n.latency = Math.floor(Math.random() * 500);
    }
    const pref = Math.random() > 0.5 ? pool.nodes[Math.floor(Math.random() * pool.nodes.length)] : null;
    if (pool.pick(pref).url !== oldPick(pref).url) mismatch++;
  }
  assert(mismatch === 0, `pick() 应与 v1.7.1 一致，200 组里 ${mismatch} 组不同`);
  console.log('✅ NodePool.pick: 200 组随机负载与 v1.7.1 sort 实现选节点完全一致');

  // ---- 4) 【核心】关键数据严格保持 v1.7.1 ----
  assert(/, 1500, 'POLL_INTERVAL_MS'/.test(text), 'POLL_INTERVAL_MS 默认必须仍是 1500ms');
  assert(/await sleep\(CFG\.POLL_INTERVAL_MS\);/.test(text), '轮询循环必须仍按 1.5s sleep');
  assert(!/POLL_IDLE_MS|wsHealthy|FTS_POLL_IDLE_MS/.test(text),
    '禁止出现 WS 降频心跳（会抬高入场延迟 / 漏场次）');
  assert(/, 200, 'TRADE_BUY_SCAN_N'/.test(text), 'TRADE_BUY_SCAN_N 默认必须仍是 200');
  assert(/const orders = await scanMarketOrders\(market, CFG\.TRADE_BUY_SCAN_N\);/.test(text),
    '买单必须每轮实时全表扫描，不得复用缓存');
  assert(!/scanMarketOrdersCached|TRADE_SCAN_CACHE_MS|marketScanCache/.test(text),
    '禁止给挂单扫描加缓存（会基于过期数据决策）');
  assert(/const mine = await scanMyActiveOrders/.test(text), '卖单必须保留独立扫描');
  assert(!/getCurrentRound|roundIdCache/.test(text), '禁止给 currentRound 加缓存（领取轮次可能滞后）');
  assert(/inst\.queue\.currentRound\(room\)/.test(text), 'currentRound 必须实时读链');
  assert(!/getCurrentRound\(room\)/.test(text), '不得替换为缓存版 currentRound');
  assert(!/const jsBodies = new Map\(\)/.test(text), '网页合约探测链路保持原样');
  assert(!/Promise\.all\(\[\s*mgr\.rpc\(p => p\.getTransactionCount/.test(text),
    'nonce 巡检保持串行，不改请求时序');
  assert(example.TRADE_BUY_SCAN_N === undefined && example.POLL_IDLE_MS === undefined,
    'config.example.json 不得新增会改变默认值的关键项');
  assert(/, 12, 'RPC_MAX_CONCURRENT'/.test(text), '并发默认值必须仍是 12');
  // 启动器：原版每次重写，禁止 .new + cmp 跳过写盘
  assert(/cat << 'CORE_EOF' > core\.js/.test(tpl), '启动器必须每次重写 core.js');
  assert(!/core\.js\.new/.test(tpl) && !/cmp -s/.test(tpl),
    '禁止 .new + cmp 跳过写盘（原版每次重写是一致性保障）');
  assert(/node --check core\.js/.test(tpl), '启动器语法检查保持原版');
  console.log('✅ 稳定性基线: 1.5s 轮询 / 200 扫描窗口 / 实时 currentRound / 启动器每次重写 / 串行巡检 / 并发 12 全部原样');

  // ---- 5) 日志滚动 ----
  assert(/LOG_MAX_BYTES/.test(text) && /logSeq\+\+/.test(text), '日志应按大小滚动到序号文件');
  assert(/logStream\.write\(line \+ '\\n'\)/.test(text), '日志写入行为保持');
  console.log('✅ 日志: 按 FTS_LOG_MAX_MB 切序号文件，console 输出保留');

  console.log('');
  if (errors.length === 0) { console.log('✅ 全部通过: v1.8.0 资源优化未改变任何业务时序与关键数据'); process.exit(0); }
  console.log('❌ 失败:'); errors.forEach(e => console.log('   -', e));
  process.exit(1);
})().catch(e => { console.error(e); process.exit(2); });
