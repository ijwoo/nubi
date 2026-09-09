import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ScriptedPlanner } from './brain/planner.js';
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
    expect(first.ok).toBe(true);
    if (first.kind !== 'explored') throw new Error('unreachable');
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
    expect(second.ok).toBe(true);
    if (second.kind !== 'replayed') throw new Error('unreachable');
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
