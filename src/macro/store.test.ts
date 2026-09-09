import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Macro } from '../shared/types.js';
import { MacroStore } from './store.js';

let dir: string;
let store: MacroStore;

const macro = (over: Partial<Macro> = {}): Macro =>
  ({
    id: 'demo',
    version: 1,
    triggers: ['테스트'],
    app: 'com.example.app',
    risk: 'safe',
    params: {},
    steps: [
      { op: 'tap', sel: { id: 'a' } },
      { op: 'tap', sel: { id: 'b' } },
    ],
    stats: { runs: 0, fails: 0, avgMs: 0 },
    ...over,
  }) as Macro;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'nubi-macros-'));
  store = new MacroStore(dir);
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('MacroStore — reading and writing', () => {
  it('round-trips a macro', () => {
    store.save(macro());
    expect(store.get('demo').steps).toHaveLength(2);
  });

  it('writes readable JSON, since these files are reviewed by people', () => {
    store.save(macro());
    const text = readFileSync(join(dir, 'demo.json'), 'utf8');
    expect(text).toContain('\n  "id": "demo"');
    expect(text.endsWith('\n')).toBe(true);
  });

  it('leaves no partial file behind if a write is cut short', () => {
    // Written to a temp name and renamed, so an interrupted run cannot leave a
    // truncated macro for the next one to choke on.
    store.save(macro());
    expect(() => store.get('demo')).not.toThrow();
    expect(readFileSync(join(dir, 'demo.json'), 'utf8')).not.toContain('.tmp');
  });

  it('refuses a macro that would not load again', () => {
    expect(() => store.save(macro({ id: 'Not A Filename!' }))).toThrow();
  });

  it('is loud about a corrupt file rather than skipping it', () => {
    // Silently ignoring one would make a macro disappear from routing with no
    // sign of why.
    writeFileSync(join(dir, 'broken.json'), '{ not json');
    expect(() => store.all()).toThrow();
  });
});

describe('MacroStore — run statistics', () => {
  beforeEach(() => store.save(macro()));

  it('counts runs and failures', () => {
    store.recordRun('demo', { ok: true, durationMs: 1000 });
    store.recordRun('demo', { ok: false, durationMs: 9000 });
    const s = store.get('demo').stats;
    expect(s.runs).toBe(2);
    expect(s.fails).toBe(1);
  });

  it('averages only successful runs', () => {
    // How long a failure took to give up is a different quantity; folding it
    // in produces an average that describes neither.
    store.recordRun('demo', { ok: true, durationMs: 1000 });
    store.recordRun('demo', { ok: true, durationMs: 2000 });
    store.recordRun('demo', { ok: false, durationMs: 60_000 });
    expect(store.get('demo').stats.avgMs).toBe(1500);
  });

  it('records when it last ran', () => {
    store.recordRun('demo', { ok: true, durationMs: 1000 });
    expect(store.get('demo').stats.lastRun).toMatch(/^\d{4}-/);
  });
});

describe('MacroStore — demotion', () => {
  it('keeps trusting a macro that mostly works', () => {
    store.save(macro({ stats: { runs: 10, fails: 2, avgMs: 100 } }));
    expect(store.routable().map((m) => m.id)).toContain('demo');
  });

  it('stops routing to one that fails often', () => {
    // A macro that fails often is worse than none: it burns a run before
    // falling back to exploring, every time.
    store.save(macro({ stats: { runs: 10, fails: 5, avgMs: 100 } }));
    expect(store.routable()).toHaveLength(0);
    expect(store.demoted().map((m) => m.id)).toEqual(['demo']);
  });

  it('holds judgement until there is enough evidence', () => {
    store.save(macro({ stats: { runs: 2, fails: 2, avgMs: 0 } }));
    expect(store.routable()).toHaveLength(1);
  });

  it('does not delete a demoted macro', () => {
    // Its steps are still the best starting point anyone has, and a repair may
    // bring it back.
    store.save(macro({ stats: { runs: 10, fails: 9, avgMs: 100 } }));
    expect(store.get('demo').steps).toHaveLength(2);
  });
});

describe('MacroStore — repair', () => {
  beforeEach(() => store.save(macro()));

  it('replaces the step and bumps the version', () => {
    const patched = store.patchSelector('demo', 1, { op: 'tap', sel: { id: 'b2' } });
    expect(patched.version).toBe(2);
    expect(patched.steps[1]).toEqual({ op: 'tap', sel: { id: 'b2' } });
    expect(patched.steps[0]).toEqual({ op: 'tap', sel: { id: 'a' } });
  });

  it('keeps the replaced selector as a fallback', () => {
    // A rolled-back release or an A/B bucket puts the old screen back. It is
    // also how a bad repair announces itself: a macro that keeps winning
    // through `alt` is saying the replacement was wrong.
    store.patchSelector('demo', 1, { op: 'tap', sel: { id: 'b2' }, alt: { id: 'b' } });
    expect(store.get('demo').steps[1]).toMatchObject({ alt: { id: 'b' } });
  });

  it('stamps when it was healed', () => {
    store.patchSelector('demo', 0, { op: 'tap', sel: { id: 'a2' } });
    expect(store.get('demo').stats.healedAt).toMatch(/^\d{4}-/);
  });

  it('refuses a step index that does not exist', () => {
    expect(() => store.patchSelector('demo', 9, { op: 'back' })).toThrow(/no step 9/);
  });
});
