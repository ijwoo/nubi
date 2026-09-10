#!/usr/bin/env tsx
/**
 * Run the eval set and report what each approach cost.
 *
 *   scripts/wda.sh &
 *   npm run eval                       every task, against the device
 *   npm run eval -- --fake             against recorded screens, no device
 *   npm run eval -- --task settings-open-accessibility
 *   npm run eval -- --runs 3
 *   npm run eval -- --executor explore    let the model find the route
 *   npm run eval -- --executor both       run both and report them together
 *   npm run eval -- --model claude-sonnet-5
 *   npm run eval -- --effort low
 */
import { copyFileSync, mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ClaudePlanner, ExploreExecutor } from '../src/brain/index.js';
import {
  type Aggregate,
  type Executor,
  ScriptedExecutor,
  aggregate,
  loadTask,
  runTask,
} from '../src/eval/index.js';
import { FakeHands } from '../src/hands/fake.js';
import type { Hands } from '../src/hands/types.js';
import { WdaHands } from '../src/hands/wda.js';
import { MacroStore, ReplayExecutor, ScriptedRepairer } from '../src/macro/index.js';
import { hasApiKey, loadEnv } from '../src/shared/env.js';
import { MacroSchema } from '../src/shared/types.js';

const TASK_DIR = fileURLToPath(new URL('../src/eval/tasks/', import.meta.url));
const MACRO_DIR = fileURLToPath(new URL('../macros/', import.meta.url));
const TRACE_DIR = fileURLToPath(new URL('../traces/', import.meta.url));
const SCENARIO = fileURLToPath(
  new URL('../src/hands/fixtures/settings/settings.scenario.json', import.meta.url),
);

loadEnv();

const argv = process.argv.slice(2);
const flag = (name: string): string | undefined => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? undefined : argv[i + 1];
};
const useFake = argv.includes('--fake');
const which = flag('executor') ?? 'scripted';
if (!['scripted', 'replay', 'explore', 'both', 'all'].includes(which)) {
  console.error(`unknown executor "${which}" — scripted | replay | explore | both | all`);
  process.exit(1);
}
const wants = (name: 'scripted' | 'replay' | 'explore') =>
  which === name || which === 'all' || (which === 'both' && name !== 'replay');

/**
 * Macros are copied somewhere temporary before replay runs against them.
 *
 * Replay repairs the route it is running and writes the fix back, which is the
 * point of it — and exactly what a measurement must not do to the library it
 * is measuring. A benchmark that permanently edits its own subject cannot be
 * run twice.
 */
function scratchLibrary(): MacroStore {
  const dir = mkdtempSync(join(tmpdir(), 'nubi-eval-'));
  for (const file of readdirSync(MACRO_DIR).filter((f) => f.endsWith('.json'))) {
    copyFileSync(MACRO_DIR + file, join(dir, file));
  }
  return new MacroStore(dir);
}
const model = flag('model');
const effort = flag('effort');
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

/** Executors this task can be attempted with, in the order they are reported. */
function executorsFor(task: ReturnType<typeof loadTask>): Executor[] {
  const chosen: Executor[] = [];

  if (wants('scripted')) {
    if (!task.scripted) {
      console.log(`${task.id}: no macro for the scripted executor, skipping it`);
    } else {
      const macro = MacroSchema.parse(
        JSON.parse(readFileSync(`${MACRO_DIR}${task.scripted.macro}.json`, 'utf8')),
      );
      chosen.push(new ScriptedExecutor(macro));
    }
  }

  if (wants('replay')) {
    if (!task.scripted) {
      console.log(`${task.id}: no macro for the replay executor, skipping it`);
    } else {
      const store = scratchLibrary();
      chosen.push(
        new ReplayExecutor({
          macro: store.get(task.scripted.macro),
          store,
          // Scrolling is free and needs nobody; repair would need a key and a
          // model, and mixing the two would leave it unclear which one earned
          // the difference from `scripted`.
          repairer: new ScriptedRepairer([undefined]),
        }),
      );
    }
  }

  if (wants('explore')) {
    // Explore is the only executor that needs credentials, so it fails here
    // rather than partway through a run that has already cost time.
    if (!hasApiKey()) {
      console.error('ANTHROPIC_API_KEY 가 없습니다. .env 에 넣거나 export 하세요.');
      process.exit(1);
    }
    chosen.push(
      new ExploreExecutor({
        planner: new ClaudePlanner({
          ...(model ? { model } : {}),
          ...(effort ? { effort: effort as 'low' | 'medium' | 'high' | 'xhigh' | 'max' } : {}),
        }),
      }),
    );
  }

  return chosen;
}

for (const task of tasks) {
  // Nothing animates in a recording, so the settling time a device needs is
  // pure wall clock here — and it would dominate every fake measurement.
  const shaped = useFake ? { ...task, setup: { ...task.setup, settleMs: 0 } } : task;

  for (const executor of executorsFor(task)) {
    const result = await runTask({
      hands,
      task: shaped,
      executor,
      ...(runsOverride ? { runs: Number(runsOverride) } : {}),
      ...(useFake ? {} : { traceDir: TRACE_DIR }),
    });
    results.push(aggregate(result));
  }
}

await hands.close();
report(results);

function report(rows: Aggregate[]): void {
  const head = ['task', 'executor', 'ok', 'p50', 'p95', 'acts', 'model', 'tok', '$/run'];
  const body = rows.map((r) => [
    r.taskId,
    r.executor,
    `${r.successes}/${r.attempts}`,
    `${r.p50Ms}ms`,
    `${r.p95Ms}ms`,
    String(r.avgActions),
    String(r.avgModelCalls),
    String(r.avgInputTokens),
    r.avgUsd === 0 ? '—' : `$${r.avgUsd.toFixed(4)}`,
  ]);
  const widths = head.map((h, i) =>
    Math.max(h.length, ...body.map((row) => (row[i] ?? '').length)),
  );
  const line = (cells: string[]) => cells.map((c, i) => c.padEnd(widths[i] ?? 0)).join('  ');

  console.log(line(head));
  console.log(widths.map((w) => '─'.repeat(w)).join('  '));
  for (const row of body) console.log(line(row));

  const total = rows.reduce((a, r) => a + r.totalUsd, 0);
  if (total > 0) console.log(`\n합계 $${total.toFixed(3)}`);

  const falseClaims = rows.reduce((a, r) => a + r.falseClaims, 0);
  const recoveries = rows.reduce((a, r) => a + r.recoveries, 0);
  console.log();
  if (falseClaims > 0)
    console.log(`⚠ ${falseClaims} attempt(s) claimed success the device did not confirm`);
  const unclaimed = rows.reduce((a, r) => a + r.unclaimed, 0);
  if (unclaimed > 0)
    console.log(`⚠ ${unclaimed} attempt(s) reached the goal without the executor saying so`);
  if (recoveries > 0) console.log(`  ${recoveries} session recovery(ies) during the set`);
  if (!useFake) console.log('  traces: traces/');

  const failed = rows.some((r) => r.successes < r.attempts);
  process.exitCode = failed ? 1 : 0;
}
