#!/usr/bin/env node
/**
 * 发行一致性检查（v1.8.0）
 *
 * 保证"源代码、发行版、README"三者对得上：
 *   - VERSION / README / RELEASE_NOTES / core.js 的版本号都是 1.7.1
 *   - 模板占位符与构建产物一致，产物里没有残留占位符或旧引擎版本号
 *   - dist/ 6 个附件齐全，SHA256SUMS.txt 与实际文件哈希逐项一致
 *   - dist 内嵌的引擎/更新器与 src/ 一致
 *   - 示例配置的安全默认值与代码默认值一致
 *   - 发版工作流走 tag 触发、跑全量测试、使用统一的 RELEASE_NOTES.md
 *
 * 用法: node test/release-consistency.js   （需先执行 python3 build/build.py）
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const ROOT = path.dirname(__dirname);
const VER = '1.8.0';

let bad = 0;
function check(name, cond, detail) {
  if (cond) console.log('  ✅ ' + name);
  else { bad++; console.log('  ❌ ' + name + (detail ? ' -> ' + detail : '')); }
}
const read = p => fs.readFileSync(path.join(ROOT, p), 'utf8').replace(/^\uFEFF/, '');
const exists = p => fs.existsSync(path.join(ROOT, p));
const sha = p => crypto.createHash('sha256').update(fs.readFileSync(path.join(ROOT, p))).digest('hex');

console.log('--- 版本号 ---');
check('VERSION = ' + VER, read('VERSION').trim() === VER, read('VERSION').trim());
check('README 标注当前版本 v' + VER, read('README.md').includes('当前版本：v' + VER));
check('RELEASE_NOTES.md 标题为 v' + VER, read('RELEASE_NOTES.md').startsWith('# v' + VER));
const core = read('src/core.js');
check('core.js 回落版本为 ' + VER, core.includes("|| '" + VER + "'"));
check('core.js 不再有 2.2-v8 引擎版本号', !core.includes("'2.2-v8'"));
for (const t of ['templates/autofts.sh.tpl', 'templates/autofts.ps1.tpl']) {
  check(t + ' 使用 @@VERSION@@ 占位符', read(t).includes('@@VERSION@@'));
}

console.log('\n--- README 旧的不实陈述已清除 ---');
const readme = read('README.md');
for (const s of [
  'shishengh/FTS-Queue-Bot',
  '启动时不会检查更新',
  '没有任意转账能力',
  '无后台服务：脚本只跟 BSC 节点和游戏合约通信',
  '额度越小，资金占用越少'
]) {
  check('不含: ' + s, !readme.includes(s));
}
check('README 含外联域名说明', readme.includes('api.github.com') && readme.includes('registry.npmjs.org'));
check('README 说明自动更新默认关闭', readme.includes('默认关闭'));
check('README 说明 WEB_AUTO_SYNC 默认 false', readme.includes('`WEB_AUTO_SYNC`') && readme.includes('`false`'));

console.log('\n--- 示例配置默认值 ---');
const cfg = JSON.parse(read('config.example.json'));
check('WEB_AUTO_SYNC=false', cfg.WEB_AUTO_SYNC === false);
check('WEB_SYNC_ALLOW_FUNDS_KEYS=false', cfg.WEB_SYNC_ALLOW_FUNDS_KEYS === false);
check('AUTO_UPDATE=false', cfg.AUTO_UPDATE === false);
check('APPROVE_ROUNDS=1', cfg.APPROVE_ROUNDS === 1);
check('APPROVE_MAX_ROUNDS=3', cfg.APPROVE_MAX_ROUNDS === 3);
check('APPROVE_MAX_USD=100', cfg.APPROVE_MAX_USD === 100);
check('UPDATE_REPO 指向官方仓库', cfg.UPDATE_REPO === '0041995/FTS-Queue-Bot');

console.log('\n--- 发行版产物 ---');
const assets = ['autofts.sh', 'autofts.ps1', 'update.sh', 'update.ps1', 'update.js'];
for (const a of assets) check('dist/' + a + ' 存在', exists('dist/' + a));
check('dist/SHA256SUMS.txt 存在', exists('dist/SHA256SUMS.txt'));
if (assets.every(a => exists('dist/' + a)) && exists('dist/SHA256SUMS.txt')) {
  for (const a of ['autofts.sh', 'autofts.ps1']) {
    const body = read('dist/' + a);
    check('dist/' + a + ' 头部含 v' + VER, body.split('\n').slice(0, 6).join('\n').includes('v' + VER));
    check('dist/' + a + ' 无残留占位符', !body.includes('@@'));
    check('dist/' + a + ' 无旧引擎版本号', !body.includes('2.2-v8'));
  }
  check('dist/autofts.sh 内嵌新授权逻辑', read('dist/autofts.sh').includes('function computeApproveTarget('));
  check('dist/autofts.sh 内嵌资金字段冻结', read('dist/autofts.sh').includes('WEB_SYNC_ALLOW_FUNDS_KEYS'));
  check('dist/update.js 与 src/update.js 逐字节一致',
    sha('dist/update.js') === sha('src/update.js'));
  check('dist/update.sh 无残留占位符', !read('dist/update.sh').includes('@@'));
  check('dist/update.ps1 无残留占位符', !read('dist/update.ps1').includes('@@'));

  const lines = read('dist/SHA256SUMS.txt').trim().split(/\r?\n/);
  check('SHA256SUMS.txt 恰好 5 行', lines.length === 5, String(lines.length));
  const map = {};
  for (const l of lines) {
    const m = /^([a-fA-F0-9]{64})\s+(\S+)$/.exec(l.trim());
    if (m) map[m[2]] = m[1].toLowerCase();
  }
  for (const a of assets) {
    check('SHA256SUMS 中 ' + a + ' 哈希与实际一致', map[a] === sha('dist/' + a), map[a] || '缺失');
  }
}

console.log('\n--- 发版工作流 ---');
const wf = read('.github/workflows/release.yml');
check('tag 触发而不是 push main 自动发版', wf.includes("tags: ['v*']") && !wf.includes('branches: [main]'));
check('校验 VERSION 与 tag 一致', wf.includes('校验 VERSION 与 tag 一致'));
check('Release 正文统一用 RELEASE_NOTES.md', wf.includes('--notes-file RELEASE_NOTES.md'));
check('同版本可覆盖附件', wf.includes('--clobber'));
check('用 build.py 生成校验和', wf.includes('python3 build/build.py'));
for (const t of ['web-sync.js', 'trade.js', 'safety-guards.js', 'update-vercmp.js', 'release-consistency.js', 'perf-guards.js']) {
  check('CI 跑 test/' + t, wf.includes('node test/' + t));
}

console.log('');
if (bad === 0) { console.log('✅ 全部通过: 源代码 / 发行版 / README 完全对齐到 v' + VER); process.exit(0); }
console.log(`❌ ${bad} 项不一致`); process.exit(1);
