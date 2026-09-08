import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CONTRACT } from './contract.js';
import { FakeHands } from './fake.js';

/**
 * The shared contract, run against the fake replaying **recorded** screens.
 *
 * This is the closest CI gets to the device. The trees are real Settings
 * dumps and the transitions are the ones that actually fired when
 * `npm run record` walked the app, so a rule that only works on a
 * hand-written tree fails here rather than surviving until someone plugs in a
 * phone.
 *
 * The same cases pass against a live agent under `npm run live`, with the same
 * selectors — the identifiers below are Settings' own.
 */

const SCENARIO = fileURLToPath(
  new URL('./fixtures/settings/settings.scenario.json', import.meta.url),
);

describe('Hands contract — FakeHands over recorded Settings screens', () => {
  for (const c of CONTRACT) {
    it(c.name, async () => {
      const hands = FakeHands.fromScenario(SCENARIO);
      const ctx = {
        presentId: 'com.apple.settings.general',
        presentLabel: '스크린 타임',
        absentId: 'definitely-not-here',
        reset: async () => {
          await hands.launch({ bundleId: 'com.apple.Preferences', restart: true });
        },
      };
      await expect(c.run(hands, ctx)).resolves.toBeUndefined();
      await hands.close();
    });
  }
});

describe('recorded Settings — navigation', () => {
  const open = () => FakeHands.fromScenario(SCENARIO);

  it('replays the walk that was recorded', async () => {
    const hands = open();
    expect(hands.screenName).toBe('root');

    await hands.tap({ id: 'com.apple.settings.general' });
    expect(hands.screenName).toBe('general');

    await hands.back();
    expect(hands.screenName).toBe('root-again');
  });

  it('kept the two root screens apart', async () => {
    // Returning to the list does not reproduce the screen byte for byte — 16
    // elements on arrival, 17 after coming back. A hand-written fixture would
    // have made them identical and hidden the fact that a macro cannot assume
    // going back lands somewhere it has seen before.
    const hands = open();
    const first = await hands.screen();
    await hands.tap({ id: 'com.apple.settings.general' });
    await hands.back();
    const second = await hands.screen();
    expect(second.hash).not.toBe(first.hash);
    expect(second.elements.some((e) => e.id === 'com.apple.settings.general')).toBe(true);
  });
});
