#!/usr/bin/env node
/**
 * 每日场次限制回归测试
 *
 * 验证:
 *   1) 默认关闭(全局0/账号0) -> 永远放行
 *   2) 全局限制生效，达上限后拒绝
 *   3) 账号单独限制覆盖全局(更严的那个生效)
 *   4) 账号设 0 = 用全局；不设 = 用全局
 *   5) 计数按日期切天，隔天自动清零
 *   6) 计数持久化(读同一文件)
 *   7) dry-run 不计入
 *
 * 用法: node test/daily-limit.js
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const ROOT = path.dirname(__dirname);
const text = fs.readFileSync(path.join(ROOT, 'src', 'core.js'), 'utf8');

function extract(name) {
  const start = text.indexOf(name);
  if (start < 0) throw new Error('找不到 ' + name);
  let depth = 0, end = -1;
  for (let j = text.indexOf('{', start); j < text.length; j++) {
    if (text[j] === '{') depth++;
    else if (text[j] === '}') { depth--; if (depth === 0) { end = j + 1; break; } }
  }
  return text.slice(start, end);
}
const src = [
  "const ENTRY_COUNTER_FILE = path.join(ROOT, 'entry-counter.json');",
  extract('function todayKey()'),
  extract('function readEntryCounter()'),
  extract('function writeEntryCounter(c)'),
  extract('function checkEntryLimit(inst)'),
  extract('function recordEntry(inst)')
].join('\n');

let pass = 0, fail = 0;
const check = (name, cond, detail) => {
  if (cond) { pass++; console.log('  ✅ ' + name); }
  else { fail++; console.log('  ❌ ' + name + (detail ? ' -> ' + detail : '')); }
};

// 用临时目录模拟计数文件
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fts-limit-'));
const counterFile = path.join(tmp, 'entry-counter.json');
let fakeDate = '2026-11-28T10:00:00';

function build(cfg, dry) {
  const stubs = {
    CFG: cfg, DRY_RUN: !!dry, ROOT: tmp, fs, path,
    warnOnce: () => { }, formatError: e => String(e),
    Date: class extends Date {
      constructor(...a) { super(...(a.length ? a : [fakeDate])); }
      static now() { return new Date(fakeDate).getTime(); }
    }
  };
  const body = src + '\nreturn { checkEntryLimit, recordEntry, readEntryCounter, todayKey };';
  return new Function(...Object.keys(stubs), body)(...Object.values(stubs));
}
function reset() { try { fs.unlinkSync(counterFile); } catch (e) { } }

(async () => {
  // 1) 默认关闭
  reset();
  let api = build({ DAILY_ENTRY_LIMIT: 0 });
  check('默认关闭 -> 放行', api.checkEntryLimit({ address: '0xA', conf: {} }).allowed);

  // 2) 全局限制
  reset();
  api = build({ DAILY_ENTRY_LIMIT: 2 });
  const A = { address: '0xA', conf: {} };
  check('全局2场: 第1次放行', api.checkEntryLimit(A).allowed);
  api.recordEntry(A); api.recordEntry(A);
  check('全局2场: 已满后拒绝', !api.checkEntryLimit(A).allowed, JSON.stringify(api.checkEntryLimit(A)));
  check('计数落盘 total=2', api.readEntryCounter().total === 2);

  // 3) 账号单独限制(更严)
  reset();
  api = build({ DAILY_ENTRY_LIMIT: 10 });
  const B = { address: '0xB', conf: { DAILY_ENTRY_LIMIT: 1 } };
  api.recordEntry(B);
  const rb = api.checkEntryLimit(B);
  check('账号限制1场覆盖全局10场', !rb.allowed && /本账号/.test(rb.reason), JSON.stringify(rb));

  // 4) 账号设 0 / 不设 -> 用全局
  reset();
  api = build({ DAILY_ENTRY_LIMIT: 1 });
  check('账号设0 -> 用全局', api.checkEntryLimit({ address: '0xC', conf: { DAILY_ENTRY_LIMIT: 0 } }).allowed);
  api.recordEntry({ address: '0xC', conf: { DAILY_ENTRY_LIMIT: 0 } });
  check('全局满后账号设0也被拦', !api.checkEntryLimit({ address: '0xC', conf: { DAILY_ENTRY_LIMIT: 0 } }).allowed);

  // 5) 隔天清零
  reset();
  api = build({ DAILY_ENTRY_LIMIT: 1 });
  api.recordEntry(A);
  check('当天已满', !api.checkEntryLimit(A).allowed);
  fakeDate = '2026-11-29T09:00:00';
  check('隔天自动清零可再跑', api.checkEntryLimit(A).allowed);

  // 6) 持久化: 新实例读同一文件
  reset();
  const api1 = build({ DAILY_ENTRY_LIMIT: 5 });
  api1.recordEntry(A);
  const api2 = build({ DAILY_ENTRY_LIMIT: 5 });
  check('新实例读到已有计数', api2.readEntryCounter().total === 1);

  // 7) dry-run 不计入
  reset();
  const apiDry = build({ DAILY_ENTRY_LIMIT: 1 }, true);
  apiDry.recordEntry(A);
  check('dry-run 不写计数', apiDry.readEntryCounter().total === 0);

  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { }
  console.log('');
  if (fail === 0) { console.log('✅ 全部通过 (' + pass + ' 项)'); process.exit(0); }
  console.log('❌ ' + fail + ' 项失败 / 共 ' + (pass + fail) + ' 项'); process.exit(1);
})().catch(e => { console.error('测试异常:', e && e.stack || e); process.exit(3); });
