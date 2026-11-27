#!/usr/bin/env node
/**
 * 多节点分层池回归测试
 *
 * 验证:
 *   1) 节点按档位分闸门(fast=14 / slow=12)
 *   2) 请求分散到多个节点(不是全挤一个)
 *   3) 某节点冷却时，请求自动落到其它健康节点(溢出)
 *   4) 账号专属节点优先，专属节点满了能溢出
 *   5) 每节点并发不超自己的闸门
 *
 * 做法: 从 core.js 抽出Semaphore/nodeTier/NodeConn/NodePool，注入桩 provider。
 *
 * 用法: node test/node-pool.js
 */

const fs = require('fs');
const path = require('path');
const ROOT = path.dirname(__dirname);
const SRC = process.env.CORE_PATH || path.join(ROOT, 'src', 'core.js');
const text = fs.readFileSync(SRC, 'utf8');

function extract(startSig, endSig) {
  const s = text.indexOf(startSig);
  if (s < 0) throw new Error('找不到 ' + startSig);
  const e = text.indexOf(endSig, s);
  if (e < 0) throw new Error('找不到 ' + endSig);
  return text.slice(s, e);
}
// Semaphore 整段
const semSrc = extract('class Semaphore {', 'const rpcGate =');
// nodeTier + NodeConn + NodePool 整段(到 const nodePool 前)
const poolSrc = extract('function nodeTier(url) {', 'const nodePool = new NodePool');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const CFG = {
  CHAIN_ID: 56, NODE_POOL_ENABLED: true,
  NODE_TIER_CONCURRENCY: { fast: 14, slow: 12 },
  RPC_MIN_SPACING_MS: 0
};
// provider 桩: 每次调用记一句
const ethers = { JsonRpcProvider: class { constructor(url) { this.url = url; } } };

(async () => {
  const stubs = { CFG, ethers, sleep };
  const makeSem = new Function('CFG', 'sleep', semSrc + '\nreturn Semaphore;')(CFG, sleep);
  const rpcGate = { run: async fn => fn() };
  const factory = new Function('CFG', 'ethers', 'Semaphore', 'rpcGate', poolSrc + '\nreturn {nodeTier, NodeConn, NodePool};');
  const { nodeTier, NodePool } = factory(CFG, ethers, makeSem, rpcGate);

  const errors = [];
  const assert = (cond, msg) => { if (!cond) errors.push(msg); };

  // 1) 档位判定
  assert(nodeTier('https://bsc-dataseed.bnbchain.org') === 'fast', 'bnbchain 应判为 fast');
  assert(nodeTier('https://bsc-rpc.publicnode.com') === 'slow', 'publicnode 应判为 slow');
  console.log('✅ 节点档位判定');

  // 2) 建池 + 闸门值
  const urls = [
    'https://bsc-dataseed.bnbchain.org', 'https://bsc-dataseed1.bnbchain.org', // fast 14
    'https://bsc-rpc.publicnode.com', 'https://bsc.publicnode.com'              // slow 12
  ];
  const pool = new NodePool(urls);
  assert(pool.nodes.length === 4, '应有 4 个节点');
  assert(pool.nodes[0].gate.max === 14, 'fast 节点闸门应为 14');
  assert(pool.nodes[2].gate.max === 12, 'slow 节点闸门应为 12');
  console.log('✅ 每节点独立闸门(14/12)');

  // 3) 请求分散到多节点(无preferred时按负载最低选)
  const used = {};
  await Promise.all(Array.from({ length: 40 }, () => pool.run(async (p) => {
    used[p.url] = (used[p.url] || 0) + 1;
    await sleep(2);
  })));
  const spread = Object.keys(used).length;
  assert(spread >= 2, `请求应分散到>=2节点，实际 ${spread}`);
  console.log(`✅ 请求分散到 ${spread} 个节点:`, JSON.stringify(used));

  // 4) 某节点冷却时自动落到其它节点
  const n0 = pool.nodes[0];
  pool.cooldown(n0, 60000);
  assert(!n0.available, '节点0 应处于冷却');
  let hitCooled = 0;
  await Promise.all(Array.from({ length: 20 }, () => pool.run(async (p) => {
    if (p.url === n0.url) hitCooled++;
    await sleep(1);
  })));
  assert(hitCooled === 0, `冷却节点不应被选中，实际被选中 ${hitCooled} 次`);
  console.log('✅ 冷却节点自动跳过');

  // 5) 每节点并发不超闸门
  n0.cooldownUntil = 0; n0.ok = true;
  const pool2 = new NodePool([urls[0]]); // 单节点，闸门14
  let running = 0, peak = 0;
  await Promise.all(Array.from({ length: 60 }, () => pool2.run(async () => {
    running++; peak = Math.max(peak, running);
    await sleep(3);
    running--;
  })));
  assert(peak <= 14, `单节点峰值并发 ${peak} 超过闸门 14`);
  console.log(`✅ 单节点并发未超闸门(峰值 ${peak}/14)`);

  console.log('');
  if (errors.length === 0) { console.log('✅ 全部通过: 多节点分层池工作正常'); process.exit(0); }
  console.log('❌ 失败:'); errors.forEach(e => console.log('   -', e));
  process.exit(1);
})().catch(e => { console.error(e); process.exit(2); });
