import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { FakeHands } from '../hands/fake.js';
import { MacroSchema } from '../shared/types.js';
import { ScriptedExecutor } from './executor.js';
import { aggregate, runTask } from './runner.js';
import { loadTask } from './task.js';

const SCENARIO = fileURLToPath(
  new URL('../hands/fixtures/settings/settings.scenario.json', import.meta.url),
);
const TASK = fileURLToPath(new URL('./tasks/settings-open-accessibility.yaml', import.meta.url));
const MACRO = fileURLToPath(
  new URL('../../macros/settings-open-accessibility.json', import.meta.url),
);

const loaded = loadTask(TASK);
/** No settling against recorded screens — nothing is animating. */
const task = { ...loaded, setup: { ...loaded.setup, settleMs: 0 } };
const macro = MacroSchema.parse(JSON.parse(readFileSync(MACRO, 'utf8')));

/** The recorded scenario reaches accessibility only from `root-again`. */
function fake(): FakeHands {
  return FakeHands.fromScenario(SCENARIO);
}

describe('task definitions', () => {
  it('states a goal and its evidence, never the route', () => {
    expect(task.prompt).toBeTruthy();
    expect(task.assert.selector).toEqual({ id: 'ACCESSIBILITY_PLACARD' });
    // Steps live in a macro, so the same task can measure any approach.
    expect(Object.keys(task)).not.toContain('steps');
  });

  it('defaults a settle time and a run count', () => {
    expect(task.setup.restart).toBe(true);
    expect(task.runs).toBe(5);
  });
});

describe('runTask against the fake', () => {
  it('replays the macro and passes the task assertion', async () => {
    const hands = fake();
    // The recorded walk reaches accessibility from the screen after going
    // back, so this fixture needs the intermediate step the real device does
    // not. It is the scenario that is narrow here, not the macro.
    const stepped = new ScriptedExecutor({
      ...macro,
      steps: [
        { op: 'launch', bundleId: 'com.apple.Preferences', restart: true },
        { op: 'tap', sel: { id: 'com.apple.settings.general' } },
        { op: 'back' },
        { op: 'tap', sel: { id: 'com.apple.settings.accessibility' } },
      ],
    });

    const result = await runTask({ hands, task, executor: stepped, runs: 3 });
    const agg = aggregate(result);

    expect(agg.attempts).toBe(3);
    expect(agg.successRate).toBe(1);
    // The whole claim of the replay path: no model, at any point (ADR 0003).
    expect(agg.avgModelCalls).toBe(0);
    expect(agg.falseClaims).toBe(0);
  });

  it('records a false claim when the executor disagrees with the device', async () => {
    // An executor that reports success it did not achieve is the failure mode
    // the runner exists to catch — which is why it, not the executor, judges.
    const liar = {
      name: 'liar',
      run: async () => true,
    };
    const result = await runTask({ hands: fake(), task, executor: liar, runs: 2 });
    const agg = aggregate(result);

    expect(agg.successRate).toBe(0);
    expect(agg.falseClaims).toBe(2);
  });

  it('resets between attempts so run 2 does not inherit run 1', async () => {
    const hands = fake();
    const once = new ScriptedExecutor({
      ...macro,
      steps: [{ op: 'tap', sel: { id: 'com.apple.settings.general' } }],
    });
    await runTask({ hands, task, executor: once, runs: 2 });
    // Both attempts started from the app's own home screen, so both tapped
    // the same row rather than the second finding itself already deeper in.
    expect(hands.calls.filter((c) => c.action === 'launch')).toHaveLength(2);
  });
});

describe('aggregate', () => {
  const summaries = (durations: number[]) => ({
    taskId: 't',
    executor: 'x',
    runs: durations.map((d, i) => ({
      runId: `r${i}`,
      ok: true,
      durationMs: d,
      actions: 2,
      observations: 3,
      asserts: 1,
      modelCalls: 0,
      inputTokens: 0,
      outputTokens: 0,
      recoveries: 0,
      approvals: 0,
      failures: 0,
      asserted: true,
      claimed: true,
      usd: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    })),
  });

  it('reports a percentile that actually occurred', () => {
    // Nearest-rank on a small sample: interpolating would report a duration no
    // attempt ever took.
    const a = aggregate(summaries([100, 200, 300, 400, 5000]));
    expect(a.p50Ms).toBe(300);
    expect(a.p95Ms).toBe(5000);
  });

  it('keeps p95 next to p50, so a rare slow run stays visible', () => {
    const a = aggregate(summaries([100, 100, 100, 100, 9000]));
    expect(a.p50Ms).toBe(100);
    expect(a.p95Ms).toBe(9000);
  });
});
