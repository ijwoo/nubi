#!/usr/bin/env tsx
/**
 * Break a macro on purpose and see whether the model puts it back.
 *
 * Waiting for a real app redesign is not a test plan. Pointing one step at an
 * identifier that does not exist leaves exactly the situation a redesign
 * leaves — one step finds nothing, the rest are fine — and it can be done on
 * demand, which is the difference between a claim and a measurement.
 *
 * Runs the same macro twice each way, because the interesting number is not
 * that the repair worked once but that the second run is fast again: the fix
 * is written into the macro, so it is paid for once.
 *
 *   scripts/wda.sh &
 *   npm run heal -- settings-open-accessibility
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ScriptedExecutor } from '../src/eval/executor.js';
import { runTask } from '../src/eval/runner.js';
import { loadTask } from '../src/eval/task.js';
import { WdaHands } from '../src/hands/wda.js';
import { ClaudeRepairer, MacroStore, ReplayExecutor } from '../src/macro/index.js';
import { hasApiKey, loadEnv } from '../src/shared/env.js';
import { type Macro, MacroSchema } from '../src/shared/types.js';

loadEnv();
if (!hasApiKey()) {
  console.error('ANTHROPIC_API_KEY 없음 — .env 또는 환경변수에 넣으세요');
  process.exit(1);
}

const name = process.argv[2] ?? 'settings-open-accessibility';
const runs = Number(process.argv[3] ?? 2);

const MACRO_DIR = fileURLToPath(new URL('../macros/', import.meta.url));
const TASK_DIR = fileURLToPath(new URL('../src/eval/tasks/', import.meta.url));
const original = MacroSchema.parse(JSON.parse(readFileSync(`${MACRO_DIR}${name}.json`, 'utf8')));

/** The first tap is the one to break; a launch has no selector to lose. */
const stepIndex = original.steps.findIndex((s) => s.op === 'tap');
if (stepIndex === -1) {
  console.error(`${name} has no tap step to break`);
  process.exit(1);
}

function broken(macro: Macro): Macro {
  const step = macro.steps[stepIndex];
  if (step?.op !== 'tap') throw new Error('unreachable');
  const sel = step.sel;
  const wrecked =
    'id' in sel
      ? { id: `${sel.id}.RENAMED` }
      : 'label' in sel
        ? { ...sel, label: `${sel.label} (사라짐)` }
        : sel;
  const steps = [...macro.steps];
  steps[stepIndex] = { ...step, sel: wrecked };
  return { ...macro, steps };
}

/** A throwaway store, so a failed experiment cannot leave a mended macro behind. */
function scratchStore(macro: Macro): { store: MacroStore; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), 'nubi-heal-'));
  writeFileSync(join(dir, `${macro.id}.json`), JSON.stringify(macro, null, 2));
  return { store: new MacroStore(dir), dir };
}

const task = loadTask(`${TASK_DIR}${name}.yaml`);
const hands = new WdaHands({ bundleId: original.app });

console.log(`\n자가치유 확인 — ${name}`);
const step = original.steps[stepIndex];
if (step?.op === 'tap') {
  console.log(`  ${stepIndex}번 스텝을 깨뜨림: ${JSON.stringify(step.sel)}`);
  console.log(`                  → ${JSON.stringify(broken(original).steps[stepIndex])}\n`);
}

// 1) 복구 없이. 깨진 스텝에서 그대로 멈춰야 한다.
const withoutStore = scratchStore(broken(original));
const without = await runTask({
  hands,
  task,
  executor: new ScriptedExecutor(withoutStore.store.get(original.id)),
  runs,
});
console.log(`  복구 없음 (scripted)  ${without.runs.filter((r) => r.asserted).length}/${runs}`);

// 2) 복구 있음. 같은 깨진 매크로에서 출발한다.
const withStore = scratchStore(broken(original));
const replay = new ReplayExecutor({
  macro: withStore.store.get(original.id),
  store: withStore.store,
  repairer: new ClaudeRepairer(),
});
const healed = await runTask({ hands, task, executor: replay, runs });
console.log(`  복구 있음 (replay)    ${healed.runs.filter((r) => r.asserted).length}/${runs}`);

const after = withStore.store.get(original.id);
console.log(`\n  매크로  v${broken(original).version} → v${after.version}`);
console.log(`  healedAt  ${after.stats.healedAt ?? '없음'}`);
const fixed = after.steps[stepIndex];
if (fixed?.op === 'tap') {
  console.log(`  now  ${JSON.stringify(fixed.sel)}`);
  console.log(`  alt  ${JSON.stringify(fixed.alt ?? null)}`);
}

// Per run, because the claim being tested is not that repair works but that
// it is paid for once: the fix is written into the macro, so run 2 replays a
// mended route and calls nobody.
console.log('\n  런별 비용·복구');
healed.runs.forEach((r, i) => {
  console.log(
    `    ${i + 1}런  $${r.usd.toFixed(4)}  모델 ${r.modelCalls}회  ` +
      `복구 ${r.repairs}회  세션재생성 ${r.recoveries}회  ${r.durationMs}ms`,
  );
});

await hands.close();
rmSync(withoutStore.dir, { recursive: true, force: true });
rmSync(withStore.dir, { recursive: true, force: true });
