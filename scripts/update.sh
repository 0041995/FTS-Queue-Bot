#!/bin/bash
# 一键更新: 获取最新 update.js 并原地替换 autofts.sh
# 用法: bash update.sh
# 私有仓库: 在 config.json 写入 {"UPDATE_TOKEN":"ghp_xxx"} 或 export FTS_UPDATE_TOKEN=...
# v1.7.1: 版本只从文件头注释精确读取、下载走 browser_download_url、403 明确区分限流
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
command -v node >/dev/null 2>&1 || { echo "需要 Node.js 18+"; exit 1; }

node - "$DIR" <<'NODE'
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const dir = process.argv[2];
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path.join(dir, 'config.json'), 'utf8').replace(/^\uFEFF/, '')); } catch (e) { }
const repo = process.env.FTS_UPDATE_REPO || cfg.UPDATE_REPO || '0041995/FTS-Queue-Bot';
const token = process.env.FTS_UPDATE_TOKEN || cfg.UPDATE_TOKEN || '';
(async () => {
  const h = { 'User-Agent': 'fts-updater', Accept: 'application/vnd.github+json' };
  if (token) h.Authorization = 'token ' + token;
  const r = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, { headers: h });
  if (!r.ok) {
    if (r.status === 403 || r.status === 429) {
      console.error('获取版本失败: HTTP ' + r.status + '（GitHub API 限流，请稍后重试；公开仓库无需 token）');
    } else if (r.status === 404) {
      console.error('获取版本失败: HTTP 404（私有仓库请在 config.json 配置 UPDATE_TOKEN）');
    } else {
      console.error('获取版本失败: HTTP ' + r.status);
    }
    process.exit(1);
  }
  const rel = await r.json();
  const a = (rel.assets || []).find(x => x.name === 'update.js');
  if (!a) { console.error('该版本未附带 update.js，请改用 autofts.sh --update'); process.exit(1); }
  // 公开 CDN 直链，避开未认证 API asset 端点的 403
  const d = await fetch(a.browser_download_url || a.url, { headers: h });
  if (!d.ok) { console.error('下载 update.js 失败: HTTP ' + d.status); process.exit(1); }
  const buf = Buffer.from(await d.arrayBuffer());
  const digest = String(a.digest || '').replace(/^sha256:/i, '').toLowerCase();
  if (digest && digest !== crypto.createHash('sha256').update(buf).digest('hex')) {
    console.error('update.js 与 GitHub API digest 不一致，已拒绝写入'); process.exit(1);
  }
  fs.writeFileSync(path.join(dir, 'update.js'), buf);
  console.log('已获取更新器，目标版本 ' + rel.tag_name);
})().catch(e => { console.error('网络错误: ' + e.message); process.exit(1); });
NODE

# v1.7.1: 只匹配文件头注释里的三段版本号，正文注释里出现其它版本号也不会取错
CUR="$(node -e '
const fs=require("fs");
const s=fs.readFileSync(process.argv[1],"utf8");
const m=s.match(/^#\s*FTS[^\n]*\bv(\d+\.\d+\.\d+)\b/m);
process.stdout.write(m?m[1]:"0.0.0");
' autofts.sh 2>/dev/null || echo 0.0.0)"
node update.js --apply --current="${CUR:-0.0.0}" --asset=autofts.sh
