#requires -Version 5.1
# 一键更新: 获取最新 update.js 并原地替换 autofts.ps1
# 用法: powershell -ExecutionPolicy Bypass -File .\update.ps1
# 私有仓库: 在 config.json 写入 {"UPDATE_TOKEN":"ghp_xxx"} 或设置环境变量 FTS_UPDATE_TOKEN

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $dir

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Write-Host "需要 Node.js 18+" -ForegroundColor Red; exit 1 }

$boot = @'
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
  if (!a) { console.error('该版本未附带 update.js，请改用 autofts.ps1 --update'); process.exit(1); }
  const d = await fetch(a.url, { headers: { ...h, Accept: 'application/octet-stream' } });
  if (!d.ok) { console.error('下载 update.js 失败: HTTP ' + d.status); process.exit(1); }
  fs.writeFileSync(path.join(dir, 'update.js'), Buffer.from(await d.arrayBuffer()));
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

$cur = '0.0.0'
if (Test-Path -LiteralPath 'autofts.ps1') {
    $m = Select-String -LiteralPath 'autofts.ps1' -Pattern 'v(\d+\.\d+\.\d+)' | Select-Object -First 1
    if ($m) { $cur = $m.Matches[0].Groups[1].Value }
}
& node (Join-Path $dir 'update.js') --apply --current=$cur --asset=autofts.ps1
exit $LASTEXITCODE
