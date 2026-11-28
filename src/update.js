#!/usr/bin/env node
'use strict';
/**
 * FTS 脚本自更新器（支持私有仓库 / 公开仓库）
 * 用法:
 *   node update.js --check  --current=1.8.0 --asset=autofts.sh [--quiet]
 *   node update.js --apply  --current=1.8.0 --asset=autofts.sh
 *   node update.js --auto   --current=1.8.0 --asset=autofts.sh
 * 配置: config.json 里 UPDATE_REPO / UPDATE_TOKEN；也可用环境变量
 *   FTS_UPDATE_REPO / FTS_UPDATE_TOKEN
 *
 * v1.7.1:
 *   - cmpVer 正确处理预发布版本号（1.8.0-beta < 1.8.0）
 *   - 403 区分"限流"与"需要 token"，限流后退避而不是每 10 秒刷 API
 *   - 下载改用 browser_download_url，绕开未认证 API asset 端点的 403
 *   - 用 GitHub API 的 digest 交叉校验脚本本体与 SHA256SUMS.txt
 *   - 校验和行精确匹配文件名；Windows 备份保留多份
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
const CACHE_MS = 10 * 60 * 1000;          // 10 分钟内不重复请求
const RATE_LIMIT_BACKOFF_MS = 15 * 60 * 1000;

const say = s => { if (!QUIET) console.log(s); };
const out = s => console.log(s);

// 解析 "1.8.0-beta.2" -> {num:[1,8,0], pre:'beta.2'}；无后缀 pre=''。
// 约定: 同为正式版相等；预发布版低于同数字正式版；预发布之间按段比较。
function parseVer(v) {
  const s = String(v || '').replace(/^v/i, '').split('+')[0];
  const i = s.indexOf('-');
  const main = i < 0 ? s : s.slice(0, i);
  const pre = i < 0 ? '' : s.slice(i + 1);
  const parts = main.split('.').map(n => parseInt(n, 10) || 0);
  while (parts.length < 3) parts.push(0);
  return { num: parts.slice(0, 3), pre };
}
function cmpVer(a, b) {
  const pa = parseVer(a), pb = parseVer(b);
  for (let i = 0; i < 3; i++) {
    if (pa.num[i] !== pb.num[i]) return pa.num[i] > pb.num[i] ? 1 : -1;
  }
  if (!pa.pre && !pb.pre) return 0;
  if (!pa.pre) return 1;       // 正式版 > 预发布版
  if (!pb.pre) return -1;
  const sa = pa.pre.split('.'), sb = pb.pre.split('.');
  for (let i = 0; i < Math.max(sa.length, sb.length); i++) {
    const x = sa[i] || '', y = sb[i] || '';
    if (x === y) continue;
    const nx = /^\d+$/.test(x), ny = /^\d+$/.test(y);
    if (nx && ny) return Number(x) > Number(y) ? 1 : -1;
    if (nx) return -1;         // 数字段 < 字母段(符合 semver)
    if (ny) return 1;
    return x > y ? 1 : -1;
  }
  return 0;
}
const sha256 = buf => crypto.createHash('sha256').update(buf).digest('hex');

// v1.7.1: 公开仓库未认证请求撞限流也是 403，必须和"私有仓库需要 token"区分开。
// 抽成纯函数便于回归测试。
function classifyHttpError(status, remain, msg) {
  if (status === 401) return 'AUTH';
  if (status === 429) return 'RATE_LIMIT';   // Too Many Requests 本身就是限流
  if (status !== 403) return 'HTTP';
  const rate = String(remain) === '0' || /rate limit|abuse|secondary/i.test(String(msg || ''));
  return rate ? 'RATE_LIMIT' : 'AUTH';
}

function writeCache(patch) {
  let c = {};
  try { c = JSON.parse(fs.readFileSync(CACHE, 'utf8')) || {}; } catch (e) { }
  c = Object.assign(c, patch, { ts: Date.now() });
  try { fs.writeFileSync(CACHE, JSON.stringify(c), 'utf8'); } catch (e) { }
}

async function api(url, accept) {
  const headers = { 'User-Agent': 'fts-updater', Accept: accept || 'application/vnd.github+json' };
  if (TOKEN) headers.Authorization = 'token ' + TOKEN;
  const ac = new AbortController();
  const t = setTimeout(() => { try { ac.abort(); } catch (e) { } }, 20000);
  try {
    return await fetch(url, { headers, redirect: 'follow', signal: ac.signal });
  } finally {
    clearTimeout(t);
  }
}

// sha256sum 格式: "<64位hex>  <文件名>"；只接受文件名完全相等的行。
function expectHash(sumsTxt, name) {
  for (const l of sumsTxt.split(/\r?\n/)) {
    const m = /^([a-fA-F0-9]{64})\s+\*?(\S+)\s*$/.exec(l.trim());
    if (m && m[2] === name) return m[1].toLowerCase();
  }
  return '';
}

(async () => {
  // 缓存: 10 分钟内且缓存版本不比当前新，就不再打 API；限流退避独立判断
  if (MODE !== 'apply') {
    try {
      const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'));
      if (c && c.rateLimitedUntil && Date.now() < c.rateLimitedUntil) {
        out('SKIP_RATE_LIMIT cached');
        return;
      }
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
    if (r.status === 401 || r.status === 403 || r.status === 429) {
      // 公开仓库未认证请求撞上限流也是 403，不能一律提示"需要 token"
      const remain = r.headers.get('x-ratelimit-remaining');
      let msg = '';
      try { msg = String((await r.clone().json()).message || ''); } catch (e) { }
      const kind = classifyHttpError(r.status, remain, msg);
      if (kind === 'RATE_LIMIT') {
        writeCache({ rateLimitedUntil: Date.now() + RATE_LIMIT_BACKOFF_MS });
        out('SKIP_RATE_LIMIT ' + r.status);
      } else {
        out('SKIP_AUTH ' + r.status);
      }
      return;
    }
    if (!r.ok) { out('SKIP_HTTP ' + r.status); return; }
    rel = await r.json();
  } catch (e) {
    out('SKIP_NETWORK');
    return;
  }

  const tag = String(rel.tag_name || '').replace(/^v/i, '');
  if (!tag) { out('SKIP_NO_TAG'); return; }
  writeCache({ tag, rateLimitedUntil: 0 });

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

    // v1.7.1: 优先走 browser_download_url（公开 CDN，不需要 API 鉴权）。
    // 旧版一律请求 API asset 端点，未认证时很容易撞 403 rate limit。
    const dl = url => api(url, 'application/octet-stream');
    say('下载 ' + ASSET + ' ...');
    let buf, sumsBuf;
    try {
      const r1 = await dl(asset.browser_download_url || asset.url);
      if (!r1.ok) { out('ERROR_DOWNLOAD ' + r1.status); return; }
      buf = Buffer.from(await r1.arrayBuffer());
      const r2 = await dl(sums.browser_download_url || sums.url);
      if (!r2.ok) { out('ERROR_DOWNLOAD_SUMS ' + r2.status); return; }
      sumsBuf = Buffer.from(await r2.arrayBuffer());
    } catch (e) { out('ERROR_NETWORK'); return; }

    const sumsTxt = sumsBuf.toString('utf8');
    const expect = expectHash(sumsTxt, ASSET);
    const got = sha256(buf);
    if (!expect || expect !== got) { out('ERROR_CHECKSUM'); return; }

    // v1.7.1: 用 GitHub API 独立计算的 digest 再交叉校验一遍。
    // 这仍不是离线签名信任根，但能挡住"只替换校验和文本"这一类的不一致。
    const digestOf = a => String((a && a.digest) || '').replace(/^sha256:/i, '').toLowerCase();
    const assetDigest = digestOf(asset), sumsDigest = digestOf(sums);
    if (assetDigest && assetDigest !== got) { out('ERROR_CHECKSUM'); return; }
    if (sumsDigest && sumsDigest !== sha256(sumsBuf)) { out('ERROR_CHECKSUM'); return; }

    const tmp = TARGET + '.new';
    try {
      fs.writeFileSync(tmp, buf);
      try { fs.chmodSync(tmp, 0o755); } catch (e) { }
      if (process.platform === 'win32') {
        // v1.7.1: 备份带时间戳，保留最近 3 份，不再每次覆盖同一份 .bak
        try {
          const stamp = new Date().toISOString().replace(/[:.]/g, '-');
          fs.copyFileSync(TARGET, TARGET + '.bak.' + stamp);
          const baks = fs.readdirSync(DIR)
            .filter(n => n.startsWith(path.basename(TARGET) + '.bak.'))
            .sort();
          while (baks.length > 3) {
            try { fs.unlinkSync(path.join(DIR, baks.shift())); } catch (e) { }
          }
        } catch (e) { }
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
