#!/usr/bin/env node
/**
 * 网页合约探测回归测试
 *
 * 验证:
 *   1) 从 HTML 提取 JS 地址(跳过 vendor)
 *   2) 从 JS 解析 VITE_P2_* 映射
 *   3) 相对/绝对 URL 处理
 *   4) 映射常量覆盖所有关键合约，且不含 v1.7.1 已移除的死键
 *   5) 广域扫描: 同域页面 + chunk 递归 + ABI 兜底(收紧后)
 *   6) v1.7.1: filterSyncCandidates 在校验失败/RPC 不可用/资金字段冻结时拒绝写回
 *
 * 用法: node test/web-sync.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const SRC = path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');

function ex(a, b) {
  const i = text.indexOf(a), j = text.indexOf(b, i);
  if (i < 0 || j < 0) throw new Error(`抽取标记缺失: ${a} / ${b}`);
  return text.slice(i, j);
}
const src = ex('const WEB_CONTRACT_MAP', '// 校验地址在链上有代码');
const filterSrc = ex('// v1.7.1: 决定哪些网页地址允许写回', '// 把探测到的地址写回 config.json');

const errors = [];
const assert = (c, m) => { if (!c) errors.push(m); };

(async () => {
  // 构造模拟 fetch
  const HTML = `<html><script src="/assets/vendor-react.js"></script><script src="/assets/index-ABC.js"></script></html>`;
  const JS = `const c={VITE_P2_QUEUE:"0x1111111111111111111111111111111111111111",VITE_P2_USDT: '0x2222222222222222222222222222222222222222',VITE_P2_MINING:"0x3333333333333333333333333333333333333333",VITE_OTHER:"0x4444444444444444444444444444444444444444"};`;
  const fetchMock = async url => {
    if (url.endsWith('/dapp/game')) return { ok: true, text: async () => HTML };
    if (url.includes('index-ABC.js')) return { ok: true, text: async () => JS };
    return { ok: false, status: 404 };
  };
  const factory = new Function('CFG', 'fetch', src + '\n' + filterSrc +
    '\nreturn {probeWebContracts, WEB_CONTRACT_MAP, WEB_FUNDS_KEYS, absoluteUrl, filterSyncCandidates, findAddressByFingerprint};');
  const CFG = { GAME_URL: 'https://example.com/dapp/game' };
  const { probeWebContracts, WEB_CONTRACT_MAP, WEB_FUNDS_KEYS, absoluteUrl, filterSyncCandidates, findAddressByFingerprint } =
    factory(CFG, fetchMock);

  // 1) URL 处理
  assert(absoluteUrl('https://x.com/dapp/game', '/assets/a.js') === 'https://x.com/assets/a.js', '相对URL解析错误');
  console.log('✅ 相对/绝对 URL 处理');

  // 2) 映射常量
  const keys = Object.values(WEB_CONTRACT_MAP).flat();
  assert(keys.includes('VITE_P2_QUEUE') && keys.includes('VITE_P2_MINING') && keys.includes('VITE_P2_USDT'), '映射常量缺关键合约');
  assert(keys.includes('VITE_MARKET_ESCROW'), '映射常量缺市场合约');
  assert(!('FTS_ADDR' in WEB_CONTRACT_MAP) && !('PAIR_ADDR' in WEB_CONTRACT_MAP), 'v1.7.1 应移除 FTS_ADDR / PAIR_ADDR 死键');
  assert(WEB_FUNDS_KEYS.every(k => k in WEB_CONTRACT_MAP), '资金字段必须都在映射白名单里');
  console.log(`✅ 映射常量覆盖 ${keys.length} 个 VITE 键 / ${Object.keys(WEB_CONTRACT_MAP).length} 个合约字段`);

  // 3) 探测
  const r = await probeWebContracts(CFG.GAME_URL);
  assert(r.found.QUEUE_ADDR === '0x1111111111111111111111111111111111111111', 'QUEUE 解析错误');
  assert(r.found.USDT_ADDR === '0x2222222222222222222222222222222222222222', 'USDT 解析错误(单引号)');
  assert(r.found.MINING_VAULT_ADDR === '0x3333333333333333333333333333333333333333', 'MINING 解析错误');
  assert(r.all.VITE_OTHER === '0x4444444444444444444444444444444444444444', '非关键映射也应记录');
  assert(r.jsUrls && r.jsUrls.some(u => u.includes('index-ABC.js')), '应选中主 JS(非 vendor)');
  console.log('✅ 从 HTML+JS 解析合约映射');

  // 4) 广域: 同域链接 + chunk 递归 + ABI 兜底
  const HTML2 = `<html><a href="/dapp/market">市场</a><a href="/dapp/ranks">排行</a>
    <a href="https://other.com/x">外站</a><script src="/assets/index-ABC.js"></script></html>`;
  const JS2 = `const c={VITE_P2_QUEUE:"0x1111111111111111111111111111111111111111"};
    import("./MarketPage-XYZ.js");import("./abi-QQQ.js");`;
  const MARKET_JS = `const A=["function nextOrderId() view returns (uint256)","function fillOrder(uint256 orderId)"];
    const addr="0x9999999999999999999999999999999999999999";const m=new Contract(addr,A);`;
  const fetch2 = async url => {
    if (url.endsWith('/dapp/game') || url.endsWith('/dapp/market') || url.endsWith('/dapp/ranks'))
      return { ok: true, text: async () => HTML2 };
    if (url.includes('index-ABC.js')) return { ok: true, text: async () => JS2 };
    if (url.includes('MarketPage-XYZ.js')) return { ok: true, text: async () => MARKET_JS };
    if (url.includes('abi-QQQ.js')) return { ok: true, text: async () => 'export const x=1;' };
    return { ok: false, status: 404 };
  };
  const factory2 = new Function('CFG', 'fetch', 'URL', src + '\nreturn {probeWebContracts};');
  const { probeWebContracts: probe2 } = factory2(CFG, fetch2, URL);
  const r2 = await probe2('https://example.com/dapp/game', 'https://example.com/dapp/market', true);
  assert(r2.jsUrls.some(u => u.includes('MarketPage-XYZ.js')), '应递归抓到 chunk');
  assert(r2.pagesScanned >= 2, '应扫描多个同域页面');
  assert(!r2.jsUrls.some(u => u.includes('other.com')), '不应抓外站链接');
  assert(r2.found.QUEUE_ADDR === '0x1111111111111111111111111111111111111111', 'VITE 映射应生效');
  assert(r2.found.MARKET_ADDR === '0x9999999999999999999999999999999999999999',
    'ABI 特征应兜底识别市场合约，实际=' + r2.found.MARKET_ADDR);
  console.log('✅ 广域扫描: 同域页面 + chunk 递归 + ABI 兜底识别');

  // 5) ABI 兜底收紧: 多个候选地址时拒绝猜测
  const multi = findAddressByFingerprint(
    'const A=["enterQueue","roomConfigs"];const x="0x1111111111111111111111111111111111111111";' +
    'const y="0x2222222222222222222222222222222222222222";',
    ['enterQueue', 'roomConfigs']);
  assert(multi === null, '多个候选地址时应返回 null，不能认错');
  const far = findAddressByFingerprint(
    'const addr="0x1111111111111111111111111111111111111111";' + 'x'.repeat(900) + 'enterQueue roomConfigs',
    ['enterQueue', 'roomConfigs']);
  assert(far === null, '特征离地址太远时不应命中');
  console.log('✅ ABI 兜底: 歧义候选与远距离特征均拒绝');

  // 6) v1.7.1 写回白名单
  const found = {
    QUEUE_ADDR: '0x' + '1'.repeat(40),
    USDT_ADDR: '0x' + '2'.repeat(40),
    MINING_VAULT_ADDR: '0x' + '3'.repeat(40),
    BOGUS_ADDR: '0x' + '4'.repeat(40)
  };
  const okValid = {
    QUEUE_ADDR: true, USDT_ADDR: true, MINING_VAULT_ADDR: true, BOGUS_ADDR: true
  };
  const none = filterSyncCandidates(found, {}, {}, { WEB_SYNC_ALLOW_FUNDS_KEYS: false });
  assert(Object.keys(none.accepted).length === 0, 'RPC 不可用(valid 为空)时一个地址都不能写回');
  const frozen = filterSyncCandidates(found, okValid, {}, { WEB_SYNC_ALLOW_FUNDS_KEYS: false });
  assert(!('QUEUE_ADDR' in frozen.accepted) && !('USDT_ADDR' in frozen.accepted), '资金字段默认必须冻结');
  assert(frozen.accepted.MINING_VAULT_ADDR === found.MINING_VAULT_ADDR, '非资金字段校验通过应可写回');
  assert(!('BOGUS_ADDR' in frozen.accepted), '非白名单字段必须拒绝');
  const abi = filterSyncCandidates(found, okValid, { MINING_VAULT_ADDR: found.MINING_VAULT_ADDR }, {});
  assert(!('MINING_VAULT_ADDR' in abi.accepted), 'ABI 启发式结果不能写回');
  const partial = filterSyncCandidates(found, { QUEUE_ADDR: false, USDT_ADDR: true, MINING_VAULT_ADDR: true }, {}, {});
  assert(!('QUEUE_ADDR' in partial.accepted), '校验为 false 必须拒绝');
  const allowed = filterSyncCandidates(found, okValid, {}, { WEB_SYNC_ALLOW_FUNDS_KEYS: true });
  assert(allowed.accepted.QUEUE_ADDR === found.QUEUE_ADDR && allowed.accepted.USDT_ADDR === found.USDT_ADDR,
    '显式允许后资金字段才可写回');
  console.log('✅ 写回白名单: 校验失败/RPC 掉线/资金冻结/ABI 结果/未知字段全部拒绝');

  console.log('');
  if (errors.length === 0) { console.log('✅ 全部通过: 网页合约探测与写回防护正常'); process.exit(0); }
  console.log('❌ 失败:'); errors.forEach(e => console.log('   -', e));
  process.exit(1);
})().catch(e => { console.error(e); process.exit(2); });
