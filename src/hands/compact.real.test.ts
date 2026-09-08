import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { compact, estimateTokens } from './compact.js';
import { resolve } from './selector.js';
import type { WdaNode } from './wda-types.js';

/**
 * Compaction measured against trees captured from a real iOS Simulator, not
 * hand-written ones.
 *
 * Every rule in `compact` exists because of something in these files: Settings
 * repeats a row's text across the Button and each StaticText inside it, wraps
 * every row in an untitled Cell, and hangs an identified `chevron.forward`
 * Image off each one. A fixture written from imagination has none of that.
 */

const DIR = fileURLToPath(new URL('./fixtures/real/', import.meta.url));

function load(name: string): WdaNode {
  return JSON.parse(readFileSync(`${DIR}${name}.json`, 'utf8')).value as WdaNode;
}
function screenOf(name: string) {
  return compact(load(name), { app: name });
}

const APPS = readdirSync(DIR)
  .filter((f) => f.endsWith('.json'))
  .map((f) => f.replace('.json', ''))
  .sort();

describe('real trees — every app', () => {
  it.each(APPS)('%s: every element can be named in a selector', (app) => {
    // An element with no label, value, or identifier cannot be targeted. It
    // costs budget and gives the model something it can see but not act on.
    for (const e of screenOf(app).elements) {
      expect(e.l ?? e.v ?? e.id, `${app}: ${e.t} at ${e.r.join(',')}`).toBeDefined();
    }
  });

  it.each(APPS)('%s: reports no element twice', (app) => {
    // WDA emits some elements twice, identical down to the rect. A duplicate
    // makes the resolver report two matches for a selector naming one control,
    // which is exactly the signal used to flag an under-specified selector.
    const keys = screenOf(app).elements.map(
      (e) => `${e.t}|${e.id ?? ''}|${e.l ?? ''}|${e.v ?? ''}|${e.r.join(',')}`,
    );
    expect(new Set(keys).size).toBe(keys.length);
  });

  it.each(APPS)('%s: stays inside the observation budget', (app) => {
    // Measured on the simulator: Maps 136, Reminders 192, Settings 504,
    // Calendar 686. ADR 0002 set 300-600 as a target before any of this was
    // measured; a dense screen like a day view legitimately carries thirty
    // addressable controls. The ceiling here bounds that real worst case
    // rather than pretending the guess was right.
    expect(estimateTokens(screenOf(app).elements)).toBeLessThan(800);
  });

  it.each(APPS)('%s: compacts by at least an order of magnitude', (app) => {
    const raw = JSON.stringify(load(app)).length;
    const out = JSON.stringify(screenOf(app).elements).length;
    expect(raw / out).toBeGreaterThan(10);
  });
});

describe('real trees — Settings list', () => {
  const screen = screenOf('settings');
  const labels = screen.elements.map((e) => e.l);

  it('keeps the row button and drops the untitled cell wrapping it', () => {
    const general = screen.elements.find((e) => e.id === 'com.apple.settings.general');
    expect(general?.t).toBe('Button');
    expect(screen.elements.some((e) => e.t === 'Cell')).toBe(false);
  });

  it('drops the chevron each row hangs off itself', () => {
    // Nine of these, one per row, each with its own identifier.
    expect(screen.elements.some((e) => e.id === 'chevron.forward')).toBe(false);
  });

  it('drops text the row button already speaks for', () => {
    // iOS builds the row's label by joining its children, so the fragments
    // "Apple 계정" and "iCloud 데이터…" appear again inside it.
    expect(labels.filter((l) => l === 'Apple 계정')).toHaveLength(0);
    expect(labels.some((l) => l?.startsWith('Apple 계정, iCloud'))).toBe(true);
  });

  it('takes identifiers from rawIdentifier rather than inferring them', () => {
    const ids = screen.elements.map((e) => e.id).filter(Boolean);
    expect(ids.length).toBeGreaterThan(5);
    expect(ids).toContain('com.apple.settings.general');
  });

  it('keeps an identifier that happens to equal its label', () => {
    // The Apple ID icon carries rawIdentifier "apple.id" and label "apple.id".
    // The heuristic this replaced — treat `name` as an identifier only when it
    // differs from the label — would have discarded a real identifier here.
    // Reading the authoritative field removes the guess entirely.
    const icon = screen.elements.find((e) => e.id === 'apple.id');
    expect(icon?.l).toBe('apple.id');
  });
});

describe('real trees — selectors resolve', () => {
  it('finds a Settings row by its identifier', () => {
    const r = resolve({ id: 'com.apple.settings.accessibility' }, screenOf('settings'));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.element.l).toBe('손쉬운 사용');
    expect(r.matched).toBe(1); // unambiguous on a real screen
  });

  it('finds a Calendar control by label', () => {
    const r = resolve({ label: '오늘', type: 'Button' }, screenOf('mobilecal'));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.element.id).toBe('today-button');
  });

  it('hit-tests a normalized point against a real layout', () => {
    const screen = screenOf('settings');
    const target = screen.elements.find((e) => e.id === 'com.apple.settings.general');
    if (!target) throw new Error('fixture changed');
    const cx = (target.r[0] + target.r[2] / 2) / screen.size.w;
    const cy = (target.r[1] + target.r[3] / 2) / screen.size.h;
    const r = resolve({ point: [cx, cy] }, screen);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.element.id).toBe('com.apple.settings.general');
  });
});
