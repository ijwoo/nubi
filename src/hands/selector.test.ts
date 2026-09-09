import { describe, expect, it } from 'vitest';
import { compact } from './compact.js';
import fixture from './fixtures/music-search.json' with { type: 'json' };
import { resolve, resolveWithFallback } from './selector.js';
import type { WdaNode } from './wda-types.js';

const screen = compact(fixture.value as WdaNode, { app: 'com.apple.Music' });

/** Narrow to the success shape, failing the test with the reason if it missed. */
function hit(r: ReturnType<typeof resolve>) {
  if (!r.ok) throw new Error(`expected a match, got ${r.reason}`);
  return r;
}

describe('resolve — identifier', () => {
  it('finds a control by accessibilityIdentifier', () => {
    const r = hit(resolve({ id: 'nav_back' }, screen));
    expect(r.element.l).toBe('뒤로');
    expect(r.rung).toBe('id');
    expect(r.matched).toBe(1);
  });

  it('misses cleanly when the identifier is gone', () => {
    const r = resolve({ id: 'nope' }, screen);
    expect(r).toEqual({ ok: false, reason: 'no-match' });
  });
});

describe('resolve — label', () => {
  it('matches an exact label', () => {
    expect(hit(resolve({ label: 'Ditto' }, screen)).element.t).toBe('Cell');
  });

  it('also matches a field by its current content', () => {
    // "음악" is the search field's value, not its label.
    expect(hit(resolve({ label: '음악' }, screen)).element.t).toBe('SearchField');
  });

  it('prefers a tappable control when a label is ambiguous', () => {
    // "검색" is both the navigation title (StaticText) and the tab (Button).
    // A tap is aimed at the button; the title is never the target.
    const r = hit(resolve({ label: '검색' }, screen));
    expect(r.element.t).toBe('Button');
    expect(r.element.id).toBe('tab_search');
    expect(r.matched).toBe(2);
  });

  it('reports how many matched, so an under-specified macro is visible', () => {
    // It resolves today by tie-break, and will pick differently the day the
    // screen changes. `matched > 1` is the warning.
    expect(hit(resolve({ label: '검색' }, screen)).matched).toBeGreaterThan(1);
    expect(hit(resolve({ label: 'Ditto' }, screen)).matched).toBe(1);
  });

  it('disambiguates by type when the macro says one', () => {
    const r = hit(resolve({ label: '검색', type: 'StaticText' }, screen));
    expect(r.element.t).toBe('StaticText');
    expect(r.matched).toBe(1);
  });
});

describe('resolve — labelContains', () => {
  it('matches a substring', () => {
    expect(hit(resolve({ labelContains: '셔플' }, screen)).element.id).toBe('shuffle_all');
  });

  it('narrows by type', () => {
    const r = resolve({ labelContains: '검', type: 'SearchField' }, screen);
    expect(r.ok).toBe(false);
  });
});

describe('resolve — index', () => {
  it('takes the nth element of a type in document order', () => {
    expect(hit(resolve({ index: { type: 'Cell', n: 0 } }, screen)).element.l).toBe('트랙 1');
    expect(hit(resolve({ index: { type: 'Cell', n: 1 } }, screen)).element.l).toBe('Ditto');
  });

  it('misses when the list is shorter than the index', () => {
    expect(resolve({ index: { type: 'Cell', n: 9 } }, screen).ok).toBe(false);
  });
});

describe('resolve — point', () => {
  it('hits the innermost element containing the point', () => {
    // Centre of the "Ditto" cell: y 219..283 of an 852pt screen.
    const r = hit(resolve({ point: [0.5, 251 / 852] }, screen));
    expect(r.element.l).toBe('Ditto');
  });

  it('distinguishes landing outside everything from a miss', () => {
    // A blank strip below the tab bar. The control is not gone — the layout
    // moved — so repair should treat this differently.
    const r = resolve({ point: [0.5, 0.995] }, screen);
    expect(r).toEqual({ ok: false, reason: 'point-outside' });
  });
});

describe('resolve — ranking', () => {
  it('avoids a disabled control when an enabled one also matches', () => {
    const twin = {
      ...screen,
      elements: [
        {
          i: 0,
          t: 'Button',
          l: '저장',
          r: [0, 0, 50, 20] as [number, number, number, number],
          e: false,
        },
        {
          i: 1,
          t: 'Button',
          l: '저장',
          r: [0, 30, 50, 20] as [number, number, number, number],
          e: true,
        },
      ],
    };
    expect(hit(resolve({ label: '저장' }, twin)).element.i).toBe(1);
  });
});

describe('resolveWithFallback', () => {
  it('uses the primary selector when it resolves', () => {
    const r = resolveWithFallback({ id: 'nav_back' }, { label: '뒤로' }, screen);
    expect(r.via).toBe('sel');
  });

  it('falls back to the selector a repair replaced', () => {
    // Repair keeps the old selector as `alt`, so a rolled-back release or an
    // A/B bucket still resolves.
    const r = resolveWithFallback({ id: 'renamed_in_v2' }, { label: '뒤로' }, screen);
    expect(r.ok).toBe(true);
    expect(r.via).toBe('alt');
  });

  it('reports the primary failure when neither resolves', () => {
    const r = resolveWithFallback({ id: 'gone' }, { id: 'also-gone' }, screen);
    expect(r.ok).toBe(false);
    expect(r.via).toBe('sel');
  });
});
