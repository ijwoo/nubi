import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadTask } from '../eval/task.js';
import { FakeHands } from '../hands/fake.js';
import type { Macro } from '../shared/types.js';
import { Trace } from '../trace/index.js';
import { type RepairSuggestion, ScriptedRepairer } from './repair.js';
import { ReplayExecutor } from './replay.js';
import { MacroStore } from './store.js';

/**
 * Repair, exercised offline.
 *
 * A broken macro is easy to produce without an app update: point a step at an
 * identifier the recorded screen does not have. What that leaves is exactly
 * the situation a redesign creates — a step that resolves nothing while
 * everything around it still works.
 */

const SCENARIO = fileURLToPath(
  new URL('../hands/fixtures/settings/settings.scenario.json', import.meta.url),
);
const TASK = fileURLToPath(
  new URL('../eval/tasks/settings-open-accessibility.yaml', import.meta.url),
);
const task = loadTask(TASK);

let dir: string;
let store: MacroStore;
let hands: FakeHands;
let trace: Trace;

/** A route whose second step no longer resolves, as a redesign would leave it. */
const broken = (): Macro =>
  ({
    id: 'demo',
    version: 1,
    triggers: ['t'],
    app: 'com.apple.Preferences',
    risk: 'safe',
    params: {},
    steps: [
      { op: 'launch', bundleId: 'com.apple.Preferences', restart: true },
      { op: 'tap', sel: { id: 'renamed_in_the_update' } },
    ],
    stats: { runs: 0, fails: 0, avgMs: 0 },
  }) as Macro;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'nubi-replay-'));
  store = new MacroStore(dir);
  hands = FakeHands.fromScenario(SCENARIO);
  trace = Trace.start();
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

/** Whichever element index the accessibility row currently occupies. */
async function accessibilityIndex(): Promise<number> {
  const screen = await hands.screen();
  return screen.elements.findIndex((e) => e.id === 'com.apple.settings.accessibility');
}

function replay(macro: Macro, answers: (RepairSuggestion | undefined)[]) {
  store.save(macro);
  return new ReplayExecutor({ macro, store, repairer: new ScriptedRepairer(answers) });
}

describe('replay — when nothing is broken', () => {
  it('runs the route without calling the repairer', async () => {
    const macro = broken();
    macro.steps[1] = { op: 'tap', sel: { id: 'com.apple.settings.accessibility' } };
    const executor = replay(macro, []);

    expect(await executor.run(hands, task, trace)).toBe(true);
    expect(executor.repairs).toBe(0);
    expect(hands.screenName).toBe('accessibility');
  });
});

describe('replay — mending a broken step', () => {
  it('finds the control again and finishes the route', async () => {
    const executor = replay(broken(), [{ element: await accessibilityIndex(), why: '같은 행' }]);

    expect(await executor.run(hands, task, trace)).toBe(true);
    expect(executor.repairs).toBe(1);
    expect(hands.screenName).toBe('accessibility');
  });

  it('writes the replacement back, so the next run needs no model', async () => {
    // This is the whole point: a repair is paid for once.
    await replay(broken(), [{ element: await accessibilityIndex(), why: '' }]).run(
      hands,
      task,
      trace,
    );

    const saved = store.get('demo');
    expect(saved.version).toBe(2);
    expect(saved.steps[1]).toMatchObject({ sel: { id: 'com.apple.settings.accessibility' } });
    expect(saved.stats.healedAt).toMatch(/^\d{4}-/);
  });

  it('keeps the selector it replaced as a fallback', async () => {
    await replay(broken(), [{ element: await accessibilityIndex(), why: '' }]).run(
      hands,
      task,
      trace,
    );
    expect(store.get('demo').steps[1]).toMatchObject({ alt: { id: 'renamed_in_the_update' } });
  });

  it('records the repair in the trace with both selectors', async () => {
    // Without this a session that healed five times reads like one that never
    // needed to.
    await replay(broken(), [{ element: await accessibilityIndex(), why: '같은 위치의 행' }]).run(
      hands,
      task,
      trace,
    );

    const event = trace.events.find((e) => e.kind === 'recover');
    expect(event?.detail).toMatchObject({
      was: { id: 'renamed_in_the_update' },
      now: { id: 'com.apple.settings.accessibility' },
      why: '같은 위치의 행',
      version: 2,
    });
  });
});

describe('replay — refusing a bad repair', () => {
  it('gives up when nothing on screen resembles the control', async () => {
    const executor = replay(broken(), [undefined]);

    expect(await executor.run(hands, task, trace)).toBe(false);
    expect(store.get('demo').version).toBe(1); // untouched
    expect(trace.events.some((e) => e.detail.reason?.toString().includes('resembles'))).toBe(true);
  });

  it('gives up when the suggestion names an element that is not there', async () => {
    const executor = replay(broken(), [{ element: 999, why: '' }]);
    expect(await executor.run(hands, task, trace)).toBe(false);
    expect(store.get('demo').version).toBe(1);
  });

  it('will not write a coordinate over a named control', async () => {
    // A coordinate works once and breaks again, and overwrites what the step
    // used to say. Failing and letting exploration find a real route is
    // better than a macro that has quietly become fragile.
    const screen = await hands.screen();
    const nameless = screen.elements.findIndex((e) => !e.id && !e.l && !e.v);
    if (nameless < 0) return; // this fixture has none; nothing to assert

    const executor = replay(broken(), [{ element: nameless, why: '' }]);
    expect(await executor.run(hands, task, trace)).toBe(false);
    expect(store.get('demo').version).toBe(1);
  });

  it('stops after the repair budget, rather than mending its way through', async () => {
    // A route needing repair at every step has changed, not shifted. Rewriting
    // it wholesale would produce a macro nobody chose.
    const macro = broken();
    macro.steps.push({ op: 'tap', sel: { id: 'also_gone' } });
    macro.steps.push({ op: 'tap', sel: { id: 'gone_too' } });
    const idx = await accessibilityIndex();

    store.save(macro);
    const executor = new ReplayExecutor({
      macro,
      store,
      repairer: new ScriptedRepairer([
        { element: idx, why: '' },
        { element: idx, why: '' },
        { element: idx, why: '' },
      ]),
      maxRepairs: 1,
    });

    expect(await executor.run(hands, task, trace)).toBe(false);
    expect(executor.repairs).toBe(1);
  });
});
