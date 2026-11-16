#!/bin/bash
# 一键更新: 获取最新 update.js 并原地替换 autofts.sh
# 用法: bash update.sh
# 私有仓库: 在 config.json 写入 {"UPDATE_TOKEN":"ghp_xxx"} 或 export FTS_UPDATE_TOKEN=...
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
command -v node >/dev/null 2>&1 || { echo "需要 Node.js 18+"; exit 1; }

node - "$DIR" <<'NODE'
const fs = require('fs'), path = require('path');
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
    console.error('获取版本失败: HTTP ' + r.status + (r.status === 404 ? '（私有仓库请在 config.json 配置 UPDATE_TOKEN）' : ''));
    process.exit(1);
  }
  const rel = await r.json();
  const a = (rel.assets || []).find(x => x.name === 'update.js');
  if (!a) { console.error('该版本未附带 update.js，请改用 autofts.sh --update'); process.exit(1); }
  const d = await fetch(a.url, { headers: { ...h, Accept: 'application/octet-stream' } });
  if (!d.ok) { console.error('下载 update.js 失败: HTTP ' + d.status); process.exit(1); }
  fs.writeFileSync(path.join(dir, 'update.js'), Buffer.from(await d.arrayBuffer()));
  console.log('已获取更新器，目标版本 ' + rel.tag_name);
})().catch(e => { console.error('网络错误: ' + e.message); process.exit(1); });
NODE

CUR="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' autofts.sh 2>/dev/null | head -n1 | sed 's/^v//')"
node update.js --apply --current="${CUR:-0.0.0}" --asset=autofts.sh
