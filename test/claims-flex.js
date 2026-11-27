#!/usr/bin/env node
/**
 * 领取健壮性 / 灵活资金决策 / 入房 deadline 回归测试(模拟链，不碰真实资金)
 *
 * 覆盖本次改动:
 *   1) 错误分类 isTransientClaimRevert / isTerminalClaimSkipReason
 *      —— 资金不足/窗口未开/未知 revert 绝不能算"终态"，否则钱到位也不再领
 *   2) confirmTxInBackground 重播回滚
 *      —— 交易超时被同 nonce 重播后，重播若上链 revert 必须撤 claimed(onFailed)
 *   3) 灵活资金决策 tryFlexTopUp / pickFlexDonor
 *      —— 默认关闭=零行为；开启时按差额从富余账号转账；donor 保留额生效
 *   4) (已撤销) 入房 deadline 缓冲: 经真实链核对 roundInfo.deadline 是"领取窗口截止"，
 *      并非"入场截止"，不适用于入场，故撤销，入房逻辑维持原样
 *   5) 静态断言: 旧的"非 transient 即永久标记"写法已不存在
 *
 * 用法: NODE_PATH=<含 ethers 的 node_modules> node test/claims-flex.js
 */
const fs = require('fs');
const path = require('path');
let ethers;
try { ethers = require('ethers'); }
catch (e) { console.error('本测试需要 ethers: npm install ethers@6'); process.exit(2); }

const ROOT = path.dirname(__dirname);
const SRC = process.env.CORE_PATH || path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');

function extract(name) {
  const start = text.indexOf(name);
  if (start < 0) throw new Error('找不到 ' + name + '，core.js 结构可能变了');
  let depth = 0, end = -1;
  for (let j = text.indexOf('{', start); j < text.length; j++) {
    if (text[j] === '{') depth++;
    else if (text[j] === '}') { depth--; if (depth === 0) { end = j + 1; break; } }
  }
  return text.slice(start, end);
}
const build = (fnNames, stubs) => {
  const body = fnNames.map(extract).join('\n') + '\nreturn { ' + fnNames.map(n => n.replace(/^.*function\s+/, '').replace(/\(.*$/, '')).join(', ') + ' };';
  return new Function(...Object.keys(stubs), body)(...Object.values(stubs));
};

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  ✅ ' + name); }
  else { fail++; console.log('  ❌ ' + name + (detail ? ' -> ' + detail : '')); }
}
const mkRevert = (msg) => ({
  code: 'CALL_EXCEPTION',
  data: '0x08c379a0' + ethers.AbiCoder.defaultAbiCoder().encode(['string'], [msg]).slice(2),
  reason: msg, message: msg, shortMessage: msg
});

(async () => {
  // ============ 1. 错误分类 ============
  console.log('--- 1. 领取错误分类 ---');
  const cls = build(
    ['function decodeRevert(e) {', 'function formatError(e) {', 'function rpcDetail(e) {',
      'function isTransientClaimRevert(e) {', 'function isTerminalClaimSkipReason(e) {'],
    { ethers }
  );
  const T = cls.isTransientClaimRevert, P = cls.isTerminalClaimSkipReason;
  check('insufficient funds -> 可恢复(非终态)', T(mkRevert('insufficient funds for gas')) && !P(mkRevert('insufficient funds for gas')));
  check('not settled -> 可恢复', T(mkRevert('round not settled')) && !P(mkRevert('round not settled')));
  check('please wait -> 可恢复', T(mkRevert('please wait')) && !P(mkRevert('please wait')));
  check('gas too low -> 可恢复', T(mkRevert('gas too low')) && !P(mkRevert('gas too low')));
  check('already claimed -> 终态(可永久标记)', P(mkRevert('already claimed')) && !T(mkRevert('already claimed')));
  check('not in round -> 终态', P(mkRevert('not in round')));
  check('not winner -> 终态', P(mkRevert('not winner')));
  check('未知 revert -> 既非可恢复也非终态(拿不准就不永久标记)', !T(mkRevert('boom xyz')) && !P(mkRevert('boom xyz')));
  check('空错误对象不抛异常', (() => { try { T({}); P({}); return true; } catch (e) { return false; } })());

  // ============ 5. 静态断言(先做，源码层面防回潮) ============
  console.log('\n--- 5. 源码静态断言 ---');
  check('不再有 "!isTransientClaimRevert(e)) inst.claimed.add" 旧写法', !/!isTransientClaimRevert\(e[2]?\)\)\s*inst\.claimed\.add/.test(text));
  check('改用 isTerminalClaimSkipReason 永久标记', text.includes('isTerminalClaimSkipReason(e)') && text.includes('isTerminalClaimSkipReason(e2)'));

  // ============ 2. confirmTxInBackground 重播回滚 ============
  console.log('\n--- 2. 后台确认/重播回滚 ---');
  const confirmStubs = (recovery) => {
    const state = { failed: 0, confirmed: 0 };
    const fn = build(['function confirmTxInBackground(inst, tx, opt, nonce) {'], {
      withTimeout: (p) => p,
      rebroadcastSameNonce: async () => recovery,   // 字符串 hash 或 null
      ok: () => { }, err: () => { }, warnOnce: () => { },
      CFG: { TX_WAIT_MS: 1000 }
    }).confirmTxInBackground;
    return { fn, state };
  };
  const timeoutTx = () => ({ hash: '0xh', wait: async () => { const e = new Error('timeout'); e.code = 'TIMEOUT'; throw e; } });

  { // 超时 -> 重播 -> 重播上链失败(status=0) -> 必须 onFailed 并清零 unconfirmed
    const { fn, state } = confirmStubs('0xrep');
    const inst = { address: '0xA', stats: { sent: 0, failed: 0 }, unconfirmed: 1, provider: { waitForTransaction: async () => ({ status: 0 }) } };
    fn(inst, timeoutTx(), { label: 't', onFailed: () => state.failed++, onConfirmed: () => state.confirmed++ }, 5);
    await new Promise(r => setTimeout(r, 30));
    check('重播上链失败(status=0)触发 onFailed(撤 claimed)', state.failed === 1, 'failed=' + state.failed);
    check('重播失败不误报 onConfirmed', state.confirmed === 0);
    check('unconfirmed 归零', inst.unconfirmed === 0, 'unconfirmed=' + inst.unconfirmed);
  }
  { // 正常上链 -> onConfirmed
    const { fn, state } = confirmStubs(null);
    const inst = { address: '0xA', stats: { sent: 0, failed: 0 }, unconfirmed: 1, provider: {} };
    const tx = { hash: '0xh', wait: async () => ({ status: 1, gasUsed: 21000n, blockNumber: 1 }) };
    fn(inst, tx, { label: 't', onFailed: () => state.failed++, onConfirmed: () => state.confirmed++ }, 5);
    await new Promise(r => setTimeout(r, 30));
    check('上链成功触发 onConfirmed', state.confirmed === 1);
    check('成功后 unconfirmed 归零', inst.unconfirmed === 0);
  }
  { // 超时 -> 重播也为 null -> onFailed
    const { fn, state } = confirmStubs(null);
    const inst = { address: '0xA', stats: { sent: 0, failed: 0 }, unconfirmed: 1, provider: {} };
    fn(inst, timeoutTx(), { label: 't', onFailed: () => state.failed++, onConfirmed: () => state.confirmed++ }, 5);
    await new Promise(r => setTimeout(r, 30));
    check('重播失败(onFailed)撤销标记', state.failed === 1);
    check('此时 unconfirmed 归零', inst.unconfirmed === 0);
  }

  // ============ 3. 灵活资金决策 ============
  console.log('\n--- 3. 灵活资金决策 ---');
  const U = (s) => ethers.parseUnits(s, 18);
  const mkFlex = (cfg, accA, accB) => {
    const sends = [];
    const instances = [accA, accB];
    const stubs = {
      CFG: Object.assign({
        FLEX_ENABLED: false, FLEX_GAS_POOLING: false, FLEX_FUND_AGGREGATION: false,
        FLEX_DONOR_KEEP_USDT: 20, FLEX_DONOR_KEEP_BNB: 0.01, MIN_BNB_GAS: 0.005, TX_WAIT_MS: 1000
      }, cfg),
      DRY_RUN: false,
      ethers,
      instances,
      mgr: { rpc: async (fn) => fn({ getTransactionCount: async () => 0, getBalance: async () => 0n }) },
      info: () => { }, warnOnce: () => { }, formatError: (e) => String(e && e.message || e),
      buildFeeParams: async () => ({ tx: {}, gasPrice: 0n, desc: 'x', type: 0 }),
      withTimeout: (p) => p,
      sendTx: async (from, opt) => { sends.push({ from: from.address, opt }); return true; }
    };
    const flexStart = text.indexOf('const flexReserved');
    const flexEnd = text.indexOf('async function ensureFunds', flexStart);
    if (flexStart < 0 || flexEnd < 0) throw new Error('FLEX 代码段结构变了');
    const body = text.slice(flexStart, flexEnd) + '\nreturn { pickFlexDonor, flexSendNative, tryFlexTopUp };';
    const api = new Function(...Object.keys(stubs), body)(...Object.values(stubs));
    return { api, sends };
  };
  const acct = (addr, { usdt, bnb }) => ({
    address: addr,
    usdt: { balanceOf: async () => U(usdt) },
    provider: { getBalance: async () => ethers.parseEther(String(bnb)), getTransactionCount: async () => 0 },
    mutex: { acquire: async () => () => { } },
    wallet: { sendTransaction: async () => ({ hash: '0xn', wait: async () => ({}) }) },
    nonce: null
  });

  { // 关闭: 零行为
    const A = acct('0xA', { usdt: '5', bnb: 1 }), B = acct('0xB', { usdt: '100', bnb: 1 });
    const { api, sends } = mkFlex({ FLEX_ENABLED: false, FLEX_FUND_AGGREGATION: true, FLEX_GAS_POOLING: true }, A, B);
    await api.tryFlexTopUp(A, U('10'), ethers.parseEther('0.005'));
    check('总开关关闭 -> 不发起任何转账', sends.length === 0, 'sends=' + sends.length);
  }
  { // 凑 USDT: A 只有 5U，需 10U，B 有 100U(保留 20) -> 转 5U
    const A = acct('0xA', { usdt: '5', bnb: 1 }), B = acct('0xB', { usdt: '100', bnb: 1 });
    const { api, sends } = mkFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true, FLEX_GAS_POOLING: false }, A, B);
    await api.tryFlexTopUp(A, U('10'), 0n);
    const s = sends[0];
    check('USDT 不足 -> 从富余账号凑差额', sends.length === 1 && s.from === '0xB', JSON.stringify(s && s.from));
    check('转账方法/金额正确(transfer 5U 给 A)', s && s.opt.method === 'transfer' && s.opt.args[0] === '0xA' && s.opt.args[1] === U('5'),
      s ? s.opt.method + ' ' + (s.opt.args && ethers.formatUnits(s.opt.args[1], 18)) : 'none');
  }
  { // donor 保留额生效: B 只有 20U = keep，凑不出 -> 不转
    const A = acct('0xA', { usdt: '5', bnb: 1 }), B = acct('0xB', { usdt: '20', bnb: 1 });
    const { api, sends } = mkFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, B);
    await api.tryFlexTopUp(A, U('10'), 0n);
    check('donor 扣除保留额后无富余 -> 不转账', sends.length === 0, 'sends=' + sends.length);
  }
  { // 匀 BNB: A 0.001 需 0.005，B 1 BNB(保留 0.01) -> 转 native
    const A = acct('0xA', { usdt: '100', bnb: 0.001 }), B = acct('0xB', { usdt: '100', bnb: 1 });
    const { api } = mkFlex({ FLEX_ENABLED: true, FLEX_GAS_POOLING: true, FLEX_FUND_AGGREGATION: false }, A, B);
    let nativeCalls = 0;
    B.wallet.sendTransaction = async () => { nativeCalls++; return { hash: '0xn', wait: async () => ({}) }; };
    await api.tryFlexTopUp(A, 0n, ethers.parseEther('0.005'));
    check('BNB 不足 -> 从富余账号做 native 转账', nativeCalls === 1, 'nativeCalls=' + nativeCalls);
  }

  // 说明: 原计划的"入房 deadline 缓冲"经真实链核对——roundInfo.deadline 是 48h 领取窗口截止，
  // 并非入场截止(入场能否进由人数是否满 / state 决定，满员时 estimateGas 预检已会拦截，不会白烧 gas)。
  // 故不适用于入场，该项已撤销，避免用错误语义误挡入场。入房逻辑维持原样。

  // ============ 3b. ensureFunds: 仅"报资金不足"时才触发灵活决策 ============
  console.log('\n--- 3b. ensureFunds 不足时才触发 ---');
  const mkEnsureFlex = (cfg, accA, accB) => {
    const sends = [];
    const instances = [accA, accB];
    const stubs = {
      CFG: Object.assign({
        FLEX_ENABLED: false, FLEX_GAS_POOLING: false, FLEX_FUND_AGGREGATION: false,
        FLEX_DONOR_KEEP_USDT: 20, FLEX_DONOR_KEEP_BNB: 0.01, MIN_BNB_GAS: 0.005,
        TX_WAIT_MS: 1000, QUEUE_ADDR: '0x0000000000000000000000000000000000000042', APPROVE_USD: null, APPROVE_ROUNDS: 1
      }, cfg),
      DRY_RUN: false, ethers, instances,
      mgr: { rpc: async (fn) => fn({ getTransactionCount: async () => 0, getBalance: async () => 0n }) },
      info: () => { }, warnOnce: () => { }, err: () => { }, errOnce: () => { }, formatError: (e) => String(e && e.message || e),
      roomLabel: () => '房间0',
      buildFeeParams: async () => ({ tx: {}, gasPrice: 0n, desc: 'x', type: 0 }),
      withTimeout: (p) => p,
      sendTx: async (from, opt) => {
        sends.push({ from: from.address, opt });
        if (opt.method === 'transfer') {   // 凑单转账: 把差额记到收款账号余额上
          const to = instances.find(x => String(x.address).toLowerCase() === String(opt.args[0]).toLowerCase());
          if (to) to._balVar.v += opt.args[1];
        }
        return true;
      }
    };
    // FLEX 辅助定义(预留表/节流/选donor/转账/凑单)是一整段，直接按起止标记抽取，
    // 避免只抽函数而漏掉 const 声明导致 ReferenceError。
    const flexStart = text.indexOf('const flexReserved');
    const flexEnd = text.indexOf('async function ensureFunds', flexStart);
    if (flexStart < 0 || flexEnd < 0) throw new Error('FLEX 代码段结构变了');
    const flexBlock = text.slice(flexStart, flexEnd);
    const ensureSrc = extract('async function ensureFunds(inst, ticketPrice, room) {');
    const body = flexBlock + '\n' + ensureSrc + '\nreturn { pickFlexDonor, flexSendNative, tryFlexTopUp, ensureFunds };';
    const api = new Function(...Object.keys(stubs), body)(...Object.values(stubs));
    return { api, sends };
  };
  const mkA = (addr, balVar, bnb) => ({
    address: addr, _balVar: balVar,
    usdt: { balanceOf: async () => balVar.v, allowance: async () => 0n },
    provider: { getBalance: async () => ethers.parseEther(String(bnb)), getTransactionCount: async () => 0 },
    mutex: { acquire: async () => () => { } },
    wallet: { sendTransaction: async () => ({ hash: '0xn', wait: async () => ({}) }) }, nonce: null
  });

  { // 关闭: 余额不足直接失败，不触发任何转账
    const A = mkA('0xA', { v: U('5') }, 1), B = mkA('0xB', { v: U('100') }, 1);
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: false, FLEX_FUND_AGGREGATION: true }, A, B);
    const ret = await api.ensureFunds(A, U('10'), 0);
    check('关闭: 余额不足返回 false', ret === false);
    check('关闭: 不发起任何资金转账', sends.filter(s => s.opt.method === 'transfer').length === 0);
  }
  { // 开启: 余额不足才触发凑单(5U)，补后达到 10U 并继续入场流程
    const A = mkA('0xA', { v: U('5') }, 1), B = mkA('0xB', { v: U('100') }, 1);
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, B);
    const ret = await api.ensureFunds(A, U('10'), 0);
    const tr = sends.find(s => s.opt.method === 'transfer');
    check('开启: 不足时触发一次 USDT 凑单(5U 从 B)', !!tr && tr.from === '0xB' && tr.opt.args[1] === U('5'),
      tr ? 'from=' + tr.from + ' amt=' + ethers.formatUnits(tr.opt.args[1], 18) : 'no transfer');
    check('开启: 补足后余额达 10U 并继续流程', A._balVar.v === U('10') && ret === true,
      'bal=' + ethers.formatUnits(A._balVar.v, 18) + ' ret=' + ret);
  }
  { // 开启: 余额本就足够 -> 不应触发凑单(证明是"不足才触发")
    const A = mkA('0xA', { v: U('100') }, 1), B = mkA('0xB', { v: U('100') }, 1);
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, B);
    await api.ensureFunds(A, U('10'), 0);
    check('开启但余额充足: 不触发转账(不足才触发)', sends.filter(s => s.opt.method === 'transfer').length === 0);
  }

  // ============ 3c. FLEX 边界加固 ============
  console.log('\n--- 3c. FLEX 边界情况 ---');
  { // donor 余额够 keep 但不够本次缺口 -> 不应选中(否则转不出来白烧 gas)
    const A = mkA('0xA', { v: U('0') }, 1), B = mkA('0xB', { v: U('25') }, 1);  // B 保留20，可用5；A 缺10
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, B);
    await api.ensureFunds(A, U('10'), 0);
    check('donor 可用额不足缺口 -> 不转账', sends.filter(s => s.opt.method === 'transfer').length === 0);
  }
  { // 平分极限: A 5U、B 25U(keep20)，A 需要 10U -> B 只能出 5U，正好够
    const A = mkA('0xA', { v: U('5') }, 1), B = mkA('0xB', { v: U('25') }, 1);
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, B);
    await api.ensureFunds(A, U('10'), 0);
    const tr = sends.find(s => s.opt.method === 'transfer');
    check('平分极限: donor 刚好够缺口时转 5U', !!tr && tr.opt.args[1] === U('5'),
      tr ? ethers.formatUnits(tr.opt.args[1], 18) : 'none');
  }
  { // 节流: 连续两次凑钱，第二次应被 30s 节流挡住(不重复扫/不重复转)
    const A = mkA('0xA', { v: U('5') }, 1), B = mkA('0xB', { v: U('100') }, 1);
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, B);
    await api.tryFlexTopUp(A, U('10'), 0n);
    const n1 = sends.filter(s => s.opt.method === 'transfer').length;
    await api.tryFlexTopUp(A, U('10'), 0n);   // 立刻第二次
    const n2 = sends.filter(s => s.opt.method === 'transfer').length;
    check('节流: 30s 内不重复发起凑钱', n1 === 1 && n2 === 1, `first=${n1} second=${n2}`);
  }
  { // 无 donor(只有一个账号) -> 不崩、不转账
    const A = mkA('0xA', { v: U('5') }, 1);
    const { api, sends } = mkEnsureFlex({ FLEX_ENABLED: true, FLEX_FUND_AGGREGATION: true }, A, null);
    await api.tryFlexTopUp(A, U('10'), 0n);
    check('无 donor -> 安全跳过不崩', sends.length === 0);
  }

  console.log('\n========================================');
  if (fail === 0) { console.log('✅ 全部通过 (' + pass + ' 项)'); process.exit(0); }
  console.log('❌ ' + fail + ' 项失败 / 共 ' + (pass + fail) + ' 项'); process.exit(1);
})().catch(e => { console.error('测试异常:', e && e.stack || e); process.exit(3); });
