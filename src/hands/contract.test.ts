import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CONTRACT } from './contract.js';
import { FakeHands } from './fake.js';

/**
 * The shared contract, run against the fake.
 *
 * `npm run live` runs the same cases against a real WebDriverAgent. Both
 * targets passing is what makes it reasonable to build replay, repair, and
 * explore against the fake and swap them onto a device later.
 */

const SCENARIO = fileURLToPath(new URL('./fixtures/music.scenario.json', import.meta.url));

describe('Hands contract — FakeHands', () => {
  for (const c of CONTRACT) {
    it(c.name, async () => {
      const hands = FakeHands.fromScenario(SCENARIO);
      const ctx = {
        presentId: 'tab_search',
        presentLabel: '홈',
        absentId: 'definitely-not-here',
        reset: async () => {
          await hands.launch({ bundleId: 'com.apple.Music', restart: true });
        },
      };
      await expect(c.run(hands, ctx)).resolves.toBeUndefined();
      await hands.close();
    });
  }
});
