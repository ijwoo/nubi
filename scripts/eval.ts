#!/usr/bin/env tsx
/**
 * Run the eval set and report what each approach cost.
 *
 *   scripts/wda.sh &
 *   npm run eval                       every task, against the device
 *   npm run eval -- --fake             against recorded screens, no device
 *   npm run eval -- --task settings-open-accessibility
 *   npm run eval -- --runs 3
 */
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  type Aggregate,
  ScriptedExecutor,
  aggregate,
  loadTask,
  runTask,
} from '../src/eval/index.js';
import { FakeHands } from '../src/hands/fake.js';
import type { Hands } from '../src/hands/types.js';
import { WdaHands } from '../src/hands/wda.js';
import { MacroSchema } from '../src/shared/types.js';

const TASK_DIR = fileURLToPath(new URL('../src/eval/tasks/', import.meta.url));
const MACRO_DIR = fileURLToPath(new URL('../macros/', import.meta.url));
const TRACE_DIR = fileURLToPath(new URL('../traces/', import.meta.url));
const SCENARIO = fileURLToPath(
  new URL('../src/hands/fixtures/settings/settings.scenario.json', import.meta.url),
);

const argv = process.argv.slice(2);
const flag = (name: string): string | undefined => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? undefined : argv[i + 1];
};
const useFake = argv.includes('--fake');
const only = flag('task');
const runsOverride = flag('runs');

const tasks = readdirSync(TASK_DIR)
  .filter((f) => f.endsWith('.yaml'))
  .map((f) => loadTask(TASK_DIR + f))
  .filter((t) => only === undefined || t.id === only);

if (tasks.length === 0) {
  console.error(only ? `no task "${only}"` : 'no tasks found');
  process.exit(1);
}

const hands: Hands = useFake
  ? FakeHands.fromScenario(SCENARIO)
  : new WdaHands({ bundleId: tasks[0]?.setup.bundleId ?? 'com.apple.Preferences' });

if (!useFake) {
  const health = await hands.health();
  if (!health.ready) {
    console.error(`agent not ready: ${health.detail ?? ''}\nStart it with: npm run wda`);
    process.exit(1);
  }
}

console.log(`\nnubi eval — ${useFake ? 'recorded screens' : 'live agent'}\n`);

const results: Aggregate[] = [];
for (const task of tasks) {
  if (!task.scripted) {
    console.log(`${task.id}: no executor available yet, skipping`);
    continue;
  }
  const macro = MacroSchema.parse(
    JSON.parse(readFileSync(`${MACRO_DIR}${task.scripted.macro}.json`, 'utf8')),
  );
  // Nothing animates in a recording, so the settling time a device needs is
  // pure wall clock here — and it would dominate every fake measurement.
  const shaped = useFake ? { ...task, setup: { ...task.setup, settleMs: 0 } } : task;

  const result = await runTask({
    hands,
    task: shaped,
    executor: new ScriptedExecutor(macro),
    ...(runsOverride ? { runs: Number(runsOverride) } : {}),
    ...(useFake ? {} : { traceDir: TRACE_DIR }),
  });
  results.push(aggregate(result));
}

await hands.close();
report(results);

function report(rows: Aggregate[]): void {
  const head = ['task', 'executor', 'ok', 'p50', 'p95', 'acts', 'obs', 'model', 'in tok'];
  const body = rows.map((r) => [
    r.taskId,
    r.executor,
    `${r.successes}/${r.attempts}`,
    `${r.p50Ms}ms`,
    `${r.p95Ms}ms`,
    String(r.avgActions),
    String(r.avgObservations),
    String(r.avgModelCalls),
    String(r.avgInputTokens),
  ]);
  const widths = head.map((h, i) =>
    Math.max(h.length, ...body.map((row) => (row[i] ?? '').length)),
  );
  const line = (cells: string[]) => cells.map((c, i) => c.padEnd(widths[i] ?? 0)).join('  ');

  console.log(line(head));
  console.log(widths.map((w) => '─'.repeat(w)).join('  '));
  for (const row of body) console.log(line(row));

  const falseClaims = rows.reduce((a, r) => a + r.falseClaims, 0);
  const recoveries = rows.reduce((a, r) => a + r.recoveries, 0);
  console.log();
  if (falseClaims > 0)
    console.log(`⚠ ${falseClaims} attempt(s) claimed success the device did not confirm`);
  if (recoveries > 0) console.log(`  ${recoveries} session recovery(ies) during the set`);
  if (!useFake) console.log('  traces: traces/');

  const failed = rows.some((r) => r.successes < r.attempts);
  process.exitCode = failed ? 1 : 0;
}
