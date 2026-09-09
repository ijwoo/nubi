import { describe, expect, it } from 'vitest';
import { MacroSchema, SelectorSchema, isDemoted } from './types.js';

describe('SelectorSchema', () => {
  it('accepts each rung of the priority ladder', () => {
    const rungs = [
      { id: 'search_btn' },
      { label: '검색', type: 'Button' },
      { labelContains: '햄버거' },
      { index: { type: 'Cell', n: 0 } },
      { point: [0.5, 0.12] },
    ];
    for (const r of rungs) {
      expect(SelectorSchema.safeParse(r).success).toBe(true);
    }
  });

  it('rejects coordinates outside 0..1 — points are normalized, not pixels', () => {
    expect(SelectorSchema.safeParse({ point: [540, 120] }).success).toBe(false);
  });
});

describe('MacroSchema', () => {
  const minimal = {
    id: 'music-play',
    triggers: ['음악에서 {track} 재생'],
    app: 'com.apple.Music',
    steps: [{ op: 'tap', sel: { id: 'search' } }],
  };

  it('fills defaults so a hand-written macro stays terse', () => {
    const m = MacroSchema.parse(minimal);
    expect(m.version).toBe(1);
    expect(m.risk).toBe('safe');
    expect(m.stats.runs).toBe(0);
  });

  it('requires at least one trigger — an unroutable macro is dead weight', () => {
    expect(MacroSchema.safeParse({ ...minimal, triggers: [] }).success).toBe(false);
  });

  it('rejects ids that would not be safe as filenames', () => {
    expect(MacroSchema.safeParse({ ...minimal, id: 'YT Music!' }).success).toBe(false);
  });
});

describe('isDemoted', () => {
  const withStats = (runs: number, fails: number) =>
    MacroSchema.parse({
      id: 'x',
      triggers: ['x'],
      app: 'com.x',
      steps: [{ op: 'back' }],
      stats: { runs, fails, avgMs: 0 },
    });

  it('holds judgement until there is enough evidence', () => {
    expect(isDemoted(withStats(3, 3))).toBe(false);
  });

  it('demotes a macro that fails more than 30% of the time', () => {
    expect(isDemoted(withStats(10, 4))).toBe(true);
  });

  it('keeps a macro that mostly works', () => {
    expect(isDemoted(withStats(10, 2))).toBe(false);
  });
});
