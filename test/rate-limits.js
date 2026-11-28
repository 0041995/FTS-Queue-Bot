#!/usr/bin/env node
/**
 * 并发/吞吐参数配置自检回归测试
 *
 * 背景: 实测(P95 延迟)显示并发 8 最稳、16 是延迟恶化拐点、>16 只会吃 429；
 * 间隔 <20ms、错峰 <50ms 会让闸门形同虚设。validateCfg 必须把这些保护落实。
 *
 * 做法: 从 core.js 抽出 validateCfg，注入可控的 CFG，覆盖各种边界值，
 * 断言纠正结果符合预期。
 *
 * 用法: node test/rate-limits.js
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.dirname(__dirname);
const SRC = process.env.CORE_PATH || path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');
const start = text.indexOf('function validateCfg() {');
if (start < 0) { console.error('找不到 validateCfg'); process.exit(2); }
let depth = 0, end = -1;
for (let j = text.indexOf('{', start); j < text.length; j++) {
  if (text[j] === '{') depth++;
  else if (text[j] === '}') { depth--; if (depth === 0) { end = j + 1; break; } }
}
const fnSrc = text.slice(start, end);

function run(cfg) {
  const C = Object.assign({
    SNIPE_MIN_COUNT: 30, SNIPE_MAX_COUNT: 60, ROOMS: [0, 1, 2], HTTP_POOL: ['x'],
    CLAIM_LOOKBACK: 20, GAS_MIN_GWEI: 0.01, GAS_MAX_GWEI: 10, GAS_FIXED_GWEI: 0.05,
    CLAIM_INTERVAL_MS: 20000, TX_TYPE: 'auto', APPROVE_ROUNDS: 1, APPROVE_USD: null,
    GAP_STUCK_MS: 45000, MINER_USD: 100, MINER_ROOM: 0, MINER_CHECK_MS: 10000,
    MINER_MODE: 'old', MINING_CLAIM_MS: 45000, UPDATE_CHECK_MS: 1200000,
    UPDATE_IDLE_MARGIN: 15, UPDATE_MAX_DEFER_MS: 600000
  }, cfg);
  const stubs = { CFG: C, cfgProblems: [] };
  const factory = new Function(...Object.keys(stubs), fnSrc + '\nreturn validateCfg();');
  const problems = factory(...Object.values(stubs));
  return { CFG: C, problems };
}

const cases = [
  { name: '并发=8 边界(注入桩值)', cfg: { RPC_MAX_CONCURRENT: 8, RPC_MIN_SPACING_MS: 60, ACCOUNT_STAGGER_MS: 120 },
    check: r => r.CFG.RPC_MAX_CONCURRENT === 8 && r.problems.length === 0 },
  { name: '并发>16 钳到16', cfg: { RPC_MAX_CONCURRENT: 200, RPC_MIN_SPACING_MS: 60, ACCOUNT_STAGGER_MS: 120 },
    check: r => r.CFG.RPC_MAX_CONCURRENT === 16 },
  { name: '并发13~16 软提醒不改', cfg: { RPC_MAX_CONCURRENT: 14, RPC_MIN_SPACING_MS: 60, ACCOUNT_STAGGER_MS: 120 },
    check: r => r.CFG.RPC_MAX_CONCURRENT === 14 && r.problems.some(s => s.includes('偏高')) },
  { name: '并发<1 钳到1', cfg: { RPC_MAX_CONCURRENT: 0, RPC_MIN_SPACING_MS: 60, ACCOUNT_STAGGER_MS: 120 },
    check: r => r.CFG.RPC_MAX_CONCURRENT === 1 },
  { name: '间隔<20 钳到20', cfg: { RPC_MAX_CONCURRENT: 8, RPC_MIN_SPACING_MS: 0, ACCOUNT_STAGGER_MS: 120 },
    check: r => r.CFG.RPC_MIN_SPACING_MS === 20 },
  { name: '错峰<50 钳到50', cfg: { RPC_MAX_CONCURRENT: 8, RPC_MIN_SPACING_MS: 60, ACCOUNT_STAGGER_MS: 0 },
    check: r => r.CFG.ACCOUNT_STAGGER_MS === 50 },
  { name: '非数字并发回退8', cfg: { RPC_MAX_CONCURRENT: NaN, RPC_MIN_SPACING_MS: 60, ACCOUNT_STAGGER_MS: 120 },
    check: r => r.CFG.RPC_MAX_CONCURRENT === 8 }
];

(async () => {
  const failed = [];
  for (const c of cases) {
    let r;
    try { r = run(c.cfg); } catch (e) { failed.push(`${c.name}: 抛异常 ${e.message}`); continue; }
    const pass = c.check(r);
    console.log(`${pass ? '✅' : '❌'} ${c.name}`);
    if (!pass) failed.push(`${c.name} -> 实际 并发=${r.CFG.RPC_MAX_CONCURRENT} 间隔=${r.CFG.RPC_MIN_SPACING_MS} 错峰=${r.CFG.ACCOUNT_STAGGER_MS} problems=${JSON.stringify(r.problems)}`);
  }
  console.log('');
  if (failed.length === 0) { console.log('✅ 全部通过: 并发/吞吐参数保护生效'); process.exit(0); }
  console.log('❌ 失败:'); failed.forEach(f => console.log('   -', f));
  process.exit(1);
})();
