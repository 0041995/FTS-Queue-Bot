#!/usr/bin/env node
/**
 * 钱包文件加密回归测试
 *
 * 验证:
 *   1) 加密后文件不含明文私钥
 *   2) 正确密码能解密还原
 *   3) 错误密码被拒绝
 *   4) 篡改密文被 GCM 认证拒绝
 *   5) 不同 salt 产生不同密文(防彩虹表)
 *
 * 用法: node test/wallet-crypto.js
 */

const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const SRC = path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');

function extract(sig, endSig) {
  const s = text.indexOf(sig);
  if (s < 0) throw new Error('找不到 ' + sig);
  const e = text.indexOf(endSig, s);
  if (e < 0) throw new Error('找不到 ' + endSig);
  return text.slice(s, e);
}
const cryptoSrc = extract('const CRYPTO = require(\'crypto\');', 'function getWalletPassword()');

const factory = new Function('require', cryptoSrc + '\nreturn {encryptWalletsFile, decryptWalletsFile, deriveKey};');
const { encryptWalletsFile, decryptWalletsFile } = factory(require);

const PK = 'a'.repeat(64);
const plain = { wallets: [{ PRIVATE_KEY: PK, ADDRESS: '0x123', REFERRER: '0x456' }] };
const errors = [];
const assert = (c, m) => { if (!c) errors.push(m); };

(async () => {
  // 1) 加密 + 不含明文
  const enc = encryptWalletsFile(plain, 'mypassword123');
  assert(enc.encrypted === true, '应标记为加密');
  const encStr = JSON.stringify(enc);
  assert(!encStr.includes(PK), '密文不应包含明文私钥');
  console.log('✅ 密文不含明文私钥');

  // 2) 正确密码解密
  const dec = decryptWalletsFile(enc, 'mypassword123');
  assert(dec.wallets[0].PRIVATE_KEY === PK, '解密后私钥应还原');
  console.log('✅ 正确密码解密还原');

  // 3) 错误密码
  let wrongRejected = false;
  try { decryptWalletsFile(enc, 'wrongpassword'); } catch (e) { wrongRejected = true; }
  assert(wrongRejected, '错误密码应被拒绝');
  console.log('✅ 错误密码被拒绝');

  // 4) 篡改密文
  const tampered = JSON.parse(encStr);
  tampered.data = (tampered.data[0] === 'a' ? 'b' : 'a') + tampered.data.slice(1);
  let tamperRejected = false;
  try { decryptWalletsFile(tampered, 'mypassword123'); } catch (e) { tamperRejected = true; }
  assert(tamperRejected, '篡改密文应被 GCM 拒绝');
  console.log('✅ 篡改密文被 GCM 认证拒绝');

  // 5) 不同 salt
  const enc2 = encryptWalletsFile(plain, 'mypassword123');
  assert(enc.salt !== enc2.salt && enc.data !== enc2.data, '两次加密应产生不同 salt/密文');
  console.log('✅ 随机 salt（防彩虹表）');

  console.log('');
  if (errors.length === 0) { console.log('✅ 全部通过: 钱包加密安全可靠'); process.exit(0); }
  console.log('❌ 失败:'); errors.forEach(e => console.log('   -', e));
  process.exit(1);
})().catch(e => { console.error(e); process.exit(2); });
