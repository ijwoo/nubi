import { describe, expect, it } from 'vitest';
import { compact, estimateTokens, hashElements } from './compact.js';
import fixture from './fixtures/music-search.json' with { type: 'json' };
import type { WdaNode } from './wda-types.js';
import { identifierOf } from './wda-types.js';

const root = fixture.value as WdaNode;
const screen = compact(root, { app: 'com.apple.Music' });
const byLabel = (l: string) => screen.elements.find((e) => e.l === l);

describe('compact', () => {
  it('reads screen size from the application node', () => {
    expect(screen.size).toEqual({ w: 393, h: 852 });
  });

  it('drops layout scaffolding that carries no meaning', () => {
    for (const t of ['Application', 'Window', 'Table', 'TabBar', 'NavigationBar']) {
      expect(screen.elements.some((e) => e.t === t)).toBe(false);
    }
  });

  it('keeps controls and their labels', () => {
    expect(byLabel('뒤로')?.t).toBe('Button');
    expect(byLabel('Ditto')?.t).toBe('Cell');
    expect(byLabel('홈')?.t).toBe('Button');
  });

  it('keeps a field label and its content apart', () => {
    // The label identifies the control, the value says what is in it. The
    // model needs both: to decide whether to type or to clear first, it has to
    // see that the search box already holds a query.
    const search = screen.elements.find((e) => e.t === 'SearchField');
    expect(search?.l).toBe('아티스트, 곡, 가사');
    expect(search?.v).toBe('뉴진스');
  });

  it('leaves value unset when it only repeats the label', () => {
    expect(byLabel('Ditto')?.v).toBeUndefined();
  });

  it('records an identifier only when it differs from the label', () => {
    expect(byLabel('뒤로')?.id).toBe('nav_back');
    // The Home tab reports name === label, which is WDA's fallback, not a real
    // accessibilityIdentifier. Filing it as one would put a fragile selector on
    // the most-stable rung.
    expect(byLabel('홈')?.id).toBeUndefined();
  });

  it('collapses a child that repeats its kept ancestor label', () => {
    // The "Hype Boy" cell wraps a StaticText with the same label.
    expect(screen.elements.filter((e) => e.l === 'Hype Boy')).toHaveLength(1);
    expect(byLabel('Hype Boy')?.t).toBe('Cell');
    // A sibling with different text survives.
    expect(byLabel('NewJeans')?.t).toBe('StaticText');
  });

  it('drops invisible, zero-size, and offscreen nodes', () => {
    expect(byLabel('OMG')).toBeUndefined(); // isVisible 0 and below the fold
    expect(byLabel('취소')).toBeUndefined(); // zero rect
  });

  it('keeps an accessible container — how RN and Flutter expose controls', () => {
    expect(byLabel('전체 셔플')?.t).toBe('Other');
  });

  it('drops a decorative container even though it has a label', () => {
    expect(byLabel('decorative gradient')).toBeUndefined();
  });

  it('keeps disabled controls, marked disabled', () => {
    // A greyed-out button is information: it explains why a path is blocked.
    expect(byLabel('다운로드')?.e).toBe(false);
  });

  it('stays inside the per-screen observation budget', () => {
    // ADR 0002 targets 300-600 tokens per screen. This is the regression guard.
    expect(estimateTokens(screen.elements)).toBeLessThan(600);
  });

  it('flags truncation rather than silently shortening the screen', () => {
    const capped = compact(root, { app: 'com.apple.Music', maxElements: 3 });
    expect(capped.elements).toHaveLength(3);
    expect(capped.truncated).toBe(true);
    expect(screen.truncated).toBeUndefined();
  });
});

describe('hashElements', () => {
  it('is stable across recompaction of the same tree', () => {
    const again = compact(root, { app: 'com.apple.Music' });
    expect(again.hash).toBe(screen.hash);
  });

  it('ignores sub-quantum jitter so a settling scroll is not a new screen', () => {
    const jittered = screen.elements.map((e) => ({
      ...e,
      r: [e.r[0], e.r[1] + 1, e.r[2], e.r[3]] as const,
    }));
    expect(hashElements(jittered as never)).toBe(screen.hash);
  });

  it('changes when a control appears', () => {
    expect(hashElements(screen.elements.slice(0, -1))).not.toBe(screen.hash);
  });
});

describe('identifierOf', () => {
  it('returns undefined when the app set no identifier', () => {
    expect(identifierOf({ type: 'X', name: '검색', label: '검색' })).toBeUndefined();
    expect(identifierOf({ type: 'X', label: '검색' })).toBeUndefined();
    expect(identifierOf({ type: 'X', name: '  ', label: '검색' })).toBeUndefined();
  });
});
