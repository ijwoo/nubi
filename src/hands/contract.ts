import type { Selector } from '../shared/types.js';
import type { Hands } from './types.js';

/**
 * Behaviour every Hands implementation must share.
 *
 * The premise of this project is that replay, repair, and explore can be built
 * against `FakeHands` and later swapped onto a device. That only holds if the
 * two agree, and "they implement the same interface" does not establish it —
 * TypeScript checks shapes, not behaviour. A fake that reports a miss where the
 * device reports success is type-correct and useless.
 *
 * So the cases live here as plain functions rather than vitest blocks: the unit
 * suite runs them against the fake in CI, and `npm run live` runs the same ones
 * against a real agent. One definition, two targets, no way for them to drift
 * apart quietly.
 *
 * Cases assert only what both targets can honestly promise. Anything needing
 * knowledge of a specific app's navigation belongs in that target's own tests.
 */

export interface ContractContext {
  /** An identifier present on the screen the target starts on. */
  presentId: string;
  /** A label present on that same screen. */
  presentLabel: string;
  /** An identifier that is definitely not there. */
  absentId: string;
  /**
   * Put the target back on the screen the selectors above refer to.
   *
   * Needed because the two targets differ in a way the interface does not
   * express: a fake is constructed fresh for every case, while a device
   * remembers. Running these cases against a real app left mid-navigation
   * fails four of them, and none of those failures are about the contract.
   */
  reset(): Promise<void>;
}

export interface ContractCase {
  name: string;
  /** Throws on failure; the message is the report. */
  run(hands: Hands, ctx: ContractContext): Promise<void>;
}

function expect(ok: boolean, message: string): void {
  if (!ok) throw new Error(message);
}

export const CONTRACT: ContractCase[] = [
  {
    name: 'screen returns addressable elements with an identity',
    async run(hands) {
      const s = await hands.screen();
      expect(s.elements.length > 0, 'no elements');
      expect(
        s.elements.every((e) => (e.l ?? e.v ?? e.id) !== undefined),
        'an element cannot be named in a selector',
      );
      expect(/^[0-9a-f]{12}$/.test(s.hash), `bad hash: ${s.hash}`);
      expect(s.size.w > 0 && s.size.h > 0, `bad screen size: ${JSON.stringify(s.size)}`);
      expect(s.app.length > 0, 'no app id');
    },
  },
  {
    name: 'observing twice without acting yields the same hash',
    async run(hands) {
      // Screen identity is what lets `assert` settle without a model call, so
      // an observation that is not stable would make every wait a coin flip.
      const a = await hands.screen();
      const b = await hands.screen();
      expect(a.hash === b.hash, `hash moved with no action: ${a.hash} -> ${b.hash}`);
    },
  },
  {
    name: 'find resolves a selector that is present',
    async run(hands, ctx) {
      const r = await hands.find({ id: ctx.presentId });
      expect(r.ok, `expected to find ${ctx.presentId}`);
      if (!r.ok) return;
      expect(r.element.id === ctx.presentId, 'wrong element');
      expect(r.via === 'sel', `expected primary selector, got ${r.via}`);
      expect(r.matched === 1, `expected one match, got ${r.matched}`);
    },
  },
  {
    name: 'find reports a miss and hands back the screen',
    async run(hands, ctx) {
      // Repair needs the screen at the moment of failure; fetching it
      // separately would show one that had already moved on.
      const r = await hands.find({ id: ctx.absentId });
      expect(!r.ok, 'expected a miss');
      if (r.ok) return;
      expect(r.reason === 'no-match', `expected no-match, got ${r.reason}`);
      expect(r.screen.elements.length > 0, 'miss came back without a screen');
    },
  },
  {
    name: 'a label selector matches too',
    async run(hands, ctx) {
      const r = await hands.find({ label: ctx.presentLabel });
      expect(r.ok, `expected to find label ${ctx.presentLabel}`);
    },
  },
  {
    name: 'tap on a missing selector fails without acting',
    async run(hands, ctx) {
      const before = await hands.screen();
      const r = await hands.tap({ id: ctx.absentId });
      expect(!r.ok, 'a missing selector must not report success');
      if (r.ok) return;
      expect(r.reason === 'no-match', `expected no-match, got ${r.reason}`);
      const after = await hands.screen();
      expect(after.hash === before.hash, 'a failed tap changed the screen');
    },
  },
  {
    name: 'tap falls back to the selector a repair replaced',
    async run(hands, ctx) {
      // A macro keeps its previous selector as `alt`, so a rolled-back release
      // or an A/B bucket still resolves.
      const r = await hands.find({ id: ctx.absentId }, { id: ctx.presentId });
      expect(r.ok, 'fallback did not resolve');
      if (!r.ok) return;
      expect(r.via === 'alt', `expected the fallback to win, got ${r.via}`);
    },
  },
  {
    name: 'a coordinate landing on nothing is not a missing selector',
    async run(hands) {
      // The control is not gone, the layout moved. Repair treats them
      // differently, so the reasons stay distinct.
      const r = await hands.find({ point: [0.5, 0.999] });
      if (r.ok) return; // something really is down there; nothing to assert
      expect(r.reason === 'point-outside', `expected point-outside, got ${r.reason}`);
    },
  },
  {
    name: 'assert succeeds on something already present',
    async run(hands, ctx) {
      const r = await hands.assert({ id: ctx.presentId }, 3000);
      expect(r.ok, `assert failed on a present element: ${r.ok ? '' : r.reason}`);
    },
  },
  {
    name: 'assert gives up rather than hanging',
    async run(hands, ctx) {
      const started = Date.now();
      const r = await hands.assert({ id: ctx.absentId }, 800);
      const elapsed = Date.now() - started;
      expect(!r.ok, 'assert passed on an absent element');
      expect(elapsed < 5000, `assert took ${elapsed}ms for an 800ms timeout`);
    },
  },
  {
    name: 'answering an alert that is not showing is refused',
    async run(hands) {
      const r = await hands.answerAlert('허용');
      expect(!r.ok, 'answered a non-existent alert');
    },
  },
  {
    name: 'health reports readiness and a recovery count',
    async run(hands) {
      const h = await hands.health();
      expect(h.ready, `not ready: ${h.detail ?? ''}`);
      expect(Number.isInteger(h.recoveries), 'recoveries is not a count');
    },
  },
  {
    name: 'a failed action leaves the target usable',
    async run(hands, ctx) {
      await hands.tap({ id: ctx.absentId });
      const s = await hands.screen();
      expect(s.elements.length > 0, 'target unusable after a failed action');
    },
  },
];

/** Run every case, collecting failures instead of stopping at the first. */
export async function runContract(
  hands: Hands,
  ctx: ContractContext,
): Promise<{ name: string; error?: string }[]> {
  const results: { name: string; error?: string }[] = [];
  for (const c of CONTRACT) {
    try {
      await ctx.reset();
      await c.run(hands, ctx);
      results.push({ name: c.name });
    } catch (err) {
      results.push({ name: c.name, error: err instanceof Error ? err.message : String(err) });
    }
  }
  return results;
}

export type { Selector };
