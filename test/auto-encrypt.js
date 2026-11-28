#!/usr/bin/env node
/** 自动加密回归测试: 有密码+明文->加密 / 无密码->跳过 / 已密文->跳过 / 加密可解密 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const ROOT = path.dirname(__dirname);
const text = fs.readFileSync(path.join(ROOT, 'src', 'core.js'), 'utf8');
function extract(name) {
  const start = text.indexOf(name);
  if (start < 0) throw new Error('找不到 ' + name);
  let depth = 0;
  for (let j = text.indexOf('{', start); j < text.length; j++) {
    if (text[j] === '{') depth++;
    else if (text[j] === '}') { depth--; if (depth === 0) return text.slice(start, j + 1); }
  }
}
const encSrc = text.slice(text.indexOf('const WALLET_ENC_VERSION'), text.indexOf('// ---------------- 网页自动探测合约地址'));
const autoSrc = [
  extract('function encryptWalletsWithPassword(password, opts)'),
  extract('function autoEncryptWallets(opts)')
].join('\n');
let pass = 0, fail = 0;
const check = (n, c, d) => { if (c) { pass++; console.log('  ✅ ' + n); } else { fail++; console.log('  ❌ ' + n + (d ? ' -> ' + d : '')); } };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fts-autoenc-'));
const walletsFile = path.join(tmp, 'wallets.json');
const plain = { wallets: [{ ADDRESS: '0xA', PRIVATE_KEY: 'aa', REFERRER: '0x0' }] };
function build(password) {
  if (password) process.env.FTS_WALLET_PASSWORD = password;
  else delete process.env.FTS_WALLET_PASSWORD;
  const stubs = { fs, path, CRYPTO: crypto, WALLETS_FILE: walletsFile, process, info: () => { }, warn: () => { }, ok: () => { }, fatal: () => { }, exitFlush: () => { } };
  const body = encSrc + '\n' + autoSrc + '\nreturn { autoEncryptWallets, decryptWalletsFile };';
  return new Function(...Object.keys(stubs), body)(...Object.values(stubs));
}
function resetPlain() { fs.writeFileSync(walletsFile, JSON.stringify(plain), { mode: 0o600 }); }
function isEncrypted() { return JSON.parse(fs.readFileSync(walletsFile, 'utf8')).encrypted === true; }
(async () => {
  resetPlain();
  let api = build('mypassword123');
  api.autoEncryptWallets();
  check('有密码+明文 -> 自动加密', isEncrypted());
  const enc = JSON.parse(fs.readFileSync(walletsFile, 'utf8'));
  const back = api.decryptWalletsFile(enc, 'mypassword123');
  check('加密后可正常解密', back.wallets.length === 1 && back.wallets[0].ADDRESS === '0xA');
  api.autoEncryptWallets();
  check('已是密文 -> 跳过不重复加密', JSON.parse(fs.readFileSync(walletsFile, 'utf8')).iv === enc.iv);
  resetPlain();
  api = build(null);
  const ret = api.autoEncryptWallets();
  check('没设密码 -> 跳过保持明文(可选)', ret === false && !isEncrypted());
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { }
  console.log('');
  if (fail === 0) { console.log('✅ 全部通过 (' + pass + ' 项)'); process.exit(0); }
  console.log('❌ ' + fail + ' 项失败 / 共 ' + (pass + fail) + ' 项'); process.exit(1);
})().catch(e => { console.error('测试异常:', e && e.stack || e); process.exit(3); });
