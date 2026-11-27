#!/usr/bin/env node
/**
 * 网页合约探测回归测试
 *
 * 验证:
 *   1) 从 HTML 提取 JS 地址(跳过 vendor)
 *   2) 从 JS 解析 VITE_P2_* 映射
 *   3) 相对/绝对 URL 处理
 *   4) 映射常量覆盖所有关键合约
 *
 * 用法: node test/web-sync.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const SRC = path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');

function ex(a, b) { const i = text.indexOf(a), j = text.indexOf(b, i); return text.slice(i, j); }
const src = ex('const WEB_CONTRACT_MAP', '// 校验地址在链上有代码');

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
  const factory = new Function('CFG', 'fetch', src + '\nreturn {probeWebContracts, WEB_CONTRACT_MAP, absoluteUrl};');
  const CFG = { GAME_URL: 'https://example.com/dapp/game' };
  const { probeWebContracts, WEB_CONTRACT_MAP, absoluteUrl } = factory(CFG, fetchMock);

  // 1) URL 处理
  assert(absoluteUrl('https://x.com/dapp/game', '/assets/a.js') === 'https://x.com/assets/a.js', '相对URL解析错误');
  console.log('✅ 相对/绝对 URL 处理');

  // 2) 映射常量
  const keys = Object.values(WEB_CONTRACT_MAP);
  assert(keys.includes('VITE_P2_QUEUE') && keys.includes('VITE_P2_MINING') && keys.includes('VITE_P2_USDT'), '映射常量缺关键合约');
  console.log(`✅ 映射常量覆盖 ${keys.length} 个关键合约`);

  // 3) 探测
  const r = await probeWebContracts(CFG.GAME_URL);
  assert(r.found.QUEUE_ADDR === '0x1111111111111111111111111111111111111111', 'QUEUE 解析错误');
  assert(r.found.USDT_ADDR === '0x2222222222222222222222222222222222222222', 'USDT 解析错误(单引号)');
  assert(r.found.MINING_VAULT_ADDR === '0x3333333333333333333333333333333333333333', 'MINING 解析错误');
  assert(r.all.VITE_OTHER === '0x4444444444444444444444444444444444444444', '非关键映射也应记录');
  assert(r.jsUrls && r.jsUrls.some(u => u.includes('index-ABC.js')), '应选中主 JS(非 vendor)');
  console.log('✅ 从 HTML+JS 解析合约映射');

  console.log('');
  if (errors.length === 0) { console.log('✅ 全部通过: 网页合约探测正常'); process.exit(0); }
  console.log('❌ 失败:'); errors.forEach(e => console.log('   -', e));
  process.exit(1);
})().catch(e => { console.error(e); process.exit(2); });
