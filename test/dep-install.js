#!/usr/bin/env node
/**
 * 依赖自动安装回归测试
 *
 * 验证:
 *   1) sh/ps1 都含 --install 参数解析
 *   2) 三个国内镜像都在列表且顺序正确
 *   3) 官方源 registry.npmjs.org 不在安装逻辑里(仅允许文档提及)
 *   4) 安装命令都带 --registry 参数
 *   5) 支持 FTS_NPM_REGISTRIES 覆盖
 *   6) 两个版本固定且一致
 *
 * 用法: node test/dep-install.js
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const sh = fs.readFileSync(path.join(ROOT, 'templates', 'autofts.sh.tpl'), 'utf8');
const ps = fs.readFileSync(path.join(ROOT, 'templates', 'autofts.ps1.tpl'), 'utf8');
let pass = 0, fail = 0;
const check = (n, c, d) => { if (c) { pass++; console.log('  ✅ ' + n); } else { fail++; console.log('  ❌ ' + n + (d ? ' -> ' + d : '')); } };

const mirrors = ['registry.npmmirror.com', 'mirrors.huaweicloud.com', 'mirrors.cloud.tencent.com'];

check('sh 有 --install 参数', sh.includes('--install'));
check('ps1 有 --install 参数', ps.includes('--install'));
check('sh 有 install 模式执行', sh.includes('"$MODE" = "install"'));
check('ps1 有 install 模式执行', ps.includes("$Mode -eq 'install'"));

for (const m of mirrors) {
  check('sh 含国内镜像 ' + m, sh.includes(m));
  check('ps1 含国内镜像 ' + m, ps.includes(m));
}
// 顺序: npmmirror < huaweicloud < tencent
const i1 = sh.indexOf('registry.npmmirror.com');
const i2 = sh.indexOf('mirrors.huaweicloud.com');
const i3 = sh.indexOf('mirrors.cloud.tencent.com');
check('sh 镜像顺序正确', i1 > 0 && i2 > i1 && i3 > i2, `${i1}/${i2}/${i3}`);

// 官方源不能出现在"安装"相关行(注释/文档允许)
const shInstallLines = sh.split('\n').filter(l => /npm install|--registry=/.test(l));
check('sh 安装行不含官方源', !shInstallLines.some(l => l.includes('registry.npmjs.org')));
const psInstallLines = ps.split('\n').filter(l => /\.Source install|--registry=/.test(l));
check('ps1 安装行不含官方源', !psInstallLines.some(l => l.includes('registry.npmjs.org')));

// 安装命令都带 --registry
const npmInstalls = shInstallLines.filter(l => l.trim().startsWith('npm install') && !l.trim().startsWith('#'));
check('sh npm install 全部带 --registry', npmInstalls.every(l => l.includes('--registry=')), JSON.stringify(npmInstalls));
const psInstalls = psInstallLines.filter(l => l.trim().startsWith('& $npmCmd.Source install'));
check('ps1 install 全部带 --registry', psInstalls.every(l => l.includes('--registry=')));

check('sh 支持 FTS_NPM_REGISTRIES 覆盖', sh.includes('FTS_NPM_REGISTRIES'));
check('ps1 支持 FTS_NPM_REGISTRIES 覆盖', ps.includes('FTS_NPM_REGISTRIES'));

const v1 = (sh.match(/ETHERS_VERSION="([\d.]+)"/) || [])[1];
const v2 = (ps.match(/EthersVersion = '([\d.]+)'/) || [])[1];
check('两版 ethers 版本固定且一致', v1 && v1 === v2, `sh=${v1} ps=${v2}`);

console.log('');
if (fail === 0) { console.log('✅ 全部通过 (' + pass + ' 项)'); process.exit(0); }
console.log('❌ ' + fail + ' 项失败 / 共 ' + (pass + fail) + ' 项'); process.exit(1);
