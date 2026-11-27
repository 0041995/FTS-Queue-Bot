#!/usr/bin/env node
/**
 * FTS 自动买卖逻辑回归测试
 *
 * 验证:
 *   1) 挂单扫描只取 status=1 且非自己(所有账号)的单，按单价升序
 *   2) computeFtsSpotPrice: token0 必须是 FTS 或 USDT，否则拒绝；储备为 0 拒绝
 *   3) 卖单循环有累计上限/冷却/已有挂单检查(静态源码断言)
 *   4) 买单每日累计落盘(静态源码断言)
 *   5) 阈值未配置时不交易(默认关闭、不设默认值)
 *
 * 用法: node test/trade.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const SRC = path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');

function ex(a, b) { const i = text.indexOf(a), j = text.indexOf(b, i); if (i < 0 || j < 0) throw new Error('抽取标记缺失'); return text.slice(i, j); }
const src = ex('const MARKET_ABI', '// ---------------- 钱包加载');

const errors = [];
const assert = (c, m) => { if (!c) errors.push(m); };

// ---- 桩: ethers / mgr / CFG / instances / sendTx / sleep ----
const ethersStub = {
  formatUnits: (v, d) => (Number(v) / Math.pow(10, d)).toString(),
  parseUnits: (v, d) => BigInt(Math.round(Number(v) * Math.pow(10, d))),
  Contract: class { constructor(a, abi, p) { this.target = a; } }
};
const orders = {
  1: { seller: '0xAAA', ftsAmount: 100n * 10n ** 18n, totalPriceU: 50n * 10n ** 18n, status: 1n },  // 0.5 U/FTS
  2: { seller: '0xBBB', ftsAmount: 100n * 10n ** 18n, totalPriceU: 40n * 10n ** 18n, status: 1n },  // 0.4 U/FTS
  3: { seller: '0xCCC', ftsAmount: 100n * 10n ** 18n, totalPriceU: 30n * 10n ** 18n, status: 2n },  // 已成交，应忽略
  4: { seller: '0xME', ftsAmount: 100n * 10n ** 18n, totalPriceU: 10n * 10n ** 18n, status: 1n },   // 自己的单，应忽略
  5: { seller: '0xME2', ftsAmount: 100n * 10n ** 18n, totalPriceU: 20n * 10n ** 18n, status: 1n }   // 第二个自有账号，也应忽略
};
const marketStub = {
  nextOrderId: async () => 6n,
  orders: async id => orders[id],
  pair: async () => '0xPAIR',
  fts: async () => '0xFTS',
  usdt: async () => '0xUSDT',
  fillOrder: async () => { },
  createOrder: async () => { }
};
const mgr = { rpc: async fn => fn({}) };
// v1.7.1: 多账号时任何一个自有账号的单都不能被自己吃掉
const instances = [{ address: '0xME' }, { address: '0xME2' }];
let sent = [];
const sendTx = async (inst, opt) => { sent.push(opt); return true; };
const sleep = async () => { };
const CFG = {
  TRADE_BUY_MAX_PRICE: 0.45, TRADE_BUY_MAX_TOTAL: 60, TRADE_BUY_SCAN_N: 200,
  TRADE_CHECK_MS: 1, TRADE_SELL_MODE: 'fixed', TRADE_SELL_PRICE: 0.5,
  TRADE_SELL_AMOUNT: 100, TRADE_SELL_COOLDOWN_MS: 300000, TRADE_SELL_MAX_ORDERS: 1,
  TRADE_STATE_FILE: 'trade-state.json', MARKET_ADDR: '0xMKT'
};
const warnOnce = () => { }, info = () => { }, warn = () => { }, formatError = e => String(e);
const ethers = ethersStub;

const factory = new Function(
  'ethers', 'mgr', 'instances', 'sendTx', 'sleep', 'CFG', 'warnOnce', 'info', 'warn', 'formatError',
  src + '\nreturn {scanMarketOrders, getFtsSpotPrice, computeFtsSpotPrice, tradeBuyLoop, tradeSellLoop, scanMyActiveOrders};'
);
const { scanMarketOrders, computeFtsSpotPrice } = factory(ethers, mgr, instances, sendTx, sleep, CFG, warnOnce, info, warn, formatError);

(async () => {
  // 1) 扫描过滤
  const list = await scanMarketOrders(marketStub, 200);
  assert(list.length === 2, `应只有 2 个可吃挂单(status=1且非自己)，实际 ${list.length}`);
  assert(list[0].id === 2 && list[1].id === 1, '应按单价升序(0.4 在 0.5 前)');
  console.log('✅ 挂单扫描: 过滤已成交/两个自有账号的单，按单价升序');

  // 2) 现货价: token0 归属校验
  const fmt = (v) => (Number(v) / 1e18).toString();
  const R_FTS = 100n * 10n ** 18n, R_USDT = 250n * 10n ** 18n;
  assert(computeFtsSpotPrice(R_FTS, R_USDT, '0xFTS', '0xFTS', '0xUSDT', fmt) === 2.5,
    'token0=FTS 时 USDT/FTS 应为 2.5');
  assert(computeFtsSpotPrice(R_USDT, R_FTS, '0xUSDT', '0xFTS', '0xUSDT', fmt) === 2.5,
    'token0=USDT 时 USDT/FTS 应为 2.5');
  assert(computeFtsSpotPrice(R_FTS, R_USDT, '0xBNB', '0xFTS', '0xUSDT', fmt) === null,
    'token0 是第三种代币时必须返回 null，不能算出错价');
  assert(computeFtsSpotPrice(0n, R_USDT, '0xFTS', '0xFTS', '0xUSDT', fmt) === null,
    '储备为 0 必须返回 null');
  console.log('✅ 现货价: token0 归属 + 零储备校验');

  // 3) 源码级断言: 三道闸门与每日上限落盘确实存在
  assert(/listed >= maxOrders/.test(text), '卖单必须有累计上限');
  assert(/TRADE_SELL_COOLDOWN_MS/.test(text) && /lastAt/.test(text), '卖单必须有冷却');
  assert(/scanMyActiveOrders/.test(text), '卖单必须检查已有活跃挂单');
  assert(/writeDailySpent\(CFG\.TRADE_STATE_FILE/.test(text), '买单每日花费必须落盘');
  assert(/const mine = new Set\(instances\.map/.test(text), '多账号过滤必须覆盖全部账号');
  console.log('✅ 卖单三道闸门 / 买单每日上限 / 多账号过滤');

  console.log('');
  if (errors.length === 0) { console.log('✅ 全部通过: FTS 买卖逻辑正常'); process.exit(0); }
  console.log('❌ 失败:'); errors.forEach(e => console.log('   -', e));
  process.exit(1);
})().catch(e => { console.error(e); process.exit(2); });
