import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadTask } from '../eval/task.js';
import { FakeHands } from '../hands/fake.js';
import type { Element, Macro, Screen } from '../shared/types.js';
import { Trace } from '../trace/index.js';
import { ScriptedRepairer } from './repair.js';
import { ReplayExecutor, reachable } from './replay.js';
import { MacroStore } from './store.js';

/**
 * Replaying a route on a screen that does not fit.
 *
 * Recorded from an iPhone 14 Pro, because this is the case a simulator cannot
 * produce: real Settings puts an Apple account, an update banner and cellular
 * above everything a macro written against a simulator wants, so the target is
 * off screen and the tree — which only carries what is visible — does not have
 * it at all.
 */

const SCENARIO = fileURLToPath(
  new URL('../hands/fixtures/settings-device/settings-device.scenario.json', import.meta.url),
);
const task = loadTask(
  fileURLToPath(new URL('../eval/tasks/settings-open-accessibility.yaml', import.meta.url)),
);

let dir: string;
let store: MacroStore;
let hands: FakeHands;
let trace: Trace;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'nubi-scroll-'));
  store = new MacroStore(dir);
  hands = FakeHands.fromScenario(SCENARIO);
  trace = Trace.start();
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const macro = (): Macro =>
  ({
    id: 'demo',
    version: 1,
    triggers: ['t'],
    app: 'com.apple.Preferences',
    risk: 'safe',
    params: {},
    steps: [{ op: 'tap', sel: { id: 'com.apple.settings.accessibility' } }],
    stats: { runs: 0, fails: 0, avgMs: 0 },
  }) as Macro;

/** A repairer with nothing to offer, so only the free fix can succeed. */
function replay(m: Macro) {
  store.save(m);
  return new ReplayExecutor({ macro: m, store, repairer: new ScriptedRepairer([undefined]) });
}

describe('replay — a target below the fold', () => {
  it('is not on the first screen at all', async () => {
    // Not a broken selector: compaction keeps only what is visible, so the
    // control the macro names is genuinely absent from the tree.
    const screen = await hands.screen();
    expect(screen.elements.some((e) => e.id === 'com.apple.settings.accessibility')).toBe(false);
  });

  it('scrolls to it rather than calling a model', async () => {
    // Scrolling is free and repair is not, so the cheap fix goes first.
    const executor = replay(macro());
    expect(await executor.run(hands, task, trace)).toBe(true);
    expect(executor.repairs).toBe(0);
    expect(hands.calls.filter((c) => c.action === 'swipe').length).toBeGreaterThan(0);
  });

  it('records the scroll as a recovery, not as an ordinary step', async () => {
    const executor = replay(macro());
    await executor.run(hands, task, trace);
    const scrolled = trace.events.find((e) => e.detail.op === 'scroll' && e.kind === 'recover');
    expect(scrolled).toBeDefined();
    expect(scrolled?.detail.swipes).toBeGreaterThan(0);
  });

  it('gives up when the list stops moving', async () => {
    // A scenario with nowhere to scroll leaves the screen as it was, which is
    // what the end of a list does. Swiping a fixed number of times regardless
    // would burn the budget on a list that ended three swipes ago.
    const music = FakeHands.fromScenario(
      fileURLToPath(new URL('../hands/fixtures/music.scenario.json', import.meta.url)),
    );
    const gone: Macro = { ...macro(), steps: [{ op: 'tap', sel: { id: 'not_here_at_all' } }] };
    store.save(gone);
    const executor = new ReplayExecutor({
      macro: gone,
      store,
      repairer: new ScriptedRepairer([undefined]),
    });

    expect(await executor.run(music, task, trace)).toBe(false);
    // One swipe to learn the list will not move, and no more.
    expect(music.calls.filter((c) => c.action === 'swipe').length).toBe(1);
  });
});

describe('replay — a list still moving', () => {
  it('reads until the screen repeats before deciding it has arrived', async () => {
    // On a phone the list is still decelerating when a swipe returns. Judging
    // from that frame found the row in the bottom band, and the tap that
    // followed landed on nothing — a failure that cost a full rescan.
    //
    // The fake models neither momentum nor a tap that goes nowhere, so it
    // cannot reproduce that. What it can show is the mechanism: the decision
    // is made on a screen that read the same twice, not on the first one back.
    const hands = FakeHands.fromScenario(SCENARIO);
    const executor = replay(macro());

    expect(await executor.run(hands, task, trace)).toBe(true);

    const swipes = hands.calls.filter((c) => c.action === 'swipe').length;
    const reads = hands.calls.filter((c) => c.action === 'screen').length;
    // One reading before the first swipe, then at least one per swipe to see
    // it repeat. Deciding straight from the swipe's own screen needs none.
    expect(reads).toBeGreaterThan(swipes);
  });

  it('stops reading rather than waiting on a screen that never repeats', async () => {
    // A screen that keeps changing is animating on its own. Deciding from a
    // stale frame is no worse than another that will also be stale.
    const hands = FakeHands.fromScenario(SCENARIO);
    let n = 0;
    const read = hands.screen.bind(hands);
    hands.screen = async () => ({ ...(await read()), hash: `never-still-${n++}` });

    const executor = new ReplayExecutor({
      macro: macro(),
      store,
      repairer: new ScriptedRepairer([undefined]),
      maxSettleReads: 2,
      maxScrolls: 2,
    });
    store.save(macro());
    await executor.run(hands, task, trace);

    expect(hands.calls.filter((c) => c.action === 'swipe').length).toBeLessThanOrEqual(2);
    expect(hands.calls.filter((c) => c.action === 'screen').length).toBeLessThanOrEqual(8);
  });
});

describe('reachable', () => {
  const screen = { size: { w: 393, h: 852 } } as Screen;
  const at = (y: number): Element => ({ i: 0, t: 'Button', r: [16, y, 361, 53], e: true });

  it('rejects the band where a tap is swallowed', () => {
    // Measured: y=748 on an 852pt screen resolves, reports visible, and a tap
    // at its centre does nothing whatsoever.
    expect(reachable(at(748), screen)).toBe(false);
  });

  it('accepts the position one more scroll produces', () => {
    // The same row at y=593, where the same tap works.
    expect(reachable(at(593), screen)).toBe(true);
  });

  it('rejects a row tucked under the navigation bar', () => {
    expect(reachable(at(0), screen)).toBe(false);
  });
});
