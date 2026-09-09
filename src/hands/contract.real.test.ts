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

    await hands.tap({ id: 'com.apple.settings.accessibility' });
    expect(hands.screenName).toBe('accessibility');

    await hands.back();
    expect(hands.screenName).toBe('root-back');

    await hands.tap({ id: 'com.apple.settings.general' });
    expect(hands.screenName).toBe('general');
  });

  it('reaches every screen a macro in macros/ asks for', async () => {
    // The recording used to stop at `general`, so two of the three macros had
    // no route and read 0/5 offline — a number indistinguishable from a macro
    // that had actually broken. The live run passed 5/5 and hid it for a week.
    const about = open();
    await about.tap({ id: 'com.apple.settings.general' });
    await about.tap({ id: 'About', type: 'Button' });
    expect(about.screenName).toBe('about');
    expect((await about.find({ id: 'SW_VERSION_SPECIFIER' })).ok).toBe(true);

    const search = open();
    await search.tap({ type: 'SearchField', label: '검색' });
    expect(search.screenName).toBe('search-focused');
    await search.type('손쉬운');
    expect(search.screenName).toBe('search-results');
    expect((await search.find({ label: '텍스트 지우기' })).ok).toBe(true);
  });

  it('carries the keyboard through from the recording', async () => {
    // Recorded raw and compacted on read, so the bit is not something the
    // scenario file asserts — it survives only if the keys are really there.
    const hands = open();
    expect((await hands.screen()).keyboard).toBeUndefined();
    await hands.tap({ type: 'SearchField', label: '검색' });
    expect((await hands.screen()).keyboard).toBe(true);
  });

  it('kept the first view of the list apart from a return to it', async () => {
    // Coming back does not reproduce the screen byte for byte: 16 elements on
    // arrival, 17 after returning. A hand-written fixture would have made them
    // identical and taught replay that going back lands somewhere it has
    // already seen.
    const hands = open();
    const first = await hands.screen();
    await hands.tap({ id: 'com.apple.settings.accessibility' });
    await hands.back();
    const returned = await hands.screen();

    expect(returned.hash).not.toBe(first.hash);
    expect(returned.elements.some((e) => e.id === 'com.apple.settings.general')).toBe(true);
  });

  it('settles: a second return matches the first', async () => {
    // The two returns hash identically — the recorder now folds the second one
    // into the first rather than writing it twice — so the difference is
    // first-view versus any-later-view rather than drift that keeps growing.
    // Replay can rely on a returned-to screen being stable.
    const hands = open();
    await hands.tap({ id: 'com.apple.settings.accessibility' });
    await hands.back();
    const second = await hands.screen();

    await hands.tap({ id: 'com.apple.settings.general' });
    await hands.back();
    const third = await hands.screen();

    expect(third.hash).toBe(second.hash);
  });
});
