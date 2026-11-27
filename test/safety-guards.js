#!/usr/bin/env node
/**
 * v1.7.1 安全护栏集中回归测试（纯函数桩测试，不连链、不需要 ethers）
 *
 * 覆盖:
 *   1) computeApproveTarget: 0 值回落 / 场数上限 / U 数上限 / 余额不足
 *   2) filterSyncCandidates: 校验失败、RPC 掉线、资金冻结、ABI 结果、未知字段
 *   3) computeFtsSpotPrice: token0 归属、零储备
 *   4) findAddressByFingerprint: 唯一候选、歧义、远距离特征
 *   5) WEB_CONTRACT_MAP 无死键、WEB_FUNDS_KEYS 全在白名单里
 *
 * 用法: node test/safety-guards.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const text = fs.readFileSync(path.join(ROOT, 'src', 'core.js'), 'utf8');

function ex(a, b) {
  const i = text.indexOf(a), j = text.indexOf(b, i);
  if (i < 0 || j < 0) throw new Error(`抽取标记缺失: ${a} / ${b}`);
  return text.slice(i, j);
}

const mapSrc = ex('const WEB_CONTRACT_MAP', '// ABI 特征 ->');
const approveSrc = ex('function computeApproveTarget(', 'async function ensureFunds(');
const spotSrc = ex('function computeFtsSpotPrice(', '// 读 FTS 真实价格');
const fingerprintSrc = ex('function findAddressByFingerprint(', '// 校验地址在链上有代码');
const filterSrc = ex('// v1.7.1: 决定哪些网页地址允许写回', '// 把探测到的地址写回 config.json');

const all = [mapSrc, approveSrc, spotSrc, fingerprintSrc, filterSrc].join('\n');
const G = new Function(all + `
return { WEB_CONTRACT_MAP, WEB_FUNDS_KEYS, computeApproveTarget,
         computeFtsSpotPrice, findAddressByFingerprint, filterSyncCandidates };`)();

let bad = 0;
function check(name, cond, detail) {
  if (cond) console.log('  ✅ ' + name);
  else { bad++; console.log('  ❌ ' + name + (detail ? ' -> ' + detail : '')); }
}

// 18 位精度的最小桩
const parseUnits = (v) => {
  const s = String(v);
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error('bad units: ' + s);
  const [a, b = ''] = s.split('.');
  return BigInt(a) * 10n ** 18n + BigInt((b + '0'.repeat(18)).slice(0, 18));
};
const formatUnits = (v) => (Number(v) / 1e18).toString();
const U = n => parseUnits(String(n));
const TICKET = U(10), BAL = U(100);

console.log('--- computeApproveTarget ---');
const cfg = o => Object.assign({
  APPROVE_USD: null, APPROVE_ROUNDS: 1, APPROVE_MAX_ROUNDS: 3, APPROVE_MAX_USD: 100
}, o);
const r0 = G.computeApproveTarget(TICKET, BAL, cfg({ APPROVE_USD: 0 }), parseUnits);
check('填 0 不再=全部余额，回落到 1 场', r0.target === TICKET && /废弃/.test(r0.note),
  r0.target === TICKET ? r0.note : String(r0.target));
check('按场数 50 收敛到 3 场', G.computeApproveTarget(TICKET, BAL, cfg({ APPROVE_ROUNDS: 50 }), parseUnits).target === TICKET * 3n);
check('按 U 数 500 压到 100 U', G.computeApproveTarget(TICKET, BAL, cfg({ APPROVE_USD: 500 }), parseUnits).target === U(100));
check('默认 1 场', G.computeApproveTarget(TICKET, BAL, cfg({}), parseUnits).target === TICKET);
check('余额不足一轮票价返回 null', G.computeApproveTarget(TICKET, U(1), cfg({}), parseUnits) === null);
check('绝不产生 MaxUint256 级别授权', G.computeApproveTarget(TICKET, U(1e9), cfg({ APPROVE_USD: 1e9 }), parseUnits).target === U(100));

console.log('\n--- filterSyncCandidates ---');
const Q = '0x' + '1'.repeat(40), W = '0x' + '2'.repeat(40), E = '0x' + '3'.repeat(40);
const found = { QUEUE_ADDR: Q, USDT_ADDR: W, MINING_VAULT_ADDR: E, UNKNOWN: Q };
const allTrue = { QUEUE_ADDR: true, USDT_ADDR: true, MINING_VAULT_ADDR: true, UNKNOWN: true };
check('valid 为空 -> 一个都不写回', Object.keys(G.filterSyncCandidates(found, {}, {}, {}).accepted).length === 0);
check('校验 false -> 拒绝', !('QUEUE_ADDR' in G.filterSyncCandidates(found, { QUEUE_ADDR: false }, {}, {}).accepted));
const f1 = G.filterSyncCandidates(found, allTrue, {}, { WEB_SYNC_ALLOW_FUNDS_KEYS: false });
check('资金字段默认冻结', !('QUEUE_ADDR' in f1.accepted) && !('USDT_ADDR' in f1.accepted));
check('非资金字段校验通过可写回', f1.accepted.MINING_VAULT_ADDR === E);
check('未知字段拒绝', !('UNKNOWN' in f1.accepted));
const f2 = G.filterSyncCandidates(found, allTrue, { MINING_VAULT_ADDR: E }, { WEB_SYNC_ALLOW_FUNDS_KEYS: true });
check('ABI 启发式结果不写回', !('MINING_VAULT_ADDR' in f2.accepted));
const f3 = G.filterSyncCandidates(found, allTrue, {}, { WEB_SYNC_ALLOW_FUNDS_KEYS: true });
check('显式允许后资金字段放行', f3.accepted.QUEUE_ADDR === Q && f3.accepted.USDT_ADDR === W);

console.log('\n--- computeFtsSpotPrice ---');
const RF = U(100), RU = U(250);
check('token0=FTS -> 2.5', G.computeFtsSpotPrice(RF, RU, '0xFTS', '0xFTS', '0xUSDT', formatUnits) === 2.5);
check('token0=USDT -> 2.5', G.computeFtsSpotPrice(RU, RF, '0xUSDT', '0xFTS', '0xUSDT', formatUnits) === 2.5);
check('token0=第三种代币 -> null', G.computeFtsSpotPrice(RF, RU, '0xBNB', '0xFTS', '0xUSDT', formatUnits) === null);
check('零储备 -> null', G.computeFtsSpotPrice(0n, RU, '0xFTS', '0xFTS', '0xUSDT', formatUnits) === null);

console.log('\n--- findAddressByFingerprint ---');
const A1 = '0x' + 'a'.repeat(40), A2 = '0x' + 'b'.repeat(40);
check('唯一候选命中', G.findAddressByFingerprint('enterQueue roomConfigs const x="' + A1 + '";', ['enterQueue', 'roomConfigs']) === A1);
check('多候选返回 null', G.findAddressByFingerprint('enterQueue roomConfigs "' + A1 + '" "' + A2 + '"', ['enterQueue', 'roomConfigs']) === null);
check('特征在 600 字符外不命中', G.findAddressByFingerprint('"' + A1 + '"' + 'x'.repeat(900) + 'enterQueue roomConfigs', ['enterQueue', 'roomConfigs']) === null);

console.log('\n--- 映射常量 ---');
check('无 FTS_ADDR / PAIR_ADDR 死键', !('FTS_ADDR' in G.WEB_CONTRACT_MAP) && !('PAIR_ADDR' in G.WEB_CONTRACT_MAP));
check('资金字段都在白名单里', G.WEB_FUNDS_KEYS.every(k => k in G.WEB_CONTRACT_MAP));

console.log('');
if (bad === 0) { console.log('✅ 全部通过: v1.7.1 安全护栏正常'); process.exit(0); }
console.log(`❌ ${bad} 项失败`); process.exit(1);
