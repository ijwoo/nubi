import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { compact } from '../hands/compact.js';
import type { WdaNode } from '../hands/wda-types.js';
import { renderScreen, renderTurn } from './prompt.js';

const REAL = fileURLToPath(new URL('../hands/fixtures/real/settings.json', import.meta.url));
const screen = compact(JSON.parse(readFileSync(REAL, 'utf8')).value as WdaNode, {
  app: 'com.apple.Preferences',
});

describe('renderScreen', () => {
  const text = renderScreen(screen);

  it('numbers every element so the model can name one', () => {
    for (const e of screen.elements) {
      expect(text).toContain(String(e.i).padStart(3));
    }
  });

  it('shows identifiers, which are what a durable selector is built from', () => {
    expect(text).toContain('#com.apple.settings.general');
  });

  it('keeps a field label and its content apart', () => {
    const rendered = renderScreen({
      ...screen,
      elements: [{ i: 0, t: 'SearchField', l: '검색', v: '음악', r: [0, 0, 1, 1], e: true }],
    });
    expect(rendered).toContain('"검색"');
    expect(rendered).toContain('= "음악"');
  });

  it('marks a disabled control rather than hiding it', () => {
    // A greyed-out button explains why a path is blocked.
    const rendered = renderScreen({
      ...screen,
      elements: [{ i: 0, t: 'Button', l: '저장', r: [0, 0, 1, 1], e: false }],
    });
    expect(rendered).toContain('(disabled)');
  });

  it('leaves coordinates out', () => {
    // Compaction already dropped anything off-screen, so document order tracks
    // visual order. Offering rects would invite arithmetic whose only product
    // is the most fragile kind of selector.
    expect(text).not.toMatch(/\brect\b|\bx=\d/);
  });

  it('stays small enough to send every step', () => {
    expect(Math.ceil(text.length / 3)).toBeLessThan(800);
  });
});

describe('renderTurn', () => {
  const base = { goal: '손쉬운 사용 열기', screen, history: [], stepsRemaining: 20 };

  it('leads with the goal', () => {
    expect(renderTurn(base)).toContain('Goal: 손쉬운 사용 열기');
  });

  it('says nothing about history on the first turn', () => {
    expect(renderTurn(base)).not.toContain('Already tried');
  });

  it('lists what has been tried, with the reasons given at the time', () => {
    const text = renderTurn({
      ...base,
      history: [
        { kind: 'tap', element: 4, why: '설정 목록에서 일반' },
        { kind: 'back', why: '엉뚱한 화면' },
      ],
    });
    expect(text).toContain('1. tap element 4 — 설정 목록에서 일반');
    expect(text).toContain('2. back — 엉뚱한 화면');
  });

  it('reports the previous failure, so the obvious repeat is less likely', () => {
    expect(renderTurn({ ...base, lastFailure: 'no element 999 on screen' })).toContain(
      'The last action failed: no element 999 on screen',
    );
  });

  it('shows how many steps are left', () => {
    expect(renderTurn({ ...base, stepsRemaining: 3 })).toContain('Steps left: 3');
  });

  it('says the keyboard is open so the model types instead of tapping again', () => {
    // Live run rmttza3la3nbz tapped the search field, saw an identical screen,
    // and tapped it again before typing — a wasted turn and a wasted call.
    expect(renderScreen({ ...screen, keyboard: true })).toContain('keyboard is open');
    expect(renderScreen(screen)).not.toContain('keyboard is open');
  });
});
