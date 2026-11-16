#!/usr/bin/env node
'use strict';
/**
 * FTS 脚本自更新器（支持私有仓库）
 * 用法:
 *   node update.js --check  --current=1.2.0 --asset=autofts.sh [--quiet]
 *   node update.js --apply  --current=1.2.0 --asset=autofts.sh
 *   node update.js --auto   --current=1.2.0 --asset=autofts.sh
 * 配置: config.json 里 UPDATE_REPO / UPDATE_TOKEN；也可用环境变量
 *   FTS_UPDATE_REPO / FTS_UPDATE_TOKEN
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DIR = __dirname;
const argv = process.argv.slice(2);
const argOf = k => {
  const p = argv.find(a => a.indexOf('--' + k + '=') === 0);
  return p ? p.slice(k.length + 3) : null;
};
const has = k => argv.includes('--' + k);
const MODE = has('apply') ? 'apply' : (has('auto') ? 'auto' : 'check');
const QUIET = has('quiet') || MODE === 'auto';

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '')); } catch (e) { return null; }
}
const cfg = readJson(path.join(DIR, 'config.json')) || {};
const REPO = process.env.FTS_UPDATE_REPO || cfg.UPDATE_REPO || '0041995/FTS-Queue-Bot';
const TOKEN = process.env.FTS_UPDATE_TOKEN || cfg.UPDATE_TOKEN || '';
const ASSET = argOf('asset') || (process.platform === 'win32' ? 'autofts.ps1' : 'autofts.sh');
const CURRENT = (argOf('current') || '0.0.0').replace(/^v/i, '');
const TARGET = path.join(DIR, ASSET);
const CACHE = path.join(DIR, '.update-cache.json');
const CACHE_MS = 10 * 60 * 1000;   // 10 分钟内不重复请求；新版本最多延迟 10 分钟被发现

const say = s => { if (!QUIET) console.log(s); };
const out = s => console.log(s);

function cmpVer(a, b) {
  const pa = String(a).replace(/^v/i, '').split(/[.-]/).map(n => parseInt(n, 10) || 0);
  const pb = String(b).replace(/^v/i, '').split(/[.-]/).map(n => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (x !== y) return x > y ? 1 : -1;
  }
  return 0;
}
const sha256 = buf => crypto.createHash('sha256').update(buf).digest('hex');

async function api(url, accept) {
  const headers = { 'User-Agent': 'fts-updater', Accept: accept || 'application/vnd.github+json' };
  if (TOKEN) headers.Authorization = 'token ' + TOKEN;
  const ac = new AbortController();
  const t = setTimeout(() => { try { ac.abort(); } catch (e) { } }, 15000);
  try {
    return await fetch(url, { headers, redirect: 'follow', signal: ac.signal });
  } finally {
    clearTimeout(t);
  }
}

(async () => {
  // 缓存: 10 分钟内且缓存的版本不比当前新，就不再打 API
  if (MODE !== 'apply') {
    try {
      const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'));
      if (c && c.ts && Date.now() - c.ts < CACHE_MS && c.tag && cmpVer(c.tag, CURRENT) <= 0) {
        out('UP_TO_DATE ' + CURRENT);
        return;
      }
    } catch (e) { }
  }

  let rel;
  try {
    const r = await api(`https://api.github.com/repos/${REPO}/releases/latest`);
    if (r.status === 404) { out('SKIP_PRIVATE_OR_NOT_FOUND'); return; }
    if (r.status === 401 || r.status === 403) { out('SKIP_AUTH ' + r.status); return; }
    if (!r.ok) { out('SKIP_HTTP ' + r.status); return; }
    rel = await r.json();
  } catch (e) {
    out('SKIP_NETWORK');
    return;
  }

  const tag = String(rel.tag_name || '').replace(/^v/i, '');
  if (!tag) { out('SKIP_NO_TAG'); return; }
  try { fs.writeFileSync(CACHE, JSON.stringify({ ts: Date.now(), tag }), 'utf8'); } catch (e) { }

  if (cmpVer(tag, CURRENT) <= 0) { out('UP_TO_DATE ' + CURRENT); return; }
  out('NEWER ' + tag);
  say('发现新版本: v' + tag + ' (当前 v' + CURRENT + ')');
  if (rel.body) say(rel.body.split('\n').slice(0, 12).join('\n'));

  if (MODE !== 'apply' && MODE !== 'auto') return;
  await doApply(tag);

  async function doApply(ver) {
    const asset = (rel.assets || []).find(a => a.name === ASSET);
    const sums = (rel.assets || []).find(a => a.name === 'SHA256SUMS.txt');
    if (!asset) { out('ERROR_NO_ASSET ' + ASSET); return; }
    if (!sums) { out('ERROR_NO_SUMS'); return; }

    say('下载 ' + ASSET + ' ...');
    let buf, sumsTxt;
    try {
      const r1 = await api(asset.url, 'application/octet-stream');
      if (!r1.ok) { out('ERROR_DOWNLOAD ' + r1.status); return; }
      buf = Buffer.from(await r1.arrayBuffer());
      const r2 = await api(sums.url, 'application/octet-stream');
      if (!r2.ok) { out('ERROR_DOWNLOAD_SUMS ' + r2.status); return; }
      sumsTxt = await r2.text();
    } catch (e) { out('ERROR_NETWORK'); return; }

    const line = sumsTxt.split(/\r?\n/).find(l => l.trim().endsWith('  ' + ASSET));
    const expect = line ? line.trim().split(/\s+/)[0].toLowerCase() : '';
    const got = sha256(buf);
    if (!expect || expect !== got) { out('ERROR_CHECKSUM'); return; }

    const tmp = TARGET + '.new';
    try {
      fs.writeFileSync(tmp, buf);
      try { fs.chmodSync(tmp, 0o755); } catch (e) { }
      if (process.platform === 'win32') {
        try { fs.copyFileSync(TARGET, TARGET + '.bak'); } catch (e) { }
        fs.copyFileSync(tmp, TARGET);       // Windows 覆盖已有文件
        fs.unlinkSync(tmp);
      } else {
        fs.renameSync(tmp, TARGET);         // POSIX 原子替换
      }
    } catch (e) {
      out('ERROR_WRITE ' + (e.code || e.message));
      return;
    }
    out('UPDATED ' + ver + ' ' + ASSET);
    say('已更新到 v' + ver + '，下次启动生效');
  }
})().catch(e => { out('ERROR ' + (e && e.message)); });
