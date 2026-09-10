import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ScriptedPlanner } from './brain/planner.js';
import { ScriptedGate } from './gate/index.js';
import { FakeHands } from './hands/fake.js';
import { ScriptedRepairer } from './macro/repair.js';
import { MacroStore } from './macro/store.js';
import { idFor, run } from './run.js';

/**
 * The loop end to end, on recorded screens.
 *
 * Exploration and replay were each tested already; what was never tested is
 * that one produces something the other can run. That gap is what made "한 번
 * 찾고, 계속 재생한다" two working halves rather than a loop.
 */

const SCENARIO = fileURLToPath(
  new URL('./hands/fixtures/settings/settings.scenario.json', import.meta.url),
);
const APP = 'com.apple.Preferences';

let dir: string;
let store: MacroStore;
afterEach(() => rmSync(dir, { recursive: true, force: true }));
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'nubi-run-'));
  store = new MacroStore(dir);
});

/** A planner that walks to accessibility and stops, as a real one would. */
function planner() {
  return new ScriptedPlanner([
    { kind: 'tap', element: 0, why: '손쉬운 사용으로 이동' },
    { kind: 'done', why: '도착' },
  ]);
}

/** Index of the accessibility row on the screen the fake starts on. */
async function accessibilityIndex(hands: FakeHands): Promise<number> {
  const screen = await hands.screen();
  return screen.elements.findIndex((e) => e.id === 'com.apple.settings.accessibility');
}

function opts(hands: FakeHands, actions: number) {
  const screenIndexPlanner = new ScriptedPlanner([
    { kind: 'tap', element: actions, why: '손쉬운 사용으로 이동' },
    { kind: 'done', why: '도착' },
  ]);
  return {
    hands,
    store,
    planner: screenIndexPlanner,
    repairer: new ScriptedRepairer([]),
    app: APP,
  };
}

describe('run — the loop', () => {
  it('explores when nothing matches, and keeps what it found', async () => {
    const hands = FakeHands.fromScenario(SCENARIO);
    const idx = await accessibilityIndex(hands);

    const first = await run('손쉬운 사용 열어줘', opts(hands, idx));

    expect(first.kind).toBe('explored');
    if (first.kind !== 'explored') throw new Error('unreachable');
    expect(first.ok).toBe(true);
    expect(first.saved).toBeDefined();

    const saved = store.get(first.saved as string);
    expect(saved.triggers).toContain('손쉬운 사용 열어줘');
    expect(saved.app).toBe(APP);
    // The route it walked, plus the launch and the check it derived.
    expect(saved.steps[0]?.op).toBe('launch');
    expect(saved.steps.at(-1)?.op).toBe('assert');
  });

  it('replays the saved route on the second identical request', async () => {
    // The whole point: the second time costs no model call.
    const explore = FakeHands.fromScenario(SCENARIO);
    const idx = await accessibilityIndex(explore);
    await run('손쉬운 사용 열어줘', opts(explore, idx));

    const replayHands = FakeHands.fromScenario(SCENARIO);
    const second = await run('손쉬운 사용 열어줘', {
      ...opts(replayHands, idx),
      // A planner that would throw if the loop reached for a model at all.
      planner: {
        name: 'forbidden',
        next: async () => {
          throw new Error('replay must not call a planner');
        },
      },
    });

    expect(second.kind).toBe('replayed');
    if (second.kind !== 'replayed') throw new Error('unreachable');
    expect(second.ok).toBe(true);
    expect(second.usd).toBe(0);
  });

  it('refuses to save a route whose end looks like its start', async () => {
    // It worked, but it cannot prove it worked next week. Saving anyway would
    // produce a macro that passes for having pressed buttons.
    const hands = FakeHands.fromScenario(SCENARIO);
    const standStill = {
      ...opts(hands, 0),
      planner: new ScriptedPlanner([{ kind: 'done', why: '이미 여기' }]),
    };

    const out = await run('아무것도 하지 마', standStill);
    expect(out.kind).toBe('explored');
    if (out.kind !== 'explored') throw new Error('unreachable');
    expect(out.ok).toBe(true);
    expect(out.saved).toBeUndefined();
    expect(out.why).toContain('검증 기준');
    expect(store.all()).toHaveLength(0);
  });
});

describe('run — what replay leaves behind', () => {
  it('records the run, so a route that keeps failing can be demoted', async () => {
    // The counters demotion reads were never written to. isDemoted needs five
    // runs, so no macro could reach the threshold and the library showed every
    // route as untried forever.
    const explore = FakeHands.fromScenario(SCENARIO);
    const idx = await accessibilityIndex(explore);
    const first = await run('손쉬운 사용 열어줘', opts(explore, idx));
    if (first.kind !== 'explored' || !first.saved) throw new Error('unreachable');

    const before = store.get(first.saved);
    expect(before.stats.runs).toBe(0);

    await run('손쉬운 사용 열어줘', opts(FakeHands.fromScenario(SCENARIO), idx));
    const after = store.get(first.saved);
    expect(after.stats.runs).toBe(1);
    expect(after.stats.fails).toBe(0);
    expect(after.stats.avgMs).toBeGreaterThanOrEqual(0);
    expect(after.stats.lastRun).toBeDefined();
  });

  it('counts a failed replay as a failure', async () => {
    const explore = FakeHands.fromScenario(SCENARIO);
    const idx = await accessibilityIndex(explore);
    const first = await run('손쉬운 사용 열어줘', opts(explore, idx));
    if (first.kind !== 'explored' || !first.saved) throw new Error('unreachable');

    // A route pointing at a control that is not there, and a repairer with
    // nothing to offer — the shape of an app that moved on.
    const broken = store.get(first.saved);
    broken.steps[1] = { op: 'tap', sel: { id: 'gone_in_the_update' } };
    store.save(broken);

    const out = await run('손쉬운 사용 열어줘', opts(FakeHands.fromScenario(SCENARIO), idx));
    expect(out.kind).toBe('replayed');
    if (out.kind !== 'replayed') throw new Error('unreachable');
    expect(out.ok).toBe(false);
    expect(store.get(first.saved).stats.fails).toBe(1);
  });
});

describe('run — approval', () => {
  /** Save the route the loop just learned, marked as needing approval. */
  async function riskyRoute() {
    const explore = FakeHands.fromScenario(SCENARIO);
    const idx = await accessibilityIndex(explore);
    const first = await run('손쉬운 사용 열어줘', opts(explore, idx));
    if (first.kind !== 'explored' || !first.saved) throw new Error('unreachable');
    const saved = store.get(first.saved);
    saved.risk = 'confirm';
    // A control whose name says what it does, so the request can name it too.
    saved.steps[1] = { op: 'tap', sel: { label: '삭제' } };
    store.save(saved);
    return { id: first.saved, idx };
  }

  it('refuses to run a risky route when nobody has been asked', async () => {
    // The gap this closes: `risk` was computed by extraction and read by
    // nothing, so a route marked irreversible replayed like any other.
    const { id, idx } = await riskyRoute();
    const out = await run('손쉬운 사용 열어줘', opts(FakeHands.fromScenario(SCENARIO), idx));

    expect(out.kind).toBe('refused');
    if (out.kind !== 'refused') throw new Error('unreachable');
    expect(out.macroId).toBe(id);
    // Nothing ran, so nothing was counted.
    expect(store.get(id).stats.runs).toBe(0);
  });

  it('names the control in the request, not just the risk', async () => {
    const { idx } = await riskyRoute();
    const gate = new ScriptedGate([false]);
    await run('손쉬운 사용 열어줘', {
      ...opts(FakeHands.fromScenario(SCENARIO), idx),
      gate,
    });
    expect(gate.asked[0]?.reasons).toEqual(['삭제']);
  });

  it('runs it once a person says yes', async () => {
    const { id, idx } = await riskyRoute();
    const out = await run('손쉬운 사용 열어줘', {
      ...opts(FakeHands.fromScenario(SCENARIO), idx),
      gate: new ScriptedGate([true]),
    });
    expect(out.kind).toBe('replayed');
    expect(store.get(id).stats.runs).toBe(1);
  });

  it('never asks about a blocked route', async () => {
    // Someone already decided; asking per run would make that negotiable.
    const { idx } = await riskyRoute();
    const blocked = store.all()[0];
    if (!blocked) throw new Error('unreachable');
    blocked.risk = 'blocked';
    store.save(blocked);

    const gate = new ScriptedGate([true]);
    const out = await run('손쉬운 사용 열어줘', {
      ...opts(FakeHands.fromScenario(SCENARIO), idx),
      gate,
    });
    expect(out.kind).toBe('refused');
    expect(gate.asked).toHaveLength(0);
  });
});

describe('run — when an alert is in the way', () => {
  it('says which alert blocked it, rather than blaming the route', async () => {
    // The failure mode that cost three debugging sessions on the simulator and
    // will be routine on a phone: a permission prompt absorbs every touch
    // while the tree underneath looks completely normal.
    const hands = FakeHands.fromScenario(SCENARIO);
    hands.showAlert('“설정”이 위치 정보에 접근하려고 합니다', ['허용 안 함', '허용']);

    const out = await run('손쉬운 사용 열어줘', opts(hands, 0));
    expect(out.kind).toBe('explored');
    if (out.kind !== 'explored') throw new Error('unreachable');
    expect(out.ok).toBe(false);
    expect(out.why).toContain('시스템 알림');
    expect(out.why).toContain('위치 정보');
    // Never answered on our own — the buttons grant, delete, or pay (ADR 0008).
    expect(out.why).toContain('허용');
  });
});

describe('idFor', () => {
  it('produces a filename-safe id from a Korean request', () => {
    // Macro ids are [a-z0-9-] because they are filenames, which leaves nothing
    // of the language this will mostly be asked in.
    const id = idFor('아이폰 정보 보여줘', () => false);
    expect(id).toMatch(/^[a-z0-9-]+$/);
  });

  it('does not overwrite a route already saved under that name', () => {
    expect(idFor('아이폰 정보', (id) => id === 'route')).toBe('route-2');
  });
});
