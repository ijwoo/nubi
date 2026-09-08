import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it } from 'vitest';
import { FakeHands } from './fake.js';

const SCENARIO = fileURLToPath(new URL('./fixtures/music.scenario.json', import.meta.url));

let hands: FakeHands;
beforeEach(() => {
  hands = FakeHands.fromScenario(SCENARIO);
});

describe('FakeHands — scenario loading', () => {
  it('starts on the scenario start screen', async () => {
    expect(hands.screenName).toBe('home');
    const s = await hands.screen();
    expect(s.app).toBe('com.apple.Music');
    expect(s.elements.some((e) => e.l === '지금 듣기')).toBe(true);
  });

  it('rejects a start screen the scenario does not define', () => {
    expect(() => FakeHands.fromScenario(SCENARIO, { at: 'nowhere' })).toThrow(
      /unknown start screen/,
    );
  });
});

describe('FakeHands — navigation', () => {
  it('follows a transition matched by identifier', async () => {
    const r = await hands.tap({ id: 'tab_search' });
    expect(r.ok).toBe(true);
    expect(hands.screenName).toBe('search-empty');
  });

  it('follows a transition matched by label', async () => {
    hands.goto('search-results');
    await hands.tap({ label: 'Hype Boy' });
    expect(hands.screenName).toBe('playing');
  });

  it('walks a whole route the way a macro would', async () => {
    await hands.launch({ url: 'musicapp://' });
    await hands.tap({ id: 'tab_search' });
    await hands.type('뉴진스', { submit: true });
    await hands.tap({ label: 'Hype Boy' });

    expect(hands.screenName).toBe('playing');
    const done = await hands.assert({ label: '일시정지' });
    expect(done.ok).toBe(true);
  });

  it('leaves the screen alone when a tap matches no transition', async () => {
    // Tapping the tab you are already on is a real no-op, not a failure.
    const r = await hands.tap({ label: '홈' });
    expect(r.ok).toBe(true);
    expect(hands.screenName).toBe('home');
  });

  it('prefers a screen-specific transition over a wildcard', async () => {
    hands.goto('playing');
    await hands.tap({ id: 'close_player' });
    expect(hands.screenName).toBe('search-results');
  });

  it('applies a wildcard transition when nothing specific matches', async () => {
    hands.goto('playing');
    await hands.back();
    expect(hands.screenName).toBe('home');
  });

  it('routes launch by url, falling back to start', async () => {
    await hands.launch({ url: 'musicapp://search' });
    expect(hands.screenName).toBe('search-empty');
    await hands.launch({ url: 'musicapp://unknown' });
    expect(hands.screenName).toBe('home');
  });
});

describe('FakeHands — misses', () => {
  it('reports a missing selector and hands back the screen for repair', async () => {
    const r = await hands.tap({ id: 'renamed_in_v2' });
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error('unreachable');
    expect(r.reason).toBe('no-match');
    // Repair needs the screen immediately; fetching it separately would show a
    // screen that had already moved on.
    expect(r.screen.elements.length).toBeGreaterThan(0);
    expect(hands.screenName).toBe('home');
  });

  it('distinguishes a coordinate landing on nothing', async () => {
    const r = await hands.tap({ point: [0.5, 0.999] });
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error('unreachable');
    expect(r.reason).toBe('point-outside');
  });

  it('recovers via the selector a repair replaced', async () => {
    const r = await hands.tap({ id: 'gone_in_v2' }, { label: '검색' });
    expect(r.ok).toBe(true);
    if (!r.ok) throw new Error('unreachable');
    expect(r.via).toBe('alt');
    expect(hands.screenName).toBe('search-empty');
  });

  it('fails an assert whose selector is not on screen', async () => {
    const r = await hands.assert({ label: '일시정지' }, 500);
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error('unreachable');
    expect(r.reason).toBe('no-match');
    expect(r.waitedMs).toBe(0); // fixture state only moves on an action
  });
});

describe('FakeHands — injected failures', () => {
  it('fails exactly one call, then behaves normally', async () => {
    hands.failNext('session-lost');
    const first = await hands.tap({ id: 'tab_search' });
    expect(first.ok).toBe(false);
    expect(hands.screenName).toBe('home'); // the action did not happen

    const second = await hands.tap({ id: 'tab_search' });
    expect(second.ok).toBe(true);
    expect(hands.screenName).toBe('search-empty');
  });

  it('counts a lost session so recovery can be asserted', async () => {
    expect((await hands.health()).recoveries).toBe(0);
    hands.failNext('session-lost');
    await hands.back();
    expect((await hands.health()).recoveries).toBe(1);
  });
});

describe('FakeHands — call log', () => {
  it('records what was asked and where it landed', async () => {
    await hands.tap({ id: 'tab_search' });
    await hands.type('뉴진스');

    expect(hands.calls.map((c) => c.action)).toEqual(['tap', 'type']);
    expect(hands.calls[0]).toMatchObject({ screenBefore: 'home', screenAfter: 'search-empty' });
    expect(hands.calls[1]).toMatchObject({
      screenBefore: 'search-empty',
      screenAfter: 'search-results',
    });
  });
});

describe('FakeHands — system alerts', () => {
  it('reports a modal on the screen, since the tree never shows one', async () => {
    hands.showAlert('위치를 사용하도록 허용하겠습니까?', ['허용', '허용 안 함']);
    const s = await hands.screen();
    expect(s.alert?.buttons).toEqual(['허용', '허용 안 함']);
  });

  it('blocks a tap rather than reporting a selector miss', async () => {
    // The control is there and the selector finds it — a modal is eating the
    // touch. Calling that a selector problem would send repair after the wrong
    // thing.
    hands.showAlert('허용하겠습니까?', ['허용']);
    const r = await hands.tap({ id: 'tab_search' });
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error('unreachable');
    expect(r.reason).toBe('blocked-by-alert');
    expect(hands.screenName).toBe('home');
  });

  it('never answers an alert on its own', async () => {
    hands.showAlert('삭제하시겠습니까?', ['삭제', '취소']);
    await hands.tap({ id: 'tab_search' });
    await hands.screen();
    // Granting permission or confirming a delete is exactly the kind of
    // irreversible choice the approval gate exists for (ADR 0007).
    expect((await hands.screen()).alert).toBeDefined();
  });

  it('answers only a button the alert actually offers', async () => {
    hands.showAlert('허용하겠습니까?', ['허용', '허용 안 함']);
    const wrong = await hands.answerAlert('확인');
    expect(wrong.ok).toBe(false);

    const right = await hands.answerAlert('허용 안 함');
    expect(right.ok).toBe(true);
    expect((await hands.screen()).alert).toBeUndefined();
  });

  it('resumes normally once the alert is answered', async () => {
    hands.showAlert('허용하겠습니까?', ['허용']);
    await hands.answerAlert('허용');
    const r = await hands.tap({ id: 'tab_search' });
    expect(r.ok).toBe(true);
    expect(hands.screenName).toBe('search-empty');
  });
});
