#!/usr/bin/env node
/**
 * RPC 并发闸门回归测试
 *
 * 背景: RPC_MAX_CONCURRENT 决定同时打到公共节点的最大请求数。
 * 之前默认 4，提到 10 后必须确认两件事:
 *   1) 峰值并发不会超过上限(令牌转交逻辑不能被新来的 acquire 插队顶穿)
 *   2) Queue 里等待的任务最终都会被唤醒，不会静默死锁
 *
 * 做法: 把 Semaphore 从 src/core.js 按大括号配对整段抽出来，注入 CFG/sleep 桩，
 * 用 N 个模拟 RPC 任务(带随机耗时)压上去，记录峰值并发与完成情况。
 *
 * 用法: node test/semaphore-concurrency.js [并发上限]
 *      （无需依赖，只要 Node 18+）
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.dirname(__dirname);
const SRC = process.env.CORE_PATH || path.join(ROOT, 'src', 'core.js');

const text = fs.readFileSync(SRC, 'utf8');
const start = text.indexOf('class Semaphore {');
if (start < 0) {
  console.error('找不到 Semaphore，core.js 结构可能变了，请更新本测试');
  process.exit(2);
}
let depth = 0, end = -1;
for (let j = text.indexOf('{', start); j < text.length; j++) {
  if (text[j] === '{') depth++;
  else if (text[j] === '}') { depth--; if (depth === 0) { end = j + 1; break; } }
}
const classSrc = text.slice(start, end);

const MAX = Number(process.argv[2]) || 10;
const stubs = {
  CFG: { RPC_MIN_SPACING_MS: 0 },
  sleep: async () => { }
};
const factory = new Function(...Object.keys(stubs), classSrc + '\nreturn Semaphore;');
const Semaphore = factory(...Object.values(stubs));

(async () => {
  const gate = new Semaphore(MAX);
  const N = MAX * 6;                 // 远超上限，逼出排队/令牌转交
  let running = 0, peak = 0, done = 0;
  const problems = [];

  const tasks = Array.from({ length: N }, (_, i) => gate.run(async () => {
    running++;
    peak = Math.max(peak, running);
    try {
      // 模拟 RPC 耗时抖动，让 release 与 acquire 交错
      await new Promise(r => setTimeout(r, (i % 5) + 1));
      done++;
    } finally {
      running--;
    }
  }));

  // 整体超时保护: 若令牌转交写错导致等待者永远不被唤醒，会在这里暴露
  const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('DEADLOCK')), 8000));
  try {
    await Promise.race([Promise.all(tasks), timeout]);
  } catch (e) {
    problems.push(`任务未全部完成(${done}/${N}): ${e.message}`);
  }

  console.log(`并发上限=${MAX} | 任务数=${N} | 峰值并发=${peak} | 完成=${done}/${N}`);

  if (peak > MAX) problems.push(`峰值并发 ${peak} 超过上限 ${MAX}，闸门被顶穿`);
  if (done !== N) problems.push(`只完成 ${done}/${N} 个任务，可能有等待者未被唤醒`);
  if (running !== 0) problems.push(`结束时仍有 ${running} 个任务在飞`);

  console.log('');
  if (problems.length === 0) {
    console.log('✅ 通过: 并发未顶穿，所有任务均完成，无死锁');
    process.exit(0);
  }
  console.log('❌ 失败:');
  problems.forEach(p => console.log('   -', p));
  process.exit(1);
})();
