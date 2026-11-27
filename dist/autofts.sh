#!/bin/bash
# ==============================================================
# FTS 多账号自动打金脚本 v1.7.1 - 加固版 (Termux / Linux 通用)
# ==============================================================
set -uo pipefail

# 告诉内嵌的 core.js/probe.js "我是被哪个启动器拉起来的"，用于提示文案
export FTS_LAUNCHER=bash

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORK_DIR" || exit 1
ORIG_ARGS=("$@")        # 自动更新后原地重启用
export FTS_APP_VERSION="1.7.1"
mkdir -p logs
# Windows 上用记事本把 json 存成 "UTF-8 带 BOM" 时，JSON.parse 会直接抛错、
# 整份配置被静默忽略。启动时统一把 BOM 去掉，一劳永逸。
strip_bom() {
  [ -f "$1" ] || return 0
  node -e 'const fs=require("fs");const p=process.argv[1];let s=fs.readFileSync(p,"utf8");if(s.charCodeAt(0)===0xFEFF){fs.writeFileSync(p,s.slice(1),"utf8");console.log("已移除 BOM: "+p)}' "$1" 2>/dev/null || true
}
PID_FILE="$WORK_DIR/logs/engine.pid"
STOP_FLAG="$WORK_DIR/logs/.stop"   # --stop 的"可靠信号": 即使 PID 丢失/被复用也能让外壳循环退出

MODE="run"
DO_INIT=0
DO_WIZARD=0
PROBE_ARGS=""

usage() {
  cat << 'HELP'
用法: bash autofts.sh [模式]

模式:
  --probe      链上只读探测: 验证合约地址/函数在不在(完全不需要钱包私钥)
  --selftest   只读体检: 环境/依赖/RPC/合约/余额/授权 + 交易预演(一分钱不花)
  --dry-run    全流程预演: 走完所有逻辑但交易不上链
  --run        正式运行(默认)
  --init       打开配置向导(房间/抢位区间/延迟/手续费/账号)，配完即退出
  --settings   同 --init，随时回来改设置
  --encrypt    加密 wallets.json(设置密码，运行时用 FTS_WALLET_PASSWORD 提供)
  --sync-web   从游戏网页探测合约地址(默认只提示，资金字段需显式允许才写回)
  --update     一键更新到最新版本(原地替换脚本，支持私有仓库)
  --stop       停止后台运行的引擎
  --help       查看本帮助

建议首次使用顺序:
  --probe  ->  --init  ->  --selftest  ->  --dry-run  ->  --run

常用可调项(都在 --init 向导里，也可直接改 config.json):
  ROOMS              参与房间 0=10U 1=50U 2=100U
  SNIPE_MIN_COUNT / SNIPE_MAX_COUNT  抢单人数区间，默认 30/60
  SNIPE_DELAY_MS     抢单延迟(毫秒)，默认 0
  GAS_GWEI           固定 gas 价，默认 0.05；写 null 则改为自动(按链上价 × GAS_MULT)
  CLAIM_INTERVAL_MS  领取返利扫描间隔，默认 20000
  MIN_BNB_GAS        最低 BNB 提醒阈值，默认 0.005
  MINING_CLAIM_MS    矿机产出领取扫描间隔，默认 45000（只要可领就立刻领）
  UPDATE_TOKEN       可选：仅私有仓库需要的 GitHub 只读 token；公开仓库无需 token
  AUTO_UPDATE        是否启用自动更新（默认关，需在 --init 的 [10] 显式开启）
  UPDATE_CHECK_MS    自动更新检查间隔，默认 1200000（20 分钟，仅在空闲窗口替换）
  MINER_ENABLED      是否自动组矿机；MINER_MODE=old/new/both
  外联域名          BSC RPC/WSS、fatris.fans、api.github.com、registry.npmjs.org、1rpc.io
HELP
  exit 0
}

ok_msg() { echo -e "\e[32m✅ $*\e[0m"; }
warn_msg() { echo -e "\e[33m⚠️  $*\e[0m"; }
die() { echo -e "\e[31m❌ [FATAL] $*\e[0m"; exit 1; }

# ---- 唤醒锁: 统一登记，任何退出路径都能释放 ----
WAKE_LOCKED=0
release_wake() {
  if [ "$WAKE_LOCKED" = 1 ]; then
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
    echo "已释放唤醒锁"
    WAKE_LOCKED=0
  fi
}
acquire_wake() {
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock && WAKE_LOCKED=1 && ok_msg "已获取 CPU 唤醒锁(息屏不断网)"
  else
    warn_msg "未找到 termux-wake-lock。可选: pkg install termux-api"
    warn_msg "建议同时: 系统设置 -> 电池优化 -> 将 Termux 设为不优化，否则息屏后可能被杀"
  fi
}
# 任何退出/中断都先释放唤醒锁，避免手机一直亮屏耗电
on_exit() { release_wake; }
trap on_exit EXIT INT TERM

stop_engine() {
  # 关键: 必须先停"外壳 while 循环"，再停 node。
  # 只停 node 的话，外壳会以为程序崩了，几秒后又把 node 拉起来(--stop 停不下来的根因)。
  local node_pid="" shell_pid="" found=0 p=""
  local _win_core="" _cands="" _pid="" _line="" _ok=0

  # 0) 先落"停止标志"。外壳循环每轮开头都会检查它，
  #    这样即使 PID 文件丢了 / PID 被复用 / 没有 pgrep，也一定能停下来。
  : > "$STOP_FLAG" 2>/dev/null || true

  if [ -f "$PID_FILE" ]; then
    node_pid="$(sed -n 's/^node=//p'  "$PID_FILE" 2>/dev/null | head -1)"
    shell_pid="$(sed -n 's/^shell=//p' "$PID_FILE" 2>/dev/null | head -1)"
  fi

  # PID 复用防护: 手机重启后 PID 会被别的进程占用，直接 kill 会误杀无辜进程
  alive_ours() {
    local q="$1" cmd=""
    [ -n "$q" ] || return 1
    kill -0 "$q" 2>/dev/null || return 1
    cmd="$(ps -p "$q" -o args= 2>/dev/null || echo '')"
    if [ -z "$cmd" ]; then
      # 读不到命令行(ps 不支持 -o / 权限不足)时不要贸然认领这个 PID:
      # PID 被复用时 kill 会误伤无关进程，比"少停一次"严重得多
      warn_msg "无法校验 PID $q 的命令行，跳过(如仍占用请手动结束)"
      return 1
    fi
    case "$cmd" in *autofts.sh*|*core.js*|*probe.js*) return 0 ;; esac
    return 1
  }

  if alive_ours "$shell_pid"; then
    kill -TERM "$shell_pid" 2>/dev/null
    found=1
    echo "已停止外壳守护循环 (PID $shell_pid)"
  fi
  if alive_ours "$node_pid"; then
    kill -TERM "$node_pid" 2>/dev/null
    found=1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$node_pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$node_pid" 2>/dev/null && kill -KILL "$node_pid" 2>/dev/null
    echo "已停止引擎 (PID $node_pid)"
  fi
  rm -f "$PID_FILE"

  # 兜底(PID 文件丢失的情况)
  # 注意: MSYS/Git Bash 下 pgrep 看不到原生 node.exe，必须再退回解析 ps；
  # 命令行里的路径可能是 /c/... 也可能是 C:/...，两种都要认。
  _win_core=""
  if command -v cygpath >/dev/null 2>&1; then
    _win_core="$(cygpath -m "$WORK_DIR" 2>/dev/null)/core.js"
  fi
  _cands=""
  if command -v pgrep >/dev/null 2>&1; then
    _cands="$(pgrep -f "core\.js" 2>/dev/null || true)"
  fi
  if [ -z "${_cands// /}" ]; then
    _cands="$(ps -ef 2>/dev/null | grep -i "core\.js" | grep -v grep | awk '{print $2}' || true)"
  fi
  p=""
  for _pid in $_cands; do
    _line="$(ps -ef 2>/dev/null | awk -v q="$_pid" '$2==q' || true)"
    _ok=0
    case "$_line" in *"$WORK_DIR/core.js"*) _ok=1 ;; esac
    if [ "$_ok" = 0 ] && [ -n "$_win_core" ]; then
      case "$_line" in *"$_win_core"*) _ok=1 ;; esac
    fi
    if [ "$_ok" = 0 ] && [ -r "/proc/$_pid/cwd" ]; then
      [ "$(readlink -f "/proc/$_pid/cwd" 2>/dev/null)" = "$WORK_DIR" ] && _ok=1
    fi
    [ "$_ok" = 1 ] && p="$p $_pid"
  done
  if [ -n "${p// /}" ]; then
    # shellcheck disable=SC2086
    kill -TERM $p 2>/dev/null
    sleep 1
    # shellcheck disable=SC2086
    kill -KILL $p 2>/dev/null
    echo "已停止运行中的引擎(PID: $p)"
    found=1
  fi

  if [ "$found" = 0 ]; then
    echo "当前没有运行中的引擎"
    rm -f "$STOP_FLAG"     # 没东西可停就把标志清掉，免得下次 --run 刚启动就被它打断
  fi
  release_wake
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --probe)
      MODE="probe"; shift
      PROBE_ARGS="$*"; break ;;
    --selftest) MODE="selftest" ;;
    --dry-run)  MODE="dry-run" ;;
    --run)      MODE="run" ;;
    --encrypt)  MODE="encrypt" ;;
    --sync-web) MODE="sync-web" ;;
    --init)     DO_INIT=1 ;;
    --settings) DO_WIZARD=1 ;;
    --update)   MODE="update" ;;
    --stop)     stop_engine ;;
    -h|--help)  usage ;;
    *) echo "未知参数: $1 (用 --help 查看用法)"; exit 2 ;;
  esac
  shift
done

# ==============================================================
echo -e "\e[33m[1/5] 检查运行环境...\e[0m"
IS_TERMUX=0
case "${PREFIX:-}" in *com.termux*) IS_TERMUX=1 ;; esac
if [ "$IS_TERMUX" = 1 ]; then ok_msg "Termux 环境 ($PREFIX)"; else echo "非 Termux 环境，按通用 Linux 处理"; fi

# --- Node.js ---
# 能执行且输出 vX.Y.Z 才算可用。Termux 升级后常见 "CANNOT LINK EXECUTABLE ... cannot locate symbol"，
# 这种情况下 `node -v` 返回非 0，绝不能当成"版本过低"。
node_ok() {
  local out
  out="$(node -v 2>&1)" || return 1
  case "$out" in v[0-9]*) return 0 ;; *) return 1 ;; esac
}
termux_install_node() {
  local i
  for i in 1 2 3; do
    echo "  正在安装 nodejs-lts（第 $i 次）..."
    # 先刷新索引: 镜像刚同步时 Packages.bz2 大小对不上，刷新一次往往就能过
    pkg update -y >/dev/null 2>&1 || true
    if pkg install -y nodejs-lts; then
      node_ok && return 0
    fi
    sleep 3
  done
  return 1
}
if ! command -v node >/dev/null 2>&1 || ! node_ok; then
  if command -v node >/dev/null 2>&1; then
    warn_msg "node 存在但无法运行（Termux 升级后 ABI 不匹配很常见）："
    node -v 2>&1 | head -1 | sed 's/^/    /' || true
  else
    warn_msg "未找到 Node.js，尝试安装..."
  fi
  if [ "$IS_TERMUX" = 1 ] && command -v pkg >/dev/null 2>&1; then
    if ! termux_install_node; then
      echo ""
      echo "  Node.js 自动安装失败。Termux 镜像有时同步不完整（提示"
      echo "  \"File has unexpected size / Mirror sync in progress\"），这不是脚本的问题。手动三步："
      echo "    1) termux-change-repo          # 换一个镜像，如清华 / 北外"
      echo "    2) pkg update && pkg upgrade -y"
      echo "    3) pkg install -y nodejs-lts   # 仍报损坏则: pkg reinstall nodejs-lts"
      die "Node.js 不可用，请先完成上面三步"
    fi
  else
    die "未找到可用的 Node.js。请安装 Node 18+ 后重试"
  fi
fi
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
if [ -z "${NODE_MAJOR:-}" ] || [ "$NODE_MAJOR" -lt 18 ] 2>/dev/null; then
  die "Node 版本过低 ($(node -v 2>&1))，需要 >= 18。Termux: pkg install -y nodejs-lts"
fi
if ! command -v npm >/dev/null 2>&1 || ! npm -v >/dev/null 2>&1; then
  warn_msg "npm 不可用（Termux 升级后可能同样损坏）。若依赖安装失败请执行: pkg reinstall nodejs-lts"
fi
ok_msg "Node $(node -v) / npm $(npm -v 2>/dev/null || echo '?')"

# node 确认可用之后再清 BOM（strip_bom 本身依赖 node）
strip_bom config.json
strip_bom wallets.json

# --- ethers (v1.7.1: 固定精确版本 + 禁安装脚本 + 装完校验版本，不再回退第三方镜像) ---
ETHERS_VERSION="6.15.0"
WS_VERSION="8.18.0"
if ! node -e "require('ethers')" >/dev/null 2>&1; then
  echo "安装依赖 ethers@$ETHERS_VERSION (固定版本，禁止安装脚本)..."
  for i in 1 2 3; do
    npm install "ethers@$ETHERS_VERSION" --no-audit --no-fund --ignore-scripts --save-exact && break
    warn_msg "第 $i 次安装失败，2 秒后重试..."
    sleep 2
  done
  # 光 require 成功不够: 必须确认装到的就是锁定的版本
  node -e "const v=require('ethers').version; if(v!=='$ETHERS_VERSION'){console.error('ethers version mismatch: '+v);process.exit(1)}" \
    || die "ethers 版本校验失败，请手动执行: cd $WORK_DIR && npm install ethers@$ETHERS_VERSION --ignore-scripts --save-exact"
  # 不再自动回退 registry.npmmirror.com：第三方镜像是供应链攻击面，
  # 而 ethers 是持有明文私钥并签名的核心依赖。如需镜像请自行配置 npm registry 后重试。
fi
ok_msg "ethers $(node -e "console.log(require('ethers').version)" 2>/dev/null || echo '?') 已就绪"

# --- ws (WebSocket 依赖，缺失时自动降级为 HTTP 轮询) ---
if ! node -e "try{require('ws')}catch(e){process.exit(1)}" >/dev/null 2>&1; then
  echo "安装 WebSocket 依赖 ws@$WS_VERSION ..."
  npm install "ws@$WS_VERSION" --no-audit --no-fund --ignore-scripts --save-exact >/dev/null 2>&1 \
    || warn_msg "ws 安装失败，将自动使用 HTTP 轮询模式兜底(仍可正常工作)"
fi

# ==============================================================
echo -e "\e[33m[2/5] 写入核心引擎...\e[0m"
cat << 'CORE_EOF' > core.js
'use strict';
/**
 * FTS 多账号自动打金 - 加固版核心引擎（版本与发行包 VERSION 一致）
 * 模式: run(默认) | dry-run(只预演不上链) | selftest(只读体检, 不发任何交易)
 */

// ---------------- 依赖检查 ----------------
// 必须在 require('ethers') 之前替换全局 WebSocket：
// Node 22+ 内置的 WebSocket 只有 addEventListener，没有 .on()，而 ethers 在
// 模块加载时就把 getGlobal().WebSocket 存成了常量(_WebSocket)，之后再改全局已经无效。
try {
  const __ws = require('ws');
  const __WS = __ws.WebSocket || __ws;
  if (__WS && __WS.prototype && typeof __WS.prototype.on === 'function') globalThis.WebSocket = __WS;
} catch (e) { /* 没装 ws: 后面会退回 HTTP 轮询 */ }

let ethers;
try {
  ethers = require('ethers');
} catch (e) {
  console.error('\x1b[31m[FATAL] 缺少 ethers 依赖: ' + e.message + '\x1b[0m');
  console.error('\x1b[33m修复: cd ' + __dirname + ' && npm install ethers@6\x1b[0m');
  process.exit(20);
}

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const MODE = process.argv[2] || 'run';
const DRY_RUN = MODE === 'dry-run';
const SELFTEST = MODE === 'selftest';
// v1.7.1: 引擎日志版本与发行包版本统一，不再出现两套互不相同的版本号。
// 外壳脚本把 VERSION 文件的内容通过 FTS_APP_VERSION 注入；单独运行 core.js 时回落到 1.7.1。
const APP_VERSION = process.env.FTS_APP_VERSION || '1.7.1';
const VERSION = APP_VERSION;
// 提示文案里的启动命令: Windows 上应显示 .ps1 的写法
const LAUNCH = process.env.FTS_LAUNCHER === 'ps1'
  ? 'powershell -ExecutionPolicy Bypass -File autofts.ps1'
  : (process.env.FTS_LAUNCHER === 'bash'
    ? 'bash autofts.sh'
    : (process.platform === 'win32' ? 'powershell -ExecutionPolicy Bypass -File autofts.ps1' : 'bash autofts.sh'));

const ROOT = __dirname;
const LOG_DIR = path.join(ROOT, 'logs');
const WALLETS_FILE = path.join(ROOT, 'wallets.json');
const CONFIG_FILE = path.join(ROOT, 'config.json');

const num = (v, d) => (v === undefined || v === null || v === '' ? d : Number(v));
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------- 配置 ----------------
// config.json 容错: 手改配置写错(比如把数组写成字符串、JSON 语法错误)时
// 不能让整个引擎崩掉，而是报错提示并用默认值继续跑
let userCfg = {};
let cfgProblems = [];
try {
  const raw = fs.readFileSync(CONFIG_FILE, 'utf8').replace(/^﻿/, '');
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) userCfg = parsed;
    else cfgProblems.push('config.json 顶层必须是对象，已忽略');
  } catch (e) {
    cfgProblems.push(`config.json 不是合法 JSON: ${e.message} (已使用全部默认配置)`);
  }
} catch (e) { /* 没有 config.json 是正常的 */ }

// 类型安全读取：类型不对就用默认值，绝不抛异常
function cfgArr(v, dflt, name) {
  if (v === undefined || v === null) return dflt;
  if (Array.isArray(v)) return v;
  if (typeof v === 'string') return v.split(',').map(s => s.trim()).filter(Boolean);
  cfgProblems.push(`config.json 的 ${name} 应该是数组或逗号分隔字符串，当前是 ${typeof v}，已用默认值 ${JSON.stringify(dflt)}`);
  return dflt;
}
function cfgNum(v, dflt, name) {
  if (v === undefined || v === null || v === '') return dflt;
  const n = Number(v);
  if (Number.isFinite(n)) return n;
  cfgProblems.push(`config.json 的 ${name} 应该是数字，当前是 "${v}"，已用默认值 ${dflt}`);
  return dflt;
}
function cfgStr(v, dflt, name) {
  if (v === undefined || v === null || v === '') return dflt;
  if (typeof v === 'string') return v;
  cfgProblems.push(`config.json 的 ${name} 应该是字符串，当前是 ${typeof v}，已用默认值`);
  return dflt;
}

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

const CFG = {
  // v8 队列(2026-11 网站改版后的正式队列)。旧地址 0x88E6... 已降级为 legacyQueueV7，房间全部停用。
  QUEUE_ADDR: process.env.FTS_QUEUE_ADDR || cfgStr(userCfg.QUEUE_ADDR, '0xe2E751cF79A5Ce03fED12Abf15acFA7383E296bF', 'QUEUE_ADDR'),
  USDT_ADDR: process.env.FTS_USDT_ADDR || cfgStr(userCfg.USDT_ADDR, '0x55d398326f99059fF775485246999027B3197955', 'USDT_ADDR'),
  // 老系统队列: 老额度 >= 阈值后在这里 formLP 组矿机，固定 100U(与额度多少无关)
  MINER_QUEUE_ADDR: process.env.FTS_MINER_QUEUE || cfgStr(userCfg.MINER_QUEUE_ADDR, '0x94DbcCFC460FA428755F0392ff282B83696B277d', 'MINER_QUEUE_ADDR'),
  // 矿机金库(新版 v8 / 老版)，用于领取矿机每日释放的 FTS
  MINING_VAULT_ADDR: process.env.FTS_MINING_VAULT || cfgStr(userCfg.MINING_VAULT_ADDR, '0xeC388916991332C71548E9911A73802f0F459EC5', 'MINING_VAULT_ADDR'),
  LEGACY_MINING_ADDR: process.env.FTS_LEGACY_MINING || cfgStr(userCfg.LEGACY_MINING_ADDR, '0xa710e7e87efc10dc4d9d22dc6446c66f0897d868', 'LEGACY_MINING_ADDR'),
  CHAIN_ID: cfgNum(process.env.FTS_CHAIN_ID ?? userCfg.CHAIN_ID, 56, 'CHAIN_ID'),
  // 房间 0=10U 1=50U 2=100U，全部启用；可用 FTS_ROOMS=0,1 缩小范围
  ROOMS: (process.env.FTS_ROOMS
    ? process.env.FTS_ROOMS.split(',').map(s => Number(s.trim())).filter(n => !isNaN(n))
    : cfgArr(userCfg.ROOMS, [0, 1, 2], 'ROOMS').map(Number).filter(n => !isNaN(n))),
  HTTP_POOL: process.env.FTS_HTTP_POOL
    ? process.env.FTS_HTTP_POOL.split(',').map(s => s.trim()).filter(Boolean)
    : cfgArr(userCfg.HTTP_POOL, [
      // 2026-11-27 实测: 42 个候选逐一验证 eth_blockNumber+eth_call+延迟(3次取平均)，筛出下列 11 个优质节点。
      // Tier A = bnbchain 官方(平均~200ms, 闸门14)；Tier B = 公共节点(平均~500-600ms, 闸门12)。
      // ninicoin/nodereal/meowrpc/defibit/blockrazor/0.48club 等已剔除(延迟>1.4s 或大量失败)。
      'https://bsc-dataseed.bnbchain.org',      // A ~199ms
      'https://bsc-dataseed1.bnbchain.org',     // A ~213ms
      'https://bsc-dataseed2.bnbchain.org',     // A ~213ms
      'https://bsc-dataseed3.bnbchain.org',     // A ~228ms
      'https://bsc-dataseed4.bnbchain.org',     // A ~230ms
      'https://bsc.rpc.sentio.xyz',             // B ~498ms
      'https://bsc-mainnet.public.blastapi.io', // B ~538ms
      'https://bsc-rpc.publicnode.com',         // B ~545ms
      'https://rpc-bsc.48.club',                // B ~601ms
      'https://bsc.publicnode.com'              // B ~602ms
      // pocket.network 单次~484ms 但高并发下频繁 429(实测 30 秒内 10 次)，剔除
    ], 'HTTP_POOL').map(s => String(s).trim()).filter(Boolean),
  WSS_POOL: process.env.FTS_WSS_POOL
    ? process.env.FTS_WSS_POOL.split(',').map(s => s.trim()).filter(Boolean)
    : cfgArr(userCfg.WSS_POOL, [
      // 2026-11 实测可用；meowrpc/blastapi/blockrazor 的 WSS 不可用(405/403/非ws)，移除。
      'wss://bsc-rpc.publicnode.com',
      'wss://bsc.publicnode.com',
      'wss://bsc.drpc.org'
    ], 'WSS_POOL').map(s => String(s).trim()).filter(Boolean),

  SNIPE_MIN_COUNT: cfgNum(process.env.FTS_MIN_COUNT ?? userCfg.SNIPE_MIN_COUNT, 30, 'SNIPE_MIN_COUNT'),
  SNIPE_MAX_COUNT: cfgNum(process.env.FTS_MAX_COUNT ?? userCfg.SNIPE_MAX_COUNT, 60, 'SNIPE_MAX_COUNT'),
  SNIPE_DELAY_MS: cfgNum(process.env.FTS_DELAY_MS ?? userCfg.SNIPE_DELAY_MS, 0, 'SNIPE_DELAY_MS'),
  CLAIM_INTERVAL_MS: cfgNum(process.env.FTS_CLAIM_MS ?? userCfg.CLAIM_INTERVAL_MS, 20000, 'CLAIM_INTERVAL_MS'),
  CLAIM_LOOKBACK: cfgNum(process.env.FTS_CLAIM_LOOKBACK ?? userCfg.CLAIM_LOOKBACK, 20, 'CLAIM_LOOKBACK'),
  POLL_INTERVAL_MS: cfgNum(process.env.FTS_POLL_MS ?? userCfg.POLL_INTERVAL_MS, 1500, 'POLL_INTERVAL_MS'),
  WS_STALE_MS: cfgNum(process.env.FTS_WS_STALE_MS ?? userCfg.WS_STALE_MS, 45000, 'WS_STALE_MS'),
  RPC_TIMEOUT_MS: cfgNum(process.env.FTS_RPC_TIMEOUT_MS, 12000, 'RPC_TIMEOUT_MS'),
  MAX_RPC_RETRY: cfgNum(process.env.FTS_RPC_RETRY, 3, 'MAX_RPC_RETRY'),
  TX_WAIT_MS: cfgNum(process.env.FTS_TX_WAIT_MS, 90000, 'TX_WAIT_MS'),
  GAS_MULT: cfgNum(process.env.FTS_GAS_MULT, 1.25, 'GAS_MULT'),
  // 下限要低于默认的固定价(0.05)，否则 capGwei 会把 0.05 悄悄顶到下限
  GAS_MIN_GWEI: cfgNum(process.env.FTS_GAS_MIN_GWEI, 0.01, 'GAS_MIN_GWEI'),
  GAS_MAX_GWEI: cfgNum(process.env.FTS_GAS_MAX_GWEI, 10, 'GAS_MAX_GWEI'),
  // 手续费默认"固定 0.05 gwei"。
  // 约定: config.json 里 GAS_GWEI 缺省 = 用默认 0.05；显式写 null = 自动模式(按链上价上浮)
  GAS_FIXED_GWEI: (() => {
    const raw = process.env.FTS_GAS_GWEI ?? userCfg.GAS_GWEI;
    if (raw === null) return null;                                   // 显式 null -> 自动
    if (raw === undefined || raw === '') return 0.05;                // 未配置 -> 默认固定 0.05
    const n = Number(raw);
    if (!Number.isFinite(n)) return 0.05;
    if (n <= 0) {
      // 0 gas 在 BSC 上根本不会被打包，别让用户以为设置生效了
      cfgProblems.push(`GAS_GWEI(${raw}) 必须大于 0，已按默认 0.05 gwei 处理`);
      return 0.05;
    }
    return n;
  })(),
  GAS_LIMIT_CAP: cfgNum(process.env.FTS_GAS_CAP, 800000, 'GAS_LIMIT_CAP'),
  // gasLimit 预估余量(%): 正常交易按 gasUsed 收费不受影响，但 revert 会烧掉整个 gasLimit。
  // 105% 足够覆盖轻微状态变化，避免原 125% 在 revert 时多烧 20%。
  GAS_LIMIT_BUFFER: cfgNum(process.env.FTS_GAS_BUFFER ?? userCfg.GAS_LIMIT_BUFFER, 105, 'GAS_LIMIT_BUFFER'),
  // 交易类型: auto=运行时探测链是否支持 EIP-1559 / 0=强制 Legacy / 2=强制 1559
  TX_TYPE: String(process.env.FTS_TX_TYPE || userCfg.TX_TYPE || 'auto').toLowerCase(),
  PRIORITY_MAX_GWEI: cfgNum(process.env.FTS_PRIORITY_GWEI ?? userCfg.PRIORITY_MAX_GWEI, 1.5, 'PRIORITY_MAX_GWEI'),
  // v1.7.1 授权上限: 绝不再把"填 0"解释成"授权钱包全部 USDT 余额"。
  // 按场数最多 APPROVE_MAX_ROUNDS 场，按 U 数最多 APPROVE_MAX_USD U，两者取更严的一个。
  // USDT approve 不锁资金，减小额度只是减小 spender 可划走的上限，不是"资金占用"。
  APPROVE_USD: process.env.FTS_APPROVE_USD !== undefined || userCfg.APPROVE_USD !== undefined
    ? cfgNum(process.env.FTS_APPROVE_USD ?? userCfg.APPROVE_USD, 0, 'APPROVE_USD')
    : null,                                   // null = 自动按票价 × APPROVE_ROUNDS
  APPROVE_ROUNDS: cfgNum(process.env.FTS_APPROVE_ROUNDS ?? userCfg.APPROVE_ROUNDS, 1, 'APPROVE_ROUNDS'),
  APPROVE_MAX_ROUNDS: cfgNum(process.env.FTS_APPROVE_MAX_ROUNDS ?? userCfg.APPROVE_MAX_ROUNDS, 3, 'APPROVE_MAX_ROUNDS'),
  APPROVE_MAX_USD: cfgNum(process.env.FTS_APPROVE_MAX_USD ?? userCfg.APPROVE_MAX_USD, 100, 'APPROVE_MAX_USD'),
  // 中奖后是否自动领取矿机额度(claimWin)。中奖与否由 Chainlink VRF 随机决定，脚本无法干预。
  CLAIM_WIN: (() => {
    const raw = process.env.FTS_CLAIM_WIN ?? userCfg.CLAIM_WIN;
    if (raw === undefined || raw === null || raw === '') return true;
    return !(raw === false || raw === 0 || raw === '0' || raw === 'false' || raw === 'off');
  })(),
  // ---- 组矿机(老系统固定 100U 接口 formLP) ----
  MINER_ENABLED: (() => {
    const raw = process.env.FTS_MINER_ENABLED ?? userCfg.MINER_ENABLED;
    if (raw === undefined || raw === null || raw === '') return false;
    return !(raw === false || raw === 0 || raw === '0' || raw === 'false' || raw === 'off');
  })(),
  MINER_USD: cfgNum(process.env.FTS_MINER_USD ?? userCfg.MINER_USD, 100, 'MINER_USD'),
  // 组矿机模式: old=只用老额度(固定 MINER_USD)、new=只用新版额度(按额度实额支付)、both=两者都组
  MINER_MODE: String(process.env.FTS_MINER_MODE || userCfg.MINER_MODE || 'old').toLowerCase(),
  MINER_ROOM: cfgNum(process.env.FTS_MINER_ROOM ?? userCfg.MINER_ROOM, 0, 'MINER_ROOM'),
  MINER_CHECK_MS: cfgNum(process.env.FTS_MINER_CHECK_MS ?? userCfg.MINER_CHECK_MS, 60000, 'MINER_CHECK_MS'),
  // ---- 矿机产出自动领取 ----
  // 原则: 一旦 pending > 0 就立刻领，绝不等释放完/攒到最后一块(避免中途规则变更或遗忘)。
  MINING_CLAIM: (() => {
    const raw = process.env.FTS_MINING_CLAIM ?? userCfg.MINING_CLAIM;
    if (raw === undefined || raw === null || raw === '') return true;
    return !(raw === false || raw === 0 || raw === '0' || raw === 'false' || raw === 'off');
  })(),
  MINING_CLAIM_MS: cfgNum(process.env.FTS_MINING_CLAIM_MS ?? userCfg.MINING_CLAIM_MS, 45000, 'MINING_CLAIM_MS'),
  // ---- 运行期自动更新 ----
  // v1.7.1: 启动即检测一次，之后每 UPDATE_CHECK_MS 查一次；只在"空闲窗口"替换+重启。
  // 超过 UPDATE_MAX_DEFER_MS 仍等不到空闲窗口时，只提示用户手动更新，绝不强制打断抢单。
  UPDATE_CHECK_MS: cfgNum(process.env.FTS_UPDATE_CHECK_MS ?? userCfg.UPDATE_CHECK_MS, 1200000, 'UPDATE_CHECK_MS'),
  UPDATE_IDLE_MARGIN: cfgNum(process.env.FTS_UPDATE_IDLE_MARGIN ?? userCfg.UPDATE_IDLE_MARGIN, 15, 'UPDATE_IDLE_MARGIN'),
  // 推迟上限只用于告警，不再作为"跳过忙碌判断"的理由
  UPDATE_MAX_DEFER_MS: cfgNum(process.env.FTS_UPDATE_MAX_DEFER_MS ?? userCfg.UPDATE_MAX_DEFER_MS, 7200000, 'UPDATE_MAX_DEFER_MS'),
  // 发现新版后重试"空闲窗口"的间隔；限流时由 update.js 退避，避免每 10 秒打一次 API
  UPDATE_RETRY_MS: cfgNum(process.env.FTS_UPDATE_RETRY_MS ?? userCfg.UPDATE_RETRY_MS, 60000, 'UPDATE_RETRY_MS'),
  MIN_BNB_GAS: cfgNum(process.env.FTS_MIN_BNB ?? userCfg.MIN_BNB_GAS, 0.005, 'MIN_BNB_GAS'),
  // nonce 断档自愈: 发现"有在途交易但 latest 长期不动"就补一笔自转填坑
  GAP_CHECK_MS: cfgNum(process.env.FTS_GAP_CHECK_MS, 20000, 'GAP_CHECK_MS'),
  GAP_STUCK_MS: cfgNum(process.env.FTS_GAP_STUCK_MS, 45000, 'GAP_STUCK_MS'),
  // 并发与限流: 多节点分层，每个节点独立闸门(见 NODE_TIER_CONCURRENCY)。
  // RPC_MAX_CONCURRENT 作为"单节点闸门上限"的默认兜底与全局总闸的参考值。
  // 实测(2026-11-27, 每节点120请求): 官方节点并发16是延迟拐点、14最优(p95 158-314ms)；
  // 公共节点(publicnode/blastapi/48club)并发14拐点、12更稳。取拐点前一位，不取50%。
  RPC_MAX_CONCURRENT: cfgNum(process.env.FTS_RPC_CONCURRENCY ?? userCfg.RPC_MAX_CONCURRENT, 12, 'RPC_MAX_CONCURRENT'),
  RPC_MIN_SPACING_MS: cfgNum(process.env.FTS_RPC_SPACING_MS, 40, 'RPC_MIN_SPACING_MS'),
  ACCOUNT_STAGGER_MS: cfgNum(process.env.FTS_ACCOUNT_STAGGER_MS, 120, 'ACCOUNT_STAGGER_MS'),
  // 多节点分层: 每个节点一个独立闸门，账号平摊到节点，节点闸门满/冷却时溢出到下一个节点。
  // 闸门值按节点档位: bnbchain 官方(快)14, 其他公共节点(慢)12, 均取实测拐点前一位。
  // 可用 config.json 的 NODE_TIER_CONCURRENCY 覆盖，格式 {"fast":14,"slow":12}。
  NODE_TIER_CONCURRENCY: (() => {
    const raw = userCfg.NODE_TIER_CONCURRENCY;
    const d = { fast: 14, slow: 12 };
    if (!raw || typeof raw !== 'object') return d;
    const f = Number(raw.fast), s = Number(raw.slow);
    return {
      fast: Number.isFinite(f) && f >= 1 && f <= 16 ? Math.floor(f) : d.fast,
      slow: Number.isFinite(s) && s >= 1 && s <= 16 ? Math.floor(s) : d.slow
    };
  })(),
  // 节点分层开关(默认开)。关掉时退回单节点全局闸门模式。
  NODE_POOL_ENABLED: (() => {
    const raw = process.env.FTS_NODE_POOL ?? userCfg.NODE_POOL_ENABLED;
    if (raw === undefined || raw === null || raw === '') return true;
    return !(raw === false || raw === 0 || raw === '0' || raw === 'false' || raw === 'off');
  })(),
  // 游戏网址: 用于从网页自动探测最新合约地址(网页换合约时无需改代码)
  GAME_URL: cfgStr(process.env.FTS_GAME_URL ?? userCfg.GAME_URL, 'https://fatris.fans/dapp/game', 'GAME_URL'),
  MARKET_URL: cfgStr(process.env.FTS_MARKET_URL ?? userCfg.MARKET_URL, 'https://fatris.fans/dapp/market', 'MARKET_URL'),
  // v1.7.1: 网页合约自动同步默认关闭。上游页面被污染时曾可把任意地址写回 config.json
  // 并被当成 USDT approve 的 spender，因此改为"默认只用 config.json 里的固定地址"。
  WEB_AUTO_SYNC: (() => {
    const raw = process.env.FTS_WEB_SYNC ?? userCfg.WEB_AUTO_SYNC;
    return raw === true || raw === 1 || raw === '1' || raw === 'true' || raw === 'on';
  })(),
  // 资金相关字段(授权 spender / USDT / 老队列 / 市场)默认禁止网页写回；需用户显式打开。
  WEB_SYNC_ALLOW_FUNDS_KEYS: (() => {
    const raw = process.env.FTS_WEB_SYNC_ALLOW_FUNDS ?? userCfg.WEB_SYNC_ALLOW_FUNDS_KEYS;
    return raw === true || raw === 1 || raw === '1' || raw === 'true' || raw === 'on';
  })(),
  // 启动排水: 等上一轮未确认交易落地，避免重启后 nonce 回退
  STARTUP_DRAIN_MS: cfgNum(process.env.FTS_DRAIN_MS, 30000, 'STARTUP_DRAIN_MS'),
  // ---- FTS 自动买卖(两个独立开关，默认都关；阈值不设默认值，必须由用户显式配置) ----
  // 买单: 监控市场挂单，单价 <= 阈值时吃单；累计花费有上限。
  TRADE_BUY_ENABLED: (() => {
    const raw = process.env.FTS_TRADE_BUY ?? userCfg.TRADE_BUY_ENABLED;
    return raw === true || raw === 1 || raw === '1' || raw === 'true' || raw === 'on';
  })(),
  TRADE_BUY_MAX_PRICE: (() => { const v = process.env.FTS_BUY_MAX_PRICE ?? userCfg.TRADE_BUY_MAX_PRICE; const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; })(),
  TRADE_BUY_MAX_TOTAL: (() => { const v = process.env.FTS_BUY_MAX_TOTAL ?? userCfg.TRADE_BUY_MAX_TOTAL; const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; })(),
  TRADE_BUY_SCAN_N: cfgNum(process.env.FTS_BUY_SCAN_N ?? userCfg.TRADE_BUY_SCAN_N, 200, 'TRADE_BUY_SCAN_N'),
  TRADE_CHECK_MS: cfgNum(process.env.FTS_TRADE_CHECK_MS ?? userCfg.TRADE_CHECK_MS, 15000, 'TRADE_CHECK_MS'),
  // 卖单: 读 FTS 真实价格(DEX池储备，不读市场挂单价)，达到卖出条件时挂单。
  TRADE_SELL_ENABLED: (() => {
    const raw = process.env.FTS_TRADE_SELL ?? userCfg.TRADE_SELL_ENABLED;
    return raw === true || raw === 1 || raw === '1' || raw === 'true' || raw === 'on';
  })(),
  // 卖出触发价模式: fixed=价格>=固定值; spotMinus=价格>=真实价-差值(即挂单价=真实价-差值)
  TRADE_SELL_MODE: String(process.env.FTS_SELL_MODE ?? userCfg.TRADE_SELL_MODE ?? 'fixed').toLowerCase(),
  TRADE_SELL_PRICE: (() => { const v = process.env.FTS_SELL_PRICE ?? userCfg.TRADE_SELL_PRICE; const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; })(),
  TRADE_SELL_AMOUNT: (() => { const v = process.env.FTS_SELL_AMOUNT ?? userCfg.TRADE_SELL_AMOUNT; const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; })(),
  // v1.7.1: 卖单不再无限制重复挂单 —— 已有活跃挂单不重复挂、两次挂单有冷却、累计有上限。
  TRADE_SELL_COOLDOWN_MS: cfgNum(process.env.FTS_SELL_COOLDOWN_MS ?? userCfg.TRADE_SELL_COOLDOWN_MS, 300000, 'TRADE_SELL_COOLDOWN_MS'),
  TRADE_SELL_MAX_ORDERS: cfgNum(process.env.FTS_SELL_MAX_ORDERS ?? userCfg.TRADE_SELL_MAX_ORDERS, 1, 'TRADE_SELL_MAX_ORDERS'),
  // 买单每日累计花费落盘，重启不再清零（"今日已花费"日志才与事实相符）
  TRADE_STATE_FILE: cfgStr(process.env.FTS_TRADE_STATE_FILE ?? userCfg.TRADE_STATE_FILE, 'trade-state.json', 'TRADE_STATE_FILE'),
  // 市场合约地址(留空则从网页 VITE_MARKET_ESCROW 自动探测)
  MARKET_ADDR: cfgStr(process.env.FTS_MARKET_ADDR ?? userCfg.MARKET_ADDR, '', 'MARKET_ADDR'),
  // ---- 灵活资金决策(多账号互相匀 gas / 凑 USDT) ----
  // 总开关，默认关闭：关闭时所有资金判断维持"单账号独立、不足即跳过"的原行为，零开销。
  FLEX_ENABLED: (() => {
    const raw = process.env.FTS_FLEX ?? userCfg.FLEX_DECISION;
    if (raw === undefined || raw === null || raw === '') return false;
    return !(raw === false || raw === 0 || raw === '0' || raw === 'false' || raw === 'off');
  })(),
  // 匀开 gas: 某账号 BNB 不足以发交易时，从 BNB 富余的账号转入差额(真实链上转账)。默认关。
  FLEX_GAS_POOLING: (() => {
    const raw = process.env.FTS_FLEX_GAS ?? userCfg.FLEX_GAS_POOLING;
    if (raw === undefined || raw === null || raw === '') {
      // 未单独配置时跟随总开关(界面打开"灵活决策"即启用匀 gas)
      const f = process.env.FTS_FLEX ?? userCfg.FLEX_DECISION;
      if (f === undefined || f === null || f === '') return false;
      return !(f === false || f === 0 || f === '0' || f === 'false' || f === 'off');
    }
    return !(raw === false || raw === 0 || raw === '0' || raw === 'false' || raw === 'off');
  })(),
  // 凑 USDT: 各账号 USDT 单独都不够、但合计够一次入场时，从富余账号转入差额。默认关。
  FLEX_FUND_AGGREGATION: (() => {
    const raw = process.env.FTS_FLEX_FUND ?? userCfg.FLEX_FUND_AGGREGATION;
    if (raw === undefined || raw === null || raw === '') {
      // 未单独配置时跟随总开关(界面打开"灵活决策"即启用凑 USDT)
      const f = process.env.FTS_FLEX ?? userCfg.FLEX_DECISION;
      if (f === undefined || f === null || f === '') return false;
      return !(f === false || f === 0 || f === '0' || f === 'false' || f === 'off');
    }
    return !(raw === false || raw === 0 || raw === 'false' || raw === 'off');
  })(),
  // donor 账号转入后自身至少保留的 USDT / BNB，避免把富余账号抽干
  FLEX_DONOR_KEEP_USDT: cfgNum(process.env.FTS_FLEX_KEEP_USDT ?? userCfg.FLEX_DONOR_KEEP_USDT, 20, 'FLEX_DONOR_KEEP_USDT'),
  FLEX_DONOR_KEEP_BNB: cfgNum(process.env.FTS_FLEX_KEEP_BNB ?? userCfg.FLEX_DONOR_KEEP_BNB, 0.01, 'FLEX_DONOR_KEEP_BNB')
};

// ---------------- 配置自检 ----------------
// 启动时把有问题的配置一次性说清楚，而不是运行中崩掉或静默失效
function validateCfg() {
  const p = [];
  if (CFG.SNIPE_MIN_COUNT >= CFG.SNIPE_MAX_COUNT) {
    p.push(`抢单人数下限(${CFG.SNIPE_MIN_COUNT}) >= 上限(${CFG.SNIPE_MAX_COUNT})，条件永远不成立 -> 永远不会入场。已自动放宽为 [${CFG.SNIPE_MIN_COUNT}, ${CFG.SNIPE_MIN_COUNT + 1})`);
    CFG.SNIPE_MAX_COUNT = CFG.SNIPE_MIN_COUNT + 1;
  }
  if (CFG.SNIPE_MIN_COUNT < 0) { p.push('抢单人数下限为负数，已改为 0'); CFG.SNIPE_MIN_COUNT = 0; }
  // 人数是整数，30.5 这种值没有意义(还会让向导显示"30.5 ~ 60.5 人")
  if (!Number.isInteger(CFG.SNIPE_MIN_COUNT)) { p.push(`抢单人数下限(${CFG.SNIPE_MIN_COUNT}) 必须是整数，已取整为 ${Math.floor(CFG.SNIPE_MIN_COUNT)}`); CFG.SNIPE_MIN_COUNT = Math.floor(CFG.SNIPE_MIN_COUNT); }
  if (!Number.isInteger(CFG.SNIPE_MAX_COUNT)) { p.push(`抢单人数上限(${CFG.SNIPE_MAX_COUNT}) 必须是整数，已取整为 ${Math.ceil(CFG.SNIPE_MAX_COUNT)}`); CFG.SNIPE_MAX_COUNT = Math.ceil(CFG.SNIPE_MAX_COUNT); }
  if (!CFG.ROOMS.length) { p.push('ROOMS 为空，已恢复为 [0,1,2]'); CFG.ROOMS = [0, 1, 2]; }
  if (!CFG.HTTP_POOL.length) { p.push('HTTP_POOL 为空，已恢复为默认 BSC 节点'); CFG.HTTP_POOL = ['https://bsc-dataseed1.binance.org', 'https://bsc-rpc.publicnode.com']; }
  if (CFG.CLAIM_LOOKBACK < 1) { p.push('CLAIM_LOOKBACK 必须 >=1，已改为 1'); CFG.CLAIM_LOOKBACK = 1; }
  if (CFG.GAS_MIN_GWEI > CFG.GAS_MAX_GWEI) { p.push(`GAS_MIN_GWEI(${CFG.GAS_MIN_GWEI}) > GAS_MAX_GWEI(${CFG.GAS_MAX_GWEI})，已对调`); [CFG.GAS_MIN_GWEI, CFG.GAS_MAX_GWEI] = [CFG.GAS_MAX_GWEI, CFG.GAS_MIN_GWEI]; }
  // 固定 gas 高于上限时，capGwei 会把它悄悄压下来，用户会以为设置没生效
  if (CFG.GAS_FIXED_GWEI && CFG.GAS_FIXED_GWEI > CFG.GAS_MAX_GWEI) {
    p.push(`固定 gas(${CFG.GAS_FIXED_GWEI} gwei) 高于上限(${CFG.GAS_MAX_GWEI} gwei)，已把上限提到 ${CFG.GAS_FIXED_GWEI}`);
    CFG.GAS_MAX_GWEI = CFG.GAS_FIXED_GWEI;
  }
  // 低于下限同理(默认 0.05 gwei 必须能原样发出去，不能被顶到 1 gwei)
  if (CFG.GAS_FIXED_GWEI && CFG.GAS_FIXED_GWEI < CFG.GAS_MIN_GWEI) {
    p.push(`固定 gas(${CFG.GAS_FIXED_GWEI} gwei) 低于下限(${CFG.GAS_MIN_GWEI} gwei)，已把下限降到 ${CFG.GAS_FIXED_GWEI}`);
    CFG.GAS_MIN_GWEI = CFG.GAS_FIXED_GWEI;
  }
  // 领返利间隔太短 = 不停地打节点，很快就会吃 429，反而漏领。
  // 0 / 几百毫秒这种值多半是手改配置时算错了单位(把秒当毫秒写)。
  if (CFG.CLAIM_INTERVAL_MS < 5000) {
    p.push(`CLAIM_INTERVAL_MS(${CFG.CLAIM_INTERVAL_MS}ms) 过小，已按 5000ms 处理(否则会疯狂请求节点触发限流)`);
    CFG.CLAIM_INTERVAL_MS = 5000;
  }
  if (!['auto', '0', '2'].includes(CFG.TX_TYPE)) { p.push(`TX_TYPE 只能是 auto/0/2，当前 "${CFG.TX_TYPE}"，已改为 auto`); CFG.TX_TYPE = 'auto'; }
  if (CFG.APPROVE_ROUNDS < 1) { p.push('APPROVE_ROUNDS 必须 >=1，已改为 1'); CFG.APPROVE_ROUNDS = 1; }
  // v1.7.1 授权上限: 缺字段时静默补默认值(CFG 构造已有兜底)，只有显式配错才提示。
  // 老配置升级、以及只注入部分字段的单测桩都不会被无意义告警刷屏。
  if (CFG.APPROVE_MAX_ROUNDS === undefined) CFG.APPROVE_MAX_ROUNDS = 3;
  else if (!Number.isFinite(CFG.APPROVE_MAX_ROUNDS) || CFG.APPROVE_MAX_ROUNDS < 1) {
    p.push('APPROVE_MAX_ROUNDS 无效，已改为 3'); CFG.APPROVE_MAX_ROUNDS = 3;
  }
  CFG.APPROVE_MAX_ROUNDS = Math.min(20, Math.floor(CFG.APPROVE_MAX_ROUNDS));
  if (CFG.APPROVE_MAX_USD === undefined) CFG.APPROVE_MAX_USD = 100;
  else if (!Number.isFinite(CFG.APPROVE_MAX_USD) || CFG.APPROVE_MAX_USD <= 0 || CFG.APPROVE_MAX_USD >= 1e21) {
    p.push('APPROVE_MAX_USD 无效，已改为 100'); CFG.APPROVE_MAX_USD = 100;
  }
  // cfgNum 只校验"是不是有限数字"，1.5 能过关，但后面 BigInt(1.5) 会抛 RangeError，
  // 结果是这个账号每次要授权时都炸在这里，且日志被节流后基本看不到
  if (!Number.isInteger(CFG.APPROVE_ROUNDS)) {
    const fixed = Math.max(1, Math.floor(CFG.APPROVE_ROUNDS));
    p.push(`APPROVE_ROUNDS(${CFG.APPROVE_ROUNDS}) 必须是整数，已改为 ${fixed}`);
    CFG.APPROVE_ROUNDS = fixed;
  }
  if (CFG.APPROVE_USD !== null) {
    // 负数: parseUnits 能过，但 approve(uint256) 编码时会炸
    if (!(CFG.APPROVE_USD >= 0)) {
      p.push(`APPROVE_USD(${CFG.APPROVE_USD}) 不能为负，已改回自动(一轮票价)`);
      CFG.APPROVE_USD = null;
    } else if (CFG.APPROVE_USD >= 1e21) {
      // 1e21 及以上 String() 会变成 "1e+21" 这种科学计数法，parseUnits 直接不认。
      // 注意不要用"字符串里有没有 e"来判断: String(0.0000001) 是 "1e-7"，会误伤小数。
      // 而 1e21-1 在 Number 精度下就等于 1e21，所以 >= 1e21 已经覆盖了边界。
      p.push(`APPROVE_USD(${CFG.APPROVE_USD}) 过大(会被转成科学计数法而无法解析)，已改回自动(一轮票价)`);
      CFG.APPROVE_USD = null;
    }
  }
  if (CFG.GAP_STUCK_MS < 15000) { p.push('GAP_STUCK_MS 太小(容易误判)，已改为 15000'); CFG.GAP_STUCK_MS = 15000; }
  if (CFG.MINER_USD <= 0) { p.push(`MINER_USD(${CFG.MINER_USD}) 必须大于 0，已改为 100`); CFG.MINER_USD = 100; }
  if (CFG.MINER_USD >= 1e21) { p.push('MINER_USD 过大，已改为 100'); CFG.MINER_USD = 100; }
  if (!Number.isInteger(CFG.MINER_ROOM) || CFG.MINER_ROOM < 0 || CFG.MINER_ROOM > 255) { p.push(`MINER_ROOM(${CFG.MINER_ROOM}) 必须是 0~255 的整数，已改为 0`); CFG.MINER_ROOM = 0; }
  if (CFG.MINER_CHECK_MS < 10000) { p.push('MINER_CHECK_MS 太小，已改为 10000'); CFG.MINER_CHECK_MS = 10000; }
  if (!['old', 'new', 'both'].includes(CFG.MINER_MODE)) {
    p.push(`MINER_MODE 只能是 old/new/both，当前 "${CFG.MINER_MODE}"，已改为 old`);
    CFG.MINER_MODE = 'old';
  }
  if (CFG.MINING_CLAIM_MS < 15000) { p.push('MINING_CLAIM_MS 太小，已改为 15000'); CFG.MINING_CLAIM_MS = 15000; }
  if (CFG.UPDATE_CHECK_MS < 60000) { p.push('UPDATE_CHECK_MS 太小，已改为 60000'); CFG.UPDATE_CHECK_MS = 60000; }
  if (CFG.UPDATE_IDLE_MARGIN < 0) { p.push('UPDATE_IDLE_MARGIN 不能为负，已改为 15'); CFG.UPDATE_IDLE_MARGIN = 15; }
  if (CFG.UPDATE_MAX_DEFER_MS < 600000) { p.push('UPDATE_MAX_DEFER_MS 太小，已改为 600000'); CFG.UPDATE_MAX_DEFER_MS = 600000; }
  if (CFG.UPDATE_RETRY_MS === undefined) CFG.UPDATE_RETRY_MS = 60000;
  else if (!Number.isFinite(CFG.UPDATE_RETRY_MS) || CFG.UPDATE_RETRY_MS < 10000) {
    p.push('UPDATE_RETRY_MS 太小(会刷 GitHub API)，已改为 60000'); CFG.UPDATE_RETRY_MS = 60000;
  }
  if (CFG.TRADE_SELL_COOLDOWN_MS === undefined) CFG.TRADE_SELL_COOLDOWN_MS = 300000;
  else if (!Number.isFinite(CFG.TRADE_SELL_COOLDOWN_MS) || CFG.TRADE_SELL_COOLDOWN_MS < 1000) {
    p.push('TRADE_SELL_COOLDOWN_MS 无效，已改为 300000'); CFG.TRADE_SELL_COOLDOWN_MS = 300000;
  }
  if (CFG.TRADE_SELL_MAX_ORDERS === undefined) CFG.TRADE_SELL_MAX_ORDERS = 1;
  else if (!Number.isInteger(CFG.TRADE_SELL_MAX_ORDERS) || CFG.TRADE_SELL_MAX_ORDERS < 1) {
    p.push('TRADE_SELL_MAX_ORDERS 必须 >=1，已改为 1'); CFG.TRADE_SELL_MAX_ORDERS = 1;
  }
  // 并发闸门: 默认 8(实测稳定最优点)。硬上限 16=延迟恶化拐点，超过只能是自找 429/高延迟。
  if (!Number.isInteger(CFG.RPC_MAX_CONCURRENT) || CFG.RPC_MAX_CONCURRENT < 1 || CFG.RPC_MAX_CONCURRENT > 16) {
    const fixed = Number.isFinite(CFG.RPC_MAX_CONCURRENT)
      ? Math.min(16, Math.max(1, Math.floor(CFG.RPC_MAX_CONCURRENT))) : 8;
    p.push(`RPC_MAX_CONCURRENT(${CFG.RPC_MAX_CONCURRENT}) 超出 1~16 范围(16 是实测延迟拐点)，已改为 ${fixed}`);
    CFG.RPC_MAX_CONCURRENT = fixed;
  } else if (CFG.RPC_MAX_CONCURRENT > 12) {
    // 软提醒: 不强制改(用私有节点的人可能需要)，但明确告知公共节点风险
    p.push(`RPC_MAX_CONCURRENT(${CFG.RPC_MAX_CONCURRENT}) 偏高: 公共节点实测 >12 延迟明显恶化，建议 <=8；私有节点可忽略`);
  }
  // 请求间隔: 0/极小值会让闸门形同虚设，公共节点分分钟 429。默认 60ms，下限 20ms(实测 20ms 时延迟已开始抬头)
  if (!Number.isFinite(CFG.RPC_MIN_SPACING_MS) || CFG.RPC_MIN_SPACING_MS < 20) {
    const fixed = Number.isFinite(CFG.RPC_MIN_SPACING_MS) ? 20 : 60;
    p.push(`RPC_MIN_SPACING_MS(${CFG.RPC_MIN_SPACING_MS}) 过小(<20ms 易触发公共节点限流)，已改为 ${fixed}`);
    CFG.RPC_MIN_SPACING_MS = fixed;
  }
  // 账号错峰: 0 会让所有账号同一瞬间打向节点，抵消闸门作用。下限 50ms
  if (!Number.isFinite(CFG.ACCOUNT_STAGGER_MS) || CFG.ACCOUNT_STAGGER_MS < 50) {
    const fixed = Number.isFinite(CFG.ACCOUNT_STAGGER_MS) ? 50 : 120;
    p.push(`ACCOUNT_STAGGER_MS(${CFG.ACCOUNT_STAGGER_MS}) 过小(<50ms 账号会同时打节点)，已改为 ${fixed}`);
    CFG.ACCOUNT_STAGGER_MS = fixed;
  }
  return p.concat(cfgProblems);
}

// ---------------- 日志 ----------------
let logStream = null;
try {
  if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });
  const lf = path.join(LOG_DIR, 'fts-' + new Date().toISOString().slice(0, 10).replace(/-/g, '') + '.log');
  logStream = fs.createWriteStream(lf, { flags: 'a' });
  logStream.write(`\n===== 启动 v${VERSION} mode=${MODE} ${new Date().toLocaleString()} =====\n`);
} catch (e) { /* 日志不可用时仅控制台 */ }

const C = { g: '\x1b[32m', r: '\x1b[31m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[0m' };
const tss = () => new Date().toLocaleTimeString('zh-CN', { hour12: false });
const short = a => (a || 'SYS').slice(0, 8);

function log(level, addr, msg, color) {
  const line = `[${tss()}] [${level}] [${short(addr)}] ${msg}`;
  console.log((color || '') + line + C.d);
  try { logStream.write(line + '\n'); } catch (e) { }
}
// 同一原因的报错做节流，避免每个块刷屏（默认 60s 内只报一次）
const errSeen = new Map();
function errOnce(addr, m, ms) {
  const gap = ms === undefined ? 60000 : ms;
  const key = (addr || '') + '|' + m.replace(/\d+(\.\d+)?/g, '#');
  const now = Date.now();
  const last = errSeen.get(key) || 0;
  if (now - last < gap) return;
  errSeen.set(key, now);
  err(addr, m);
}

const info = (a, m) => log('INFO', a, m);
const ok = (a, m) => log(' OK ', a, m, C.g);
const warn = (a, m) => log('WARN', a, m, C.y);
const err = (a, m) => log('ERR ', a, m, C.r);
const fatal = (a, m) => log('FATAL', a, m, C.r);

// 警告就是警告: 用黄色 WARN，不要打成红色 ERR 吓人
function warnOnce(addr, m, ms) {
  const gap = ms === undefined ? 60000 : ms;
  const key = 'W|' + (addr || '') + '|' + m.replace(/\d+(\.\d+)?/g, '#');
  const now = Date.now();
  if (now - (errSeen.get(key) || 0) < gap) return;
  errSeen.set(key, now);
  warn(addr, m);
}

// ---------------- 错误详情 ----------------
function decodeRevert(e) {
  try {
    const data = e.data || (e.info && e.info.error && e.info.error.data) || (e.error && e.error.data);
    if (typeof data === 'string' && data.startsWith('0x08c379a0')) {
      return ethers.AbiCoder.defaultAbiCoder().decode(['string'], '0x' + data.slice(10))[0];
    }
    if (typeof data === 'string' && data !== '0x') return 'raw=' + data.slice(0, 20) + '...';
  } catch (x) { }
  return null;
}
function formatError(e) {
  if (!e) return '未知错误';
  const parts = [];
  parts.push('code=' + (e.code || e.name || 'UNKNOWN'));
  const msg = e.shortMessage || e.reason || e.message || '';
  if (msg) parts.push('msg=' + String(msg).replace(/\n/g, ' ').slice(0, 300));
  const rv = decodeRevert(e);
  if (rv) parts.push('revert=' + rv);
  if (e.action) parts.push('action=' + e.action);
  if (e.transaction && e.transaction.to) parts.push('to=' + e.transaction.to);
  if (e.info && e.info.error && e.info.error.message) parts.push('rpc=' + String(e.info.error.message).slice(0, 200));
  return parts.join(' | ');
}
function rpcDetail(e) {
  if (!e) return '';
  const bits = [];
  const push = v => { if (v && typeof v === 'string' && bits.length < 10) bits.push(v); };
  push(e.shortMessage); push(e.reason); push(e.message);
  const walk = (o, depth) => {
    if (!o || typeof o !== 'object' || depth > 3) return;
    if (o.message) push(o.message);
    if (o.code !== undefined) push(String(o.code));
    if (o.error) walk(o.error, depth + 1);
    if (o.info) walk(o.info, depth + 1);
  };
  walk(e.error, 0); walk(e.info, 0);
  return bits.join(' | ');
}
// "还没到能领的时候 / 暂时因资金或节点原因领不了"的 revert: 不能标记为已领取，
// 否则结算窗口一开、或资金/gas 补上后就永远错过 —— 这正是"钱后来够了却没再领"的根因。
function isTransientClaimRevert(e) {
  const t = (decodeRevert(e) || '') + ' ' + (e && (e.reason || e.shortMessage || e.message) || '') + ' ' + rpcDetail(e);
  return /not refunding|vrf pending|not drawn|please wait|try again|still open|not settled|not ended|not complete|round not|insufficient funds|insufficient balance|not enough|too early|not ready|window|gas too low|underpriced/i.test(t);
}
// 只有"明确是终态"的 revert 才允许永久标记为已领，避免把可恢复的失败误判为永久。
// 拿不准(空 reason / 未知 revert)一律不算终态 -> 不标记，留给下一轮重试。
function isTerminalClaimSkipReason(e) {
  const t = (decodeRevert(e) || '') + ' ' + (e && (e.reason || e.shortMessage || e.message) || '') + ' ' + rpcDetail(e);
  return /already claimed|already refunded|already paid|already received|not in round|not\s+(?:a\s+|the\s+)?winner|not eligible|no refund|nothing to claim|已经领|已领取|没有可领/i.test(t);
}
function isNetworkErr(e) {
  if (!e) return false;
  if (['NETWORK_ERROR', 'TIMEOUT', 'SERVER_ERROR'].includes(e.code)) return true;
  const s = rpcDetail(e);
  return /ENOTFOUND|EAI_AGAIN|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EPIPE|fetch failed|socket hang up|could not coalesce|429|too many requests|rate limit/i.test(s);
}
// console.log 写管道是异步的，直接 process.exit 可能在 flush 前退出、把最后几行截掉
// (重定向到文件时尤其明显)。这里等 stdout 排空再退，exitCode 先设好兜底。
function exitFlush(code) {
  process.exitCode = code;
  try { process.stdout.write('', () => process.exit(code)); }
  catch (e) { process.exit(code); }
}
function withTimeout(p, ms, label) {
  return Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(Object.assign(new Error('超时 ' + ms + 'ms: ' + (label || '')), { code: 'TIMEOUT' })), ms))]);
}

// ---------------- ABI ----------------
const QUEUE_ABI = [
  'function currentRound(uint8 room) view returns (uint256)',
  'function roundInfo(uint8 room, uint256 roundIndex) view returns (uint256 count, uint256 startTime, uint8 state, uint256 deadline, address[] winners)',
  'function roomConfigs(uint8 room) view returns (uint256 ticketPrice, uint256 maxCapacity, uint256 winnerCount, uint256 loserAirdropUsd, uint256 quotaThreshold, bool enabled, uint16 dailyRoundLimit, uint16 todayRounds, uint32 todayRoundsDay)',
  'function enterQueue(uint8 room, address referrer)',
  'function claimRefundAndAirdrop(uint8 room, uint256 roundIndex)',
  'function claimRefundOnly(uint8 room, uint256 roundIndex)',
  'function claimWin(uint8 room, uint256 roundId, uint256 minFtsOut)',
  'function formLP(uint8 room)',
  'function pendingQuotaUsd(address) view returns (uint256)',
  'function quotaMigrated(address) view returns (bool)',
  'function roomCount() view returns (uint8)',
  'function allowance(address owner, address spender) view returns (uint256)' // 仅用于兼容性探测
];
// 矿机金库: 新版(v8)按档位释放，pendingOf 为当前可领总额
const MINING_V8_ABI = [
  'function pendingOf(address) view returns (uint256)',
  'function trancheCount(address) view returns (uint256)',
  'function machineOf(address) view returns ((uint256 quotaUsd, uint256 releasedUsd, uint256 startDay, uint256 claimedDays, bool done)[] list, bool isActive)',
  'function claim() returns (uint256)',
  'function claimTranche(uint256 index) returns (uint256)'
];
// 老版矿机金库
const MINING_LEGACY_ABI = [
  'function pendingReward(address) view returns (uint256)',
  'function machineOf(address) view returns (uint256 quotaUsd, uint256 releasedUsd, uint256 startDay, uint256 claimedDays, bool active)',
  'function claim() returns (uint256)'
];
const USDT_ABI = [
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)'
];

// ---------------- 并发闸门 ----------------
// 公共节点对并发很敏感(429)，全局限制同时在飞的请求数，并保证最小间隔
class Semaphore {
  constructor(max) { this.max = Math.max(1, max); this.n = 0; this.q = []; this.lastAt = 0; }
  async acquire() {
    if (this.n < this.max) {
      this.n++;
    } else {
      // 排队等待: release() 会把令牌"直接转交"给等待者(不减少 n)，
      // 所以这里绝不能再自增 —— 否则等待者恢复前新来的 acquire 会看到 n<max 插队，
      // 最终并发数被顶穿，超过 RPC_MAX_CONCURRENT。
      await new Promise(r => this.q.push(r));
    }
    const gap = CFG.RPC_MIN_SPACING_MS - (Date.now() - this.lastAt);
    if (gap > 0) await sleep(gap);
    this.lastAt = Date.now();
  }
  release() {
    const next = this.q.shift();
    if (next) { next(); return; }   // 令牌转交，n 保持不变
    this.n = Math.max(0, this.n - 1);
  }
  async run(fn) { await this.acquire(); try { return await fn(); } finally { this.release(); } }
}
const rpcGate = new Semaphore(CFG.RPC_MAX_CONCURRENT);

// ---------------- 多节点分层池 ----------------
// 每个节点一个独立闸门(按档位定阈值)，账号平摊到节点；节点闸门满/冷却时溢出到负载最低的健康节点。
// 这样 100 个账号的请求分散到 N 个节点并行，而不是全挤在单一节点/单一闸门。
function nodeTier(url) {
  // bnbchain 官方域名 = 快档(闸门14)，其余公共节点 = 慢档(闸门12)
  return /bnbchain\.org/.test(url) ? 'fast' : 'slow';
}
class NodeConn {
  constructor(url, max) {
    this.url = url;
    this.gate = new Semaphore(max);
    this.provider = new ethers.JsonRpcProvider(url, CFG.CHAIN_ID, { staticNetwork: true });
    this.cooldownUntil = 0;
    this.latency = 0;
    this.ok = true;
    this.inflight = 0;
    this.sent = 0;
    this.failed = 0;
  }
  get available() { return this.ok && this.cooldownUntil <= Date.now(); }
  get load() { return this.gate.n / this.gate.max; }
}
class NodePool {
  constructor(urls) {
    this.nodes = urls.map(u => new NodeConn(u, CFG.NODE_TIER_CONCURRENCY[nodeTier(u)]));
    this.enabled = CFG.NODE_POOL_ENABLED && this.nodes.length > 0;
  }
  // 选节点: 优先 preferred(账号专属节点)，其不可用/满则挑负载最低的健康节点
  pick(preferred) {
    const healthy = this.nodes.filter(n => n.available);
    const pool = healthy.length ? healthy : this.nodes;
    if (preferred && preferred.available && preferred.load < 0.9) return preferred;
    // 负载最低优先，同负载按延迟低优先
    return pool.slice().sort((a, b) => (a.load - b.load) || (a.latency - b.latency))[0];
  }
  // 在选中节点的闸门内执行 fn(provider, node)。核心: 把请求分散到各节点独立闸门。
  // fn 第二个参数是选中的节点对象，供 RpcManager 在 429/失败时精准冷却该节点。
  async run(fn, preferred) {
    if (!this.enabled) return rpcGate.run(() => fn(this.nodes[0].provider, this.nodes[0]));
    // 重试时重新选节点: 排队等待期间原节点可能已被 429 冷却，不能在 acquire 后还打它
    for (let attempt = 0; attempt < 4; attempt++) {
      const node = this.pick(preferred);
      await node.gate.acquire();
      // 关键: 拿到令牌后再确认节点仍可用。若排队期间被冷却，释放令牌重选，
      // 否则已被冷却的节点仍会收到请求，导致同一节点被反复 429(实测会连续冷却 10 次)
      if (!node.available && this.nodes.some(n => n.available)) {
        node.gate.release();
        preferred = null;
        continue;
      }
      node.inflight++;
      try {
        const r = await fn(node.provider, node);
        node.sent++;
        return r;
      } finally {
        node.inflight--;
        node.gate.release();
      }
    }
    // 所有节点都在冷却: 兜底用负载最低的(总比卡死强)
    const node = this.pick(null);
    await node.gate.acquire();
    node.inflight++;
    try { return await fn(node.provider, node); }
    finally { node.inflight--; node.gate.release(); }
  }
  cooldown(node, ms) { if (node) { node.cooldownUntil = Date.now() + (ms || 30000); } }
  stats() { return this.nodes.map(n => `${n.url.replace('https://','')}:${n.gate.max}/${n.inflight}${n.available ? '' : '(冷却)'}`).join(' '); }
}
const nodePool = new NodePool(CFG.HTTP_POOL);

// ---------------- 429 / 限流识别 ----------------
function isRateLimited(e) {
  const s = (e.shortMessage || e.message || '') + (e.info && e.info.error && e.info.error.message || '');
  return e.code === 'SERVER_ERROR' && /429|too many requests|rate limit|over rate|exceed/i.test(s);
}
// 节点冷却表: 被限流的节点短时间内不再使用
const cooldown = new Map();
const cooldownLeft = url => Math.max(0, (cooldown.get(url) || 0) - Date.now());
function markCooldown(url, ms) { cooldown.set(url, Date.now() + ms); }

// ---------------- RPC 管理器 ----------------
class RpcManager {
  constructor(urls) {
    this.urls = urls.slice();
    this.index = 0;
    this.provider = null;
    this.failStreak = 0;
    this.listeners = [];
    this.stats429 = 0;
    this.rotating = null;   // 换节点去重: 并发的 rotate() 共用同一次探测结果
  }
  onRotate(fn) { this.listeners.push(fn); }
  makeProvider(url) {
    return new ethers.JsonRpcProvider(url, CFG.CHAIN_ID, { staticNetwork: true });
  }
  async probe(url) {
    const t0 = Date.now();
    try {
      const p = this.makeProvider(url);
      const h = await withTimeout(p.getBlockNumber(), CFG.RPC_TIMEOUT_MS, 'getBlockNumber');
      // 有些公共节点允许 eth_blockNumber 但屏蔽 eth_call(会报 400 / "eth_call is not supported")，
      // 这种节点会导致预演和余额读取全挂，必须在这里筛掉。
      const ret = await withTimeout(p.call({ to: CFG.USDT_ADDR, data: '0x313ce567' }), CFG.RPC_TIMEOUT_MS, 'eth_call');
      if (!ret || ret === '0x') throw new Error('eth_call 返回空');
      return { url, latency: Date.now() - t0, height: h, ok: true };
    } catch (e) {
      return { url, ok: false, error: e };
    }
  }
  async pickBest() {
    const rs = await Promise.all(this.urls.map(u => this.probe(u)));
    const good = rs.filter(r => r.ok).sort((a, b) => a.latency - b.latency);
    if (!good.length) {
      const detail = rs.map(r => `${r.url} -> ${r.error ? (r.error.shortMessage || r.error.message) : 'x'}`).join('; ');
      throw new Error('所有 HTTP 节点不可用: ' + detail);
    }
    good.forEach(r => info('SYS', `节点可用: ${r.url} 延迟=${r.latency}ms 高度=${r.height}`));
    // 把探测结果同步到 nodePool: 不可用节点标记冷却，可用的记录延迟
    if (nodePool.enabled) {
      const goodUrls = new Set(good.map(r => r.url));
      for (const n of nodePool.nodes) {
        const gr = good.find(r => r.url === n.url);
        if (gr) { n.latency = gr.latency; n.ok = true; }
        else { n.ok = false; n.cooldownUntil = Date.now() + 300000; }
      }
      nodePool.nodes.sort((a, b) => (a.latency || 99999) - (b.latency || 99999));
      ok('SYS', `节点分层池已就绪: ${nodePool.nodes.filter(n => n.ok).length}/${nodePool.nodes.length} 个节点，每节点独立闸门(${CFG.NODE_TIER_CONCURRENCY.fast}/${CFG.NODE_TIER_CONCURRENCY.slow})`);
    }
    this.index = this.urls.indexOf(good[0].url);
    this.provider = this.makeProvider(good[0].url);
    ok('SYS', `主节点: ${good[0].url} (${good[0].latency}ms)`);
    return this.provider;
  }
  async rotate() {
    // 多账号/多循环可能同时触发换节点: 合并成一次探测，避免同一 URL 被并发打 4 次、日志刷屏
    if (this.rotating) return this.rotating;
    this.rotating = this._rotate()
      .catch(e => { warnOnce('SYS', '切换节点异常: ' + formatError(e), 60000); return false; })
      .finally(() => { this.rotating = null; });
    return this.rotating;
  }
  async _rotate() {
    const old = this.urls[this.index];
    // 第一轮优先跳过处于冷却期的节点
    for (let pass = 0; pass < 2; pass++) {
    for (let i = 1; i <= this.urls.length; i++) {
      const idx = (this.index + i) % this.urls.length;
      const left = cooldownLeft(this.urls[idx]);
      if (pass === 0 && left > 0) continue;   // 冷却中，先试别的
      const r = await this.probe(this.urls[idx]);
      if (!r.ok) warnOnce('SYS', `备用节点不可用 ${this.urls[idx]}: ${formatError(r.error)}`, 60000);
      if (r.ok) {
        this.index = idx;
        this.provider = this.makeProvider(this.urls[idx]);
        this.failStreak = 0;
        warn('SYS', `已切换节点: ${old} -> ${this.urls[idx]} (${r.latency}ms)`);
        for (const fn of this.listeners) { try { fn(this.provider); } catch (e) { } }
        return true;
      }
    }
    }
    warn('SYS', '所有节点探测失败(或被限流冷却)，3 秒后重试');
    await sleep(3000);
    return false;
  }
  async rpc(fn, label, preferred) {
    let lastErr;
    let usedNode = null;
    for (let i = 0; i < CFG.MAX_RPC_RETRY; i++) {
      // 闸门只保护"发请求"这一瞬间；重试的退避/换节点必须在闸门外，
      // 否则一次慢/失败的重试会占住名额，把整个引擎堵死(实测会静默卡住)
      // 通过 nodePool 分发: fn 收到被选中节点的 provider 和 node 对象。
      try {
        const r = await nodePool.run((provider, node) => {
          usedNode = node;
          // 全局兜底超时: 没有它，一个卡死的 HTTP 请求会永久占住闸门名额，静默死锁
          return withTimeout(Promise.resolve(fn(provider, node)), CFG.RPC_TIMEOUT_MS, 'rpc');
        }, preferred);
        this.failStreak = 0;
        return r;
      } catch (e) {
        lastErr = e;
        this.failStreak++;
      }
      // ---- 以下重试逻辑都在闸门之外 ----
      if (isRateLimited(lastErr)) {
        this.stats429++;
        const backoff = 2000 * (i + 1);
        const badUrl = usedNode ? usedNode.url : this.urls[this.index];
        warn('SYS', `节点限流(429) 第 ${this.stats429} 次，冷却 ${badUrl} 30s 并切换到其它节点: ${formatError(lastErr).slice(0, 110)}`);
        nodePool.cooldown(usedNode, 30000);
        markCooldown(badUrl, 30000);
        await this.rotate();
        await sleep(backoff);
        continue;
      }
      const transient = ['NETWORK_ERROR', 'SERVER_ERROR', 'TIMEOUT', 'BAD_DATA'].includes(lastErr.code) || !lastErr.code;
      if (transient) {
        if (usedNode) { usedNode.failed++; nodePool.cooldown(usedNode, this.failStreak >= 2 ? 15000 : 3000); }
        if (this.failStreak >= 2) await this.rotate();
        await sleep(400 * (i + 1));
        continue;
      }
      throw lastErr;
    }
    throw lastErr;
  }
  // 统一的"受闸门保护"的直连调用(用于不经过重试逻辑的场景)
  gated(fn) { return nodePool.enabled ? nodePool.run(fn) : rpcGate.run(fn); }
  // 账号专属节点: 按索引平摊到各节点(节点数=账号数时一对一，多账号则轮转平摊)
  nodeFor(index) { return nodePool.enabled ? nodePool.nodes[index % nodePool.nodes.length] : null; }
}

// ---------------- 全局状态 ----------------
const mgr = new RpcManager(CFG.HTTP_POOL);
const instances = [];

function bind(inst, provider, node) {
  // 多节点分层: 账号专属节点用于写交易(wallet/contract)；单节点模式退回主节点
  if (node) inst.node = node;
  inst.provider = provider;
  inst.wallet = new ethers.Wallet(inst.pk, provider);
  inst.queue = new ethers.Contract(CFG.QUEUE_ADDR, QUEUE_ABI, inst.wallet);
  inst.usdt = new ethers.Contract(CFG.USDT_ADDR, USDT_ABI, inst.wallet);
  inst.miner = new ethers.Contract(CFG.MINER_QUEUE_ADDR, QUEUE_ABI, inst.wallet);
  inst.mining = new ethers.Contract(CFG.MINING_VAULT_ADDR, MINING_V8_ABI, inst.wallet);
  inst.legacyMining = new ethers.Contract(CFG.LEGACY_MINING_ADDR, MINING_LEGACY_ABI, inst.wallet);
}

// 推荐人解析: 配置里没填/填 0 时，读链上 referrerOfV2(已绑定的推荐关系)自动补全
async function resolveReferrer(inst) {
  if (inst.referrer && inst.referrer.toLowerCase() !== ZERO_ADDR) return inst.referrer;
  try {
    const r = await mgr.rpc(p => inst.queue.referrerOfV2(inst.address));
    if (r && r.toLowerCase() !== ZERO_ADDR) {
      inst.referrer = r;
      info(inst.address, `推荐人自动识别成功: ${r}（来自链上绑定关系）`);
      return r;
    }
  } catch (e) {
    warnOnce(inst.address, '推荐人自动识别失败(不影响入场): ' + formatError(e).slice(0, 100), 300000);
  }
  inst.referrer = ZERO_ADDR;
  return ZERO_ADDR;
}
mgr.onRotate(p => {
  // 分层模式: 账号已有专属节点，不随主节点轮换整体改绑(否则分层失效)。
  // 只有账号专属节点被冷却/失效时，才重新分配到当前最健康节点。
  if (nodePool.enabled) {
    for (const i of instances) {
      if (!i.node || !i.node.available) {
        const n = nodePool.pick(null);
        bind(i, n.provider, n);
      }
    }
  } else {
    instances.forEach(i => bind(i, p));
  }
});

// ---------------- WebSocket 可用性 ----------------
function ensureWebSocket() {
  // Node 22+ 自带 WebSocket(undici 实现)，但它只有 addEventListener，没有 .on()，
  // 而 ethers 的 WebSocketProvider 依赖 .on('block') -> 会抛 "provider.websocket.on is not a function"。
  // 所以优先注入 ws 模块(有完整 EventEmitter 接口)，失败才退回内置实现。
  try {
    const wsmod = require('ws');
    const WS = wsmod.WebSocket || wsmod;
    if (WS && WS.prototype && typeof WS.prototype.on === 'function') {
      if (globalThis.WebSocket !== WS) {
        globalThis.WebSocket = WS;
        info('SYS', '已注入 ws 模块作为 WebSocket 实现(兼容 ethers)');
      }
      return true;
    }
  } catch (e) { /* 没有 ws 就继续往下走 */ }
  if (typeof globalThis.WebSocket !== 'undefined') {
    warnOnce('SYS', '当前 WebSocket 实现可能不兼容 ethers(缺少 .on)，建议 npm install ws；已用 HTTP 轮询兜底', 300000);
    return true;
  }
  warn('SYS', 'WebSocket 不可用(缺少 ws)，将使用 HTTP 轮询模式兜底。修复: npm install ws');
  return false;
}

// ---------------- 区块流: WS 优先 + 轮询兜底 ----------------
class BlockStream {
  constructor() {
    this.wsOk = false;
    this.wsIndex = 0;
    this.wsBackoff = 3000;
    // 初始化为"现在"，否则首次 watchdog 检查时会把 Date.now()-0 打印成
    // "已 17 亿秒未收到新块"这种吓人的假告警
    this.lastBlockAt = Date.now();
    this.lastHeight = 0;
    this.wsProvider = null;
    this.stopped = false;
    this.ticking = false;
    this.dupSkipped = 0;
    this.tickCount = 0;
    // 去重改用"区块号"，不再用 800ms 时间窗(BSC 出块已降到 0.75s，时间窗会丢块)
    this.seenBlocks = new Set();
    this.blockRetry = new Map();   // 块号 -> 状态读取失败次数
    this.pendingBlocks = [];      // 上一轮没查完时挂起，查完立刻补跑
    this.isReconnecting = false;  // 防止同时连出多条 WebSocket(幽灵连接)
    this.connecting = false;
    this.wsErrAt = 0;
    this.pollFailStreak = 0;
  }
  start() {
    if (ensureWebSocket()) this.connectWs(); else warn('SYS', 'WS 不可用，直接进入轮询模式');
    this.startPolling();
    this.startWatchdog();
  }
  connectWs() {
    if (this.stopped) return;
    // 幽灵连接防护: 同一时刻只允许一条连接流程在跑。
    // 断线时 open/close/error 可能连续触发，无锁会同时开出四五条 WS 挤爆手机网络。
    if (this.connecting) { this.dupSkipped++; return; }
    const url = CFG.WSS_POOL[this.wsIndex % CFG.WSS_POOL.length];
    if (!url) return;
    this.connecting = true;
    let opened = false;
    let provider = null;
    const guard = setTimeout(() => {
      if (!opened) {
        warn('SYS', `WS 连接超时: ${url} -> 换下一个节点`);
        this.connecting = false;
        try { provider && provider.destroy && provider.destroy(); } catch (e) { }
        this.scheduleReconnect();
      }
    }, 12000);
    try {
      provider = new ethers.WebSocketProvider(url, CFG.CHAIN_ID, { staticNetwork: true });
      this.wsProvider = provider;
      provider.websocket.on('open', () => {
        opened = true; clearTimeout(guard);
        this.connecting = false;
        this.wsOk = true; this.wsBackoff = 3000;
        ok('SYS', `WebSocket 已连接: ${url}`);
      });
      provider.websocket.on('close', () => {
        clearTimeout(guard);
        this.connecting = false;
        this.wsOk = false;
        warnOnce('SYS', 'WebSocket 断开，准备重连', 30000);
        this.scheduleReconnect();
      });
      provider.websocket.on('error', (e) => {
        clearTimeout(guard);
        this.connecting = false;
        const m = (e && (e.message || e.type)) || 'unknown';
        warnOnce('SYS', `WebSocket 错误(${url}): ${m}`, 30000);
      });
      // ethers v6 的 JsonRpcApiProvider 会在内部请求失败时 emit('error')。
      // EventEmitter 上如果没有 'error' 监听者，Node 会直接抛 ERR_UNHANDLED_ERROR，
      // 之前只监听了底层 socket 的 error，provider 层的没监听 -> 变成"未捕获异常"。
      provider.on('error', (e) => {
        this.wsErrAt = Date.now();
        this.wsOk = false;
        warnOnce('SYS', `WS provider 异常(将触发重连): ${(e && (e.shortMessage || e.message)) || e}`, 15000);
        this.scheduleReconnect();
      });
      provider.on('block', (bn) => { this.lastBlockAt = Date.now(); this.lastHeight = bn; this.tick(bn, 'ws'); });
    } catch (e) {
      clearTimeout(guard);
      this.connecting = false;
      err('SYS', `WebSocket 初始化失败: ${formatError(e)}`);
      this.scheduleReconnect();
    }
  }
  scheduleReconnect() {
    if (this.stopped) return;
    // 已经在重连流程中就不再排新的，避免重连风暴
    if (this.isReconnecting) return;
    this.isReconnecting = true;
    this.connecting = false;
    try { this.wsProvider && this.wsProvider.destroy && this.wsProvider.destroy(); } catch (e) { }
    this.wsOk = false;
    this.wsIndex++;
    const wait = Math.min(this.wsBackoff, 30000);
    this.wsBackoff = Math.min(this.wsBackoff * 2, 30000);
    info('SYS', `${Math.round(wait / 1000)} 秒后重连 WebSocket (第 ${this.wsIndex} 次)`);
    setTimeout(() => {
      this.isReconnecting = false;
      this.connectWs();
    }, wait);
  }
  startPolling() {
    const loop = async () => {
      while (!this.stopped) {
        try {
          const h = await mgr.rpc(p => withTimeout(p.getBlockNumber(), 8000, 'poll'));
          this.pollFailStreak = 0;
          // 块号变了就交给 tick，去重在 tick 里按块号做(不再靠时间窗判断)
          if (h > this.lastHeight) {
            this.lastHeight = h;
            this.lastBlockAt = Date.now();
            this.tick(h, 'poll');
          }
        } catch (e) {
          this.pollFailStreak++;
          // 连续失败就换节点并放慢轮询，避免 DNS 掉线时每 1.5s 刷一条错误
          if (this.pollFailStreak >= 2) await mgr.rotate();
          const backoff = Math.min(1000 * this.pollFailStreak, 15000);
          errOnce('SYS', '轮询获取区块失败: ' + formatError(e), 60000);
          await sleep(backoff);
        }
        await sleep(CFG.POLL_INTERVAL_MS);
      }
    };
    loop().catch(e => warnOnce('SYS', '轮询循环异常: ' + formatError(e), 60000));
  }
  startWatchdog() {
    setInterval(() => {
      if (this.stopped) return;
      if (Date.now() - this.lastBlockAt > CFG.WS_STALE_MS) {
        warnOnce('SYS', `已 ${Math.round((Date.now() - this.lastBlockAt) / 1000)}s 未收到新块，轮询兜底中` + (this.wsOk ? '，重置 WS' : ''), 30000);
        if (this.wsOk) { this.scheduleReconnect(); }
      }
    }, 10000);
  }
  // 出块处理: 按"区块号"去重 + 忙时挂起补跑
  // 旧实现用 800ms 时间窗去重，BSC 出块已降到 ~0.75s，会直接丢掉约一半的区块；
  // 而且上一轮没查完时新块被直接丢弃。现在改成：没查过的块号排队，查完立刻补跑。
  tick(height, src) {
    const h = Number(height);
    if (!Number.isFinite(h)) return;
    if (this.seenBlocks.has(h)) { this.dupSkipped++; return; }  // 同一个块只处理一次(WS/轮询双通道去重)
    this.seenBlocks.add(h);
    // 控制缓存体积
    if (this.seenBlocks.size > 500) this.seenBlocks = new Set([...this.seenBlocks].slice(-200));

    this.pendingBlocks.push(h);
    if (this.pendingBlocks.length > 50) this.pendingBlocks.splice(0, this.pendingBlocks.length - 50);

    if (this.ticking) return;  // 正在处理，新块排队等下一轮自动补跑
    this.runQueue().catch(e => warnOnce('SYS', '区块处理队列异常: ' + formatError(e), 30000));
  }

  async runQueue() {
    if (this.ticking) return;
    this.ticking = true;
    try {
      while (this.pendingBlocks.length && !this.stopped) {
        // 关键: 只按"最新块号"处理一次，而不是把排队的每个块都完整查一遍。
        // 旧写法逐块处理，每块要 3 房间 × 2 个串行 RTT(≈1s)，再加账号错峰 await 睡眠，
        // 而 BSC 0.75s 出一块 -> 队列永远追不上，实际退化成 2s 一次的状态轮询，
        // 抢单窗口早就过去了(而且每轮 height 都不同，共享缓存完全不命中)。
        const h = Math.max(...this.pendingBlocks);
        this.pendingBlocks.length = 0;
        this.tickCount++;
        let rooms;
        try {
          rooms = await getSharedState(h);
        } catch (e) {
          // 关键: 不能把失败当成"这个块处理过了"。tick 里已经 seenBlocks.add(h)，
          // 如果这里直接 continue，WS 和轮询再送同一个块号都会被去重掉，
          // 这个块的抢单窗口就永久丢了。这里退回 seenBlocks 并重排，最多重试 3 次。
          const tries = (this.blockRetry.get(h) || 0) + 1;
          this.blockRetry.set(h, tries);
          if (this.blockRetry.size > 200) {
            // 按块号淘汰(块号单调递增)。不能按插入顺序删 —— 那可能把还在重试中的块
            // 删掉，计数归零后又白送 3 次机会，极端情况下会无限重试
            for (const k of this.blockRetry.keys()) { if (k < h - 200) this.blockRetry.delete(k); }
          }
          if (tries <= 3 && !this.stopped) {
            this.seenBlocks.delete(h);           // 允许同块号再次进入
            this.pendingBlocks.push(h);
            warnOnce('SYS', `读取区块 ${h} 状态失败(第 ${tries} 次)，稍后重试: ${formatError(e).slice(0, 120)}`, 20000);
            await sleep(300 * tries);
          } else {
            errOnce('SYS', `区块 ${h} 连续 ${tries} 次读取失败，放弃该块: ${formatError(e)}`, 30000);
          }
          continue;
        }
        // 账号错峰用 setTimeout，不要 await sleep —— 否则 10 个账号光"睡觉"就 1.2s，
        // 把出块队列直接堵死
        let idx = 0;
        for (const inst of instances) {
          if (!inst || inst.busy) continue;
          const delay = Math.min(idx * CFG.ACCOUNT_STAGGER_MS, 300);
          idx++;
          const fire = () => snipeWithState(inst, rooms).catch(e => err(inst.address, '抢单异常: ' + formatError(e)));
          if (delay > 0) setTimeout(fire, delay); else fire();
        }
      }
    } finally {
      this.ticking = false;
      // 收尾时又来新块则再跑一轮，避免遗漏
      if (this.pendingBlocks.length && !this.stopped) this.runQueue().catch(e => warnOnce('SYS', '区块处理队列异常: ' + formatError(e), 30000));
    }
  }
}

// ---------------- 房间标签 ----------------
// 0=10U 1=50U 2=100U；若链上票价与预设不符，直接显示真实票价
const ROOM_NAMES = { 0: '10U', 1: '50U', 2: '100U' };
function roomLabel(room, ticketPrice) {
  const preset = ROOM_NAMES[room];
  if (ticketPrice === null || ticketPrice === undefined) return `房间${room}${preset ? '(' + preset + ')' : ''}`;
  const p = Number(ethers.formatUnits(ticketPrice, 18));
  if (!Number.isFinite(p)) return `房间${room}${preset ? '(' + preset + ')' : ''}`;
  return preset && preset !== String(p) + 'U' ? `房间${room}(链上票价${p}U,预设${preset})` : `房间${room}(${p}U)`;
}

// ---------------- 资金与授权 ----------------
// ---------------- 灵活资金决策(多账号互匀 gas / 凑 USDT) ----------------
// 仅在 CFG.FLEX_ENABLED=true 时生效；关闭(默认)时立即返回，行为与现状完全一致。
// 语义限制: 退款/空投只能由资格地址自己领(claim 退给 msg.sender)，脚本无法代领，
// 因此"匀开/凑单"在这里实现为【从富余账号向本账号做真实链上转账】补 gas 或 USDT，
// 转账本身的 gas 由 donor 承担。默认关闭，不开启不产生任何额外请求或交易。
// FLEX 并发安全: 多账号可能同时向同一 donor 要钱，导致 donor 余额被重复计算而超支。
// 用"预留"表记录正在转账中的金额，pickFlexDonor 计算可用余额时扣掉这部分。
const flexReserved = new Map();   // address(lower) -> BigInt
function flexReserve(addr, wei) { const k = addr.toLowerCase(); flexReserved.set(k, (flexReserved.get(k) || 0n) + wei); }
function flexRelease(addr, wei) { const k = addr.toLowerCase(); const v = (flexReserved.get(k) || 0n) - wei; if (v > 0n) flexReserved.set(k, v); else flexReserved.delete(k); }

// 找 donor: 返回 {inst, slack}。slack 已扣除 keep 保留额、本次缺口、以及正在转账中的预留额。
// 严格判断 slack >= shortWei，避免"选了个余额不够的 donor"导致转账失败还白烧 gas。
async function pickFlexDonor(inst, asset, shortWei) {
  const keep = asset === 'bnb'
    ? ethers.parseEther(String(CFG.FLEX_DONOR_KEEP_BNB))
    : ethers.parseUnits(String(CFG.FLEX_DONOR_KEEP_USDT), 18);
  let best = null, bestSlack = 0n;
  for (const d of (typeof instances !== 'undefined' ? instances : [])) {
    if (!d || String(d.address).toLowerCase() === String(inst.address).toLowerCase()) continue;
    try {
      const bal = asset === 'bnb'
        ? await mgr.rpc(p => d.provider.getBalance(d.address))
        : await mgr.rpc(p => d.usdt.balanceOf(d.address));
      const reserved = flexReserved.get(String(d.address).toLowerCase()) || 0n;
      // 可用 = 余额 - 保留额 - 已预留 - 本次缺口(保证 donor 自己还留得下 keep)
      const slack = bal - keep - reserved;
      // 关键: 必须够本次缺口，否则选了也转不出来
      if (slack >= shortWei && slack > bestSlack) { best = d; bestSlack = slack; }
    } catch (e) { /* 该 donor 读失败，跳过 */ }
  }
  return best ? { inst: best, slack: bestSlack } : null;
}
// 转 BNB: 必须显式带 nonce(和 inst.nonce 体系一致)，否则 ethers 自己读可能撞号
async function flexSendNative(fromInst, to, amtWei) {
  const release = await fromInst.mutex.acquire();
  try {
    const fee = await buildFeeParams(1);
    const nonce = fromInst.nonce !== null
      ? fromInst.nonce
      : await mgr.rpc(p => p.getTransactionCount(fromInst.address, 'pending'));
    const tx = await withTimeout(fromInst.wallet.sendTransaction({ to, value: amtWei, nonce, gasLimit: 21000n, ...fee.tx }), 30000, 'flex-bnb');
    fromInst.nonce = nonce + 1;   // 立刻推进本地 nonce，避免后续交易撞号
    info(fromInst.address, `[灵活决策] 转 BNB 给 ${to} 已广播 ${tx.hash} (nonce=${nonce})`);
    try { await withTimeout(tx.wait(1, CFG.TX_WAIT_MS), CFG.TX_WAIT_MS + 10000, 'flex-bnb-wait'); } catch (e) { }
    return true;
  } catch (e) { warnOnce(fromInst.address, `[灵活决策] 转 BNB 失败: ${formatError(e)}`, 60000); fromInst.nonce = null; return false; }
  finally { release(); }
}
// 节流: 同一账号对同一资产(USDT/BNB) 30 秒内只尝试一次凑钱，避免每轮扫全部 donor + 反复转账。
// 也防止"两个账号互相都缺、互相转来转去"的抖动(转完仍不足时至少等 30s 再试)。
const flexLastTry = new Map();   // key = addr:asset -> ts
function flexThrottled(inst, asset) {
  const k = inst.address + ':' + asset;
  const now = Date.now();
  if (now - (flexLastTry.get(k) || 0) < 30000) return true;
  flexLastTry.set(k, now);
  if (flexLastTry.size > 2000) { const t = now - 300000; for (const [kk, vv] of flexLastTry) if (vv < t) flexLastTry.delete(kk); }
  return false;
}
async function tryFlexTopUp(inst, needUsdtWei, needGasWei) {
  if (!CFG.FLEX_ENABLED || DRY_RUN) return;
  const needGas = needGasWei || 0n;
  const needUsdt = needUsdtWei || 0n;
  // 两个方向分别节流: 缺 USDT 和缺 BNB 是独立事件
  const allowGas = CFG.FLEX_GAS_POOLING && needGas > 0n && !flexThrottled(inst, 'bnb');
  const allowUsdt = CFG.FLEX_FUND_AGGREGATION && needUsdt > 0n && !flexThrottled(inst, 'usdt');
  if (!allowGas && !allowUsdt) return;
  let bnbBal = 0n, usdtBal = 0n;
  try {
    [bnbBal, usdtBal] = await Promise.all([
      mgr.rpc(p => inst.provider.getBalance(inst.address)),
      needUsdt > 0n ? mgr.rpc(p => inst.usdt.balanceOf(inst.address)) : Promise.resolve(0n)
    ]);
  } catch (e) { return; }
  // 1) gas 匀开: 本账号 BNB 不足以发交易 -> 找 BNB 富余的 donor 转入差额
  if (allowGas && bnbBal < needGas) {
    const short = needGas - bnbBal;
    // 转账本身也要 gas: 多要 20% 覆盖 donor 的手续费波动，但不超过 donor 可用额度
    const want = short + short / 5n;
    const donor = await pickFlexDonor(inst, 'bnb', want);
    if (donor) {
      flexReserve(donor.inst.address, want);
      info(inst.address, `[灵活决策] BNB 不足(${ethers.formatEther(bnbBal)})，从 ${donor.inst.address} 匀 ${ethers.formatEther(want)} 作 gas`);
      const okSend = await flexSendNative(donor.inst, inst.address, want);
      flexRelease(donor.inst.address, want);
      if (okSend) {
        // 验证到账: 转完重读，没到账就明确报错(不静默继续)
        try {
          const after = await mgr.rpc(p => inst.provider.getBalance(inst.address));
          if (after <= bnbBal) warnOnce(inst.address, `[灵活决策] BNB 转账后余额未增加(可能还在确认)，本轮继续但下轮会重试`, 60000);
          else inst.bnbCache = { at: Date.now(), v: after };
        } catch (e) { }
      }
    } else warnOnce(inst.address, `[灵活决策] 需匀 ${ethers.formatEther(short)} BNB 但无账号有足够富余(已扣保留额/在途预留)`, 120000);
  }
  // 2) USDT 凑单: 本账号 USDT 单独不够、但存在富余 donor -> 转入差额
  if (allowUsdt && usdtBal < needUsdt) {
    const short = needUsdt - usdtBal;
    const donor = await pickFlexDonor(inst, 'usdt', short);
    if (donor) {
      flexReserve(donor.inst.address, short);
      info(inst.address, `[灵活决策] USDT 不足(${ethers.formatUnits(usdtBal, 18)}U)，从 ${donor.inst.address} 凑 ${ethers.formatUnits(short, 18)}U`);
      const okSend = await sendTx(donor.inst, { label: `[灵活决策] 转 USDT 给 ${inst.address}`, contract: donor.inst.usdt, method: 'transfer', args: [inst.address, short] });
      flexRelease(donor.inst.address, short);
      if (!okSend) warnOnce(inst.address, '[灵活决策] USDT 转账广播失败，本轮可能仍不足，下轮重试', 60000);
    } else warnOnce(inst.address, '[灵活决策] 需凑 USDT 但无单账号富余可匀出(或均不足)', 120000);
  }
}

// v1.7.1: 授权额度计算（纯函数，便于回归测试）。
// 返回 { target: BigInt, note: string }；余额不足一轮票价时返回 null，避免发起无意义授权。
// 硬规则: 0 不再等于"全部余额"；额度同时受场数上限与 U 数上限约束；绝不 MaxUint256。
function computeApproveTarget(ticketPrice, bal, cfg, parseUnits) {
  const note = [];
  const maxRounds = Math.min(20, Math.max(1, Math.floor(Number(cfg.APPROVE_MAX_ROUNDS) || 3)));
  const maxUsdRaw = Number(cfg.APPROVE_MAX_USD);
  const maxUsd = Number.isFinite(maxUsdRaw) && maxUsdRaw > 0 && maxUsdRaw < 1e21 ? maxUsdRaw : 100;
  const capByUsd = parseUnits(String(maxUsd), 18);
  const capByRounds = ticketPrice * BigInt(maxRounds);
  // 按模式分别设上限：按场数最多 maxRounds 场，按 U 数最多 maxUsd U。
  let target, cap;
  if (cfg.APPROVE_USD === null || cfg.APPROVE_USD === undefined) {
    cap = capByRounds;
    const want = Math.max(1, Math.floor(Number(cfg.APPROVE_ROUNDS) || 1));
    const rounds = Math.min(maxRounds, want);
    if (rounds !== want) note.push(`授权场数已收敛到上限 ${maxRounds} 场`);
    target = ticketPrice * BigInt(rounds);
  } else if (Number(cfg.APPROVE_USD) === 0) {
    // v1.7.0 把 0 解释成"全部余额"，与项目自己的安全承诺冲突；1.7.1 起一律回落到一轮票价。
    cap = ticketPrice;
    note.push('APPROVE_USD=0（全部余额）已废弃，按 1 场票价授权');
    target = ticketPrice;
  } else {
    cap = capByUsd;
    try { target = parseUnits(String(cfg.APPROVE_USD), 18); }
    catch (e) { note.push('APPROVE_USD 解析失败，按 1 场票价授权'); target = ticketPrice; }
  }
  if (!(target > 0n)) { target = ticketPrice; }
  if (target > cap) { note.push(`授权额已压到上限 ${maxUsd}U / ${maxRounds} 场`); target = cap; }
  if (bal < ticketPrice) return null;          // 余额不够入场：不发注定无意义的 approve
  if (target > bal) target = bal;
  if (!(target > 0n)) return null;
  return { target, note: note.join('；') };
}

async function ensureFunds(inst, ticketPrice, room) {
  const tag = roomLabel(room, ticketPrice);
  // 1) USDT 余额
  let bal = 0n;
  try {
    bal = await mgr.rpc(p => inst.usdt.balanceOf(inst.address));
  } catch (e) {
    err(inst.address, `[${tag}] 读取 USDT 余额失败: ${formatError(e)}`);
    err(inst.address, `[${tag}] 排查: 检查 USDT 合约地址是否正确(FTS_USDT_ADDR)、该节点是否 ban 了 eth_call、换节点重试`);
    return false;
  }
  if (bal < ticketPrice) {
    // 仅"报资金不足"时才触发灵活决策(默认关闭=no-op): 尝试从富余账号凑 USDT，补后重读
    if (CFG.FLEX_ENABLED) {
      await tryFlexTopUp(inst, ticketPrice, 0n);
      try { bal = await mgr.rpc(p => inst.usdt.balanceOf(inst.address)); } catch (e) { }
    }
    if (bal < ticketPrice) {
      errOnce(inst.address, `[${tag}] USDT 余额不足: 本轮需要 ${ethers.formatUnits(ticketPrice, 18)}，钱包当前 ${ethers.formatUnits(bal, 18)} -> 跳过本轮，不会发交易(已节流，60s 内不重复打印)`);
      return false;
    }
  }
  // 2) BNB gas 检查（60s 缓存: BNB 只用于付 gas，变化极慢，没必要每个块都查）
  try {
    const nowTs = Date.now();
    if (!inst.bnbCache || nowTs - inst.bnbCache.at > 60000) {
      inst.bnbCache = { at: nowTs, v: await mgr.rpc(p => inst.provider.getBalance(inst.address)) };
    }
    const gasNeed = ethers.parseEther(String(CFG.MIN_BNB_GAS));
    if (inst.bnbCache.v < gasNeed) {
      // 仅 BNB(gas) 不足时才触发灵活决策(默认关闭=no-op): 从富余账号匀一笔，补后重读
      if (CFG.FLEX_ENABLED) {
        await tryFlexTopUp(inst, 0n, gasNeed);
        inst.bnbCache = { at: Date.now(), v: await mgr.rpc(p => inst.provider.getBalance(inst.address)) };
      }
    }
    const bnb = inst.bnbCache.v;
    if (bnb < gasNeed) {
      warnOnce(inst.address, `[${tag}] BNB 余额偏低(gas): ${ethers.formatEther(bnb)} BNB，建议保留 > ${CFG.MIN_BNB_GAS}，否则交易发不出去`);
    }
  } catch (e) { /* 非致命 */ }

  // 3) 授权：必须以 USDT 合约为准（原版误用 QUEUE 合约，导致抢单静默失败）
  let allowance = 0n;
  try {
    allowance = await mgr.rpc(p => inst.usdt.allowance(inst.address, CFG.QUEUE_ADDR));
  } catch (e) {
    err(inst.address, `[${tag}] 读取 USDT 授权额度失败: ${formatError(e)}`);
    err(inst.address, `[${tag}] 排查: 确认 USDT 合约支持 allowance(view)；若该节点异常请换节点`);
    return false;
  }
  // 每轮只授权"刚好这一轮"的票价，用完下一轮再授权（不做多轮/大额授权）
  const need = ticketPrice;
  if (allowance >= need) return true;

  // v1.7.1: 统一走 computeApproveTarget —— 拒绝"全部余额"、压上限、余额不足不空发 approve
  let plan;
  try {
    plan = computeApproveTarget(ticketPrice, bal, CFG, ethers.parseUnits);
  } catch (e) {
    err(inst.address, `[${tag}] 计算授权额度失败，本轮放弃入场: ${formatError(e)}`);
    return false;
  }
  if (!plan) {
    warnOnce(inst.address, `[${tag}] USDT 余额 ${ethers.formatUnits(bal, 18)} < 本轮票价 ${ethers.formatUnits(need, 18)}，不发起无意义授权，跳过本轮`, 60000);
    return false;
  }
  const target = plan.target;
  if (plan.note) warnOnce(inst.address, `[${tag}] ${plan.note}`, 300000);
  const rounds = Number(ethers.formatUnits(target, 18)) / Number(ethers.formatUnits(ticketPrice, 18));
  info(inst.address, `[${tag}] 授权不足(当前 ${ethers.formatUnits(allowance, 18)} < 本轮需要 ${ethers.formatUnits(need, 18)})，发起授权 ${ethers.formatUnits(target, 18)} USDT (${rounds >= 1 ? Math.round(rounds) : rounds.toFixed(2)} 轮用量，上限 ${CFG.APPROVE_MAX_USD}U / ${CFG.APPROVE_MAX_ROUNDS} 场)`);
  const okTx = await sendTx(inst, {
    label: `[${tag}] USDT 授权 ${ethers.formatUnits(target, 18)}`,
    contract: inst.usdt,
    method: 'approve',
    args: [CFG.QUEUE_ADDR, target]
  });
  if (!okTx) {
    err(inst.address, `[${tag}] 授权失败，本轮放弃入场(不会扣款)。具体原因见上方 sendTx 的日志(余额不足 / gas 不够 / revert / 广播失败)`);
    return false;
  }
  return true;
}

// ---------------- 手续费策略: 运行时探测，不硬编码 ----------------
// BSC 各节点对 EIP-1559 的支持程度不一(部分节点 baseFee 恒为 0)。
// 这里读最新区块的 baseFeePerGas 判断：>0 走 type 2(可用优先费插队)，否则走 type 0。
let eip1559Cached = null; // null=未探测 / true / false
async function detectEip1559() {
  if (eip1559Cached !== null) return eip1559Cached;
  try {
    const blk = await mgr.rpc(p => withTimeout(p.getBlock('latest'), 8000, 'getBlock'));
    const base = blk && blk.baseFeePerGas !== null && blk.baseFeePerGas !== undefined ? BigInt(blk.baseFeePerGas) : 0n;
    eip1559Cached = base > 0n;
    info('SYS', `手续费模式探测: baseFeePerGas=${base} -> ${eip1559Cached ? 'EIP-1559 (type 2)' : 'Legacy (type 0)'}`);
    return eip1559Cached;
  } catch (e) {
    warn('SYS', `手续费模式探测失败，回退 Legacy: ${formatError(e).slice(0, 120)}`);
    eip1559Cached = false;
    return false;
  }
}
function capGwei(v) {
  const max = ethers.parseUnits(String(CFG.GAS_MAX_GWEI), 'gwei');
  const min = ethers.parseUnits(String(CFG.GAS_MIN_GWEI), 'gwei');
  if (v > max) v = max;
  if (v < min) v = min;
  return v;
}
function scaled(base, attempt) {
  const mult = BigInt(Math.round(CFG.GAS_MULT * 100)) * (attempt > 1 ? 130n : 100n) / 100n;
  return capGwei((base * mult) / 100n);
}
async function buildFeeParams(attempt) {
  const forced = CFG.TX_TYPE === '2' ? true : (CFG.TX_TYPE === '0' ? false : await detectEip1559());
  const bump = attempt > 1 ? 1.3 : 1;

  if (!forced) {
    let gasPrice;
    if (CFG.GAS_FIXED_GWEI) {
      gasPrice = capGwei(ethers.parseUnits(String(CFG.GAS_FIXED_GWEI), 'gwei'));
    } else {
      const fd = await mgr.rpc(p => withTimeout(p.getFeeData(), 8000, 'feeData'));
      gasPrice = scaled(fd.gasPrice || fd.maxFeePerGas || ethers.parseUnits('1', 'gwei'), attempt);
    }
    return { type: 0, gasPrice, tx: { type: 0, gasPrice }, desc: `${ethers.formatUnits(gasPrice, 'gwei')}gwei` };
  }

  const fd = await mgr.rpc(p => withTimeout(p.getFeeData(), 8000, 'feeData'));
  let baseFee = fd.lastBaseFeePerGas || 0n;
  if (!baseFee) {
    try {
      const blk = await mgr.rpc(p => withTimeout(p.getBlock('latest'), 8000, 'getBlock'));
      baseFee = blk && blk.baseFeePerGas ? BigInt(blk.baseFeePerGas) : 0n;
    } catch (e) { }
  }
  const prioMax = ethers.parseUnits(String(CFG.PRIORITY_MAX_GWEI), 'gwei');
  let maxPriorityFeePerGas = (fd.maxPriorityFeePerGas || ethers.parseUnits('0.5', 'gwei'));
  const prio = (maxPriorityFeePerGas * BigInt(Math.round(bump * 100))) / 100n;
  maxPriorityFeePerGas = prio > prioMax ? prioMax : prio;
  // maxFee = base*2 + prio，再乘上浮系数；同时保证不低于 legacy 报价，避免被判定低价
  let maxFeePerGas = (baseFee * 2n + maxPriorityFeePerGas);
  maxFeePerGas = scaled(maxFeePerGas || ethers.parseUnits('1', 'gwei'), attempt);
  if (CFG.GAS_FIXED_GWEI) {
    const g = capGwei(ethers.parseUnits(String(CFG.GAS_FIXED_GWEI), 'gwei'));
    maxFeePerGas = g; maxPriorityFeePerGas = g > prioMax ? prioMax : g;
  }
  return {
    type: 2,
    gasPrice: maxFeePerGas, // 仅用于日志/展示
    tx: { type: 2, maxFeePerGas, maxPriorityFeePerGas },
    desc: `maxFee=${ethers.formatUnits(maxFeePerGas, 'gwei')} prio=${ethers.formatUnits(maxPriorityFeePerGas, 'gwei')}gwei`
  };
}

// ---------------- 后台确认 ----------------
// 广播后不等 receipt，确认过程放后台，成功/失败单独打日志并回调。
// 失败时通过 onFailed 把"已领取"标记撤掉，下一轮会重试，不会漏退款。
function confirmTxInBackground(inst, tx, opt, nonce) {
  (async () => {
    try {
      const receipt = await withTimeout(tx.wait(1, CFG.TX_WAIT_MS), CFG.TX_WAIT_MS + 10000, 'wait');
      if (receipt && receipt.status === 1) {
        ok(inst.address, `${opt.label} 已确认! hash=${tx.hash} gasUsed=${receipt.gasUsed} block=${receipt.blockNumber}`);
        if (opt.onConfirmed) { try { opt.onConfirmed(); } catch (e) { } }
      } else {
        inst.stats.failed++;
        err(inst.address, `${opt.label} 上链失败(status=0): ${tx.hash} -> 可能 revert，请到区块浏览器查看`);
        if (opt.onFailed) { try { opt.onFailed(); } catch (e) { } }
      }
    } catch (e) {
      // 超时 != 失败: 交易可能还在 mempool。这里必须做"同 nonce 加价重播"，
      // 否则一旦这笔被公共节点丢弃，nonce 就永久断档 —— 该账号后续所有交易
      // 都会排在它后面卡死，直到进程重启(drainPending 只在启动时跑一次)。
      const reb = await rebroadcastSameNonce(inst, tx, nonce);
      if (reb) {
        warnOnce(inst.address, `${opt.label} 确认超时，已按同 nonce(${nonce}) 加价重播: ${reb}`, 30000);
        // 关键: 重播也要盯最终结果。旧逻辑直接 return，若重播交易最终 revert，
        // claimed 会一直挂着、这笔到游戏结束都不再领(漏领的第二个来源)。
        try {
          const rep = await withTimeout(inst.provider.waitForTransaction(reb, 1, CFG.TX_WAIT_MS), CFG.TX_WAIT_MS + 10000, 'replay-wait');
          if (rep && rep.status === 1) {
            if (opt.onConfirmed) { try { opt.onConfirmed(); } catch (x) { } }
          } else {
            inst.stats.failed++;
            warnOnce(inst.address, `${opt.label} 重播交易上链失败(status=0): ${reb}`, 30000);
            if (opt.onFailed) { try { opt.onFailed(); } catch (x) { } }
          }
        } catch (x) {
          // 重播仍查不到结果: 交给 nonce 巡检 + 下轮预检重判，不臆断成功/失败
          warnOnce(inst.address, `${opt.label} 重播确认仍超时: ${reb} -> 交下轮重扫`, 60000);
        }
        return;
      }
      inst.stats.failed++;
      warnOnce(inst.address, `${opt.label} 确认超时: ${tx.hash} -> 已交给 nonce 巡检，稍后会自动补交易填坑`, 30000);
      if (opt.onFailed) { try { opt.onFailed(); } catch (e) { } }
    } finally {
      // noWait 领取在途计数归零(与 sendTx 广播成功时的 +1 配对)，供 isBusyForRestart 判断
      inst.unconfirmed = Math.max(0, (inst.unconfirmed || 1) - 1);
    }
  })().catch(() => { });
}

// 用完全相同的 nonce + 更高 gas 重播原交易（内容不变，只换手续费）
async function rebroadcastSameNonce(inst, tx, nonce) {
  if (DRY_RUN) return null;
  // 广播必须和 sendTx / gapFixer 共用同一把 nonce 锁，
  // 否则三者可能同时用同一个 nonce 发交易，互相覆盖
  const release = await inst.mutex.acquire();
  try {
    const fee = await buildFeeParams(2);   // attempt=2 -> 1.3 倍加价
    const rep = await withTimeout(inst.wallet.sendTransaction({
      to: tx.to,
      data: tx.data,
      value: tx.value || 0n,
      nonce,
      gasLimit: tx.gasLimit || undefined,
      ...fee.tx
    }), 30000, 'rebroadcast');
    return rep.hash;
  } catch (e) {
    warnOnce(inst.address, `同 nonce(${nonce}) 重播失败: ${formatError(e)}`, 60000);
    return null;
  } finally {
    release();
  }
}

// ---------------- nonce 断档自愈 ----------------
// 定时对比 latest / pending: 只要"有在途交易"且 latest 长时间不推进，就在缺失的
// nonce 上补一笔 0 值自转。它既能替换掉被 mempool 丢弃的那笔，也能把 nonce 空洞填平，
// 让账号不会因为一笔丢包就静默死亡。
function startGapFixer(inst) {
  if (DRY_RUN || SELFTEST) return;
  let lastLatest = -1;
  let sameSince = Date.now();
  let busy = false;
  setInterval(async () => {
    if (busy) return;
    busy = true;
    try {
      const latest = Number(await mgr.rpc(p => p.getTransactionCount(inst.address, 'latest')));
      const pending = Number(await mgr.rpc(p => p.getTransactionCount(inst.address, 'pending')));
      if (latest !== lastLatest) { lastLatest = latest; sameSince = Date.now(); return; }
      if (pending <= latest) return;                            // 没有在途交易，健康
      if (Date.now() - sameSince < CFG.GAP_STUCK_MS) return;    // 还没卡够久
      const stuck = Math.round((Date.now() - sameSince) / 1000);
      warn(inst.address, `nonce 疑似卡住: latest=${latest} pending=${pending} 已 ${stuck}s 未推进 -> 在 nonce=${latest} 补一笔 0 值自转填坑`);
      // 和 sendTx / 重播共用 nonce 锁，避免三方同时用同一 nonce 广播
      const release = await inst.mutex.acquire();
      try {
        const fee = await buildFeeParams(2);
        const tx = await withTimeout(inst.wallet.sendTransaction({
          to: inst.address, value: 0n, nonce: latest, gasLimit: 21000n, ...fee.tx
        }), 30000, 'gapfill');
        ok(inst.address, `填坑交易已广播: ${tx.hash} (nonce=${latest})`);
        inst.nonce = null;      // 让后续交易重新读 pending，避免继续用错号
      } finally {
        release();
      }
      sameSince = Date.now();
    } catch (e) {
      warnOnce(inst.address, `nonce 巡检失败: ${formatError(e)}`, 60000);
    } finally {
      busy = false;
    }
  }, CFG.GAP_CHECK_MS);
}

// ---------------- 统一交易发送 ----------------
async function sendTx(inst, opt) {
  const release = await inst.mutex.acquire();
  inst.inflight = (inst.inflight || 0) + 1;
  try {
    // 跨 attempt 保留的 nonce: 第一次读出来就锁定。
    // 不锁的话: attempt 1 广播超时(交易其实可能已进 mempool)后 inst.nonce 仍是 null，
    // attempt 2 会重新读 pending 拿到 N+1，结果是"并排发两笔"而不是
    // buildFeeParams(2) 想要的"同 nonce 加价替换"，白烧一笔 gas。
    let attemptNonce = null;
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        // ---- 手续费策略: 运行时探测链是否支持 EIP-1559，不硬编码交易类型 ----
        const fee = await buildFeeParams(attempt);
        const gasPrice = fee.gasPrice;

        // gasLimit 预估(同时充当 revert 预检)
        let gasLimit;
        try {
          const est = await withTimeout(
            opt.contract[opt.method].estimateGas(...opt.args, { from: inst.address }),
            12000, 'estimateGas'
          );
          // gasLimit 余量: BSC 正常交易只按 gasUsed 收费，gasLimit 高低不影响正常花费；
          // 但 revert 交易会烧掉整个 gasLimit。所以余量过大会放大 revert 损失。
          // 105% 足够覆盖状态轻微变化，又不会让 revert 多烧 25%。(可配 GAS_LIMIT_BUFFER 调整)
          const buf = Number.isFinite(CFG.GAS_LIMIT_BUFFER) && CFG.GAS_LIMIT_BUFFER >= 100 && CFG.GAS_LIMIT_BUFFER <= 200
            ? BigInt(Math.round(CFG.GAS_LIMIT_BUFFER)) : 105n;
          gasLimit = (est * buf) / 100n;
          // 兜底下限: 太低的 gasLimit 会让正常交易 out-of-gas 反而更亏
          if (gasLimit < est) gasLimit = est;
          if (gasLimit > BigInt(CFG.GAS_LIMIT_CAP)) gasLimit = BigInt(CFG.GAS_LIMIT_CAP);
        } catch (e) {
          // 业务 revert(人数已满/已入场/不在轮次) 很常见，直接放弃这一轮；
          // 但节点抖动导致的 estimateGas 失败不该白白浪费抢单窗口，重试一次
          const c = e.code || '';
          if (attempt === 1 && isNetworkErr(e)) {
            warnOnce(inst.address, `${opt.label} 预检遇到网络问题，换节点重试一次: ${formatError(e).slice(0, 120)}`, 30000);
            await mgr.rotate();
            continue;
          }
          // 业务状态(precheck revert)不是故障: 已入场/已满/今日场次用完/已领取等，降级为提醒
          const rv = `${decodeRevert(e) || ''} ${rpcDetail(e)}`;
          if (/already joined|full|capacity|daily round limit|already claimed|not in round|not refunding|not winner|window|已经|已满/i.test(rv)) {
            warnOnce(inst.address, `${opt.label} 预检未通过(业务状态，正常): ${formatError(e).slice(0, 140)}`, 60000);
            return false;
          }
          errOnce(inst.address, `${opt.label} 预检失败(不会上链): ${formatError(e)}`, 15000);
          return false;
        }

        const nonce = attemptNonce !== null
          ? attemptNonce
          : (inst.nonce !== null
              ? inst.nonce
              : await mgr.rpc(p => p.getTransactionCount(inst.address, 'pending')));
        attemptNonce = nonce;   // 锁定，attempt 2 不再重读 pending

        if (DRY_RUN) {
          info(inst.address, `[DRY-RUN] 将发送 ${opt.label}: to=${opt.contract.target} fn=${opt.method}(${opt.args.map(String).join(',')}) nonce=${nonce} gas=${gasLimit} gasPrice=${ethers.formatUnits(gasPrice, 'gwei')}gwei`);
          return true;
        }

        const tx = await withTimeout(
          opt.contract[opt.method](...opt.args, Object.assign({ gasLimit, nonce }, fee.tx)),
          30000, 'send'
        );
        info(inst.address, `${opt.label} 交易已广播: ${tx.hash} (nonce=${nonce}, gas=${gasLimit}, ${fee.desc}, type=${fee.type})`);
        // 广播成功就立刻推进本地 nonce，保证同一账号后续交易不会撞号
        inst.nonce = nonce + 1;

        if (opt.noWait) {
          // 不等上链: 拿到 hash 就交还控制权(领取退款专用)。
          // 若等 90 秒 receipt，抢单雷达会在这期间完全瞎掉。
          // nonce 锁只在"广播"这一瞬间持有，确认交给后台，不会卡住抢单。
          inst.stats.sent++;
          inst.unconfirmed = (inst.unconfirmed || 0) + 1;   // 在途计数，confirm 终态归零(见 isBusyForRestart)
          confirmTxInBackground(inst, tx, opt, nonce);
          return true;
        }

        let receipt;
        try {
          receipt = await withTimeout(tx.wait(1, CFG.TX_WAIT_MS), CFG.TX_WAIT_MS + 10000, 'wait');
        } catch (e) {
          // 这里和 confirmTxInBackground 的 wait 超时策略不同: 那边是"同 nonce 加价重播"，
          // 这边直接放弃、下一轮重读 pending。原因是 sendTx 全程持有 inst.mutex，
          // 而 rebroadcastSameNonce 也要拿同一把锁(不可重入)，在这里调用会死锁。
          // 当前行为能闭环(gapFixer 兜底)，代价是最多多烧一笔 gas。
          warn(inst.address, `${opt.label} 等待确认超时: ${tx.hash} -> 需手动确认，暂时锁定 nonce`);
          inst.nonce = null;
          return false;
        }
        if (receipt && receipt.status === 1) {
          inst.stats.sent++;
          ok(inst.address, `${opt.label} 成功! hash=${tx.hash} gasUsed=${receipt.gasUsed} block=${receipt.blockNumber}`);
          return true;
        }
        inst.nonce = null;
        inst.stats.failed++;
        err(inst.address, `${opt.label} 链上失败(status=0): ${tx.hash} gasUsed=${receipt ? receipt.gasUsed : '?'} -> 可能触发 revert，请到区块浏览器查看`);
        return false;
      } catch (e) {
        const c = e.code || '';
        if (c === 'NONCE_EXPIRED' || /nonce/i.test(e.shortMessage || e.message || '')) {
          warn(inst.address, `${opt.label} nonce 冲突，刷新后重试: ${formatError(e)}`);
          attemptNonce = null;   // 唯一应该重读 nonce 的场景
          inst.nonce = null;
          await sleep(500);
          continue;
        }
        if (c === 'REPLACEMENT_UNDERPRICED') {
          // attemptNonce 保留: 正是要用同一 nonce 加价替换
          warn(inst.address, `${opt.label} gas 过低(replacement underpriced)，加价重试`);
          await sleep(500);
          continue;
        }
        if (c === 'INSUFFICIENT_FUNDS') {
          err(inst.address, `${opt.label} BNB 不足以支付 gas: ${formatError(e)}`);
          inst.nonce = null;
          return false;
        }
        if (c === 'CALL_EXCEPTION') {
          err(inst.address, `${opt.label} 合约调用失败(revert): ${formatError(e)}`);
          inst.nonce = null;
          return false;
        }
        if (['NETWORK_ERROR', 'SERVER_ERROR', 'TIMEOUT'].includes(c)) {
          // attemptNonce 保留: 第一次很可能已经广播进 mempool 了，
          // attempt 2 应该用同一 nonce 加价替换，而不是再发一笔 N+1
          warn(inst.address, `${opt.label} 网络异常(${c})，切换节点重试(${attempt}/2): ${formatError(e)}`);
          await mgr.rotate();
          await sleep(800);
          continue;
        }
        // ethers 对节点返回的非标准错误统一包成 UNKNOWN_ERROR("could not coalesce error")，
        // 里面可能藏着 "already known"(重复广播) / 429 / ENOTFOUND / revert，必须拆开分别处理。
        const detail = rpcDetail(e);
        if (c === 'UNKNOWN_ERROR' || /could not coalesce/i.test(e.message || '')) {
          if (/already known|known transaction|already imported|already exists|nonce too low/i.test(detail)) {
            ok(inst.address, `${opt.label} 已在内存池/链上(重复广播)，按成功处理`);
            inst.stats.sent++;
            return true;
          }
          if (/insufficient funds|insufficient balance/i.test(detail)) {
            err(inst.address, `${opt.label} BNB 不足以支付 gas: ${detail.slice(0, 160)}`);
            inst.nonce = null;
            return false;
          }
          if (/execution reverted/i.test(detail)) {
            err(inst.address, `${opt.label} 合约调用失败(revert): ${detail.slice(0, 160)}`);
            inst.nonce = null;
            return false;
          }
          warn(inst.address, `${opt.label} 节点返回异常，切换节点重试(${attempt}/2): ${detail.slice(0, 160)}`);
          await mgr.rotate();
          await sleep(800);
          continue;
        }
        err(inst.address, `${opt.label} 未分类错误: ${formatError(e)}`);
        inst.nonce = null;
        return false;
      }
    }
    return false;
  } finally {
    inst.inflight = Math.max(0, (inst.inflight || 1) - 1);
    release();
  }
}

// ---------------- 共享只读合约 ----------------
// 所有账号共用同一个 provider 合约读轮次状态，避免 N 个账号重复发同样的查询
let readQueue = null;
function bindRead(p) { try { readQueue = new ethers.Contract(CFG.QUEUE_ADDR, QUEUE_ABI, p); } catch (e) { } }
mgr.onRotate(bindRead);

// ---------------- 出块共享状态缓存 ----------------
// 同一个区块内，所有房间/所有账号共用一份查询结果 -> 请求量从 O(账号数×房间×3) 降到 O(房间×3)
const sharedCache = { height: -1, at: 0, rooms: null };
// 票价/容量/开关这类配置几乎不变，缓存 60s；否则每个块都要为每个房间多打一次 RPC
const roomCfgCache = new Map();
async function getRoomCfg(room) {
  const c = roomCfgCache.get(room);
  if (c && Date.now() - c.at < 60000) return c.cfg;
  const cfg = await mgr.rpc(p => readQueue.roomConfigs(room)).catch(() => null);
  if (cfg) roomCfgCache.set(room, { at: Date.now(), cfg });
  return cfg;
}
async function getSharedState(height) {
  if (sharedCache.rooms && sharedCache.height === height && Date.now() - sharedCache.at < 3000) return sharedCache.rooms;
  if (!readQueue) bindRead(mgr.provider);
  // 房间之间并行查(串行 3 房间 = 6 个 RTT，BSC 0.75s 出块根本来不及)
  const pairs = await Promise.all(CFG.ROOMS.map(async room => {
    try {
      const rId = Number(await mgr.rpc(p => readQueue.currentRound(room)));
      // currentRound=0 说明该房间还没开过任何一轮，查 roundInfo(room,0) 必然 revert，
      // 这是正常状态，不要当成错误刷告警
      if (rId === 0) return null;
      const [info2, cfg] = await Promise.all([
        mgr.rpc(p => readQueue.roundInfo(room, rId)).catch(() => null),
        getRoomCfg(room)
      ]);
      if (!info2) {
        warnOnce('SYS', `房间${room} roundInfo 返回空，本轮跳过该房间`, 30000);
        return null;
      }
      return [room, {
        rId,
        count: Number(info2.count),
        state: Number(info2.state),
        startTime: Number(info2.startTime),
        enabled: cfg ? cfg.enabled !== false : true,
        ticketPrice: cfg ? cfg.ticketPrice : null
      }];
    } catch (e) {
      warnOnce('SYS', `读取房间${room} 状态失败: ${formatError(e).slice(0, 140)}`, 30000);
      return null;
    }
  }));
  const rooms = {};
  for (const p of pairs) if (p) rooms[p[0]] = p[1];
  // 一个房间都没读出来就别写缓存，否则接下来 3 秒会一直返回"空状态"
  if (Object.keys(rooms).length) {
    sharedCache.height = height; sharedCache.at = Date.now(); sharedCache.rooms = rooms;
  }
  return rooms;
}

// ---------------- 启动排水: 解决重启后 nonce 脏数据 ----------------
// 崩溃/重启后内存中维护的 nonce 丢失，若上一笔交易还在 mempool，
// RPC 的 pending nonce 可能尚未更新 -> 直接发会 nonce too low 或覆盖前一笔。
// 这里在启动(或重启)后先等 pending == latest，确认没有在途交易再开始。
async function drainPending(inst) {
  const t0 = Date.now();
  try {
    let latest = Number(await mgr.rpc(p => p.getTransactionCount(inst.address, 'latest')));
    let pending = Number(await mgr.rpc(p => p.getTransactionCount(inst.address, 'pending')));
    if (pending <= latest) { inst.nonce = pending; return; }
    warn(inst.address, `检测到 ${pending - latest} 笔在途交易，等待其确认后再开始(最多 ${Math.round(CFG.STARTUP_DRAIN_MS / 1000)}s)...`);
    while (Date.now() - t0 < CFG.STARTUP_DRAIN_MS) {
      await sleep(2000);
      latest = Number(await mgr.rpc(p => p.getTransactionCount(inst.address, 'latest')));
      pending = Number(await mgr.rpc(p => p.getTransactionCount(inst.address, 'pending')));
      if (pending <= latest) {
        inst.nonce = pending;
        ok(inst.address, `在途交易已清空，起始 nonce=${pending}`);
        return;
      }
    }
    warn(inst.address, `排水超时，仍有 ${pending - latest} 笔在途；改用 pending nonce=${pending} 并继续(失败会自动重试)`);
    inst.nonce = pending;
  } catch (e) {
    warn(inst.address, `排水检查失败，按运行时获取 nonce 处理: ${formatError(e).slice(0, 140)}`);
    inst.nonce = null;
  }
}

// ---------------- 抢单 ----------------
async function snipeWithState(inst, rooms) {
  if (!inst || inst.busy) return;
  inst.busy = true;
  try {
    for (const room of CFG.ROOMS) {
      const st = rooms[room];
      if (!st) continue;
      const count = st.count;
      if (st.state !== 0) continue;                    // 0=进行中
      if (count < inst.min || count >= inst.max) continue;

      const now = Math.floor(Date.now() / 1000);
      if (now < st.startTime + inst.delayMs / 1000) continue;

      const key = `${room}:${st.rId}`;
      if (inst.acted.has(key)) continue;
      if (!st.enabled) { warnOnce(inst.address, `${roomLabel(room, st.ticketPrice)} 已停用，跳过`, 300000); continue; }
      // 注意不能用 !st.ticketPrice 判断: 0n 在 JS 里是 falsy，票价真为 0 时会被误判成"读不到票价"
      if (st.ticketPrice === null || st.ticketPrice === undefined) {
        errOnce(inst.address, `[房间${room}] 读不到票价(roomConfigs 返回空)，跳过本轮。排查: 该房间是否已在链上配置`, 300000);
        continue;
      }
      const tag = roomLabel(room, st.ticketPrice);

      if (!(await ensureFunds(inst, st.ticketPrice, room))) { continue; }

      inst.acted.add(key);
      const okTx = await sendTx(inst, {
        label: `[${tag}] 入场(当前 ${count} 人, 轮次 ${st.rId})`,
        contract: inst.queue,
        method: 'enterQueue',
        args: [room, inst.referrer]
      });
      if (!okTx) inst.acted.delete(key); // 失败允许重试
    }
  } catch (e) {
    err(inst.address, '抢单流程异常: ' + formatError(e));
    err(inst.address, '抢单流程排查: 若持续报错，先用 --selftest 检查合约地址/ABI/余额/授权');
  } finally {
    inst.busy = false;
    if (inst.acted.size > 300) inst.acted = new Set([...inst.acted].slice(-100));
  }
}

// ---------------- 领取返利 ----------------
// roundInfo 全局缓存: 已结算轮次的信息永远不变，同一个 (房间,轮次) 只查一次。
// 多账号共享这份缓存，请求量从 O(账号 × 房间 × 轮次) 降到 O(房间 × 轮次)。
const roundInfoCache = new Map();
async function getRoundInfo(inst, room, r) {
  const key = `${room}:${r}`;
  const hit = roundInfoCache.get(key);
  // 已结算(state!=0) -> 永久复用；进行中 -> 10 秒内复用
  if (hit && (hit.settled || Date.now() - hit.at < 10000)) return hit;
  const info2 = await mgr.rpc(p => inst.queue.roundInfo(room, r));
  const state = Number(info2.state);
  const rec = {
    at: Date.now(),
    count: Number(info2.count),
    state,
    winners: (info2.winners || []).map(w => String(w).toLowerCase()),
    settled: state !== 0
  };
  roundInfoCache.set(key, rec);
  if (roundInfoCache.size > 3000) {
    [...roundInfoCache.keys()].slice(0, 1000).forEach(k => roundInfoCache.delete(k));
  }
  return rec;
}

// 领取失败退避: 同一 (房间,轮次) 反复 revert 时，避免每 20 秒重发一笔交易白烧 gas。
// 连续失败次数越多，冷却越久(指数退避，封顶 30 分钟)。成功/业务终态会清除。
const claimFail = new Map();   // key = address:room:round -> {n, until}
function claimCooling(inst, ck) {
  const k = inst.address + ':' + ck;
  const v = claimFail.get(k);
  return v && v.until > Date.now();
}
function claimMarkFail(inst, ck) {
  const k = inst.address + ':' + ck;
  const v = claimFail.get(k) || { n: 0, until: 0 };
  v.n++;
  // 1次=30s, 2次=2min, 3次=8min... 封顶30min
  v.until = Date.now() + Math.min(30 * 60000, 30000 * Math.pow(4, v.n - 1));
  claimFail.set(k, v);
  if (claimFail.size > 3000) { const now = Date.now(); for (const [kk, vv] of claimFail) if (vv.until < now) claimFail.delete(kk); }
}
function claimClearFail(inst, ck) { claimFail.delete(inst.address + ':' + ck); }

async function claimLoop(inst) {
  while (true) {
    try {
      for (const room of CFG.ROOMS) {
        let rId = NaN;
        try {
          rId = Number(await mgr.rpc(p => inst.queue.currentRound(room)));
        } catch (e) {
          // 读当前轮次失败(多半是 DNS/网络抖动)不能让整个领取流程中断，
          // 否则一个房间失败会把其他房间该领的钱也一起拖没。
          if (isNetworkErr(e)) warnOnce(inst.address, `[房间${room}] 读取当前轮次失败(网络)，本轮跳过稍后重试: ${formatError(e).slice(0, 120)}`, 60000);
          else err(inst.address, `[房间${room}] 读取当前轮次失败: ${formatError(e)}`);
          continue;
        }
        if (!Number.isFinite(rId)) continue;
        const start = Math.max(0, rId - CFG.CLAIM_LOOKBACK);
        // 重要: 不再用 state === 2 过滤。进行中(state 0)的轮次同样可能允许退款，
        // 只按 "本轮有人(count>0) 且 我不是中奖者" 粗筛，能不能领一律交给
        // staticCall 预检决定 —— 这样才不会漏掉任何一笔退款。
        // 注意用 <= : 当前轮次(rId)也要扫。
        let netErrs = 0;
        for (let r = start; r <= rId; r++) {
          const ck = `${room}:${r}`;
          // 已处理过的轮次直接跳过，连 roundInfo 都不查 —— 这是省掉绝大部分请求的关键
          if (inst.claimed.has(ck)) continue;
          // 连续 revert 的轮次在冷却期内跳过，避免每 20 秒重发交易白烧 gas
          if (claimCooling(inst, ck)) continue;
          let rec;
          try { rec = await getRoundInfo(inst, room, r); }
          catch (e) {
            // 网络断了就别硬扫剩下的几十轮了，换节点、本轮房间直接跳过
            if (isNetworkErr(e)) {
              netErrs++;
              if (netErrs >= 2) { warnOnce(inst.address, `[房间${room}] 连续读取轮次失败(网络)，本轮跳过`, 60000); break; }
            }
            continue;
          }
          netErrs = 0;
          if (rec.count <= 0) continue;         // 空轮次，无人可退
          const isWinner = rec.winners.includes(inst.address.toLowerCase());

          // 中奖者: v8 的奖励是"矿机额度"(claimWin)，不再是退款。
          // 注意: 中奖与否由 Chainlink VRF 随机决定，客户端无法干预，只能决定领不领。
          if (isWinner) {
            if (!CFG.CLAIM_WIN) {
              if (rec.state !== 0) inst.claimed.add(ck);
              continue;
            }
            let canWin = true;
            try {
              await mgr.rpc(p => inst.queue.claimWin.staticCall(room, r, 0, { from: inst.address }));
            } catch (e) {
              canWin = false;
              const hardFail = e.code === 'CALL_EXCEPTION' || decodeRevert(e) !== null;
              // 仅当 revert 明确是终态(already claimed / 不在本轮 / 非中奖者)才永久跳过；
              // 窗口未开、资金不足、未知原因一律保留，等条件恢复后重试(否则钱到位也永远不领)。
              if (hardFail && rec.state !== 0 && isTerminalClaimSkipReason(e)) inst.claimed.add(ck);
              else if (hardFail) warnOnce(inst.address, `[房间${room}] 轮次${r} 中奖暂不可领(窗口/资金/未知)，保留稍后重试: ${formatError(e).slice(0, 120)}`, 120000);
              else warnOnce(inst.address, `[房间${room}] 轮次${r} 中奖预检遇到网络问题，稍后重试: ${formatError(e).slice(0, 120)}`, 60000);
            }
            if (!canWin) continue;
            const okWin = await sendTx(inst, {
              label: `[房间${room}] 领取中奖额度 轮次${r}`,
              contract: inst.queue,
              method: 'claimWin',
              args: [room, r, 0],
              noWait: true,
              onFailed: () => { inst.claimed.delete(ck); claimMarkFail(inst, ck); }
            });
            if (okWin) { inst.claimed.add(ck); claimClearFail(inst, ck); }
            continue;
          }

          // 预检: 不报错就说明可领。报错(Queue: not in round / claimed 等)静默跳过
          let claimable = true;
          let method = 'claimRefundAndAirdrop';
          try {
            await mgr.rpc(p => inst.queue.claimRefundAndAirdrop.staticCall(room, r, { from: inst.address }));
          } catch (e) {
            const hardFail = e.code === 'CALL_EXCEPTION' || decodeRevert(e) !== null;
            if (!hardFail) {
              claimable = false;
              warnOnce(inst.address, `[房间${room}] 轮次${r} 预检遇到网络问题，稍后重试(不标记已领): ${formatError(e).slice(0, 120)}`, 60000);
            } else {
              // "退款+空投"不可用时，可能是超时全员退款轮次(只能退本金) -> 再试 claimRefundOnly
              try {
                await mgr.rpc(p => inst.queue.claimRefundOnly.staticCall(room, r, { from: inst.address }));
                method = 'claimRefundOnly';
              } catch (e2) {
                claimable = false;
                const hard2 = e2.code === 'CALL_EXCEPTION' || decodeRevert(e2) !== null;
                // 只有终态(already claimed / 不在本轮 / 无可退)才永久标记；
                // 资金不足、窗口未开、未知 revert 全部保留，钱到位后重试 —— 修复漏领主因。
                if (hard2 && rec.state !== 0 && isTerminalClaimSkipReason(e2)) inst.claimed.add(ck);
                else if (hard2) warnOnce(inst.address, `[房间${room}] 轮次${r} 退款暂不可领(窗口/资金/未知)，保留稍后重试: ${formatError(e2).slice(0, 120)}`, 120000);
                else warnOnce(inst.address, `[房间${room}] 轮次${r} 退款预检遇到网络问题，稍后重试(不标记已领): ${formatError(e2).slice(0, 120)}`, 60000);
              }
            }
          }
          if (!claimable) continue;

          // 领取不等上链: 广播成功即返回，确认在后台进行。
          // 这样领取不会占用 nonce 锁长达数十秒，抢单雷达始终在线。
          const okTx = await sendTx(inst, {
            label: method === 'claimRefundOnly'
              ? `[房间${room}] 领取退款 轮次${r}(state=${rec.state})`
              : `[房间${room}] 领取返利 轮次${r}(state=${rec.state})`,
            contract: inst.queue,
            method,
            args: [room, r],
            noWait: true,
            // 上链失败撤标记+退避: 撤标记保证不漏领，退避避免连续 revert 每 20 秒白烧 gas
            onFailed: () => { inst.claimed.delete(ck); claimMarkFail(inst, ck); }
          });
          if (okTx) { inst.claimed.add(ck); claimClearFail(inst, ck); }
          else errOnce(inst.address, `[房间${room}] 轮次${r} 预检通过但广播未成功，已保留标记会在下一轮重试(不会漏领)`, 60000);
        }
      }
    } catch (e) {
      if (isNetworkErr(e)) {
        // DNS 掉线/节点全挂: 属于网络层问题，换节点后继续，不要用"合约变了"误导排查
        warnOnce(inst.address, '领取流程遇到网络问题，已换节点，稍后自动重试: ' + formatError(e), 60000);
        await mgr.rotate();
      } else {
        err(inst.address, '领取流程异常: ' + formatError(e));
        errOnce(inst.address, '领取流程排查: currentRound/roundInfo 是否为预期格式; 合约地址或房间号是否变更', 60000);
      }
    }
    if (inst.claimed.size > 500) inst.claimed = new Set([...inst.claimed].slice(-200));
    // 纯定时扫描: 默认 20 秒一轮，随机抖动避免多账号同时打节点
    await sleep(CFG.CLAIM_INTERVAL_MS + Math.random() * 5000);
  }
}

// ---------------- 组矿机(老额度固定100U / 新版按额度) ----------------
// 背景: 新版矿机额度只能靠中奖(VRF 随机)累积，脚本无法操控。
//   old : 老系统 formLP，老额度 >= 阈值后固定支付 MINER_USD(默认 100U)，与额度多少无关
//   new : 新队列 formLP，USDT 腿按当前额度实额支付(额度多少付多少) + 等值 FTS
//   both: 先新版、再老版(老矿机运行中会挡住新机组装)
function minerTargets() {
  const list = [];
  if (CFG.MINER_MODE === 'new' || CFG.MINER_MODE === 'both') {
    list.push({ key: 'new', label: '新版(按额度实付)', addr: CFG.QUEUE_ADDR, fixed: false });
  }
  if (CFG.MINER_MODE === 'old' || CFG.MINER_MODE === 'both') {
    list.push({ key: 'old', label: `老系统(固定${CFG.MINER_USD}U)`, addr: CFG.MINER_QUEUE_ADDR, fixed: true });
  }
  return list;
}

async function minerLoop(inst) {
  if (!CFG.MINER_ENABLED) return;
  const room = CFG.MINER_ROOM;
  const fixedUsd = ethers.parseUnits(String(CFG.MINER_USD), 18);
  const minBnb = ethers.parseEther(String(CFG.MIN_BNB_GAS));
  const targets = minerTargets().map(t => ({
    ...t,
    done: false,
    lastLogAt: 0,
    contract: t.key === 'new' ? inst.queue : inst.miner
  }));
  if (!targets.length) return;

  while (true) {
    for (const t of targets) {
      if (t.done) continue;
      try {
        const [rc, quota] = await Promise.all([
          mgr.rpc(p => t.contract.roomConfigs(room)),
          mgr.rpc(p => t.contract.pendingQuotaUsd(inst.address))
        ]);
        const threshold = BigInt(rc.quotaThreshold);
        if (BigInt(quota) < threshold) {
          if (Date.now() - t.lastLogAt > 1800000) {
            t.lastLogAt = Date.now();
            info(inst.address, `[矿机/${t.label}] 额度 ${ethers.formatUnits(quota, 18)}U / 需要 ${ethers.formatUnits(threshold, 18)}U，还差 ${ethers.formatUnits(threshold - quota, 18)}U，暂不组机`);
          }
          continue;
        }
        // 老系统固定 MINER_USD；新版按当前额度实额支付
        const pay = t.fixed ? fixedUsd : BigInt(quota);
        let [usdtBal, allowance, bnb] = await Promise.all([
          mgr.rpc(p => inst.usdt.balanceOf(inst.address)),
          mgr.rpc(p => inst.usdt.allowance(inst.address, t.addr)),
          mgr.rpc(p => inst.provider.getBalance(inst.address))
        ]);
        // 仅资金不足时才触发灵活决策(默认关闭=no-op): 凑 USDT / 匀 BNB，补后重读
        if ((usdtBal < pay || bnb < minBnb) && CFG.FLEX_ENABLED) {
          await tryFlexTopUp(inst, usdtBal < pay ? pay : 0n, bnb < minBnb ? minBnb : 0n);
          [usdtBal, allowance, bnb] = await Promise.all([
            mgr.rpc(p => inst.usdt.balanceOf(inst.address)),
            mgr.rpc(p => inst.usdt.allowance(inst.address, t.addr)),
            mgr.rpc(p => inst.provider.getBalance(inst.address))
          ]);
        }
        if (usdtBal < pay) {
          warnOnce(inst.address, `[矿机/${t.label}] USDT 不足: 需要 ${ethers.formatUnits(pay, 18)}U，当前 ${ethers.formatUnits(usdtBal, 18)}U，跳过`, 600000);
          continue;
        }
        if (bnb < minBnb) {
          warnOnce(inst.address, `[矿机/${t.label}] BNB 不足以付 gas(${ethers.formatEther(bnb)} < ${CFG.MIN_BNB_GAS})，跳过`, 600000);
          continue;
        }
        if (allowance < pay) {
          info(inst.address, `[矿机/${t.label}] 授权不足(${ethers.formatUnits(allowance, 18)}U)，先授权 ${ethers.formatUnits(pay, 18)} USDT`);
          const okApprove = await sendTx(inst, {
            label: `[矿机/${t.label}] USDT 授权 ${ethers.formatUnits(pay, 18)}`,
            contract: inst.usdt,
            method: 'approve',
            args: [t.addr, pay]
          });
          if (!okApprove) {
            err(inst.address, `[矿机/${t.label}] 授权失败，稍后重试`);
            continue;
          }
        }
        info(inst.address, `[矿机/${t.label}] 额度 ${ethers.formatUnits(quota, 18)}U 已达标，发起 formLP(房间${room}, 另付 ${ethers.formatUnits(pay, 18)}U + 等值 FTS)`);
        const okTx = await sendTx(inst, {
          label: `[矿机/${t.label}] formLP(房间${room}, ${ethers.formatUnits(pay, 18)}U)`,
          contract: t.contract,
          method: 'formLP',
          args: [room],
          noWait: true
        });
        if (okTx) {
          t.done = true;
          ok(inst.address, `[矿机/${t.label}] 组机交易已广播，矿机开始 100 天释放；需要再组请重启脚本`);
        }
      } catch (e) {
        errOnce(inst.address, `[矿机/${t.label}] 流程异常: ` + formatError(e), 120000);
      }
    }
    await sleep(CFG.MINER_CHECK_MS + Math.random() * 8000);
  }
}

async function readMiningPending(inst, v) {
  try {
    return BigInt(await mgr.rpc(p => v.c[v.fn](inst.address)));
  } catch (e) {
    // 没矿机时老版合约会直接 revert(无 revert data)，属正常状态，按 0 处理
    if (e.code === 'CALL_EXCEPTION' || decodeRevert(e) !== null) return 0n;
    throw e;
  }
}

// ---------------- 矿机产出领取 ----------------
// 原则: 只要 pending > 0 就立刻领，绝不等"释放完/攒到最后一块"再领。
// 规则随时可能调整、私钥可能丢、gas 可能涨——早领早落袋。
async function miningClaimLoop(inst) {
  if (!CFG.MINING_CLAIM) return;
  const vaults = [
    { key: 'v8', label: '新版矿机', c: inst.mining, fn: 'pendingOf' },
    { key: 'legacy', label: '老版矿机', c: inst.legacyMining, fn: 'pendingReward' }
  ];
  const lastAt = { v8: 0, legacy: 0 };
  const minBnb = ethers.parseEther(String(CFG.MIN_BNB_GAS));
  while (true) {
    for (const v of vaults) {
      try {
        const pending = await readMiningPending(inst, v);
        if (BigInt(pending) <= 0n) continue;
        const now = Date.now();
        // 同一笔产出 90 秒内不重复提交(交易未上链时 pendingOf 仍是旧值)
        if (now - lastAt[v.key] < 90000) continue;
        const bnb = await mgr.rpc(p => inst.provider.getBalance(inst.address));
        if (bnb < minBnb) {
          warnOnce(inst.address, `[${v.label}] 可领 ${ethers.formatUnits(pending, 18)} FTS，但 BNB 不足付 gas，跳过`, 600000);
          continue;
        }
        info(inst.address, `[${v.label}] 检测到可领取 ${ethers.formatUnits(pending, 18)} FTS，立即领取`);
        const okTx = await sendTx(inst, {
          label: `[${v.label}] 领取矿机产出 ${ethers.formatUnits(pending, 18)} FTS`,
          contract: v.c,
          method: 'claim',
          args: [],
          noWait: true
        });
        if (okTx) lastAt[v.key] = now;
      } catch (e) {
        errOnce(inst.address, `[${v.label}] 领取产出失败: ` + formatError(e), 120000);
      }
    }
    await sleep(CFG.MINING_CLAIM_MS + Math.random() * 6000);
  }
}

// ---------------- 运行期自动更新(空闲窗口) ----------------
// v1.7.1: 启动即检测一次，之后每 UPDATE_CHECK_MS 查一次；发现新版先记下来，
// 等到"没有轮次接近满员 / 没有交易在途 / 没有结算中"的空闲窗口，
// 才替换脚本并 exit 90，由外壳脚本原地重启。
// 超过 UPDATE_MAX_DEFER_MS 仍等不到空闲窗口时只告警，绝不强制打断抢单。
let updatePendingTag = null;
let updatePendingSince = 0;
let updateBusy = false;

function runUpdateCli(args) {
  return new Promise(resolve => {
    execFile(process.execPath, [path.join(__dirname, 'update.js'), ...args], {
      cwd: __dirname,
      timeout: 45000,
      windowsHide: true
    }, (err, stdout) => resolve(String(stdout || '').trim()));
  });
}

function isBusyForRestart() {
  // unconfirmed>0: 有 noWait 领取已广播但后台确认未完成，此时重启会中断确认(虽可重扫自愈，但多烧 gas)，保守不重启
  if (instances.some(i => (i.inflight || 0) > 0 || i.busy || (i.unconfirmed || 0) > 0)) return true;
  const rooms = sharedCache.rooms;
  if (!rooms) return true;                       // 状态还没读到，保守不重启
  // v1.7.1: 抢位窗口内也视为忙(人数已进入可入场区间)，结算/开轮中同样不重启
  const need = Math.max(1, CFG.SNIPE_MIN_COUNT - CFG.UPDATE_IDLE_MARGIN);
  for (const k of Object.keys(rooms)) {
    const st = rooms[k];
    if (!st.enabled) continue;
    if (st.state !== 0) return true;                                // 结算/开轮中
    if (st.count >= need) return true;                              // 快满员或已在抢位区间
  }
  return false;
}

async function tryApplyUpdate(asset, force) {
  // v1.7.1: 无论是否超时都先问 isBusyForRestart —— 旧版 force=true 会跳过忙碌判断，
  // 在"正在抢单/有交易在途"时强制替换并 exit 90，与"不会打断抢单"的承诺冲突。
  if (isBusyForRestart()) {
    warnOnce('SYS', force
      ? `新版 v${updatePendingTag} 已推迟超过 ${Math.round(CFG.UPDATE_MAX_DEFER_MS / 3600000)} 小时仍等不到空闲窗口；不会强制打断抢单，可择机手动执行 --update`
      : `有新版本 v${updatePendingTag}，当前正在抢单/有交易在途，暂缓更新`, 300000);
    return false;
  }
  info('SYS', `进入空闲窗口，开始更新到 v${updatePendingTag} ...`);
  const out = await runUpdateCli(['--apply', '--current=' + APP_VERSION, '--asset=' + asset]);
  if (/UPDATED\s+(\S+)/.test(out)) {
    ok('SYS', `已更新到 v${RegExp.$1}，准备原地重启...`);
    await sleep(500);
    process.exit(90);
  }
  err('SYS', '自动更新失败: ' + (out || '无输出'));
  return false;
}

async function updateLoop() {
  const asset = process.platform === 'win32' ? 'autofts.ps1' : 'autofts.sh';
  // 启动即检测一次(用户要求): 立刻知道有没有新版本，不用等一个周期。
  // 注意只是"检测+标记"，真正应用仍等空闲窗口(tryApplyUpdate 忙则返回)，不会打断抢单。
  info('SYS', '启动自动检测更新...');
  while (true) {
    try {
      if (updatePendingTag) {
        const force = updatePendingSince && Date.now() - updatePendingSince > CFG.UPDATE_MAX_DEFER_MS;
        await tryApplyUpdate(asset, force);       // 忙就返回 false，按 UPDATE_RETRY_MS 再看
        await sleep(CFG.UPDATE_RETRY_MS);
        continue;
      }
      if (!updateBusy) {
        updateBusy = true;
        const out = await runUpdateCli(['--check', '--current=' + APP_VERSION, '--asset=' + asset]);
        updateBusy = false;
        if (/NEWER\s+(\S+)/.test(out)) {
          updatePendingTag = RegExp.$1;
          updatePendingSince = Date.now();
          info('SYS', `发现新版本 v${updatePendingTag}，将等空闲窗口自动更新(不打断抢单)`);
        } else if (/SKIP_RATE_LIMIT/.test(out)) {
          // 公开仓库未认证请求也会撞 403，提示"需要 token"是误导；这里明确是限流并已退避
          warnOnce('SYS', '自动更新检查遇到 GitHub API 限流，已自动退避；公开仓库无需 token', 3600000);
        } else if (/SKIP_AUTH/.test(out)) {
          warnOnce('SYS', '自动更新跳过: 该仓库需要 GitHub 只读 token（仅私有仓库需要）', 3600000);
        } else if (/SKIP_PRIVATE/.test(out)) {
          warnOnce('SYS', '自动更新跳过: 仓库不存在或无权访问', 3600000);
        }
      }
    } catch (e) {
      updateBusy = false;
      warnOnce('SYS', '自动更新检查异常: ' + formatError(e), 1800000);
    }
    await sleep(CFG.UPDATE_CHECK_MS + Math.random() * 60000);
  }
}

// ---------------- 自检 ----------------
let selftestWallets = [];
async function selftest() {
  console.log(C.b + '\n========== FTS 自检报告 ==========' + C.d);
  console.log(`引擎版本: ${VERSION} | node: ${process.version} | ethers: ${ethers.version}`);
  console.log(`WS 可用: ${ensureWebSocket()} | 队列合约: ${CFG.QUEUE_ADDR} | USDT: ${CFG.USDT_ADDR}`);

  console.log('\n--- 1. RPC 节点探测 ---');
  try { await mgr.pickBest(); } catch (e) { fatal('SYS', formatError(e)); exitFlush(1); return; }

  console.log('\n--- 2. 合约存在性 ---');
  for (const [name, addr] of [['QUEUE', CFG.QUEUE_ADDR], ['USDT', CFG.USDT_ADDR], ['MINER_QUEUE', CFG.MINER_QUEUE_ADDR]]) {
    const code = await mgr.rpc(p => p.getCode(addr));
    console.log(`  ${name} ${addr}: ${code && code !== '0x' ? '有合约代码 (长度 ' + code.length + ')' : '❌ 无合约代码，地址可能错误'}`);
  }

  console.log('\n--- 3. 合约方法探测 ---');
  const probe = async (label, fn) => {
    try { const v = await mgr.rpc(p => withTimeout(fn(), 10000, label)); console.log(`  ✅ ${label}: ${String(v).slice(0, 120)}`); return v; }
    catch (e) { console.log(`  ❌ ${label}: ${formatError(e)}`); return null; }
  };
  const qRead = new ethers.Contract(CFG.QUEUE_ADDR, QUEUE_ABI, mgr.provider);
  const uRead = new ethers.Contract(CFG.USDT_ADDR, USDT_ABI, mgr.provider);
  await probe('QUEUE.currentRound(0)', () => qRead.currentRound(0));
  await probe('QUEUE.roomCount()', () => qRead.roomCount());
  // 逐个房间体检(0=10U 1=50U 2=100U)，房间不存在/未启用要能一眼看出
  const roomOk = {};
  for (const room of CFG.ROOMS) {
    // 注意: probe 返回的是格式化后的字符串，这里另外取一次原始对象用于判断。
    // 读取失败会重试 3 次，避免一次网络抖动被误判成"房间不存在"
    await probe(`QUEUE.roomConfigs(${room})`, () => qRead.roomConfigs(room).then(c =>
      `ticketPrice=${ethers.formatUnits(c.ticketPrice, 18)} max=${c.maxCapacity} winners=${c.winnerCount} enabled=${c.enabled} daily=${c.dailyRoundLimit}/已开${c.todayRounds}`));
    let cfg = null, lastCfgErr = null;
    for (let a = 0; a < 3 && !cfg; a++) {
      try { cfg = await qRead.roomConfigs(room); } catch (e) { lastCfgErr = e; await sleep(600); }
    }
    if (cfg && cfg.ticketPrice !== undefined && cfg.ticketPrice !== null) {
      const enabled = cfg.enabled;
      const price = Number(ethers.formatUnits(cfg.ticketPrice, 18));
      roomOk[room] = enabled;
      const expect = { 0: 10, 1: 50, 2: 100 }[room];
      if (expect && price !== expect) console.log(`  ⚠️ 房间${room} 链上票价 ${price}U 与预设 ${expect}U 不符，以链上为准`);
      if (!enabled) console.log(`  ⚠️ 房间${room} 链上标记为停用(enabled=false)，脚本会自动跳过`);
      await probe(`QUEUE.currentRound(${room})`, () => qRead.currentRound(room));
      const rid = await qRead.currentRound(room).catch(() => null);
      // currentRound 为 0 表示这个房间还没开过任何一轮，此时查 roundInfo(room,0)
      // 会 revert(ARRAY_RANGE_ERROR)，那是正常的，不该报成 ❌
      if (rid !== null && BigInt(rid) > 0n) {
        await probe(`QUEUE.roundInfo(${room}, ${rid})`, () => qRead.roundInfo(room, rid).then(i =>
          `count=${i.count} state=${i.state} start=${i.startTime} deadline=${i.deadline} winners=${i.winners.length}`));
      } else if (rid !== null) {
        console.log(`  ○ 房间${room} 尚无任何轮次(currentRound=0)，跳过 roundInfo 查询`);
      }
      // 每日轮次上限: 用完后再入场必然 revert，提前说清楚，别让人以为是脚本坏了
      const dLimit = Number(cfg.dailyRoundLimit), dUsed = Number(cfg.todayRounds);
      if (dLimit > 0 && dUsed >= dLimit) {
        console.log(`  ⚠️ 房间${room} 今日轮次已用完 (${dUsed}/${dLimit})，现在入场会 revert "Queue: daily round limit"，需等次日重置`);
      }
    } else {
      roomOk[room] = false;
      console.log(`  ⚠️ 房间${room} 读取失败(已重试 3 次): ${lastCfgErr ? formatError(lastCfgErr) : '返回空'}`);
      console.log(`     含义: 该房间可能未在链上配置，或合约不支持 roomConfigs(${room})。脚本会自动跳过，其他房间不受影响`);
    }
  }
  // 队列合约没有 allowance，这是"兼容性探测"，失败才是预期结果，不该报 ❌
  try {
    await mgr.rpc(p => qRead.allowance(CFG.QUEUE_ADDR, CFG.QUEUE_ADDR));
    console.log('  ✅ QUEUE.allowance 可调用(意外: 该合约本不该有 allowance)');
  } catch (e) {
    console.log('  ○ QUEUE.allowance 不可调用(符合预期: 授权额度以 USDT 合约为准)');
  }
  await probe('USDT.decimals', () => uRead.decimals());
  await probe('USDT.symbol', () => uRead.symbol());

  console.log('\n--- 4. 账号检查 ---');
  // 复用 main 已经加载好的钱包列表，不再重复 loadWallets()(否则校验失败信息会打印两遍)
  const wallets = selftestWallets;
  if (!wallets.length) { fatal('CFG', 'wallets.json 中没有有效账号'); exitFlush(1); return; }
  // selftest 是"合约+主账号体检"，不是"全账号余额审计"。
  // 全部账号做本地校验(私钥/地址，零RPC)；只有第 1 个账号做链上余额/授权详细检查。
  // 这样 100 账号也能秒级完成，而不是几分钟(每个账号 3+ 次 RPC)。
  const roomCfgs = {};
  for (const room of CFG.ROOMS) {
    if (!roomOk[room]) continue;
    roomCfgs[room] = await qRead.roomConfigs(room).catch(() => null);
  }
  const minBnb = ethers.parseEther(String(CFG.MIN_BNB_GAS));
  console.log(`  （${wallets.length} 个账号：全部做本地校验，仅第 1 个做链上余额体检，避免几百次 RPC 拖慢自检）`);
  const results = await Promise.all(wallets.map(async (w, wi) => {
    const lines = [];
    let ready = true;
    lines.push(`\n  账号 ${w.ADDRESS}`);
    if (w.wallet.address.toLowerCase() !== w.ADDRESS.toLowerCase()) {
      lines.push('   ❌ 私钥与地址不匹配，跳过');
      return { lines, ready: false };
    }
    if (wi > 0) {
      lines.push('   ✅ 本地校验通过（私钥/地址匹配；余额体检见第 1 个账号，运行时逐账号处理）');
      return { lines, ready };
    }
    try {
      const [bnb, usdt, allow] = await Promise.all([
        mgr.rpc(p => p.getBalance(w.ADDRESS)),
        mgr.rpc(p => uRead.balanceOf(w.ADDRESS)),
        mgr.rpc(p => uRead.allowance(w.ADDRESS, CFG.QUEUE_ADDR))
      ]);
      lines.push(`   BNB=${ethers.formatEther(bnb)} | USDT=${ethers.formatUnits(usdt, 18)} | 已授权=${ethers.formatUnits(allow, 18)} (单轮授权模式)`);
      if (bnb < minBnb) {
        lines.push(`   ❌ BNB 不足(当前 ${ethers.formatEther(bnb)} < 阈值 ${CFG.MIN_BNB_GAS})，无法支付 gas，所有交易都会失败`);
        ready = false;
      } else if (bnb < minBnb * 3n) {
        lines.push(`   ⚠️ BNB 偏低(当前 ${ethers.formatEther(bnb)}，阈值 ${CFG.MIN_BNB_GAS})，建议多留一点，否则拥堵时可能不够 gas`);
      }
      for (const room of CFG.ROOMS) {
        const cfg = roomCfgs[room];
        if (!cfg) continue;
        const price = cfg.ticketPrice;
        const okBal = usdt >= price;
        lines.push(`   房间${room}(${ethers.formatUnits(price, 18)}U): USDT ${okBal ? '✅ 够' : '❌ 不够(差 ' + ethers.formatUnits(price - usdt, 18) + ')'}` +
          ` | 授权 ${allow >= price ? '✅ 够' : '⚠️ 需先授权 ' + ethers.formatUnits(price, 18)}`);
        if (!okBal) ready = false;
      }
      if (allow === 0n) lines.push('   ⚠️ 授权为 0，首次入场会自动发起"单轮票价"授权交易');
      if (CFG.MINING_CLAIM) {
        try {
          const mv = new ethers.Contract(CFG.MINING_VAULT_ADDR, MINING_V8_ABI, mgr.provider);
          const lm = new ethers.Contract(CFG.LEGACY_MINING_ADDR, MINING_LEGACY_ABI, mgr.provider);
          const [pv, pl] = await Promise.all([
            mv.pendingOf(w.ADDRESS),
            lm.pendingReward(w.ADDRESS).catch(e => {
              if (e.code === 'CALL_EXCEPTION' || decodeRevert(e) !== null) return 0n;
              throw e;
            })
          ]);
          lines.push(`   矿机产出: 新版可领 ${ethers.formatUnits(pv, 18)} FTS / 老版可领 ${ethers.formatUnits(pl, 18)} FTS` +
            (BigInt(pv) + BigInt(pl) > 0n ? '（>0 会立即领取）' : ''));
        } catch (e) { lines.push('   矿机产出读取失败: ' + formatError(e)); }
      }
      if (CFG.MINER_ENABLED) {
        for (const t of minerTargets()) {
          try {
            const c = new ethers.Contract(t.addr, QUEUE_ABI, mgr.provider);
            const [q, rc] = await Promise.all([c.pendingQuotaUsd(w.ADDRESS), c.roomConfigs(CFG.MINER_ROOM)]);
            const canForm = BigInt(q) >= BigInt(rc.quotaThreshold);
            const payDesc = t.fixed ? `固定 ${CFG.MINER_USD}U` : `按额度 ${ethers.formatUnits(q, 18)}U`;
            lines.push(`   矿机组装[${t.label}]: 额度 ${ethers.formatUnits(q, 18)}U / 阈值 ${ethers.formatUnits(rc.quotaThreshold, 18)}U -> ` +
              (canForm ? `✅ 可组机(${payDesc})` : '⏳ 额度不足，暂不可组机'));
          } catch (e) { lines.push(`   矿机组装[${t.label}] 读取失败: ` + formatError(e)); }
        }
      }
    } catch (e) {
      lines.push('   ❌ 账号检查失败: ' + formatError(e));
      ready = false;
    }
    return { lines, ready };
  }));
  let allReady = true;
  for (const r of results) { r.lines.forEach(l => console.log(l)); if (!r.ready) allReady = false; }

  console.log('\n--- 5. 交易预演 (不上链，一分钱不花) ---');
  // 预演只验证"合约能否调通、账号是否满足业务规则"，同一合约对任何账号结果一致，
  // 抽查前 3 个即可；100 账号全跑既慢又白费节点请求。
  const PREVIEW_N = Math.min(3, wallets.length);
  console.log(`  （合约预演是全局性的，抽查前 ${PREVIEW_N} 个账号即可，避免 100 账号逐个预演太慢）`);
  for (const w of wallets.slice(0, PREVIEW_N)) {
    for (const room of CFG.ROOMS) {
      let cfg = null;
      try { cfg = await mgr.rpc(p => qRead.roomConfigs(room)); } catch (e) { }
      if (!cfg || !cfg.ticketPrice) {
        console.log(`  ○ ${short(w.ADDRESS)} 房间${room} 未启用/未配置，跳过预演(运行时也会自动跳过)`);
        continue;
      }
      if (cfg.enabled === false) {
        console.log(`  ○ ${short(w.ADDRESS)} 房间${room}(${ethers.formatUnits(cfg.ticketPrice, 18)}U) 链上已停用，跳过预演`);
        continue;
      }
      const tag = roomLabel(room, cfg.ticketPrice);
      try {
        const data = qRead.interface.encodeFunctionData('enterQueue', [room, w.REFERRER]);
        await mgr.rpc(p => withTimeout(p.call({ to: CFG.QUEUE_ADDR, from: w.ADDRESS, data }), 10000, 'enterQueue.call'));
        console.log(`  ✅ ${short(w.ADDRESS)} [${tag}] enterQueue 预演通过`);
      } catch (e) {
        const txt = String(e.shortMessage || e.reason || e.message || '');
        // 每日上限 / 房间满员属于"业务状态"，不是配置错误，不该算阻塞项
        if (/daily round limit|full|capacity/i.test(txt)) {
          console.log(`  ℹ️ ${short(w.ADDRESS)} [${tag}] enterQueue 预演未通过(业务状态，非配置问题): ${txt.slice(0, 120)}`);
        } else {
          console.log(`  ❌ ${short(w.ADDRESS)} [${tag}] enterQueue 预演失败: ${formatError(e)}`);
          console.log(`     排查: ①该账号是否已绑定推荐人 ②是否已在其他轮次排队 ③房间是否满员/已达每日上限 ④USDT 余额或授权是否不足`);
          allReady = false;
        }
      }
    }
    for (const room of CFG.ROOMS) {
      if (roomOk[room] === false) continue;
      try {
        const rId = Number(await mgr.rpc(p => qRead.currentRound(room)));
        if (rId <= 0) continue;
        const data = qRead.interface.encodeFunctionData('claimRefundAndAirdrop', [room, rId - 1]);
        await mgr.rpc(p => withTimeout(p.call({ to: CFG.QUEUE_ADDR, from: w.ADDRESS, data }), 10000, 'claim.call'));
        console.log(`  ✅ ${short(w.ADDRESS)} [房间${room}] claimRefundAndAirdrop 预演通过`);
      } catch (e) {
        console.log(`  ℹ️ ${short(w.ADDRESS)} [房间${room}] claim 预演不可用(多为当前无可领轮次，属正常): ${formatError(e).slice(0, 160)}`);
      }
    }
  }

  console.log('\n========== 自检结论 ==========');
  console.log(allReady ? C.g + '✅ 具备交易条件，可执行: ' + LAUNCH + ' --run' + C.d : C.y + '⚠️ 存在阻塞项，请根据上方 ❌ 修复后再运行' + C.d);
  exitFlush(allReady ? 0 : 1);
}

// ---------------- 钱包文件加密 ----------------
// 格式: {"v":1,"encrypted":true,"salt":hex,"iv":hex,"tag":hex,"data":hex}
// 密钥: scrypt(密码, salt, N=2^14) -> 32 字节 AES-256 密钥；AES-256-GCM 认证加密。
// 密码只从环境变量 FTS_WALLET_PASSWORD 读一次；解密后明文私钥仅在内存停留到进程结束，
// 不写日志、不回显、不进环境变量(避免 /proc/<pid>/environ 泄露)。
const CRYPTO = require('crypto');
const WALLET_ENC_VERSION = 1;
function deriveKey(password, salt) {
  // scrypt 内存硬函数，抗暴力破解；N=16384 约 16MB，单次 ~50ms
  return CRYPTO.scryptSync(password, salt, 32, { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });
}
function encryptWalletsFile(plainObj, password) {
  const salt = CRYPTO.randomBytes(16);
  const iv = CRYPTO.randomBytes(12);
  const key = deriveKey(password, salt);
  const cipher = CRYPTO.createCipheriv('aes-256-gcm', key, iv);
  const plaintext = Buffer.from(JSON.stringify(plainObj), 'utf8');
  const enc = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  key.fill(0); plaintext.fill(0);
  return {
    v: WALLET_ENC_VERSION, encrypted: true,
    salt: salt.toString('hex'), iv: iv.toString('hex'),
    tag: tag.toString('hex'), data: enc.toString('hex')
  };
}
function decryptWalletsFile(obj, password) {
  if (!obj || obj.encrypted !== true) throw new Error('不是加密格式');
  if (obj.v !== WALLET_ENC_VERSION) throw new Error('不支持的加密版本: ' + obj.v);
  const salt = Buffer.from(obj.salt, 'hex'), iv = Buffer.from(obj.iv, 'hex');
  const tag = Buffer.from(obj.tag, 'hex'), enc = Buffer.from(obj.data, 'hex');
  const key = deriveKey(password, salt);
  const decipher = CRYPTO.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  let dec;
  try { dec = Buffer.concat([decipher.update(enc), decipher.final()]); }
  catch (e) { key.fill(0); throw new Error('解密失败: 密码错误或文件被篡改'); }
  key.fill(0);
  const txt = dec.toString('utf8'); dec.fill(0);
  return JSON.parse(txt);
}
function getWalletPassword() {
  if (process.env.FTS_WALLET_PASSWORD) return process.env.FTS_WALLET_PASSWORD;
  return null;
}

// ---------------- 网页自动探测合约地址 ----------------
// 游戏前端把合约地址写成 VITE_P2_XXX:"0x..." 映射在 JS bundle 里，网页换合约时
// 这个映射会变。直接抓页面 -> 提取 JS 地址 -> 解析映射 -> 写回 config.json，
// 无需改代码。所有地址都做链上代码存在性校验，避免抓到假地址。
// 脚本真正用到的合约字段 <- 网页 VITE 键名。一个字段可对应多个候选键(按顺序取第一个命中)。
// v1.7.1: 只保留引擎真正会读的字段。FTS_ADDR / PAIR_ADDR 在 v1.7.0 里只是往 config.json
// 多写两个永远没人读的死键(现货价实际来自 market.fts()/market.pair())，已移除。
const WEB_CONTRACT_MAP = {
  QUEUE_ADDR: ['VITE_P2_QUEUE'],
  MINER_QUEUE_ADDR: ['VITE_P2_LEGACY_QUEUE', 'VITE_P2_LEGACY_QUEUE_V7'],
  MINING_VAULT_ADDR: ['VITE_P2_MINING'],
  LEGACY_MINING_ADDR: ['VITE_P2_LEGACY_MINING'],
  USDT_ADDR: ['VITE_P2_USDT', 'VITE_USDT_ADDRESS'],
  MARKET_ADDR: ['VITE_MARKET_ESCROW']
};
// 资金相关字段: USDT approve 的 spender、USDT 合约、老队列、市场合约都直接触达资金。
// 默认禁止网页自动写回；必须 VITE 映射命中 + 链上校验通过 + 用户显式允许三者同时成立。
const WEB_FUNDS_KEYS = ['QUEUE_ADDR', 'USDT_ADDR', 'MINER_QUEUE_ADDR', 'MARKET_ADDR'];
// ABI 特征 -> 合约字段。VITE 映射缺失/改名时的兜底识别：
// 地址附近(上下文窗口)出现这组函数名，就认定是该类合约。
// v1.7.1: 兜底只用于"提示"，绝不用于写回资金相关字段（见 filterSyncCandidates）。
const ABI_FINGERPRINTS = [
  { field: 'QUEUE_ADDR', need: ['enterQueue', 'roomConfigs'] },
  { field: 'MARKET_ADDR', need: ['nextOrderId', 'fillOrder'] },
  { field: 'MINING_VAULT_ADDR', need: ['pendingOf', 'trancheCount'] },
  { field: 'LEGACY_MINING_ADDR', need: ['pendingReward', 'machineOf'] },
  { field: 'PAIR_ADDR', need: ['getReserves', 'token0'] }
];
async function fetchText(url, timeoutMs) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs || 15000);
  try {
    const r = await fetch(url, { signal: ctl.signal, headers: { 'User-Agent': 'Mozilla/5.0 FTS-Bot-Contract-Sync' } });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return await r.text();
  } finally { clearTimeout(timer); }
}
function absoluteUrl(base, path) {
  try { return new URL(path, base).href; } catch (e) { return null; }
}
// 探测网页返回 {found:{configKey:addr}, all:{VITE_*:addr}, jsUrls}
// 同时抓游戏页和市场页(市场合约 VITE_MARKET_ESCROW 只在市场页 bundle 里)
// 并发受限的批量抓取: 同一域名下 JS 很多，一次全抓会打爆站点也会拖慢启动
async function fetchMany(urls, limit, timeoutMs) {
  const out = [];
  let i = 0;
  const workers = Array.from({ length: Math.min(limit, urls.length) }, async () => {
    while (true) {
      const idx = i++;
      if (idx >= urls.length) return;
      try { out[idx] = { url: urls[idx], body: await fetchText(urls[idx], timeoutMs || 20000) }; }
      catch (e) { out[idx] = { url: urls[idx], body: null }; }
    }
  });
  await Promise.all(workers);
  return out.filter(x => x && x.body);
}
// 从 HTML 里提取同域链接(页面 + JS)，用于"整个站点都扫一遍"
function extractLinks(html, baseUrl, origin) {
  const pages = [], scripts = [];
  for (const m of html.matchAll(/<a[^>]+href=["']([^"'#]+)["']/gi)) {
    const u = absoluteUrl(baseUrl, m[1]);
    if (u && u.startsWith(origin) && !/\.(png|jpg|jpeg|gif|svg|css|ico|woff2?|ttf|pdf|zip)$/i.test(u)) pages.push(u);
  }
  for (const m of html.matchAll(/<script[^>]+src=["']([^"']+)["']/gi)) {
    const u = absoluteUrl(baseUrl, m[1]);
    if (u && u.startsWith(origin) && /\.js(\?|$)/i.test(u)) scripts.push(u);
  }
  return { pages: [...new Set(pages)], scripts: [...new Set(scripts)] };
}
// 从 JS 正文里提取它 import 的 chunk。
// Vite 产物既可能是 "assets/Xxx-hash.js" 也可能是 "./Xxx-hash.js"，
// 统一按"相对该 JS 自身 URL"解析，再只保留同域结果。
function extractChunks(js, jsUrl, origin) {
  const out = [];
  for (const m of js.matchAll(/["']([^"']+\.js)["']/g)) {
    const raw = m[1];
    if (/^(https?:)?\/\//i.test(raw)) continue;   // 外站绝对地址
    if (/vendor/i.test(raw)) continue;            // 第三方库，无业务地址
    // 路径解析: 以 / 或 assets/ 开头 -> 站根；否则相对当前 JS 所在目录。
    // 不能一律用 jsUrl 解析，否则 assets/X.js 会变成 /assets/assets/X.js(404)。
    let u;
    if (raw.startsWith('/') || raw.startsWith('assets/')) u = absoluteUrl(origin + '/', raw);
    else u = absoluteUrl(jsUrl, raw);
    if (u && u.startsWith(origin)) out.push(u);
  }
  return [...new Set(out)];
}
// 广域探测: 从用户配置的页面出发，扫同域页面 + 递归扫 JS chunk，
// 汇总所有 VITE_* 映射；VITE 缺失时用 ABI 特征兜底识别。
// 返回 {found:{configField:addr}, all:{VITE_KEY:addr}, jsUrls, pagesScanned, viaAbi}
async function probeWebContracts(gameUrl, marketUrl, deep) {
  deep = deep !== false;   // 默认完整扫描；启动时传 false 走轻量(只抓主bundle+一层chunk)
  const startPages = [gameUrl, marketUrl].filter(Boolean);
  if (!startPages.length) throw new Error('未配置游戏/市场网址');
  let origin;
  try { origin = new URL(startPages[0]).origin; } catch (e) { throw new Error('网址格式错误: ' + startPages[0]); }

  const MAX_PAGES = deep ? 15 : 2, MAX_JS = deep ? 40 : 8;
  const pagesSeen = new Set(), jsSeen = new Set(), jsQueue = [];
  const found = {}, all = {};
  const addJs = u => { if (u && !jsSeen.has(u) && jsSeen.size + jsQueue.length < MAX_JS) jsQueue.push(u); };

  // 1) 抓起始页 + 同域链接页。SPA 各路由往往返回同一份 HTML，用内容指纹去重避免重复解析。
  const pageQueue = [...startPages];
  const htmlSeen = new Set();
  while (pageQueue.length && pagesSeen.size < MAX_PAGES) {
    const pageUrl = pageQueue.shift();
    if (pagesSeen.has(pageUrl)) continue;
    pagesSeen.add(pageUrl);
    let html;
    try { html = await fetchText(pageUrl, 15000); } catch (e) { continue; }
    const fp = html.length + ':' + html.slice(0, 300);
    if (htmlSeen.has(fp)) continue;      // 同一份 SPA 外壳，已解析过
    htmlSeen.add(fp);
    const { pages, scripts } = extractLinks(html, pageUrl, origin);
    // 主 bundle 优先(vendor 太大且无业务地址，跳过)
    scripts.filter(s => !/vendor/i.test(s)).forEach(addJs);
    pages.filter(p => !pagesSeen.has(p)).forEach(p => pageQueue.push(p));
  }

  // 2) 逐层抓 JS，并从 JS 里继续发现 chunk(最多两轮，避免无限递归)
  for (let round = 0; round < 2 && jsQueue.length; round++) {
    const batch = jsQueue.splice(0, jsQueue.length).filter(u => !jsSeen.has(u));
    batch.forEach(u => jsSeen.add(u));
    const bodies = await fetchMany(batch, 10, 25000);
    for (const { url, body } of bodies) {
      // VITE 映射
      const re = /(VITE_[A-Z0-9_]+)\s*:\s*["'](0x[a-fA-F0-9]{40})["']/g;
      let m;
      while ((m = re.exec(body))) {
        all[m[1]] = m[2];
        for (const [field, keys] of Object.entries(WEB_CONTRACT_MAP)) {
          if (!found[field] && keys.includes(m[1])) found[field] = m[2];
        }
      }
      // 继续发现 chunk
      if (round === 0) extractChunks(body, url, origin).filter(u => !jsSeen.has(u)).forEach(addJs);
    }
  }

  // 2b) 从 JS 里提取站内路由(SPA 的导航写在 JS 里，HTML 的 <a> 抓不到)，
  // 再抓这些页面 —— 保证"同域名下任何链接"都覆盖到。
  if (deep && pagesSeen.size < MAX_PAGES) {
    const routeSet = new Set();
    const bodies = await fetchMany([...jsSeen].slice(0, 8), 4, 20000);
    for (const { body } of bodies) {
      for (const m of body.matchAll(/["'`](\/[a-z][a-z0-9/_-]{2,40})["'`]/g)) {
        const p = m[1];
        // 只保留像路由的(排除 assets/静态资源)
        if (/^\/(dapp|dashboard|market|game|claim|ranks|v9|relief|lp|operator|simulator)/i.test(p) && !/\.(js|css|png|svg|jpg)$/i.test(p)) {
          routeSet.add(p);
        }
      }
    }
    for (const p of routeSet) {
      if (pagesSeen.size >= MAX_PAGES) break;
      const u = absoluteUrl(origin + '/', p);
      if (!u || pagesSeen.has(u)) continue;
      pagesSeen.add(u);
      try {
        const html = await fetchText(u, 12000);
        const { scripts } = extractLinks(html, u, origin);
        scripts.filter(s => !/vendor/i.test(s)).forEach(addJs);
      } catch (e) { }
    }
    // 新发现的 chunk 也抓一遍(补全)
    const extra = jsQueue.splice(0, jsQueue.length).filter(u => !jsSeen.has(u));
    extra.forEach(u => jsSeen.add(u));
    if (extra.length) {
      const more = await fetchMany(extra, 10, 20000);
      for (const { body } of more) {
        const re = /(VITE_[A-Z0-9_]+)\s*:\s*["'](0x[a-fA-F0-9]{40})["']/g;
        let m;
        while ((m = re.exec(body))) {
          all[m[1]] = m[2];
          for (const [field, keys] of Object.entries(WEB_CONTRACT_MAP)) {
            if (!found[field] && keys.includes(m[1])) found[field] = m[2];
          }
        }
      }
    }
  }

  // 3) ABI 特征兜底: 对还没有值的字段，在 JS 里找"地址附近出现特征函数名"的
  const viaAbi = {};
  if (Object.keys(found).length < Object.keys(WEB_CONTRACT_MAP).length) {
    const missing = ABI_FINGERPRINTS.filter(fp => !found[fp.field]);
    if (missing.length) {
      const bodies = await fetchMany([...jsSeen].slice(0, 20), 10, 20000);
      for (const { body } of bodies) {
        for (const fp of missing) {
          if (found[fp.field]) continue;
          const addr = findAddressByFingerprint(body, fp.need);
          if (addr) { found[fp.field] = addr; viaAbi[fp.field] = addr; }
        }
      }
    }
  }
  return { found, all, jsUrls: [...jsSeen], pagesScanned: pagesSeen.size, viaAbi };
}
// 在 JS 文本里找"上下文含指定函数名"的地址
// v1.7.1: 6000 字符窗口几乎必然命中特征函数名，返回的只是"文本顺序上第一个地址"。
// 收紧到 600 字符，并要求候选唯一；多个候选一律返回 null（宁可不认，不可认错）。
function findAddressByFingerprint(js, needFns) {
  const addrRe = /0x[a-fA-F0-9]{40}/g;
  const hits = [];
  let m;
  while ((m = addrRe.exec(js))) {
    const addr = m[0];
    if (/^0x0{40}$/.test(addr)) continue;
    const ctx = js.slice(Math.max(0, m.index - 600), m.index + 600);
    if (needFns.every(fn => ctx.includes(fn))) hits.push(addr.toLowerCase());
  }
  const uniq = [...new Set(hits)];
  return uniq.length === 1 ? uniq[0] : null;
}
// 校验地址在链上有代码；返回 {key:bool}。
// v1.7.1: 每个 key 都显式写入结果；RPC 失败一律 false（调用方据此拒绝全部写回）。
async function validateContractAddresses(addrs) {
  const out = {};
  await Promise.all(Object.entries(addrs).map(async ([k, a]) => {
    if (!/^0x[a-fA-F0-9]{40}$/.test(a)) { out[k] = false; return; }
    try {
      const code = await mgr.rpc(p => p.getCode(a));
      out[k] = !!(code && code !== '0x');
    } catch (e) { out[k] = false; }
  }));
  return out;
}

// v1.7.1: 决定哪些网页地址允许写回 config.json（纯函数，可回归测试）。
// 原则: 校验必须显式通过；RPC 不可用(valid 为空)一个都不写；ABI 启发式不碰资金字段；
// 资金字段默认冻结，只有显式配置 WEB_SYNC_ALLOW_FUNDS_KEYS 才放行。
function filterSyncCandidates(found, valid, viaAbi, cfg) {
  const accepted = {}, rejected = {};
  const allowFunds = !!(cfg && cfg.WEB_SYNC_ALLOW_FUNDS_KEYS);
  const v = valid || {}, abi = viaAbi || {};
  for (const [k, addr] of Object.entries(found || {})) {
    if (!Object.prototype.hasOwnProperty.call(WEB_CONTRACT_MAP, k)) {
      rejected[k] = '非白名单字段'; continue;
    }
    if (v[k] !== true) { rejected[k] = '链上校验未通过或 RPC 不可用'; continue; }
    if (abi[k]) { rejected[k] = 'ABI 启发式结果不写回'; continue; }
    if (WEB_FUNDS_KEYS.includes(k) && !allowFunds) {
      rejected[k] = '资金相关字段默认冻结(WEB_SYNC_ALLOW_FUNDS_KEYS=false)'; continue;
    }
    accepted[k] = addr;
  }
  return { accepted, rejected };
}
// 把探测到的地址写回 config.json（保留其它配置，只改合约字段）
function saveWebContracts(found) {
  let cfg = {};
  try {
    const raw = fs.readFileSync(CONFIG_FILE, 'utf8').replace(/^\uFEFF/, '');
    cfg = JSON.parse(raw);
    if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) cfg = {};
  } catch (e) { /* 新文件 */ }
  let changed = 0;
  for (const [k, v] of Object.entries(found)) {
    if (!Object.prototype.hasOwnProperty.call(WEB_CONTRACT_MAP, k)) continue;  // v1.7.1: 不写未知键
    if (/^0x[a-fA-F0-9]{40}$/.test(v) && cfg[k] !== v) { cfg[k] = v; changed++; }
  }
  if (changed) {
    const tmp = CONFIG_FILE + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, CONFIG_FILE);
    } finally { if (fs.existsSync(tmp)) { try { fs.unlinkSync(tmp); } catch (e) { } } }
  }
  return changed;
}
// 完整同步流程: 探测 -> 校验链上代码 -> 写回；返回报告
async function syncWebContracts(apply, deep) {
  info('SYS', `从网页广域探测合约: ${CFG.GAME_URL}`);
  const r = await probeWebContracts(CFG.GAME_URL, CFG.MARKET_URL, deep);
  const keys = Object.keys(r.found);
  if (!keys.length) throw new Error('未从网页解析到任何合约地址(JS 结构可能变化)');
  info('SYS', `扫描 ${r.pagesScanned} 个页面 / ${r.jsUrls.length} 个 JS，找到 ${keys.length} 个合约: ${keys.join(', ')}`);
  if (r.viaAbi && Object.keys(r.viaAbi).length) {
    info('SYS', `其中 ${Object.keys(r.viaAbi).join(', ')} 由 ABI 特征识别(VITE 映射缺失)`);
  }
  // v1.7.1: RPC 不可用 / 校验失败时一个地址都不写回（旧版 valid={} 会让所有地址无条件通过）。
  if (!mgr.provider) {
    try { await mgr.pickBest(); } catch (e) { warn('SYS', 'RPC 不可用，本次不写回任何合约地址: ' + formatError(e).slice(0, 100)); }
  }
  const valid = mgr.provider ? await validateContractAddresses(r.found) : {};
  const { accepted, rejected } = filterSyncCandidates(r.found, valid, r.viaAbi, CFG);
  for (const [k, why] of Object.entries(rejected)) {
    warn('SYS', `${k}=${r.found[k]} 未写回: ${why}`);
  }
  if (!Object.keys(accepted).length) {
    warn('SYS', '没有任何合约地址通过校验，config.json 保持不变（不会因网页污染改授权对象）');
  }
  const changed = apply ? saveWebContracts(accepted) : 0;
  return { found: r.found, accepted, rejected, all: r.all, jsUrls: r.jsUrls, pagesScanned: r.pagesScanned, viaAbi: r.viaAbi, changed };
}

// ---------------- FTS 自动买卖 ----------------
const MARKET_ABI = [
  'function fts() view returns (address)',
  'function usdt() view returns (address)',
  'function pair() view returns (address)',
  'function poolPrice() view returns (uint256)',
  'function nextOrderId() view returns (uint256)',
  'function orders(uint256) view returns (address seller, uint256 ftsAmount, uint256 totalPriceU, uint256 createdAt, uint8 status, uint256 feeBps)',
  'function fillOrder(uint256 orderId)',
  'function createOrder(uint256 ftsAmount, uint256 totalPriceU) returns (uint256)',
  'function cancelOrder(uint256 orderId)'
];
const PAIR_ABI = [
  'function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)',
  'function token0() view returns (address)',
  'function token1() view returns (address)'
];
// v1.7.1: token0 既不是 FTS 也不是 USDT 时必须拒绝，不能默默用错储备算出错误价格去挂单。
function computeFtsSpotPrice(r0, r1, token0, ftsAddr, usdtAddr, formatUnits) {
  const a = String(token0).toLowerCase();
  const fts = String(ftsAddr).toLowerCase(), usdt = String(usdtAddr).toLowerCase();
  if (a !== fts && a !== usdt) return null;
  const v0 = Number(formatUnits(r0, 18)), v1 = Number(formatUnits(r1, 18));
  if (!(v0 > 0) || !(v1 > 0)) return null;
  const vFts = a === fts ? v0 : v1;
  const vUsdt = a === usdt ? v0 : v1;
  if (!(vFts > 0) || !(vUsdt > 0)) return null;
  return vUsdt / vFts;
}
// 读 FTS 真实价格: 从 DEX pair 储备算 USDT/FTS，不读市场挂单价(用户要求)
async function getFtsSpotPrice(market) {
  const pairAddr = await mgr.rpc(p => market.pair());
  const ftsAddr = await mgr.rpc(p => market.fts());
  const usdtAddr = await mgr.rpc(p => market.usdt());
  const pair = new ethers.Contract(pairAddr, PAIR_ABI, mgr.provider);
  const [res, t0] = await Promise.all([
    mgr.rpc(p => pair.getReserves()),
    mgr.rpc(p => pair.token0())
  ]);
  const r0 = BigInt(res.reserve0 || res[0]);
  const r1 = BigInt(res.reserve1 || res[1]);
  if (r0 <= 0n || r1 <= 0n) return null;
  // v1.7.1: 交给纯函数统一校验 token0 归属与储备有效性
  return computeFtsSpotPrice(r0, r1, t0, ftsAddr, usdtAddr, ethers.formatUnits);
}
// 扫描活跃挂单(status=1)，返回 [{id, seller, ftsAmount, totalPriceU, unitPrice}]，按单价升序
async function scanMarketOrders(market, scanN) {
  const nextId = Number(await mgr.rpc(p => market.nextOrderId()));
  if (!Number.isFinite(nextId) || nextId <= 1) return [];
  const from = Math.max(1, nextId - scanN);
  const ids = Array.from({ length: nextId - from }, (_, i) => from + i);
  // v1.7.1: 多账号时任何一个自有账号的挂单都不能被自己吃掉
  const mine = new Set(instances.map(i => String(i.address || '').toLowerCase()));
  const results = await Promise.all(ids.map(async id => {
    try {
      const o = await mgr.rpc(p => market.orders(id));
      const status = Number(o.status !== undefined ? o.status : o[4]);
      if (status !== 1) return null;                       // 只关心活跃挂单
      const seller = String(o.seller !== undefined ? o.seller : o[0]);
      if (mine.has(seller.toLowerCase())) return null;      // 不吃任何一个自有账号的单
      const ftsAmount = BigInt(o.ftsAmount !== undefined ? o.ftsAmount : o[1]);
      const totalPriceU = BigInt(o.totalPriceU !== undefined ? o.totalPriceU : o[2]);
      if (ftsAmount <= 0n) return null;
      const unitPrice = Number(ethers.formatUnits(totalPriceU, 18)) / Number(ethers.formatUnits(ftsAmount, 18));
      return { id, seller, ftsAmount, totalPriceU, unitPrice };
    } catch (e) { return null; }
  }));
  return results.filter(Boolean).sort((a, b) => a.unitPrice - b.unitPrice);
}
// v1.7.1: 买单"今日已花费"必须跨重启累计，否则重启即清零、上限形同虚设。
function readDailySpent(stateFile, addr, fsMod) {
  try {
    const d = JSON.parse(fsMod.readFileSync(stateFile, 'utf8'));
    const day = new Date().toISOString().slice(0, 10);
    const v = d && d[day] && d[day][String(addr).toLowerCase()];
    return Number(v) > 0 ? Number(v) : 0;
  } catch (e) { return 0; }
}
function writeDailySpent(stateFile, addr, spent, fsMod) {
  try {
    let d = {};
    try { d = JSON.parse(fsMod.readFileSync(stateFile, 'utf8')) || {}; } catch (e) { }
    const day = new Date().toISOString().slice(0, 10);
    if (!d[day] || typeof d[day] !== 'object') d[day] = {};
    d[day][String(addr).toLowerCase()] = spent;
    const days = Object.keys(d).sort();
    while (days.length > 7) delete d[days.shift()];
    fsMod.writeFileSync(stateFile, JSON.stringify(d, null, 2), { mode: 0o600 });
  } catch (e) { /* 状态写不了就退化为进程内计数，不阻断交易 */ }
}
// v1.7.1: 查自己名下仍活跃的挂单，避免同一价位反复 createOrder
async function scanMyActiveOrders(market, addr, scanN) {
  const nextId = Number(await mgr.rpc(p => market.nextOrderId()));
  if (!Number.isFinite(nextId) || nextId <= 1) return [];
  const from = Math.max(1, nextId - scanN);
  const mine = String(addr).toLowerCase();
  const ids = Array.from({ length: nextId - from }, (_, i) => from + i);
  const out = await Promise.all(ids.map(async id => {
    try {
      const o = await mgr.rpc(p => market.orders(id));
      const status = Number(o.status !== undefined ? o.status : o[4]);
      const seller = String(o.seller !== undefined ? o.seller : o[0]);
      return status === 1 && seller.toLowerCase() === mine ? id : null;
    } catch (e) { return null; }
  }));
  return out.filter(x => x !== null);
}
// 买单循环: 单价低于阈值时吃单，总额不超上限
async function tradeBuyLoop(inst, market) {
  let spent = readDailySpent(CFG.TRADE_STATE_FILE, inst.address, fs);
  while (true) {
    try {
      if (CFG.TRADE_BUY_MAX_PRICE === null || CFG.TRADE_BUY_MAX_TOTAL === null) {
        warnOnce(inst.address, '买单已开启但未配置阈值(TRADE_BUY_MAX_PRICE/TRADE_BUY_MAX_TOTAL)，跳过', 300000);
        await sleep(CFG.TRADE_CHECK_MS); continue;
      }
      if (spent >= CFG.TRADE_BUY_MAX_TOTAL) {
        warnOnce(inst.address, `买单今日已花费 ${spent.toFixed(2)}U 达到上限 ${CFG.TRADE_BUY_MAX_TOTAL}U，停止`, 300000);
        await sleep(CFG.TRADE_CHECK_MS); continue;
      }
      const orders = await scanMarketOrders(market, CFG.TRADE_BUY_SCAN_N);
      const affordable = orders.filter(o => o.unitPrice <= CFG.TRADE_BUY_MAX_PRICE);
      for (const o of affordable) {
        const cost = Number(ethers.formatUnits(o.totalPriceU, 18));
        if (spent + cost > CFG.TRADE_BUY_MAX_TOTAL) continue;
        // 用 sendTx 走统一的 nonce/gas 管理，避免撞号
        const okTx = await sendTx(inst, {
          label: `[买单] 吃单#${o.id} 单价${o.unitPrice.toFixed(4)}U`,
          contract: market, method: 'fillOrder', args: [o.id]
        });
        if (okTx) {
          spent += cost;
          writeDailySpent(CFG.TRADE_STATE_FILE, inst.address, spent, fs);
          info(inst.address, `[买单] 已吃单#${o.id} 花费 ${cost.toFixed(2)}U，今日累计 ${spent.toFixed(2)}U`);
        }
        if (spent >= CFG.TRADE_BUY_MAX_TOTAL) break;
      }
    } catch (e) {
      warnOnce(inst.address, '买单循环异常: ' + formatError(e).slice(0, 120), 60000);
    }
    await sleep(CFG.TRADE_CHECK_MS);
  }
}
// 卖单循环: 读真实价，满足条件时挂单(createOrder)
async function tradeSellLoop(inst, market) {
  let listed = 0;
  let lastAt = 0;
  while (true) {
    try {
      const spot = await getFtsSpotPrice(market);
      if (!spot) { warnOnce(inst.address, '卖单: 读不到 FTS 真实价格(pair 储备异常)，跳过', 300000); await sleep(CFG.TRADE_CHECK_MS); continue; }
      let shouldSell = false, targetPrice = 0;
      if (CFG.TRADE_SELL_MODE === 'fixed') {
        if (CFG.TRADE_SELL_PRICE !== null && spot >= CFG.TRADE_SELL_PRICE) { shouldSell = true; targetPrice = CFG.TRADE_SELL_PRICE; }
      } else if (CFG.TRADE_SELL_MODE === 'spotminus') {
        // 时价减差值: 只要价差参数有效就挂(挂单价=真实价-差值)
        if (CFG.TRADE_SELL_PRICE !== null && spot > CFG.TRADE_SELL_PRICE) { shouldSell = true; targetPrice = spot - CFG.TRADE_SELL_PRICE; }
      } else {
        warnOnce(inst.address, '卖单模式无效(应设 fixed 或 spotminus)，跳过', 300000);
      }
      // v1.7.1: 三道闸门 —— 累计上限 / 冷却 / 已有活跃挂单，杜绝条件满足时无限重复挂单
      const maxOrders = Math.max(1, Number(CFG.TRADE_SELL_MAX_ORDERS) || 1);
      if (listed >= maxOrders) {
        warnOnce(inst.address, `卖单累计已挂 ${listed} 单达到上限 ${maxOrders}，不再重复挂单`, 300000);
        await sleep(CFG.TRADE_CHECK_MS); continue;
      }
      if (Date.now() - lastAt < (Number(CFG.TRADE_SELL_COOLDOWN_MS) || 300000)) {
        await sleep(CFG.TRADE_CHECK_MS); continue;
      }
      if (shouldSell && targetPrice > 0 && CFG.TRADE_SELL_AMOUNT !== null) {
        const mine = await scanMyActiveOrders(market, inst.address, CFG.TRADE_BUY_SCAN_N);
        if (mine.length) {
          warnOnce(inst.address, `已有 ${mine.length} 个自己的活跃挂单，跳过本次挂单`, 300000);
          await sleep(CFG.TRADE_CHECK_MS); continue;
        }
        const ftsAmount = ethers.parseUnits(String(CFG.TRADE_SELL_AMOUNT), 18);
        const totalPriceU = ethers.parseUnits((targetPrice * CFG.TRADE_SELL_AMOUNT).toFixed(6), 18);
        const okTx = await sendTx(inst, {
          label: `[卖单] 挂 ${CFG.TRADE_SELL_AMOUNT} FTS @${targetPrice.toFixed(4)}U(真实价${spot.toFixed(4)})`,
          contract: market, method: 'createOrder', args: [ftsAmount, totalPriceU]
        });
        if (okTx) { listed++; lastAt = Date.now(); info(inst.address, `[卖单] 已挂单 ${CFG.TRADE_SELL_AMOUNT} FTS @${targetPrice.toFixed(4)}U (累计 ${listed}/${maxOrders})`); }
      }
    } catch (e) {
      warnOnce(inst.address, '卖单循环异常: ' + formatError(e).slice(0, 120), 60000);
    }
    await sleep(CFG.TRADE_CHECK_MS);
  }
}
function startTrading(inst) {
  if (!CFG.TRADE_BUY_ENABLED && !CFG.TRADE_SELL_ENABLED) return;
  const addr = CFG.MARKET_ADDR;
  if (!/^0x[a-fA-F0-9]{40}$/.test(addr || '')) {
    warn(inst.address, 'FTS 买卖已开启但市场合约地址为空，请先运行 --sync-web 或配置 MARKET_ADDR');
    return;
  }
  const market = new ethers.Contract(addr, MARKET_ABI, inst.wallet);
  if (CFG.TRADE_BUY_ENABLED) { info(inst.address, `买单循环启动(阈值≤${CFG.TRADE_BUY_MAX_PRICE}U, 上限${CFG.TRADE_BUY_MAX_TOTAL}U)`); tradeBuyLoop(inst, market); }
  if (CFG.TRADE_SELL_ENABLED) { info(inst.address, `卖单循环启动(模式${CFG.TRADE_SELL_MODE}, 阈值${CFG.TRADE_SELL_PRICE})`); tradeSellLoop(inst, market); }
}

// ---------------- 钱包加载 ----------------
function loadWallets() {
  if (!fs.existsSync(WALLETS_FILE)) {
    fatal('CFG', `找不到 ${WALLETS_FILE}，请先运行配置向导`);
    return [];
  }
  let data;
  try { data = JSON.parse(fs.readFileSync(WALLETS_FILE, 'utf8').replace(/^﻿/, '')); }
  catch (e) { fatal('CFG', `wallets.json 解析失败: ${e.message}`); return []; }
  // 加密文件解密
  if (data.encrypted === true) {
    const pwd = getWalletPassword();
    if (!pwd) {
      fatal('CFG', 'wallets.json 已加密，但未提供密码。请设置环境变量 FTS_WALLET_PASSWORD 后重试');
      return [];
    }
    try { data = decryptWalletsFile(data, pwd); }
    catch (e) { fatal('CFG', '钱包解密失败: ' + e.message); return []; }
  } else {
    warn('CFG', '⚠️ wallets.json 是明文存储！建议运行 --encrypt 加密，避免私钥泄露');
  }
  const list = data.wallets || [];
  const out = [];
  for (const c of list) {
    try {
      if (!/^(0x)?[0-9a-fA-F]{64}$/.test(c.PRIVATE_KEY || '')) { fatal('CFG', `私钥格式错误(需64位hex): ${short(c.ADDRESS)}`); continue; }
      const pk = c.PRIVATE_KEY.startsWith('0x') ? c.PRIVATE_KEY : '0x' + c.PRIVATE_KEY;
      const wallet = new ethers.Wallet(pk);
      if (!/^0x[a-fA-F0-9]{40}$/.test(c.ADDRESS || '')) { fatal('CFG', `地址格式错误: ${c.ADDRESS}`); continue; }
      if (wallet.address.toLowerCase() !== c.ADDRESS.toLowerCase()) { fatal('CFG', `私钥与地址不匹配: 配置=${c.ADDRESS} 实际=${wallet.address}`); continue; }
      if (!/^0x[a-fA-F0-9]{40}$/.test(c.REFERRER || '')) { fatal('CFG', `推荐人地址格式错误: ${c.REFERRER}`); continue; }
      out.push({ ...c, pk, wallet });
    } catch (e) {
      fatal('CFG', `账号加载失败: ${formatError(e)}`);
    }
  }
  return out;
}

// 从 stdin 逐行读密码。管道模式一次性读完再按行取(避免流提前结束导致第二次读为空)；
// TTY 模式用 readline 交互。密码不回显由终端负责。
const readline = require('readline');
function readPasswordLines() {
  return new Promise(resolve => {
    if (!process.stdin.isTTY) {
      // 管道/重定向: 一次性读全部，按行分割
      let buf = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', c => { buf += c; });
      process.stdin.on('end', () => resolve(buf.split(/\r?\n/).filter((s, i, a) => s !== '' || i < a.length - 1)));
      return;
    }
    // TTY: 交互式逐行
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const lines = [];
    rl.question('设置密码(至少8位): ', p1 => {
      lines.push(p1);
      rl.question('再输入一次确认: ', p2 => { lines.push(p2); rl.close(); resolve(lines); });
    });
  });
}
// 加密 wallets.json: 读明文 -> 输入密码两次 -> 写加密格式 -> 验证解密
async function cmdEncrypt() {
  if (!fs.existsSync(WALLETS_FILE)) { fatal('CFG', '找不到 ' + WALLETS_FILE); exitFlush(1); return; }
  const raw = fs.readFileSync(WALLETS_FILE, 'utf8').replace(/^﻿/, '');
  let obj;
  try { obj = JSON.parse(raw); } catch (e) { fatal('CFG', 'wallets.json 解析失败: ' + e.message); exitFlush(1); return; }
  if (obj.encrypted === true) { warn('CFG', 'wallets.json 已经是加密格式，无需重复加密'); exitFlush(0); return; }
  if (!obj.wallets || !obj.wallets.length) { fatal('CFG', 'wallets.json 中没有账号，无需加密'); exitFlush(1); return; }
  const lines = await readPasswordLines();
  const p1 = lines[0], p2 = lines[1];
  if (!p1 || p1.length < 8) { fatal('CFG', '密码不能少于8位，已取消'); exitFlush(1); return; }
  if (p1 !== p2) { fatal('CFG', '两次密码不一致，已取消'); exitFlush(1); return; }
  const enc = encryptWalletsFile(obj, p1);
  // 验证能正确解密(防止写出坏文件把钱包锁死)
  try {
    const back = decryptWalletsFile(enc, p1);
    if (!back.wallets || back.wallets.length !== obj.wallets.length) throw new Error('解密后账号数不符');
  } catch (e) { fatal('CFG', '加密自检失败，未写入: ' + e.message); exitFlush(1); return; }
  const tmp = WALLETS_FILE + '.tmp';
  try {
    fs.writeFileSync(tmp, JSON.stringify(enc), { mode: 0o600 });
    fs.renameSync(tmp, WALLETS_FILE);
  } finally { if (fs.existsSync(tmp)) { try { fs.unlinkSync(tmp); } catch (e) { } } }
  // v1.7.1: 删除了原来的 `raw && (()=>{})();` —— 它是空操作，且 JS 字符串不可变，
  // 无法可靠清零。真实保护来自 0600 权限 + AES-GCM 加密 + 明文不写日志/不回显。
  ok('CFG', `wallets.json 已加密(${obj.wallets.length} 个账号)。运行时用环境变量 FTS_WALLET_PASSWORD 提供密码`);
  warn('CFG', '⚠️ 请务必记住密码，丢失后无法恢复钱包！');
  exitFlush(0);
}

// ---------------- 主流程 ----------------
async function main() {
  if (MODE === 'encrypt') return cmdEncrypt();
  if (MODE === 'sync-web') {
    try {
      const r = await syncWebContracts(true);
      ok('SYS', `网页合约同步完成: 写入 ${r.changed} 项; 抓取 ${r.jsUrls.length} 个 JS`);
      for (const [k, v] of Object.entries(r.accepted)) console.log(`  ${k} = ${v}`);
      if (r.rejected && Object.keys(r.rejected).length) {
        warn('SYS', `以下字段按安全策略未写回: ${Object.entries(r.rejected).map(([k, v]) => k + '(' + v + ')').join(', ')}`);
      }
      exitFlush(0);
    } catch (e) { fatal('SYS', '网页合约同步失败: ' + formatError(e)); exitFlush(1); }
    return;
  }
  // 配置校验: 有问题就地修正并明确告知，不让它悄悄生效或让引擎崩掉
  const cfgIssues = validateCfg();
  if (cfgIssues.length) {
    warn('SYS', `配置发现 ${cfgIssues.length} 处问题，已按下列方式处理:`);
    cfgIssues.forEach(s => warn('SYS', '  - ' + s));
  }

  const gasDesc = CFG.GAS_FIXED_GWEI
    ? `固定 ${CFG.GAS_FIXED_GWEI} gwei`
    : `自动 ×${CFG.GAS_MULT} (上限 ${CFG.GAS_MAX_GWEI} gwei)`;
  info('SYS', `FTS 引擎 v${VERSION} 启动 | 模式=${MODE} | 房间=${CFG.ROOMS.join(',')} | 抢位=[${CFG.SNIPE_MIN_COUNT},${CFG.SNIPE_MAX_COUNT}) | 延迟=${CFG.SNIPE_DELAY_MS}ms | 手续费=${gasDesc}`);
  info('SYS', `队列合约=${CFG.QUEUE_ADDR} | 中奖自动领取=${CFG.CLAIM_WIN ? '开' : '关'} | 组矿机=${CFG.MINER_ENABLED ? `${CFG.MINER_MODE}(固定${CFG.MINER_USD}U/老队列 ${CFG.MINER_QUEUE_ADDR})` : '关'} | 矿机产出领取=${CFG.MINING_CLAIM ? `开(每${Math.round(CFG.MINING_CLAIM_MS / 1000)}s检测)` : '关'}`);
  const wallets = loadWallets();
  if (!wallets.length) { fatal('SYS', '没有可用账号，退出(错误码 21)'); exitFlush(21); return; }
  try { fs.chmodSync(WALLETS_FILE, 0o600); } catch (e) { }

  if (SELFTEST) { selftestWallets = wallets; return selftest(); }

  try { await mgr.pickBest(); }
  catch (e) { fatal('SYS', 'RPC 初始化失败: ' + formatError(e)); exitFlush(22); return; }
  // 网页合约同步: 默认关闭(WEB_AUTO_SYNC=false)。开启后也只在链上校验通过且非资金字段时写回。
  if (CFG.WEB_AUTO_SYNC && MODE === 'run') {
    syncWebContracts(true, false)   // 启动用轻量扫描(不拖带宽)，--sync-web 手动时才是完整扫描
      .then(r => { if (r.changed) warn('SYS', `网页检测到 ${r.changed} 个合约地址变化，已写入 config.json，重启后生效`); })
      .catch(e => warnOnce('SYS', '网页合约同步失败(不影响本次运行): ' + formatError(e).slice(0, 120), 300000));
  }
  bindRead(mgr.provider);
  await detectEip1559();

  let acctIdx = 0;
  for (const w of wallets) {
    const inst = {
      conf: w, pk: w.pk, address: w.wallet.address, wallet: null, provider: null, queue: null, usdt: null,
      referrer: w.REFERRER,
      min: num(w.SNIPE_MIN_COUNT, CFG.SNIPE_MIN_COUNT),
      max: num(w.SNIPE_MAX_COUNT, CFG.SNIPE_MAX_COUNT),
      delayMs: num(w.SNIPE_DELAY_MS, CFG.SNIPE_DELAY_MS),
      mutex: new (class { constructor() { this.q = Promise.resolve(); } async acquire() { let rel; const next = new Promise(r => rel = r); const prev = this.q; this.q = this.q.then(() => next); await prev; return rel; } })(),
      acted: new Set(), claimed: new Set(), nonce: null, busy: false,
      bnbCache: null,
      stats: { sent: 0, failed: 0 }
    };
    // 账号平摊到节点: 节点数=账号数时一对一，多账号轮转。每个账号的读写优先走专属节点。
    const node = mgr.nodeFor(acctIdx++);
    bind(inst, node ? node.provider : mgr.provider, node);
    instances.push(inst);
    ok(inst.address, `账号加载完成${node ? ' → 节点 ' + node.url.replace('https://', '') : ''}`);
  }

  // 排水并行做: 串行时 10 个账号最坏要等 5 分钟才能开始抢第一单
  await Promise.all(instances.map(i => resolveReferrer(i)));
  await Promise.all(instances.map(i => drainPending(i)));

  for (const inst of instances) {
    startGapFixer(inst);   // nonce 断档自愈
    claimLoop(inst);
    if (CFG.MINER_ENABLED) minerLoop(inst);
    if (CFG.MINING_CLAIM) miningClaimLoop(inst);
  }
  // FTS 买卖只用第一个账号跑，避免多账号重复吃同一笔单/重复挂单
  if (CFG.TRADE_BUY_ENABLED || CFG.TRADE_SELL_ENABLED) startTrading(instances[0]);

  const au = userCfg.AUTO_UPDATE;
  const autoUpdateOn = !(au === false || au === 0 || au === '0' || au === 'false' || au === 'off');
  if (MODE === 'run' && autoUpdateOn) updateLoop();   // 仅正式运行：空闲窗口自动更新并重启

  const stream = new BlockStream();
  stream.start();

  // 崩溃自愈测试钩子
  if (process.env.FTS_CRASH_TEST === '1') {
    setTimeout(() => { console.error('[CRASH-TEST] 模拟崩溃退出'); process.exit(99); }, 5000);
  }

  // 状态心跳
  setInterval(() => {
    const s = instances.map(i => `${short(i.address)}(tx${i.stats.sent}/f${i.stats.failed})`).join(' ');
    // 带上块高/已处理块数，方便一眼看出"是不是卡住了"
    const nodeDesc = nodePool.enabled
      ? `节点池=${nodePool.nodes.filter(n => n.available).length}/${nodePool.nodes.length} [${nodePool.stats()}]`
      : `节点=${CFG.HTTP_POOL[mgr.index]}`;
    info('SYS', `心跳 | ${nodeDesc} | WS=${stream.wsOk ? '连接' : '轮询'} | 块高=${stream.lastHeight} 已处理=${stream.tickCount} 去重=${stream.dupSkipped} | ${s}`);
  }, 60000);

  // 未捕获异常: 单次异常继续跑(公共节点抖动很常见)，但短时间连续爆就退出，
  // 交给外壳重启 —— 状态机可能已经被搞坏了，硬撑着跑比重启更危险。
  let crashN = 0, crashAt = Date.now();
  process.on('uncaughtException', e => {
    const now = Date.now();
    if (now - crashAt > 60000) { crashN = 0; crashAt = now; }
    crashN++;
    err('SYS', `未捕获异常(${crashN}/20，进程继续): ` + formatError(e));
    if (crashN >= 20) {
      fatal('SYS', '60 秒内未捕获异常超过 20 次，主动退出让外壳重启');
      try { logStream && logStream.end(); } catch (x) { }
      exitFlush(24);
    }
  });
  process.on('unhandledRejection', e => {
    const d = formatError(e);
    if (isNetworkErr(e)) warnOnce('SYS', '网络类 Promise 拒绝(已忽略，会自动重试): ' + d, 60000);
    else errOnce('SYS', '未处理 Promise 拒绝: ' + d, 60000);
  });
}

main().catch(e => { fatal('SYS', '主流程致命错误: ' + formatError(e)); exitFlush(23); });
CORE_EOF
cat << 'PROBE_EOF' > probe.js
#!/usr/bin/env node
'use strict';
/**
 * FTS 链上只读探针 (probe) —— 完全不需要私钥/钱包
 *
 * 用途: 在真机上验证"这个合约到底长什么样"，再决定要不要跑交易。
 * 只发 eth_call / eth_getCode 这类只读请求，不会签名、不会广播、不花一分钱。
 *
 * 用法:
 *   node probe.js                          # 用 config.json 或默认地址
 *   node probe.js 0x你的队列合约地址        # 指定要探测的合约
 *   node probe.js <合约> <你的钱包地址>     # 额外查该地址余额/授权(只读, 仍不需要私钥)
 */

// console.log 写管道是异步的，直接 process.exit 可能在 flush 前退出、截断最后几行
// (探测结论/建议的下一步最容易丢)。这里等 stdout 排空再退。
function exitFlush(code) {
  process.exitCode = code;
  try { process.stdout.write('', () => process.exit(code)); }
  catch (e) { process.exit(code); }
}

let ethers;
try { ethers = require('ethers'); }
catch (e) { console.error('缺少 ethers，请先: npm install ethers@6'); process.exit(20); }
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
let userCfg = {};
try { userCfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config.json'), 'utf8').replace(/^﻿/, '')); } catch (e) { }

const TARGET = process.argv[2] || process.env.FTS_QUEUE_ADDR || userCfg.QUEUE_ADDR || '0xe2E751cF79A5Ce03fED12Abf15acFA7383E296bF';
const USDT_ADDR = process.env.FTS_USDT_ADDR || userCfg.USDT_ADDR || '0x55d398326f99059fF775485246999027B3197955';
const WATCH_ADDR = process.argv[3] || process.env.FTS_WATCH_ADDR || '';
const CHAIN_ID = Number(process.env.FTS_CHAIN_ID || userCfg.CHAIN_ID || 56);
const RPCS = (process.env.FTS_HTTP_POOL || (userCfg.HTTP_POOL || [
  // 2026-11 实测可用，与 core 默认池保持一致
  'https://bsc-dataseed.bnbchain.org',
  'https://bsc-dataseed1.bnbchain.org',
  'https://bsc-dataseed2.defibit.io',
  'https://bsc-rpc.publicnode.com',
  'https://bsc.publicnode.com',
  'https://bsc-mainnet.public.blastapi.io',
  'https://bsc.blockrazor.xyz',
  'https://bsc.meowrpc.com'
]).join(',')).split(',').map(s => s.trim()).filter(Boolean);

const G = '\x1b[32m', R = '\x1b[31m', Y = '\x1b[33m', B = '\x1b[36m', D = '\x1b[0m';
const withTimeout = (p, ms) => Promise.race([p, new Promise((_, j) => setTimeout(() => j(Object.assign(new Error('超时'), { code: 'TIMEOUT' })), ms))]);
const errText = e => `${e.code || '?'} ${String(e.shortMessage || e.reason || e.message || e).slice(0, 150)}`;
// 提示文案按平台显示对应的启动命令
const LAUNCH = process.env.FTS_LAUNCHER === 'ps1'
  ? 'powershell -ExecutionPolicy Bypass -File autofts.ps1'
  : (process.env.FTS_LAUNCHER === 'bash'
    ? 'bash autofts.sh'
    : (process.platform === 'win32' ? 'powershell -ExecutionPolicy Bypass -File autofts.ps1' : 'bash autofts.sh'));

// ---------- 函数签名候选 ----------
// 只写函数名+参数类型(不写返回类型)，这样即使猜错返回类型也能探测存在性
const CANDIDATES = {
  currentRound: ['currentRound(uint8)', 'currentRound(uint256)', 'currentRound(uint16)', 'currentRound()', 'currentRound(uint32)'],
  roundInfo: ['roundInfo(uint8,uint256)', 'roundInfo(uint256,uint256)', 'roundInfo(uint256)', 'roundInfo(uint8,uint256,address)', 'roundInfo(uint256,address)'],
  roomConfigs: ['roomConfigs(uint8)', 'roomConfigs(uint256)', 'roomConfigs()', 'roomConfigs(uint8,uint256)'],
  enterQueue: ['enterQueue(uint8,address)', 'enterQueue(uint256,address)', 'enterQueue(address)', 'enterQueue(uint8,address,uint256)', 'enterQueue(uint256)'],
  claimRefundAndAirdrop: ['claimRefundAndAirdrop(uint8,uint256)', 'claimRefundAndAirdrop(uint256,uint256)', 'claimRefundAndAirdrop(uint256)', 'claimRefundAndAirdrop()', 'claimRefundAndAirdrop(uint8,uint256,address)'],
  claimRefundOnly: ['claimRefundOnly(uint8,uint256)', 'claimRefundOnly(uint256,uint256)', 'claimRefundOnly(uint256)'],
  claimWin: ['claimWin(uint8,uint256,uint256)', 'claimWin(uint8,uint256)', 'claimWin(uint256,uint256,uint256)'],
  formLP: ['formLP(uint8)', 'formLP(uint256)'],
  roomCount: ['roomCount()'],
  pendingQuotaUsd: ['pendingQuotaUsd(address)']
};
// 写函数没有返回值，eth_call 通常返回空 -> 只能靠"字节码里有没有这个 selector"判断
const WRITE_FNS = new Set(['enterQueue', 'claimRefundAndAirdrop', 'claimRefundOnly', 'claimWin', 'formLP']);

const nParams = sig => sig.slice(sig.indexOf('(') + 1, -1).split(',').filter(Boolean).length;
const selectorOf = sig => { try { return ethers.FunctionFragment.from(sig).selector; } catch (e) { return null; } };

function fakeArgs(sig) {
  const fr = ethers.FunctionFragment.from(sig);
  return fr.inputs.map(i => {
    const t = i.type;
    if (t.startsWith('uint')) return 1;
    if (t === 'address') return '0x0000000000000000000000000000000000000001';
    if (t === 'bool') return true;
    if (t.startsWith('bytes')) return '0x';
    if (t === 'string') return 'x';
    return 0;
  });
}

// 宽松解码: 不知道返回类型时，按 32 字节切分，逐个给出"最像什么"的解读
function looseDecode(ret) {
  if (!ret || ret === '0x') return [];
  const body = ret.slice(2);
  const words = [];
  for (let i = 0; i + 64 <= body.length; i += 64) words.push('0x' + body.slice(i, i + 64));
  return words.map((w, idx) => {
    const v = BigInt(w);
    const hex = w.slice(2);
    const isAddr = /^0{24}[0-9a-fA-F]{40}$/.test(w);
    let guess;
    if (isAddr) guess = `address ${ethers.getAddress('0x' + hex.slice(24))}`;
    else if (v === 0n) guess = 'uint 0';
    else if (v === 1n) guess = 'uint 1 (也可能是 bool true)';
    else if (v > 1e15) guess = `uint ${v} (若按18位小数 = ${ethers.formatUnits(v, 18)})`;
    else if (v > 1_600_000_000 && v < 2_500_000_000) guess = `uint ${v} (看起来像时间戳 ${new Date(Number(v) * 1000).toLocaleString('zh-CN')})`;
    else guess = `uint ${v}`;
    return `      word[${idx}] ${guess}`;
  });
}

async function pickRpc() {
  const out = [];
  for (const u of RPCS) {
    const t0 = Date.now();
    try {
      const p = new ethers.JsonRpcProvider(u, CHAIN_ID, { staticNetwork: true });
      const bn = await withTimeout(p.getBlockNumber(), 20000);
      const cid = await withTimeout(p.getNetwork().then(n => Number(n.chainId)), 8000).catch(() => null);
      out.push({ u, ok: true, lat: Date.now() - t0, bn: Number(bn), cid });
    } catch (e) { out.push({ u, ok: false, err: errText(e) }); }
  }
  return out;
}

(async () => {
  console.log(B + '\n================ FTS 链上只读探针 ================' + D);
  console.log(`探测合约: ${TARGET}`);
  console.log(`USDT    : ${USDT_ADDR}`);
  console.log(`链 ID   : ${CHAIN_ID}`);
  console.log('说明    : 全程只读，不签名、不广播、不需要私钥\n');

  // ---------- 1. RPC ----------
  console.log(B + '--- 1. RPC 连通性 ---' + D);
  const rs = await pickRpc();
  let anyOk = false;
  for (const r of rs) {
    if (r.ok) {
      anyOk = true;
      const warn = (r.cid && r.cid !== CHAIN_ID) ? ` ${Y}⚠️ 链ID与目标(${CHAIN_ID})不符${D}` : '';
      console.log(`  ${G}✅${D} ${r.u} 延迟=${r.lat}ms 高度=${r.bn} chainId=${r.cid}${warn}`);
    } else console.log(`  ${R}❌${D} ${r.u} -> ${r.err}`);
  }
  if (!anyOk) { console.log(R + '\n结论: 没有任何 RPC 可用。检查网络 / 换节点(FTS_HTTP_POOL) / 确认没被防火墙拦。' + D); exitFlush(22); return; }
  const best = rs.filter(r => r.ok).sort((a, b) => a.lat - b.lat)[0];
  const provider = new ethers.JsonRpcProvider(best.u, CHAIN_ID, { staticNetwork: true });
  console.log(`  ${G}主用节点: ${best.u}${D}`);

  // ---------- 2. 合约存在性 ----------
  console.log(B + '\n--- 2. 目标地址上有没有合约 ---' + D);
  const code = await withTimeout(provider.getCode(TARGET), 20000).catch(e => { console.log('  读取字节码失败: ' + errText(e)); return '0x'; });
  const isContract = code && code !== '0x' && code !== '0x0';
  console.log(`  字节码长度: ${(code.length - 2) / 2} 字节`);
  if (!isContract) {
    console.log(R + '  ❌ 该地址上没有合约代码 —— 不是合约地址，脚本里的合约地址很可能是错的！' + D);
    console.log(Y + '  请到项目官方渠道重新核对地址，并确认链一致(BSC / ETH 地址不通用)。' + D);
    exitFlush(1);
    return;
  }
  console.log(`  ${G}✅ 是合约${D}` + ((code.length - 2) / 2 < 500 ? ` ${Y}(代码很短，很可能是代理合约 Proxy)${D}` : ''));

  // ---------- 3. 代理探测 ----------
  console.log(B + '\n--- 3. 代理合约探测 (真合约可能藏在小代码后面) ---' + D);
  const implSet = new Set();
  const SLOTS = ['0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc', '0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3'];
  for (const slot of SLOTS) {
    try {
      const v = await withTimeout(provider.getStorage(TARGET, slot), 20000).catch(() => null);
      if (v && v !== '0x' + '0'.repeat(64)) {
        const a = ethers.getAddress('0x' + v.slice(-40));
        if (a !== ethers.ZeroAddress) { implSet.add(a); console.log(`  槽位 ${slot.slice(0, 14)}... -> 实现合约 ${a}`); }
      }
    } catch (e) { }
  }
  for (const sig of ['implementation()', 'getImplementation()', 'target()', 'masterCopy()']) {
    try {
      const r = await withTimeout(provider.call({ to: TARGET, data: selectorOf(sig) }), 8000);
      if (r && r.length >= 66) {
        const a = ethers.getAddress('0x' + r.slice(-40));
        if (a !== ethers.ZeroAddress) { implSet.add(a); console.log(`  ${sig} -> ${a}`); }
      }
    } catch (e) { }
  }
  const implList = [...implSet];
  console.log(implList.length ? `  ${G}发现 ${implList.length} 个实现合约，一并扫描其字节码${D}` : '  未发现代理结构(按普通合约处理)');

  // ---------- 4. 函数签名探测 ----------
  console.log(B + '\n--- 4. 函数签名探测 (脚本能不能调得动，全看这里) ---' + D);
  const scan = [TARGET, ...implList];
  const bcs = new Map();
  for (const a of scan) { try { bcs.set(a, (await withTimeout(provider.getCode(a), 20000)).toLowerCase()); } catch (e) { bcs.set(a, ''); } }

  const found = {};
  for (const [fn, sigs] of Object.entries(CANDIDATES)) {
    console.log(`\n  ${B}[${fn}]${D}${WRITE_FNS.has(fn) ? ' (写函数: 主要看字节码是否命中)' : ''}`);
    found[fn] = [];
    for (const sig of sigs) {
      const sel = selectorOf(sig);
      if (!sel) continue;
      let inCode = false, where = '';
      for (const [a, bc] of bcs) { if (bc && bc.includes(sel.slice(2).toLowerCase())) { inCode = true; where = a === TARGET ? '主合约' : '实现合约'; break; } }
      let callOk = false, retLen = 0, note = '';
      try {
        const fr = ethers.FunctionFragment.from(sig);
        const enc = fr.inputs.length ? ethers.AbiCoder.defaultAbiCoder().encode(fr.inputs.map(i => i.type), fakeArgs(sig)).slice(2) : '';
        const r = await withTimeout(provider.call({ to: TARGET, data: sel + enc, from: '0x0000000000000000000000000000000000000001' }), 10000);
        retLen = (r.length - 2) / 2;
        callOk = retLen > 0;
        note = callOk ? `调用返回 ${retLen} 字节` : '调用返回空(写函数属正常)';
      } catch (e) { note = '调用失败: ' + errText(e).slice(0, 100); }

      const matched = WRITE_FNS.has(fn) ? inCode : (inCode || callOk);
      if (matched) {
        found[fn].push({ sig, sel, inCode, callOk });
        console.log(`    ${G}✔${D} ${sig}`);
        console.log(`      selector=${sel} | 字节码命中=${inCode ? '是(' + where + ')' : '否'} | ${note}`);
      } else {
        console.log(`    ${R}✘${D} ${sig}  (字节码无 / 调用失败)`);
      }
    }
    if (!found[fn].length) console.log(`    ${R}⚠️ 没找到匹配签名：这个函数可能不叫这个名字，或不在该合约上${D}`);
  }

  // ---------- 5. 读取真实数据 ----------
  console.log(B + '\n--- 5. 读取真实链上数据 ---' + D);
  const readRaw = async (label, sig, args) => {
    const sel = selectorOf(sig);
    const fr = ethers.FunctionFragment.from(sig);
    const enc = args.length ? ethers.AbiCoder.defaultAbiCoder().encode(fr.inputs.map(i => i.type), args).slice(2) : '';
    try {
      const r = await withTimeout(provider.call({ to: TARGET, data: sel + enc }), 10000);
      if (!r || r === '0x') { console.log(`  ${Y}○${D} ${label}: 无返回数据(写函数或该轮次不存在)`); return null; }
      const lines = looseDecode(r);
      console.log(`  ${G}✅${D} ${label} -> ${(r.length - 2) / 2} 字节:`);
      lines.slice(0, 12).forEach(l => console.log(l));
      if (lines.length > 12) console.log(`      ... 还有 ${lines.length - 12} 个字段`);
      return r;
    } catch (e) { console.log(`  ${R}❌${D} ${label}: ${errText(e)}`); return null; }
  };

  const curSig = (found.currentRound[0] && found.currentRound[0].sig) || 'currentRound(uint8)';
  const roomSig = (found.roomConfigs[0] && found.roomConfigs[0].sig) || 'roomConfigs(uint8)';
  const infoSig = (found.roundInfo[0] && found.roundInfo[0].sig) || 'roundInfo(uint8,uint256)';

  const curRaw = await readRaw('currentRound(0)', curSig, nParams(curSig) === 0 ? [] : [0]);
  // 逐个房间查票价(0=10U 1=50U 2=100U)，哪个房间在链上存在、票价多少，一眼看清
  // 候选里还有 roomConfigs(uint8,uint256) 这种 2 参数变体，只传一个参数会抛 ABI 编码错，
  // 和 roundInfo 一样处理: 参数个数对不上就跳过，别让它变成一行看不懂的 ❌
  const roomArgCount = nParams(roomSig);
  if (roomArgCount > 1) {
    console.log(`  ○ roomConfigs 候选(${roomSig})参数过多，跳过`);
  } else {
    for (const room of [0, 1, 2]) {
      await readRaw(`roomConfigs(${room})`, roomSig, roomArgCount === 0 ? [] : [room]);
    }
  }
  let curVal = null;
  if (curRaw) { try { curVal = BigInt('0x' + curRaw.slice(2, 66)); } catch (e) { } }
  // 候选签名里可能有 3 个参数的变体(roundInfo(uint8,uint256,address))，
  // 类型未知没法瞎补参数，参数个数对不上就直接跳过这条候选，别让它抛 ABI 编码错误
  const infoArgCount = nParams(infoSig);
  if (infoArgCount <= 2) {
    const infoArgs = infoArgCount === 0 ? []
      : (infoArgCount === 1 ? [0] : [0, curVal === null ? 1 : curVal]);
    await readRaw(`roundInfo(0, ${curVal === null ? '?' : curVal})`, infoSig, infoArgs);
  } else {
    console.log('  ○ roundInfo 候选参数过多，跳过');
  }

  // ---------- 6. USDT ----------
  console.log(B + '\n--- 6. USDT 合约 ---' + D);
  const uCode = await withTimeout(provider.getCode(USDT_ADDR), 20000).catch(() => '0x');
  console.log(`  USDT 地址有合约: ${uCode && uCode !== '0x' ? G + '是' : R + '否(地址错?)'}${D}`);
  const uRead = new ethers.Contract(USDT_ADDR, ['function decimals() view returns (uint8)', 'function symbol() view returns (string)', 'function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)'], provider);
  try { console.log(`  symbol=${await withTimeout(uRead.symbol(), 20000)} decimals=${await withTimeout(uRead.decimals(), 20000)}`); }
  catch (e) { console.log(`  ${Y}读取 symbol/decimals 失败(不影响使用): ${errText(e)}${D}`); }

  // ---------- 7. 钱包体检 ----------
  console.log(B + '\n--- 7. 钱包体检 (只读，不需要私钥) ---' + D);
  if (!WATCH_ADDR) {
    console.log(`  ${Y}未提供观察地址。用法: node probe.js <合约地址> <你的钱包地址>${D}`);
    console.log(`  ${Y}余额和授权额度都是链上公开信息，任何人可查，无需私钥。${D}`);
  } else if (!/^0x[a-fA-F0-9]{40}$/.test(WATCH_ADDR)) {
    console.log(`  ${R}地址格式不对: ${WATCH_ADDR}${D}`);
  } else {
    try {
      const bnb = await withTimeout(provider.getBalance(WATCH_ADDR), 20000);
      console.log(`  BNB 余额  : ${ethers.formatEther(bnb)} ${bnb < ethers.parseEther('0.01') ? Y + '(偏少，gas 可能不够)' + D : G + '(够用)' + D}`);
      const usdt = await withTimeout(uRead.balanceOf(WATCH_ADDR), 20000);
      console.log(`  USDT 余额 : ${ethers.formatUnits(usdt, 18)}`);
      const allow = await withTimeout(uRead.allowance(WATCH_ADDR, TARGET), 20000);
      console.log(`  已授权额度: ${ethers.formatUnits(allow, 18)} ${allow === 0n ? Y + '(0，首次入场需先发授权交易)' + D : G + '(已授权)' + D}`);
      // 老系统矿机额度(只有达到房间阈值才能 formLP 组机)
      try {
        const qRead = new ethers.Contract(TARGET, ['function pendingQuotaUsd(address) view returns (uint256)', 'function roomConfigs(uint8 room) view returns (uint256,uint256,uint256,uint256,uint256,bool,uint16,uint16,uint32)'], provider);
        const q = await withTimeout(qRead.pendingQuotaUsd(WATCH_ADDR), 20000);
        const rc = await withTimeout(qRead.roomConfigs(0), 20000);
        console.log(`  矿机额度  : ${ethers.formatUnits(q, 18)}U / 阈值 ${ethers.formatUnits(rc[4], 18)}U`);
      } catch (e) { /* 新队列也可能没有老额度接口，忽略 */ }
    } catch (e) { console.log(`  ${R}读取失败: ${errText(e)}${D}`); }
  }

  // ---------- 结论 ----------
  console.log(B + '\n================ 探测结论 ================' + D);
  const missing = Object.entries(found).filter(([, v]) => !v.length).map(([k]) => k);
  if (missing.length) {
    console.log(R + `❌ 链上找不到这些函数: ${missing.join(', ')}` + D);
    console.log(Y + '   常见原因: 合约地址错了 / 链选错了 / 函数名或参数类型变过 / 合约是代理且实现已更换。' + D);
    console.log(Y + '   处理: 用上面标 ✔ 的签名更新 config.json，或向项目方索取正确地址与 ABI。' + D);
  } else {
    console.log(G + '✅ 脚本用到的函数在链上都找得到，合约地址与 ABI 基本对得上。' + D);
  }
  console.log('\n建议的下一步:');
  console.log('  1) 若上面有 ❌，先修地址/ABI，别急着跑交易');
  console.log('  2) 确认无误后: ' + LAUNCH + ' --init 配置账号');
  console.log('  3) 先跑: ' + LAUNCH + ' --selftest  (只读体检，不花钱)');
  console.log('  4) 再跑: ' + LAUNCH + ' --dry-run   (全流程演练，交易不上链)');
  console.log('  5) 最后: ' + LAUNCH + ' --run       (正式交易)');
  console.log(`\n本次使用节点: ${best.u}`);
  exitFlush(missing.length ? 1 : 0);
})().catch(e => { console.error(R + '探针自身异常: ' + (e.stack || e.message) + D); exitFlush(23); });
PROBE_EOF
node --check core.js || die "core.js 生成异常(语法错误)"
node --check probe.js || die "probe.js 生成异常(语法错误)"
cat << 'UPDATEJS_EOF' > update.js
#!/usr/bin/env node
'use strict';
/**
 * FTS 脚本自更新器（支持私有仓库 / 公开仓库）
 * 用法:
 *   node update.js --check  --current=1.7.1 --asset=autofts.sh [--quiet]
 *   node update.js --apply  --current=1.7.1 --asset=autofts.sh
 *   node update.js --auto   --current=1.7.1 --asset=autofts.sh
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
UPDATEJS_EOF
node --check update.js || die "update.js 生成异常(语法错误)"
ok_msg "核心引擎 core.js + 只读探针 probe.js + 更新器 update.js 已写入"

# --encrypt / --sync-web 都在"要求输入私钥"的向导之前退出
if [ "$MODE" = "encrypt" ]; then
  node core.js encrypt
  exit $?
fi
if [ "$MODE" = "sync-web" ]; then
  node core.js sync-web
  exit $?
fi

# --probe 是纯只读探测，必须在"要求输入私钥"之前退出
if [ "$MODE" = "probe" ]; then
  echo ""
  # 防止把 --help 之类的开关当成合约地址传下去
  case "$PROBE_ARGS" in
    -*) warn_msg "probe 只接受 <合约地址> [钱包地址]，不要带 -- 参数"; PROBE_ARGS="" ;;
  esac
  # shellcheck disable=SC2086
  node probe.js $PROBE_ARGS
  exit $?
fi

# --update: 原地替换脚本（私有仓库需在 config.json 写 UPDATE_TOKEN）
if [ "$MODE" = "update" ]; then
  echo ""
  node update.js --apply --current="1.7.1" --asset=autofts.sh
  exit $?
fi

# ==============================================================
# [3/5] 引导配置页
# ==============================================================
# 设计原则: 只放"日常真的要改"的项 —— 房间 / 抢位区间 / 延迟 / 手续费 / 领取间隔 / 最低BNB / 账号。
# 节点池、并发数、超时这些调错就出事的高级参数不放在这里，需要时直接改 config.json。

WIZ_ROOMS="0,1,2"; WIZ_MIN="30"; WIZ_MAX="60"; WIZ_DELAY="0"
WIZ_GAS_MODE="fixed"; WIZ_GAS_FIXED="0.05"; WIZ_GAS_MAX="10"; WIZ_GAS_MULT="1.25"
WIZ_CLAIM="20"; WIZ_BNB="0.005"
WIZ_MINER="0"; WIZ_MINER_USD="100"; WIZ_MINER_MODE="old"; WIZ_CLAIM_WIN="1"
WIZ_UPDATE_TOKEN=""
# v1.7.1: 自动更新开关与 token 解绑；默认关，公开仓库无需 token 也能检查更新
WIZ_AUTO_UPDATE="0"
# FTS 自动买卖(默认关、阈值留空不设默认值)
WIZ_BUY_ON="0"; WIZ_BUY_MAX_PRICE=""; WIZ_BUY_MAX_TOTAL=""
WIZ_SELL_ON="0"; WIZ_SELL_MODE="fixed"; WIZ_SELL_PRICE=""; WIZ_SELL_AMOUNT=""
# 授权额度: mode=rounds(按场数) / usd(按U数)
WIZ_APPROVE_MODE="rounds"; WIZ_APPROVE_ROUNDS="1"; WIZ_APPROVE_USD=""

# ---- 读现有 config.json 作为默认值 ----
wiz_load() {
  local k v
  [ -f config.json ] || return 0
  while IFS='=' read -r k v; do
    [ -n "$v" ] || continue
    case "$k" in
      ROOMS)            WIZ_ROOMS="$v" ;;
      SNIPE_MIN_COUNT)  WIZ_MIN="$v" ;;
      SNIPE_MAX_COUNT)  WIZ_MAX="$v" ;;
      SNIPE_DELAY_MS)   WIZ_DELAY="$v" ;;
      # 注意: $(( v / 1000 )) 遇到 "abc" 会当成变量名，set -u 下直接 unbound，
      # 所以必须先确认是纯数字再算
      CLAIM_INTERVAL_MS)
        if [[ "$v" =~ ^[0-9]+$ ]]; then
          WIZ_CLAIM="$(( v / 1000 ))"
          [ "$WIZ_CLAIM" -lt 10 ] && WIZ_CLAIM=10
        fi ;;
      MIN_BNB_GAS)      WIZ_BNB="$v" ;;
      GAS_MODE)         if [ "$v" = "auto" ]; then WIZ_GAS_MODE="auto"; else WIZ_GAS_MODE="fixed"; fi ;;
      GAS_GWEI)         WIZ_GAS_FIXED="$v"; WIZ_GAS_MODE="fixed" ;;
      GAS_MAX_GWEI)     WIZ_GAS_MAX="$v" ;;
      GAS_MULT)         WIZ_GAS_MULT="$v" ;;
      MINER_ENABLED)    if [ "$v" = "1" ]; then WIZ_MINER="1"; else WIZ_MINER="0"; fi ;;
      MINER_USD)        WIZ_MINER_USD="$v" ;;
      CLAIM_WIN)        if [ "$v" = "0" ]; then WIZ_CLAIM_WIN="0"; else WIZ_CLAIM_WIN="1"; fi ;;
      MINER_MODE)       case "$v" in old|new|both) WIZ_MINER_MODE="$v" ;; esac ;;
      FLEX)             case "$v" in 1) WIZ_FLEX="1" ;; *) WIZ_FLEX="0" ;; esac ;;
      UPDATE_TOKEN)     WIZ_UPDATE_TOKEN="$v" ;;
      AUTO_UPDATE)      case "$v" in 1|true|on) WIZ_AUTO_UPDATE="1" ;; *) WIZ_AUTO_UPDATE="0" ;; esac ;;
      TRADE_BUY)        case "$v" in 1) WIZ_BUY_ON="1" ;; *) WIZ_BUY_ON="0" ;; esac ;;
      TRADE_BUY_MAX_PRICE) WIZ_BUY_MAX_PRICE="$v" ;;
      TRADE_BUY_MAX_TOTAL) WIZ_BUY_MAX_TOTAL="$v" ;;
      TRADE_SELL)       case "$v" in 1) WIZ_SELL_ON="1" ;; *) WIZ_SELL_ON="0" ;; esac ;;
      TRADE_SELL_MODE)  case "$v" in fixed|spotminus) WIZ_SELL_MODE="$v" ;; esac ;;
      TRADE_SELL_PRICE) WIZ_SELL_PRICE="$v" ;;
      TRADE_SELL_AMOUNT) WIZ_SELL_AMOUNT="$v" ;;
      APPROVE_MODE)     case "$v" in rounds|usd) WIZ_APPROVE_MODE="$v" ;; esac ;;
      APPROVE_ROUNDS)   WIZ_APPROVE_ROUNDS="$v" ;;
      APPROVE_USD)      WIZ_APPROVE_USD="$v" ;;
    esac
  done < <(node -e '
    const fs=require("fs");
    let c={}; try{c=JSON.parse(fs.readFileSync("config.json","utf8"))}catch(e){}
    const put=(k,v)=>{ if(v!==undefined&&v!==null&&v!=="") console.log(k+"="+(Array.isArray(v)?v.join(","):String(v))); };
    put("ROOMS",c.ROOMS);
    put("SNIPE_MIN_COUNT",c.SNIPE_MIN_COUNT);
    put("SNIPE_MAX_COUNT",c.SNIPE_MAX_COUNT);
    put("SNIPE_DELAY_MS",c.SNIPE_DELAY_MS);
    put("CLAIM_INTERVAL_MS",c.CLAIM_INTERVAL_MS);
    put("MIN_BNB_GAS",c.MIN_BNB_GAS);
    console.log("GAS_MODE="+(c.GAS_GWEI===null?"auto":"fixed"));
    put("GAS_GWEI",c.GAS_GWEI);
    put("GAS_MAX_GWEI",c.GAS_MAX_GWEI);
    put("GAS_MULT",c.GAS_MULT);
    console.log("MINER_ENABLED="+(c.MINER_ENABLED===true||c.MINER_ENABLED==="true"||c.MINER_ENABLED===1?"1":"0"));
    put("MINER_USD",c.MINER_USD);
    console.log("CLAIM_WIN="+(c.CLAIM_WIN===false||c.CLAIM_WIN===0||c.CLAIM_WIN==="0"||c.CLAIM_WIN==="false"?"0":"1"));
    put("MINER_MODE",c.MINER_MODE);
    console.log("FLEX="+(c.FLEX_DECISION===true||c.FLEX_DECISION==="true"||c.FLEX_DECISION===1?"1":"0"));
    console.log("TRADE_BUY="+(c.TRADE_BUY_ENABLED===true||c.TRADE_BUY_ENABLED==="true"||c.TRADE_BUY_ENABLED===1?"1":"0"));
    put("TRADE_BUY_MAX_PRICE",c.TRADE_BUY_MAX_PRICE);
    put("TRADE_BUY_MAX_TOTAL",c.TRADE_BUY_MAX_TOTAL);
    console.log("TRADE_SELL="+(c.TRADE_SELL_ENABLED===true||c.TRADE_SELL_ENABLED==="true"||c.TRADE_SELL_ENABLED===1?"1":"0"));
    put("TRADE_SELL_MODE",c.TRADE_SELL_MODE);
    put("TRADE_SELL_PRICE",c.TRADE_SELL_PRICE);
    put("TRADE_SELL_AMOUNT",c.TRADE_SELL_AMOUNT);
    // 授权额度: APPROVE_USD 有值=按U数; 否则按场数(APPROVE_ROUNDS)
    if(c.APPROVE_USD!==undefined&&c.APPROVE_USD!==null){console.log("APPROVE_MODE=usd");put("APPROVE_USD",c.APPROVE_USD);}
    else{console.log("APPROVE_MODE=rounds");put("APPROVE_ROUNDS",c.APPROVE_ROUNDS);}
    console.log("AUTO_UPDATE="+(c.AUTO_UPDATE===true||c.AUTO_UPDATE===1||c.AUTO_UPDATE==="true"?"1":"0"));
  ' 2>/dev/null)
  # 兼容旧配置里 CLAIM_INTERVAL_MS 直接是毫秒
  [ -n "$WIZ_CLAIM" ] || WIZ_CLAIM=20

  # 手改 config.json 写成 "abc" 时，后面的 [ -ge ] 会报 integer expression expected，
  # 向导的默认值也会变成非法值。这里统一兜一道，非法就回默认。
  _is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
  _is_num "$WIZ_MIN"       || WIZ_MIN=30
  _is_num "$WIZ_MAX"       || WIZ_MAX=60
  _is_num "$WIZ_DELAY"     || WIZ_DELAY=0
  _is_num "$WIZ_CLAIM"     || WIZ_CLAIM=20
  _is_num "$WIZ_BNB"       || WIZ_BNB=0.005
  _is_num "$WIZ_GAS_MAX"   || WIZ_GAS_MAX=10
  _is_num "$WIZ_GAS_MULT"  || WIZ_GAS_MULT=1.25
  _is_num "$WIZ_GAS_FIXED" || WIZ_GAS_FIXED=0.05
  _is_num "$WIZ_MINER_USD" || WIZ_MINER_USD=100
  case "$WIZ_MINER" in 0|1) ;; *) WIZ_MINER=0 ;; esac
  case "$WIZ_CLAIM_WIN" in 0|1) ;; *) WIZ_CLAIM_WIN=1 ;; esac
  case "$WIZ_MINER_MODE" in old|new|both) ;; *) WIZ_MINER_MODE=old ;; esac
  case "$WIZ_FLEX" in 0|1) ;; *) WIZ_FLEX=0 ;; esac
  [[ "$WIZ_ROOMS" =~ ^[0-2](,[0-2])*$ ]] || WIZ_ROOMS="0,1,2"
}

wiz_rooms_text() {
  local out="" i name
  for i in ${WIZ_ROOMS//,/ }; do
    case "$i" in 0) name="10U" ;; 1) name="50U" ;; 2) name="100U" ;; *) name="房间$i" ;; esac
    out="${out:+$out · }${name}"
  done
  echo "${out:-未选择}"
}

wiz_gas_text() {
  if [ "$WIZ_GAS_MODE" = "fixed" ]; then
    echo "固定 ${WIZ_GAS_FIXED} gwei"
  else
    echo "自动(链上价 ×${WIZ_GAS_MULT}，上限 ${WIZ_GAS_MAX} gwei)"
  fi
}

wiz_miner_text() {
  if [ "$WIZ_MINER" != "1" ]; then echo "关"; return; fi
  case "$WIZ_MINER_MODE" in
    new)  echo "开(新版: 按矿机额度实额支付)" ;;
    both) echo "开(新版按额度 + 老系统固定 ${WIZ_MINER_USD} USDT)" ;;
    *)    echo "开(老系统: 固定付 ${WIZ_MINER_USD} USDT)" ;;
  esac
}

wiz_claimwin_text() {
  if [ "$WIZ_CLAIM_WIN" = "1" ]; then
    echo "中奖后自动领取矿机额度"
  else
    echo "中奖后不领取(放弃该奖励)"
  fi
}

wiz_account_count() {
  node -e 'try{const d=JSON.parse(require("fs").readFileSync("wallets.json","utf8"));console.log((d.wallets||[]).length)}catch(e){console.log(0)}' 2>/dev/null || echo 0
}

wiz_header() {
  [ -t 1 ] && clear 2>/dev/null
  echo ""
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║          FTS 自动打金 · 引导配置                   ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo "    账号数量   : $(wiz_account_count) 个"
  echo "    参与房间   : $(wiz_rooms_text)"
  echo "    抢位区间   : ${WIZ_MIN} ~ ${WIZ_MAX} 人"
  echo "    抢单延迟   : ${WIZ_DELAY} ms"
  echo "    手续费     : $(wiz_gas_text)"
  echo "    领取间隔   : ${WIZ_CLAIM} 秒"
  echo "    最低 BNB   : ${WIZ_BNB}"
  echo "    组矿机     : $(wiz_miner_text)"
  echo "    中奖处理   : $(wiz_claimwin_text)"
  echo "    灵活资金   : $(wiz_flex_text)"
  echo "    FTS 买入   : $(wiz_buy_text)"
  echo "    FTS 卖出   : $(wiz_sell_text)"
  echo "    授权额度   : $(wiz_approve_text)"
  echo "    自动更新   : $(wiz_update_text)"
  echo "  ────────────────────────────────────────────────────"
}

wiz_ask_int() {   # 提示 默认值 最小 最大 -> REPLY
  local p="$1" d="$2" lo="$3" hi="$4" v
  while true; do
    read -r -p "    $p [$d]: " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
    v="${v:-$d}"
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then warn_msg "请输入整数"; continue; fi
    if [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then warn_msg "取值范围 ${lo} ~ ${hi}"; continue; fi
    REPLY="$v"; return 0
  done
}

wiz_ask_dec() {   # 提示 默认值 最小 最大 -> REPLY（支持小数）
  local p="$1" d="$2" lo="$3" hi="$4" v
  while true; do
    read -r -p "    $p [$d]: " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
    v="${v:-$d}"
    if [[ ! "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then warn_msg "请输入数字"; continue; fi
    if ! awk -v a="$v" -v lo="$lo" -v hi="$hi" 'BEGIN{exit !((a+0)>=(lo+0) && (a+0)<=(hi+0))}'; then
      warn_msg "取值范围 ${lo} ~ ${hi}"; continue
    fi
    REPLY="$v"; return 0
  done
}

# ---- 各项设置 ----
wiz_edit_rooms() {
  local v out="" i
  wiz_header
  echo "    选择参与的房间(可多选，逗号分隔)"
  echo "      0 = 10U    1 = 50U    2 = 100U"
  echo "    当前: ${WIZ_ROOMS}"
  read -r -p "    请输入(如 0 或 0,1): " v
  v="${v:-$WIZ_ROOMS}"; v="${v// /}"
  if [[ ! "$v" =~ ^[0-2](,[0-2])*$ ]]; then warn_msg "只能填 0/1/2，用英文逗号分隔"; sleep 1; return; fi
  for i in 0 1 2; do case ",$v," in *",$i,"*) out="${out:+$out,}$i" ;; esac; done
  WIZ_ROOMS="$out"
}

wiz_edit_range() {
  local lo hi
  wiz_header
  echo "    抢位区间: 当前轮排队人数落在这个范围内才入场"
  echo "      太小 -> 还没轮到你名额就满了；太大 -> 中签率低"
  wiz_ask_int "人数下限" "$WIZ_MIN" 0 9999; lo="$REPLY"
  wiz_ask_int "人数上限" "$WIZ_MAX" 1 10000; hi="$REPLY"
  if [ "$lo" -ge "$hi" ]; then warn_msg "下限必须小于上限，本次修改已放弃"; sleep 1; return; fi
  WIZ_MIN="$lo"; WIZ_MAX="$hi"
}

wiz_edit_delay() {
  wiz_header
  echo "    抢单延迟: 轮次开始后等待多少毫秒再入场"
  echo "      0 = 立即入场；适当延迟可避开开轮瞬间的拥堵"
  wiz_ask_int "延迟(毫秒)" "$WIZ_DELAY" 0 60000
  WIZ_DELAY="$REPLY"
}

wiz_edit_gas() {
  local ch
  wiz_header
  echo "    ---- 手续费 / Gas ----"
  echo "      [1] 固定 gas 价(默认 0.05 gwei，每笔都按这个价发)"
  echo "      [2] 自动: 按链上实时价上浮，并设上限保护"
  echo "    当前: $(wiz_gas_text)"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  case "$ch" in
    2) wiz_ask_dec "上浮倍数(相对链上实时价)" "$WIZ_GAS_MULT" 1 5
       WIZ_GAS_MULT="$REPLY"
       wiz_ask_dec "gas 上限 (gwei，防止链上拥堵时被扣爆)" "$WIZ_GAS_MAX" 0.5 200
       WIZ_GAS_MAX="$REPLY"; WIZ_GAS_MODE="auto" ;;
    *) wiz_ask_dec "固定 gas 价 (gwei)" "${WIZ_GAS_FIXED:-0.05}" 0.01 200
       WIZ_GAS_FIXED="$REPLY"; WIZ_GAS_MODE="fixed" ;;
  esac
}

wiz_edit_claim() {
  wiz_header
  echo "    领取返利间隔: 每隔多少秒扫一次可领取的退款/空投"
  echo "      太小浪费节点额度，太大会漏领"
  wiz_ask_int "间隔(秒)" "$WIZ_CLAIM" 10 3600
  WIZ_CLAIM="$REPLY"
}

wiz_edit_bnb() {
  wiz_header
  echo "    最低 BNB 余额: 低于这个值只提醒，不中断运行"
  wiz_ask_dec "最低 BNB" "$WIZ_BNB" 0 1
  WIZ_BNB="$REPLY"
}

wiz_update_text() {
  local sw="关"
  [ "$WIZ_AUTO_UPDATE" = "1" ] && sw="开"
  if [ -n "$WIZ_UPDATE_TOKEN" ]; then
    echo "自动更新=$sw | Token 已配置（${WIZ_UPDATE_TOKEN:0:4}****${WIZ_UPDATE_TOKEN: -4}）"
  else
    echo "自动更新=$sw | Token 未配置（公开仓库无需 token）"
  fi
}

wiz_edit_update() {
  local ch tok
  wiz_header
  echo "    ---- 自动更新开关 / Token ----"
  echo "      公开仓库无需 token；只有私有仓库才需要 GitHub 只读 token"
  echo "      自动更新默认关闭，开启后仍只在空闲窗口替换，不会打断抢单"
  echo "    当前: $(wiz_update_text)"
  read -r -p "    是否启用自动更新? [y/N]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  case "$ch" in
    y|Y|1) WIZ_AUTO_UPDATE="1" ;;
    n|N|0|"") WIZ_AUTO_UPDATE="0" ;;
    *) warn_msg "无效选择，开关保持不变" ;;
  esac
  read -r -s -p "    粘贴 Token (仅私有仓库需要；直接回车保持，输入 - 清除): " tok || { echo; die "输入已结束(EOF)，配置向导退出"; }
  echo ""
  if [ -z "$tok" ]; then return 0; fi
  if [ "$tok" = "-" ]; then
    WIZ_UPDATE_TOKEN=""
    ok_msg "已清除 Token（不影响自动更新开关）"
    return 0
  fi
  case "$tok" in
    gh[pousr]_*|github_pat_*) ;;
    *) warn_msg "看起来不像 GitHub token，仍按输入保存" ;;
  esac
  WIZ_UPDATE_TOKEN="$tok"
  ok_msg "已保存 Token（明文写入本地 config.json，请自行收紧文件权限）"
}

wiz_edit_miner() {
  local ch
  wiz_header
  echo "    ---- 中奖处理 / 组矿机 ----"
  echo "      说明: 每轮 100 席抽 2 名中奖者，由链上 VRF 随机决定，脚本无法操控中不中奖。"
  echo "            中奖 = 门票自动换成 FTS + 获得等额矿机额度(需在 48 小时内领取)。"
  echo "            老系统保留 formLP 接口: 老额度 >= 房间阈值(通常 100U) 后，"
  echo "            固定支付 100 USDT + 等值 FTS 即可组机，与额度多少无关。"
  echo "    当前中奖处理: $(wiz_claimwin_text)"
  echo "      [1] 中奖后自动领取额度    [2] 中奖后不领取"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" = "2" ]; then WIZ_CLAIM_WIN="0"; else WIZ_CLAIM_WIN="1"; fi
  echo ""
  echo "    当前组矿机: $(wiz_miner_text)"
  echo "      [1] 开启组矿机    [2] 关闭"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" = "1" ]; then
    WIZ_MINER="1"
    echo ""
    echo "    组机模式: 老额度按固定 100U 支付；新版额度按额度实额支付"
    echo "      [1] 只用老额度(固定金额)   [2] 只用新版额度   [3] 两者都组"
    read -r -p "    请选择 [1/2/3]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
    case "$ch" in
      2) WIZ_MINER_MODE="new" ;;
      3) WIZ_MINER_MODE="both" ;;
      *) WIZ_MINER_MODE="old" ;;
    esac
    if [ "$WIZ_MINER_MODE" != "new" ]; then
      wiz_ask_dec "老系统组机固定支付(USDT)" "$WIZ_MINER_USD" 1 10000
      WIZ_MINER_USD="$REPLY"
    fi
  else
    WIZ_MINER="0"
  fi
}

wiz_flex_text() {
  if [ "$WIZ_FLEX" = "1" ]; then echo "开启"; else echo "关闭"; fi
}

wiz_edit_flex() {
  local ch
  wiz_header
  echo "    ---- 灵活资金决策 ----"
  echo "      开启后: 当某账号 USDT 或 BNB 不足以入场/组机时，"
  echo "      自动从其余富余账号凑 USDT / 匀 BNB 完成本次操作(真实链上转账)。"
  echo "      关闭(默认): 各账号独立，不足即跳过，不互相转钱。"
  echo "    当前: $(wiz_flex_text)"
  echo "      [1] 开启    [2] 关闭"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" = "1" ]; then WIZ_FLEX="1"; else WIZ_FLEX="0"; fi
}

wiz_buy_text() {
  if [ "$WIZ_BUY_ON" = "1" ]; then
    echo "开启 (单价≤${WIZ_BUY_MAX_PRICE:-未设}U, 总额≤${WIZ_BUY_MAX_TOTAL:-未设}U)"
  else echo "关闭"; fi
}

wiz_edit_buy() {
  local ch v
  wiz_header
  echo "    ---- FTS 自动买入 (默认关闭) ----"
  echo "      监控市场挂单，当单价低于你设定的值时代为吃单；总额不超过上限。"
  echo "      阈值不设默认值，必须自己填。留空=不启用对应限制。"
  echo "    当前: $(wiz_buy_text)"
  echo "      [1] 开启/修改    [2] 关闭"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" != "1" ]; then WIZ_BUY_ON="0"; return; fi
  WIZ_BUY_ON="1"
  read -r -p "    最高买入单价 (USDT/FTS，如 0.45，留空不设): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ -n "$v" ]; then
    if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && [ "$(echo "$v > 0" | bc 2>/dev/null || echo 1)" = "1" ]; then WIZ_BUY_MAX_PRICE="$v"; else warn_msg "无效数字，保持原值"; fi
  fi
  read -r -p "    买入总额上限 (USDT，留空不设): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ -n "$v" ]; then
    if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then WIZ_BUY_MAX_TOTAL="$v"; else warn_msg "无效数字，保持原值"; fi
  fi
  sleep 1
}

wiz_sell_text() {
  if [ "$WIZ_SELL_ON" = "1" ]; then
    if [ "$WIZ_SELL_MODE" = "fixed" ]; then
      echo "开启 (固定价 ${WIZ_SELL_PRICE:-未设}U, 数量 ${WIZ_SELL_AMOUNT:-未设} FTS)"
    else
      echo "开启 (时价减 ${WIZ_SELL_PRICE:-未设}U, 数量 ${WIZ_SELL_AMOUNT:-未设} FTS)"
    fi
  else echo "关闭"; fi
}

wiz_edit_sell() {
  local ch v
  wiz_header
  echo "    ---- FTS 自动卖出 (默认关闭) ----"
  echo "      读取 FTS 真实价格(DEX池储备，不读市场挂单价)。达到条件时自动挂单。"
  echo "      阈值不设默认值，必须自己填。"
  echo "    当前: $(wiz_sell_text)"
  echo "      [1] 开启/修改    [2] 关闭"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" != "1" ]; then WIZ_SELL_ON="0"; return; fi
  WIZ_SELL_ON="1"
  echo "      卖出价模式:"
  echo "        [1] 固定价: 真实价 >= 你设的值时，按该价挂单"
  echo "        [2] 时价减差值: 挂单价 = 真实价 - 你设的差值"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" = "2" ]; then WIZ_SELL_MODE="spotminus"; else WIZ_SELL_MODE="fixed"; fi
  if [ "$WIZ_SELL_MODE" = "fixed" ]; then
    read -r -p "    固定卖出单价 (USDT/FTS，留空不设): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
  else
    read -r -p "    时价减多少 (USDT/FTS，如 0.02，留空不设): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
  fi
  if [ -n "$v" ]; then
    if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then WIZ_SELL_PRICE="$v"; else warn_msg "无效数字，保持原值"; fi
  fi
  read -r -p "    卖出数量 (FTS，留空不设): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ -n "$v" ]; then
    if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then WIZ_SELL_AMOUNT="$v"; else warn_msg "无效数字，保持原值"; fi
  fi
  sleep 1
}

wiz_approve_text() {
  if [ "$WIZ_APPROVE_MODE" = "usd" ]; then
    if [ "${WIZ_APPROVE_USD:-}" = "0" ]; then echo "按 U 数: 0 已废弃，将按 1 场票价授权"; else echo "按 U 数: 每次授权 ${WIZ_APPROVE_USD:-未设} U (上限 100U)"; fi
  else
    echo "按场数: 每次授权 ${WIZ_APPROVE_ROUNDS:-1} 场的票价 (上限 3 场)"
  fi
}

wiz_edit_approve() {
  local ch v
  wiz_header
  echo "    ---- 授权额度 (USDT approve 的大小) ----"
  echo "      每轮入场前都会检查授权，不足时自动补授权。这里决定补多少："
  echo "        按场数: 授权 = 当前房间票价 x 场数 (例如 10U 房 x 3 场 = 30U)"
  echo "        按 U 数: 授权 = 固定金额 (v1.7.1 起填 0 已废弃，按 1 场票价处理)"
  echo "      上限: 按场数最多 3 场、按 U 数最多 100U。approve 不锁资金，减小的是 spender 可划走的上限，不是资金占用。"
  echo "    当前: $(wiz_approve_text)"
  echo "      [1] 按场数    [2] 按 U 数"
  read -r -p "    请选择 [1/2]: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
  if [ "$ch" = "2" ]; then
    WIZ_APPROVE_MODE="usd"
    read -r -p "    每次授权多少 U (填 0 已废弃，将按 1 场票价): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
    if [ -n "$v" ]; then
      if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then WIZ_APPROVE_USD="$v"; else warn_msg "无效数字，保持原值"; fi
    fi
    [ -n "$WIZ_APPROVE_USD" ] || WIZ_APPROVE_USD="1"
  else
    WIZ_APPROVE_MODE="rounds"
    read -r -p "    每次授权多少场的票价 (整数，默认 1): " v || { echo; die "输入已结束(EOF)，配置向导退出"; }
    if [ -n "$v" ]; then
      if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 100 ]; then WIZ_APPROVE_ROUNDS="$v"; else warn_msg "需为 1~100 的整数，保持原值"; fi
    fi
  fi
  sleep 1
}

# ---- 推荐人自动检测(读链上 referrerOfV2) ----
detect_referrer() {
  printf '%s' "$1" | node -e '
const { JsonRpcProvider, Contract } = require("ethers");
(async () => {
  const addr = require("fs").readFileSync(0, "utf8").trim();
  const abi = ["function referrerOfV2(address) view returns (address)"];
  for (const u of ["https://bsc-rpc.publicnode.com", "https://1rpc.io/bnb"]) {
    try {
      const p = new JsonRpcProvider(u, 56, { staticNetwork: true });
      const c = new Contract("0xe2E751cF79A5Ce03fED12Abf15acFA7383E296bF", abi, p);
      const r = await Promise.race([
        c.referrerOfV2(addr),
        new Promise((_, j) => setTimeout(() => j(new Error("timeout")), 12000))
      ]);
      console.log(r);
      process.exit(0);
    } catch (e) { }
  }
  console.log("");
})();
' 2>/dev/null
}

# ---- 账号管理 ----
wiz_add_account() {
  local pk addr ref
  wiz_header
  echo "    ---- 添加账号 ----"
  [ -f wallets.json ] || echo '{"wallets": []}' > wallets.json
  # read 在 stdin 到 EOF 时返回非 0 且变量为空，不处理会变成死循环刷错误
  while true; do
    read -r -s -p "    私钥 (64位hex，可不带0x，输入不显示): " pk || { echo; die "输入已结束(EOF)，配置向导退出"; }
    echo
    pk="${pk#0x}"
    if [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then break; fi
    warn_msg "私钥格式错误(必须是 64 位十六进制)"
  done
  while true; do
    read -r -p "    钱包地址 (0x开头): " addr || { echo; die "输入已结束(EOF)，配置向导退出"; }
    if [[ "$addr" =~ ^0x[a-fA-F0-9]{40}$ ]]; then break; fi
    warn_msg "地址格式错误"
  done
  echo "    推荐人地址: 直接回车 = 自动检测链上绑定；确认没有推荐人可填 0x0000000000000000000000000000000000000000"
  while true; do
    read -r -p "    推荐人地址 [自动检测]: " ref || { echo; die "输入已结束(EOF)，配置向导退出"; }
    ref="${ref// /}"
    if [ -z "$ref" ]; then
      echo "    正在链上查询推荐关系..."
      ref="$(detect_referrer "$addr")"
      if [[ "$ref" =~ ^0x[a-fA-F0-9]{40}$ ]] && [ "${ref,,}" != "0x0000000000000000000000000000000000000000" ]; then
        ok_msg "已自动识别推荐人: $ref"
      else
        warn_msg "链上没有已绑定的推荐人，将使用零地址（无推荐人）"
        ref="0x0000000000000000000000000000000000000000"
      fi
      break
    fi
    if [[ "$ref" =~ ^0x[a-fA-F0-9]{40}$ ]]; then break; fi
    warn_msg "地址格式错误（0x + 40 位十六进制），或直接回车自动检测"
  done
  # 不再写入每个账号独立的抢位设置，统一由引导页的全局配置控制。
  # 私钥不放进环境变量(同用户可通过 /proc/<pid>/environ 读到)，改从 stdin 传
  printf '%s\n%s\n%s\n' "$pk" "$addr" "$ref" | node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(0, "utf8").split("\n");
    const pk = (lines[0] || "").trim();
    const addr = (lines[1] || "").trim();
    const ref = (lines[2] || "").trim();
    // v1.7.1: 落盘前即时校验私钥是否对应该地址，避免错的私钥明文写进 wallets.json
    const { Wallet } = require("ethers");
    const derived = new Wallet("0x" + pk).address;
    if (derived.toLowerCase() !== addr.toLowerCase()) {
      console.error("私钥与地址不匹配(实际 " + derived + ")，未写入"); process.exit(3);
    }
    const d = JSON.parse(fs.readFileSync("wallets.json", "utf8"));
    if (d.wallets.some(w => String(w.ADDRESS).toLowerCase() === addr.toLowerCase())) {
      console.error("该地址已在列表中"); process.exit(2);
    }
    d.wallets.push({ PRIVATE_KEY: pk, ADDRESS: addr, REFERRER: ref });
    const tmp = "wallets.json.tmp";
    fs.writeFileSync(tmp, JSON.stringify(d, null, 2), { mode: 0o600 });
    // rename 失败时别把明文私钥留在 .tmp 里
    try { fs.renameSync(tmp, "wallets.json"); }
    finally { if (fs.existsSync(tmp)) { try { fs.unlinkSync(tmp); } catch (e) { } } }
  ' || { warn_msg "写入失败(地址重复或文件异常)"; sleep 1; return; }
  chmod 600 wallets.json 2>/dev/null || true
  ok_msg "账号 $addr 已添加"
  sleep 1
}

wiz_clear_accounts() {
  local a
  read -r -p "    确认清空全部账号? 不可恢复 (y/N): " a
  case "$a" in
    [Yy]*) echo '{"wallets": []}' > wallets.json; chmod 600 wallets.json 2>/dev/null || true
           ok_msg "已清空" ;;
    *) echo "    已取消" ;;
  esac
  sleep 1
}

wiz_accounts() {
  local ch
  while true; do
    wiz_header
    echo "    ---- 账号管理 ----"
    node -e '
      try {
        const d = JSON.parse(require("fs").readFileSync("wallets.json","utf8"));
        if (!d.wallets.length) console.log("    (还没有账号)");
        d.wallets.forEach((w,i)=>console.log("    ["+(i+1)+"] "+w.ADDRESS+"   推荐人 "+w.REFERRER));
      } catch(e) { console.log("    (还没有账号)"); }
    ' 2>/dev/null
    echo "    ────────────────────────────────────────────────"
    echo "      [1] 添加账号    [2] 清空重录    [0] 返回"
    read -r -p "    请选择: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
    case "$ch" in
      1) wiz_add_account ;;
      2) wiz_clear_accounts ;;
      0) return ;;
    esac
  done
}

wiz_defaults() {
  local a
  read -r -p "    恢复全部设置为默认值? (y/N): " a
  case "$a" in
    [Yy]*)
      WIZ_ROOMS="0,1,2"; WIZ_MIN="30"; WIZ_MAX="60"; WIZ_DELAY="0"
      WIZ_GAS_MODE="fixed"; WIZ_GAS_FIXED="0.05"; WIZ_GAS_MAX="10"; WIZ_GAS_MULT="1.25"
      WIZ_CLAIM="20"; WIZ_BNB="0.005"
      WIZ_MINER="0"; WIZ_MINER_USD="100"; WIZ_MINER_MODE="old"; WIZ_CLAIM_WIN="1"
      WIZ_FLEX="0"
      WIZ_BUY_ON="0"; WIZ_BUY_MAX_PRICE=""; WIZ_BUY_MAX_TOTAL=""
      WIZ_SELL_ON="0"; WIZ_SELL_MODE="fixed"; WIZ_SELL_PRICE=""; WIZ_SELL_AMOUNT=""
      WIZ_APPROVE_MODE="rounds"; WIZ_APPROVE_ROUNDS="1"; WIZ_APPROVE_USD=""
      ok_msg "已恢复默认(尚未保存)" ;;
    *) echo "    已取消" ;;
  esac
  sleep 1
}

# ---- 保存 ----
wiz_commit() {
  local ov a
  if [ -z "$WIZ_ROOMS" ]; then warn_msg "至少要选一个房间"; sleep 1; return 1; fi
  # 配置里手写成 30.5 时 [ -ge ] 会报 integer expression expected，先截断成整数
  if [ "${WIZ_MIN%%.*}" -ge "${WIZ_MAX%%.*}" ]; then warn_msg "抢位下限必须小于上限"; sleep 1; return 1; fi

  WIZ_ROOMS="$WIZ_ROOMS" WIZ_MIN="$WIZ_MIN" WIZ_MAX="$WIZ_MAX" WIZ_DELAY="$WIZ_DELAY" \
  WIZ_GAS_MODE="$WIZ_GAS_MODE" WIZ_GAS_FIXED="$WIZ_GAS_FIXED" WIZ_GAS_MAX="$WIZ_GAS_MAX" \
  WIZ_GAS_MULT="$WIZ_GAS_MULT" WIZ_CLAIM="$WIZ_CLAIM" WIZ_BNB="$WIZ_BNB" \
  WIZ_MINER="$WIZ_MINER" WIZ_MINER_USD="$WIZ_MINER_USD" WIZ_MINER_MODE="$WIZ_MINER_MODE" WIZ_CLAIM_WIN="$WIZ_CLAIM_WIN" \
  WIZ_FLEX="$WIZ_FLEX" \
  WIZ_BUY_ON="$WIZ_BUY_ON" WIZ_BUY_MAX_PRICE="$WIZ_BUY_MAX_PRICE" WIZ_BUY_MAX_TOTAL="$WIZ_BUY_MAX_TOTAL" \
  WIZ_SELL_ON="$WIZ_SELL_ON" WIZ_SELL_MODE="$WIZ_SELL_MODE" WIZ_SELL_PRICE="$WIZ_SELL_PRICE" WIZ_SELL_AMOUNT="$WIZ_SELL_AMOUNT" \
  WIZ_APPROVE_MODE="$WIZ_APPROVE_MODE" WIZ_APPROVE_ROUNDS="$WIZ_APPROVE_ROUNDS" WIZ_APPROVE_USD="$WIZ_APPROVE_USD" \
  WIZ_UPDATE_TOKEN="$WIZ_UPDATE_TOKEN" WIZ_AUTO_UPDATE="$WIZ_AUTO_UPDATE" \
  node -e '
    const fs = require("fs");
    let c = {};
    try { c = JSON.parse(fs.readFileSync("config.json","utf8")); } catch(e) {}
    const e = process.env;
    c.ROOMS = String(e.WIZ_ROOMS || "0,1,2").split(",").map(s=>Number(s.trim())).filter(n=>!isNaN(n));
    c.SNIPE_MIN_COUNT = Number(e.WIZ_MIN);
    c.SNIPE_MAX_COUNT = Number(e.WIZ_MAX);
    c.SNIPE_DELAY_MS  = Number(e.WIZ_DELAY);
    c.CLAIM_INTERVAL_MS = Number(e.WIZ_CLAIM) * 1000;
    c.MIN_BNB_GAS = Number(e.WIZ_BNB);
    c.GAS_MAX_GWEI = Number(e.WIZ_GAS_MAX);
    c.GAS_MULT = Number(e.WIZ_GAS_MULT);
    if (e.WIZ_GAS_MODE === "fixed") c.GAS_GWEI = Number(e.WIZ_GAS_FIXED);
    else c.GAS_GWEI = null;
    c.MINER_ENABLED = String(e.WIZ_MINER) === "1";
    c.MINER_USD = Number(e.WIZ_MINER_USD);
    c.MINER_MODE = String(e.WIZ_MINER_MODE || "old");
    c.CLAIM_WIN = String(e.WIZ_CLAIM_WIN) === "1";
    c.FLEX_DECISION = String(e.WIZ_FLEX) === "1";
    // 界面上只有一个"灵活资金决策"总开关，保存时同步两个子项，避免 config 里旧的 false 把总开关顶掉
    c.FLEX_GAS_POOLING = c.FLEX_DECISION;
    c.FLEX_FUND_AGGREGATION = c.FLEX_DECISION;
    c.UPDATE_TOKEN = String(e.WIZ_UPDATE_TOKEN || "").trim();
    // v1.7.1: 自动更新开关与 token 解绑 —— 公开仓库没有 token 也照样能检查更新
    c.AUTO_UPDATE = String(e.WIZ_AUTO_UPDATE) === "1";
    c.WEB_AUTO_SYNC = false;                // 网页合约自动同步默认关闭
    c.WEB_SYNC_ALLOW_FUNDS_KEYS = false;    // 资金相关字段默认冻结
    // FTS 自动买卖: 开关默认关；阈值只在用户填了才写入(不设默认值)
    c.TRADE_BUY_ENABLED = String(e.WIZ_BUY_ON) === "1";
    if (String(e.WIZ_BUY_MAX_PRICE || "").trim() !== "") c.TRADE_BUY_MAX_PRICE = Number(e.WIZ_BUY_MAX_PRICE);
    else delete c.TRADE_BUY_MAX_PRICE;
    if (String(e.WIZ_BUY_MAX_TOTAL || "").trim() !== "") c.TRADE_BUY_MAX_TOTAL = Number(e.WIZ_BUY_MAX_TOTAL);
    else delete c.TRADE_BUY_MAX_TOTAL;
    c.TRADE_SELL_ENABLED = String(e.WIZ_SELL_ON) === "1";
    c.TRADE_SELL_MODE = String(e.WIZ_SELL_MODE || "fixed");
    if (String(e.WIZ_SELL_PRICE || "").trim() !== "") c.TRADE_SELL_PRICE = Number(e.WIZ_SELL_PRICE);
    else delete c.TRADE_SELL_PRICE;
    if (String(e.WIZ_SELL_AMOUNT || "").trim() !== "") c.TRADE_SELL_AMOUNT = Number(e.WIZ_SELL_AMOUNT);
    else delete c.TRADE_SELL_AMOUNT;
    // 授权额度: 按U数写 APPROVE_USD(删 APPROVE_ROUNDS)；按场数反之
    if (String(e.WIZ_APPROVE_MODE) === "usd") {
      // v1.7.1: 0 = 全部余额已废弃；向导与引擎都回落到"按场数 1"
      const u = Number(String(e.WIZ_APPROVE_USD || "1").trim() || 1);
      if (u > 0) { c.APPROVE_USD = u; delete c.APPROVE_ROUNDS; }
      else { c.APPROVE_ROUNDS = 1; delete c.APPROVE_USD; }
    } else {
      c.APPROVE_ROUNDS = Math.max(1, Math.floor(Number(e.WIZ_APPROVE_ROUNDS || 1)));
      delete c.APPROVE_USD;
    }
    const tmp = "config.json.tmp";
    fs.writeFileSync(tmp, JSON.stringify(c, null, 2) + "\n");
    // rename 失败时清掉 .tmp，别在目录里留垃圾
    try { fs.renameSync(tmp, "config.json"); }
    finally { if (fs.existsSync(tmp)) { try { fs.unlinkSync(tmp); } catch (e) { } } }
  ' || { warn_msg "写入 config.json 失败"; sleep 1; return 1; }

  # 老版本会在每个账号里存 SNIPE_MIN/MAX/DELAY，它们会覆盖全局设置 -> 提示统一
  ov="$(node -e '
    try {
      const d = JSON.parse(require("fs").readFileSync("wallets.json","utf8"));
      console.log(d.wallets.filter(w => w.SNIPE_MIN_COUNT!==undefined || w.SNIPE_MAX_COUNT!==undefined || w.SNIPE_DELAY_MS!==undefined).length);
    } catch(e) { console.log(0); }
  ' 2>/dev/null || echo 0)"
  if [ "${ov:-0}" -gt 0 ]; then
    echo ""
    warn_msg "有 ${ov} 个账号带独立抢位设置，会覆盖上面的全局值"
    read -r -p "    改为统一使用全局设置? (Y/n): " a
    case "$a" in
      [Nn]*) echo "    保留账号独立设置(全局值对这些账号不生效)" ;;
      *) node -e '
        const fs = require("fs");
        const d = JSON.parse(fs.readFileSync("wallets.json","utf8"));
        d.wallets.forEach(w => { delete w.SNIPE_MIN_COUNT; delete w.SNIPE_MAX_COUNT; delete w.SNIPE_DELAY_MS; });
        const tmp = "wallets.json.tmp";
        fs.writeFileSync(tmp, JSON.stringify(d, null, 2), { mode: 0o600 });
        // rename 失败时清掉 .tmp：Git Bash on Windows 上 chmod 无效，残留就是明文私钥
        try { fs.renameSync(tmp, "wallets.json"); }
        finally { if (fs.existsSync(tmp)) { try { fs.unlinkSync(tmp); } catch (e) { } } }
      ' && ok_msg "已统一为全局设置" ;;
    esac
  fi
  return 0
}

wiz_menu() {
  echo "      [1] 参与房间          [2] 抢位人数区间"
  echo "      [3] 抢单延迟          [4] 手续费 / Gas"
  echo "      [5] 领取返利间隔      [6] 最低 BNB 余额"
  echo "      [7] 账号管理          [8] 恢复默认值"
  echo "      [9] 中奖处理/组矿机   [10] 自动更新开关 / Token"
  echo "      [11] 灵活资金决策     [12] 保存并退出"
  echo "      [13] FTS自动买入      [14] FTS自动卖出"
  echo "      [15] 授权额度"
  echo "      [0] 不保存退出"
  echo "  ────────────────────────────────────────────────────"
}

wizard_main() {
  local ch
  wiz_load
  while true; do
    wiz_header
    wiz_menu
    read -r -p "    请选择: " ch || { echo; die "输入已结束(EOF)，配置向导退出"; }
    case "$ch" in
      1) wiz_edit_rooms ;;
      2) wiz_edit_range ;;
      3) wiz_edit_delay ;;
      4) wiz_edit_gas ;;
      5) wiz_edit_claim ;;
      6) wiz_edit_bnb ;;
      7) wiz_accounts ;;
      8) wiz_defaults ;;
      9) wiz_edit_miner ;;
      10) wiz_edit_update ;;
      11) wiz_edit_flex ;;
      13) wiz_edit_buy ;;
      14) wiz_edit_sell ;;
      15) wiz_edit_approve ;;
      12) if wiz_commit; then return 0; fi ;;
      0) echo ""; echo "  已退出，未做任何修改"; return 1 ;;
      *) ;;
    esac
  done
}

# ---- 进入引导页 ----
if [ "$DO_INIT" = 1 ] || [ "$DO_WIZARD" = 1 ] || [ ! -f wallets.json ]; then
  echo -e "\e[33m[3/5] 配置向导...\e[0m"
  if [ ! -t 0 ] && [ "${FTS_ALLOW_PIPE_INIT:-0}" != "1" ]; then
    die "配置向导需要交互式终端。请在终端里直接执行: bash autofts.sh --init"
  fi
  if wizard_main; then
    echo ""
    ok_msg "配置已保存到 config.json（账号在 wallets.json）"
    echo "  当前设置: 房间=$(wiz_rooms_text) 抢位=${WIZ_MIN}~${WIZ_MAX} 延迟=${WIZ_DELAY}ms 手续费=$(wiz_gas_text)"
    echo ""
    echo "下一步建议(按顺序):"
    echo "  bash autofts.sh --selftest   # 只读体检，一分钱不花"
    echo "  bash autofts.sh --dry-run    # 全流程演练，交易不上链"
    echo "  bash autofts.sh --run        # 确认无误后再正式运行"
  fi
  # 配置向导结束一律退出，绝不自动开始交易
  exit 0
fi

node -e '
  const fs=require("fs");
  let d;
  try { d = JSON.parse(fs.readFileSync("wallets.json","utf8")); }
  catch (e) { console.error("wallets.json 不是合法的 JSON: " + e.message); process.exit(1); }
  if(!d || !Array.isArray(d.wallets) || d.wallets.length===0){ console.error("wallets.json 中没有账号"); process.exit(1); }
  console.log(`已加载 ${d.wallets.length} 个账号配置`);
' || die "wallets.json 无效或为空，请执行: bash autofts.sh --init"

# ==============================================================
echo -e "\e[33m[4/5] 设备保活...\e[0m"
# 只有真正要长时间运行的模式才拿唤醒锁；selftest/短期任务不拿，避免白耗电
case "$MODE" in
  run|dry-run) acquire_wake ;;
  *) echo "模式 $MODE 不需要长时间挂机，跳过唤醒锁(不耗电)" ;;
esac

# ==============================================================
echo -e "\e[33m[5/5] 启动引擎 (模式: $MODE)...\e[0m"
echo "--------------------------------------------------------"

if [ "$MODE" = "selftest" ]; then
  node core.js selftest
  exit $?
fi

CONSOLE_LOG="logs/console-$(date +%Y%m%d).log"
RUNNING=1
TAIL_PID=""
cleanup() {
  RUNNING=0
  echo ""
  echo "正在退出..."
  rm -f "$PID_FILE" "$STOP_FLAG"
  # Ctrl-C 时 node 通常同进程组会一起收到 SIGINT，但如果它正卡在不响应信号的
  # 调用里、或者 shell 用了 nohup/disown，就会变成孤儿进程继续跑、继续花钱。
  # 所以这里必须显式回收它。
  if [ -n "${NODE_PID:-}" ] && kill -0 "$NODE_PID" 2>/dev/null; then
    kill -TERM "$NODE_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$NODE_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "$NODE_PID" 2>/dev/null && kill -KILL "$NODE_PID" 2>/dev/null
  fi
  # 必须回收 tail，否则每次 --stop / Ctrl-C 都会漏一个常驻的 tail -f 进程
  [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null
  TAIL_PID=""
  release_wake
  exit 0
}
trap cleanup INT TERM

# 清掉上一轮遗留的停止标志，否则 --run 一启动就被它打断
rm -f "$STOP_FLAG"

# 日志清理: 只保留最近 7 天，并限制单个控制台日志体积(手机存储很宝贵)
find logs -maxdepth 1 -name 'console-*.log*' -mtime +7 -delete 2>/dev/null || true
find logs -maxdepth 1 -name 'fts-*.log'        -mtime +7 -delete 2>/dev/null || true
LOG_MAX_MB="${FTS_LOG_MAX_MB:-20}"

RESTARTS=0
RESTART_MAX="${FTS_RESTART_MAX:-50}"
# 稳定运行多久就把崩溃计数清零(默认 300 秒)，避免挂机十小时后因累计次数永久停机
STABLE_RESET_SEC="${FTS_STABLE_RESET:-300}"

while [ "$RUNNING" = 1 ]; do
  # --stop 的可靠信号: 即使 PID 文件丢了，也能在这里退出
  if [ -f "$STOP_FLAG" ]; then
    echo "检测到停止标志，外壳循环退出"
    rm -f "$STOP_FLAG"
    break
  fi

  # 控制台日志滚动，避免单文件无限增长
  if [ -f "$CONSOLE_LOG" ]; then
    SZ="$(wc -c < "$CONSOLE_LOG" 2>/dev/null || echo 0)"
    if [ "${SZ:-0}" -gt $(( LOG_MAX_MB * 1024 * 1024 )) ]; then
      mv -f "$CONSOLE_LOG" "$CONSOLE_LOG.1" 2>/dev/null || true
      echo "控制台日志超过 ${LOG_MAX_MB}MB，已滚动为 $CONSOLE_LOG.1"
    fi
  fi

  START_TS="$(date +%s)"
  # 后台跑 node(这样能拿到它真实的 PID 用于 --stop)，同时 tail -f 实时看日志
  node "$WORK_DIR/core.js" "$MODE" >> "$CONSOLE_LOG" 2>&1 &
  NODE_PID=$!
  # PID 文件用 key=value，避免"少写一行"时把行号当 PID 用
  printf 'shell=%s\nnode=%s\n' "$$" "$NODE_PID" > "$PID_FILE"
  tail -f -n 0 "$CONSOLE_LOG" 2>/dev/null &
  TAIL_PID=$!
  wait "$NODE_PID"
  CODE=$?
  NODE_PID=""   # node 已退出，清掉它；否则 sleep 期间 Ctrl-C 可能 kill 到被复用的 PID
  kill "$TAIL_PID" 2>/dev/null
  TAIL_PID=""
  rm -f "$PID_FILE"
  END_TS="$(date +%s)"
  RAN_SEC=$(( END_TS - START_TS ))
  # 跑够时间说明是稳定的，之前的崩溃计数作废
  if [ "$RAN_SEC" -ge "$STABLE_RESET_SEC" ] && [ "$RESTARTS" -ne 0 ]; then
    echo "已稳定运行 ${RAN_SEC}s(>= ${STABLE_RESET_SEC}s)，崩溃计数重置为 0"
    RESTARTS=0
  fi
  [ "$RUNNING" = 0 ] && break
  [ -f "$STOP_FLAG" ] && { rm -f "$STOP_FLAG"; echo "检测到停止标志，外壳循环退出"; break; }
  case "$CODE" in
    0)
      echo "引擎正常退出"; break ;;
    20)
      die "依赖缺失，请先安装 ethers (npm install ethers@6)" ;;
    21)
      die "没有可用账号，请执行: bash autofts.sh --init" ;;
    22)
      warn_msg "RPC 全部不可用，10 秒后重试..."; sleep 10; RESTARTS=$((RESTARTS+1)) ;;
    90)
      echo ""
      ok_msg "已更新到新版本，正在原地重启(空闲窗口内完成，不影响后续排期)..."
      RESTARTS=0
      exec bash "$0" "${ORIG_ARGS[@]}" ;;
    *)
      RESTARTS=$((RESTARTS+1))
      if [ "$RESTARTS" -gt "$RESTART_MAX" ]; then die "连续崩溃超过 ${RESTART_MAX} 次，停止重启。请查看 logs/ 排查"; fi
      WAIT=$((RESTARTS * 2)); [ "$WAIT" -gt 30 ] && WAIT=30
      warn_msg "引擎退出(码 $CODE)，${WAIT}s 后第 $RESTARTS 次重启..."
      sleep "$WAIT" ;;
  esac
done
cleanup
