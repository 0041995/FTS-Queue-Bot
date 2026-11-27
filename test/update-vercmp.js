#!/usr/bin/env node
/**
 * 更新器回归测试（纯函数，不联网）
 *
 * 覆盖:
 *   1) cmpVer: 三段版本号、v 前缀、预发布版本低于正式版、预发布之间比较
 *   2) classifyHttpError: 401 需要 token / 403 限流 / 403 真鉴权失败 / 429 / 其它
 *   3) expectHash: 校验和行精确匹配文件名，不被相似文件名骗过
 *
 * 用法: node test/update-vercmp.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const text = fs.readFileSync(path.join(ROOT, 'src', 'update.js'), 'utf8');

function ex(a, b) {
  const i = text.indexOf(a), j = text.indexOf(b, i);
  if (i < 0 || j < 0) throw new Error(`抽取标记缺失: ${a} / ${b}`);
  return text.slice(i, j);
}
const verSrc = ex('function parseVer(', 'const sha256 =');
const clsSrc = ex('function classifyHttpError(', 'function writeCache(');
const hashSrc = ex('function expectHash(', '(async () =>');
const U = new Function(verSrc + '\n' + clsSrc + '\n' + hashSrc +
  '\nreturn {cmpVer, classifyHttpError, expectHash};')();

let bad = 0;
function check(name, cond, detail) {
  if (cond) console.log('  ✅ ' + name);
  else { bad++; console.log('  ❌ ' + name + (detail ? ' -> ' + detail : '')); }
}

console.log('--- cmpVer ---');
check('1.7.1 < 1.7.2', U.cmpVer('1.7.1', '1.7.2') === -1);
check('1.7.2 > 1.7.1', U.cmpVer('1.7.2', '1.7.1') === 1);
check('1.7.1 == 1.7.1', U.cmpVer('1.7.1', '1.7.1') === 0);
check('v 前缀等价', U.cmpVer('v1.7.1', '1.7.1') === 0);
check('1.8.0-beta < 1.8.0（旧版 parseInt 会判相等）', U.cmpVer('1.8.0-beta', '1.8.0') === -1);
check('1.8.0 > 1.8.0-beta', U.cmpVer('1.8.0', '1.8.0-beta') === 1);
check('beta.2 < beta.10', U.cmpVer('1.8.0-beta.2', '1.8.0-beta.10') === -1);
check('1.7 < 1.7.0.1（缺段补 0）', U.cmpVer('1.7', '1.7.0') === 0);
check('1.10.0 > 1.9.9', U.cmpVer('1.10.0', '1.9.9') === 1);

console.log('\n--- classifyHttpError ---');
check('401 -> AUTH', U.classifyHttpError(401, null, '') === 'AUTH');
check('403 + remaining=0 -> RATE_LIMIT', U.classifyHttpError(403, '0', '') === 'RATE_LIMIT');
check('403 + rate limit 文案 -> RATE_LIMIT', U.classifyHttpError(403, '59', 'API rate limit exceeded') === 'RATE_LIMIT');
check('403 + 真鉴权失败 -> AUTH', U.classifyHttpError(403, '59', 'Bad credentials') === 'AUTH');
check('429 -> RATE_LIMIT', U.classifyHttpError(429, null, '') === 'RATE_LIMIT');
check('500 -> HTTP', U.classifyHttpError(500, null, '') === 'HTTP');

console.log('\n--- expectHash ---');
const H = 'a'.repeat(64), H2 = 'b'.repeat(64);
const sums = [
  H + '  autofts.sh',
  H2 + '  autofts.ps1',
  H2 + '  autofts.sh.bak',
  'notahash  autofts.sh'
].join('\n');
check('精确命中 autofts.sh', U.expectHash(sums, 'autofts.sh') === H);
check('精确命中 autofts.ps1', U.expectHash(sums, 'autofts.ps1') === H2);
check('相似文件名不误匹配', U.expectHash(sums, 'autofts.sh.bak') === H2);
check('不存在的资产返回空', U.expectHash(sums, 'update.js') === '');
check('非法 hex 行被忽略', U.expectHash('notahash  autofts.sh', 'autofts.sh') === '');

console.log('');
if (bad === 0) { console.log('✅ 全部通过: 版本比较 / 限流分类 / 校验和匹配正常'); process.exit(0); }
console.log(`❌ ${bad} 项失败`); process.exit(1);
