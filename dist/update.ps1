#requires -Version 5.1
# 一键更新: 获取最新 update.js 并原地替换 autofts.ps1
# 用法: powershell -ExecutionPolicy Bypass -File .\update.ps1
# 私有仓库: 在 config.json 写入 {"UPDATE_TOKEN":"ghp_xxx"} 或设置环境变量 FTS_UPDATE_TOKEN
# v1.7.1: 版本只从文件头注释精确读取、下载走 browser_download_url、403 明确区分限流

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $dir

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Write-Host "需要 Node.js 18+" -ForegroundColor Red; exit 1 }

$boot = @'
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
  if (!a) { console.error('该版本未附带 update.js，请改用 autofts.ps1 --update'); process.exit(1); }
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
'@

[System.IO.File]::WriteAllText((Join-Path $dir '.update-boot.js'), $boot, (New-Object System.Text.UTF8Encoding($false)))
try {
    & node (Join-Path $dir '.update-boot.js') $dir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Remove-Item -LiteralPath (Join-Path $dir '.update-boot.js') -Force -ErrorAction SilentlyContinue
}

# v1.7.1: 只在文件头前几行找版本号，不再用首个出现的三段版本号
$cur = '0.0.0'
if (Test-Path -LiteralPath 'autofts.ps1') {
    $head = (Get-Content -LiteralPath 'autofts.ps1' -TotalCount 8) -join "`n"
    $m = [regex]::Match($head, 'v(\d+\.\d+\.\d+)')
    if ($m.Success) { $cur = $m.Groups[1].Value }
}
& node (Join-Path $dir 'update.js') --apply --current=$cur --asset=autofts.ps1
exit $LASTEXITCODE
