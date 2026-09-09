import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it } from 'vitest';
import { loadTask } from '../eval/task.js';
import { FakeHands } from '../hands/fake.js';
import { Trace } from '../trace/index.js';
import { ExploreExecutor, selectorFor } from './explore.js';
import { type PlannedAction, ScriptedPlanner } from './planner.js';

/**
 * The explore loop, exercised without a model.
 *
 * Everything that actually goes wrong in this loop — running out of steps,
 * repeating a failing action, giving up, claiming success it did not achieve,
 * walking into a modal — reproduces with a scripted planner. Only the quality
 * of the model's choices needs the API, and that is measured by eval rather
 * than asserted here.
 */

const SCENARIO = fileURLToPath(new URL('../hands/fixtures/music.scenario.json', import.meta.url));
const TASK_FILE = fileURLToPath(
  new URL('../eval/tasks/settings-open-accessibility.yaml', import.meta.url),
);
const task = loadTask(TASK_FILE);

let hands: FakeHands;
let trace: Trace;
beforeEach(() => {
  hands = FakeHands.fromScenario(SCENARIO);
  trace = Trace.start();
});

const run = (actions: PlannedAction[], opts = {}) =>
  new ExploreExecutor({ planner: new ScriptedPlanner(actions), ...opts }).run(hands, task, trace);

const why = 'because';

describe('explore — reaching the goal', () => {
  it('acts on the element the planner chose and reports done', async () => {
    const screen = await hands.screen();
    const searchTab = screen.elements.findIndex((e) => e.id === 'tab_search');

    const ok = await run([
      { kind: 'tap', element: searchTab, why },
      { kind: 'done', why },
    ]);

    expect(ok).toBe(true);
    expect(hands.screenName).toBe('search-empty');
  });

  it('records the route as selectors, not as indices', async () => {
    // Indices only mean something on the screen they came from. What gets kept
    // has to still find the control on a later run — that is what makes an
    // exploration reusable.
    const screen = await hands.screen();
    const searchTab = screen.elements.findIndex((e) => e.id === 'tab_search');

    const explorer = new ExploreExecutor({
      planner: new ScriptedPlanner([
        { kind: 'tap', element: searchTab, why },
        { kind: 'done', why },
      ]),
    });
    await explorer.run(hands, task, trace);

    expect(explorer.route).toHaveLength(1);
    expect(explorer.route[0]?.selector).toEqual({ id: 'tab_search' });
  });
});

describe('explore — giving up well', () => {
  it('stops when the planner says it is stuck', async () => {
    const ok = await run([{ kind: 'stuck', why: 'no way forward' }]);
    expect(ok).toBe(false);
    expect(trace.events.some((e) => e.detail.reason === 'planner gave up')).toBe(true);
  });

  it('stops after repeated failures rather than burning the budget', async () => {
    // Repeating a failing action is how a loop spends everything and learns
    // nothing.
    const bad: PlannedAction = { kind: 'tap', element: 999, why };
    const ok = await run([bad, bad, bad, bad, bad], { maxConsecutiveFailures: 3 });

    expect(ok).toBe(false);
    expect(trace.events.some((e) => e.detail.reason === 'consecutive failures')).toBe(true);
  });

  it('forgives a failure that is followed by progress', async () => {
    const screen = await hands.screen();
    const searchTab = screen.elements.findIndex((e) => e.id === 'tab_search');

    const ok = await run(
      [
        { kind: 'tap', element: 999, why },
        { kind: 'tap', element: 999, why },
        { kind: 'tap', element: searchTab, why },
        { kind: 'done', why },
      ],
      { maxConsecutiveFailures: 3 },
    );

    expect(ok).toBe(true);
  });

  it('stops at the step ceiling', async () => {
    const ok = await run(
      [
        { kind: 'back', why },
        { kind: 'back', why },
      ],
      { maxSteps: 2 },
    );
    expect(ok).toBe(false);
    expect(trace.events.some((e) => e.detail.reason === 'step budget exhausted')).toBe(true);
  });

  it('refuses to plan against a screen a modal is covering', async () => {
    // The tree underneath looks entirely normal, so any action decided here
    // would silently do nothing and the planner would blame its own choice.
    hands.showAlert('허용하겠습니까?', ['허용', '허용 안 함']);
    const ok = await run([{ kind: 'done', why }]);

    expect(ok).toBe(false);
    const blocked = trace.events.find((e) => e.detail.reason === 'blocked-by-alert');
    expect(blocked?.kind).toBe('approve');
  });

  it('does not decide "done" is true — the runner checks that', async () => {
    // A planner claiming success is a claim, not a result (ADR 0009).
    const ok = await run([{ kind: 'done', why: 'looks right to me' }]);
    expect(ok).toBe(true);
    expect(hands.screenName).toBe('home'); // nothing was actually done
  });
});

describe('explore — what the planner is told', () => {
  it('reports the previous failure so the next choice can differ', async () => {
    // Without this the planner has no way to know its last action did nothing,
    // and the most likely next move is the same one again.
    const seen: (string | undefined)[] = [];
    let call = 0;
    const planner = {
      name: 'recording',
      next: async (ctx: { lastFailure?: string }) => {
        seen.push(ctx.lastFailure);
        const action: PlannedAction =
          call++ === 0 ? { kind: 'tap', element: 999, why } : { kind: 'stuck', why };
        return { action };
      },
    };

    await new ExploreExecutor({ planner }).run(hands, task, trace);

    expect(seen[0]).toBeUndefined(); // nothing had failed yet
    // Naming an element that is not on screen is the planner's mistake, not a
    // selector miss, and saying so is more use than "no-match".
    expect(seen[1]).toBe('no element 999 on screen');
  });

  it('counts down the steps it has left', async () => {
    const remaining: number[] = [];
    const planner = {
      name: 'recording',
      next: async (ctx: { stepsRemaining: number }) => {
        remaining.push(ctx.stepsRemaining);
        return { action: { kind: 'back', why } as PlannedAction };
      },
    };
    await new ExploreExecutor({ planner, maxSteps: 3 }).run(hands, task, trace);
    expect(remaining).toEqual([3, 2, 1]);
  });

  it('accumulates what has already been tried', async () => {
    const lengths: number[] = [];
    let call = 0;
    const planner = {
      name: 'recording',
      next: async (ctx: { history: PlannedAction[] }) => {
        lengths.push(ctx.history.length);
        const action: PlannedAction = call++ < 2 ? { kind: 'back', why } : { kind: 'stuck', why };
        return { action };
      },
    };
    await new ExploreExecutor({ planner }).run(hands, task, trace);
    expect(lengths).toEqual([0, 1, 2]);
  });
});

describe('selectorFor', () => {
  const el = (over: Partial<{ i: number; t: string; l: string; id: string }>) => ({
    i: 0,
    t: 'Button',
    r: [0, 0, 10, 10] as [number, number, number, number],
    e: true,
    ...over,
  });

  it('prefers an identifier', () => {
    const a = el({ id: 'save_btn', l: '저장' });
    expect(selectorFor(a, [a])).toEqual({ id: 'save_btn' });
  });

  it('uses a label only when it is unique on the screen', () => {
    const a = el({ i: 0, l: '저장' });
    const b = el({ i: 1, l: '취소' });
    expect(selectorFor(a, [a, b])).toEqual({ label: '저장' });
  });

  it('adds the type when a label alone is ambiguous', () => {
    const a = el({ i: 0, l: '검색', t: 'Button' });
    const b = el({ i: 1, l: '검색', t: 'StaticText' });
    expect(selectorFor(a, [a, b])).toEqual({ label: '검색', type: 'Button' });
  });

  it('falls to position when a label repeats within a type', () => {
    // Two identical buttons resolve by tie-break, and a selector that works by
    // tie-break today picks differently tomorrow.
    const a = el({ i: 0, l: '삭제' });
    const b = el({ i: 1, l: '삭제' });
    expect(selectorFor(b, [a, b])).toEqual({ index: { type: 'Button', n: 1 } });
  });

  it('counts position among elements of the same type', () => {
    const a = el({ i: 0, t: 'Cell' });
    const b = el({ i: 1, t: 'Cell' });
    expect(selectorFor(b, [a, b])).toEqual({ index: { type: 'Cell', n: 1 } });
  });
});

describe('explore — what the trace records', () => {
  it('records one model event per call, with its usage', async () => {
    // Timing the call with `span` and recording usage separately produced two
    // events per call, and every reported model-call count was double.
    const planner = {
      name: 'usage-reporting',
      next: async () => ({
        action: { kind: 'done', why } as PlannedAction,
        usage: { model: 'test-model', inputTokens: 100, outputTokens: 20 },
      }),
    };
    await new ExploreExecutor({ planner }).run(hands, task, trace);

    const models = trace.events.filter((e) => e.kind === 'model');
    expect(models).toHaveLength(1);
    expect(models[0]?.detail).toMatchObject({ inputTokens: 100, outputTokens: 20 });
    expect(models[0]?.durationMs).toBeGreaterThanOrEqual(0);
  });

  it('still records a call that threw', async () => {
    const planner = {
      name: 'broken',
      next: async () => {
        throw new Error('rate limited');
      },
    };
    await expect(new ExploreExecutor({ planner }).run(hands, task, trace)).rejects.toThrow();
    expect(trace.events.find((e) => e.kind === 'model')?.failed).toBe(true);
  });
});
