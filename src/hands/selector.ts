import type { Element, Screen, Selector } from '../shared/types.js';

/**
 * Resolve a selector against a compacted screen.
 *
 * This is the other half of what makes replay work without a model (ADR 0003):
 * a stored selector has to find the same control again, deterministically, on a
 * screen that may have shifted. It is a pure function over `Screen`, so the
 * whole priority ladder is testable without a device.
 */

/** Types that a tap can plausibly be aimed at. Used to break ties. */
const TAPPABLE = new Set([
  'Button',
  'Cell',
  'TextField',
  'SecureTextField',
  'SearchField',
  'TextView',
  'Switch',
  'Link',
  'MenuItem',
  'Tab',
  'Key',
  'SegmentedControl',
  'CheckBox',
  'RadioButton',
]);

/** Which rung of the priority ladder produced a match. Lower is more stable. */
export type Rung = 'id' | 'label' | 'labelContains' | 'index' | 'point';

export interface Resolution {
  element: Element;
  rung: Rung;
  /**
   * How many elements matched before ranking. Anything above 1 means the
   * selector is under-specified: it works today by tie-break, and will silently
   * pick differently the day the screen changes. Recorded so the trace shows it
   * and macro extraction can warn.
   */
  matched: number;
}

export type ResolveFailure =
  | { reason: 'no-match' }
  /** A point selector landed nowhere — usually a layout shift, not a miss. */
  | { reason: 'point-outside' };

export type ResolveResult = ({ ok: true } & Resolution) | ({ ok: false } & ResolveFailure);

export function resolve(sel: Selector, screen: Screen): ResolveResult {
  if ('id' in sel) {
    return rank(
      screen.elements.filter((e) => e.id === sel.id),
      'id',
    );
  }

  if ('label' in sel) {
    const wanted = sel.label;
    return rank(
      screen.elements.filter((e) => matchesType(e, sel.type) && (e.l === wanted || e.v === wanted)),
      'label',
      wanted,
    );
  }

  if ('labelContains' in sel) {
    const needle = sel.labelContains;
    return rank(
      screen.elements.filter(
        (e) => matchesType(e, sel.type) && (includes(e.l, needle) || includes(e.v, needle)),
      ),
      'labelContains',
    );
  }

  if ('index' in sel) {
    const ofType = screen.elements.filter((e) => e.t === sel.index.type);
    const hit = ofType[sel.index.n];
    if (!hit) return { ok: false, reason: 'no-match' };
    return { ok: true, element: hit, rung: 'index', matched: 1 };
  }

  return resolvePoint(sel.point, screen);
}

/**
 * Hit-test a normalized point.
 *
 * Coordinates are the last rung for a reason (ADR 0004), and this is where that
 * shows: several stacked elements contain any given point, so the innermost —
 * smallest area — is taken as the target. Landing outside every element is
 * reported distinctly from a miss, because it means the layout moved rather
 * than that the control is gone.
 */
function resolvePoint(point: readonly [number, number], screen: Screen): ResolveResult {
  const x = point[0] * screen.size.w;
  const y = point[1] * screen.size.h;

  const hits = screen.elements.filter(
    (e) => x >= e.r[0] && y >= e.r[1] && x <= e.r[0] + e.r[2] && y <= e.r[1] + e.r[3],
  );
  if (hits.length === 0) return { ok: false, reason: 'point-outside' };

  const innermost = hits.reduce((best, e) => (area(e) < area(best) ? e : best));
  return { ok: true, element: innermost, rung: 'point', matched: hits.length };
}

/**
 * Pick among equally-matching elements.
 *
 * A label like "검색" routinely matches both a navigation title and a tab
 * button. Ranking prefers what a tap could plausibly be aimed at, so an
 * under-specified macro still does the sensible thing — while `matched` records
 * that the ambiguity was there.
 */
function rank(candidates: Element[], rung: Rung, exactLabel?: string): ResolveResult {
  if (candidates.length === 0) return { ok: false, reason: 'no-match' };

  const best = [...candidates].sort((a, b) => score(b, exactLabel) - score(a, exactLabel))[0];
  // Non-empty candidates guarantees a first element; the sort cannot drop one.
  if (!best) return { ok: false, reason: 'no-match' };

  return { ok: true, element: best, rung, matched: candidates.length };
}

function score(e: Element, exactLabel?: string): number {
  let s = 0;
  if (e.e) s += 4; // a disabled control is almost never the intended target
  if (TAPPABLE.has(e.t)) s += 2;
  // A label match beats a value match: the label names the control, the value
  // is whatever happens to be in it right now.
  if (exactLabel !== undefined && e.l === exactLabel) s += 1;
  return s;
}

function matchesType(e: Element, type: string | undefined): boolean {
  return type === undefined || e.t === type;
}

function includes(hay: string | undefined, needle: string): boolean {
  return hay?.includes(needle) ?? false;
}

function area(e: Element): number {
  return e.r[2] * e.r[3];
}

/**
 * Try a selector, then its recorded fallback.
 *
 * Repair keeps the selector it replaced as `alt` rather than deleting it, so a
 * rolled-back release or an A/B bucket still resolves. Which one hit is
 * reported, because a macro that keeps winning on `alt` is telling you the
 * repair was wrong.
 */
export function resolveWithFallback(
  sel: Selector,
  alt: Selector | undefined,
  screen: Screen,
): ResolveResult & { via: 'sel' | 'alt' } {
  const primary = resolve(sel, screen);
  if (primary.ok || alt === undefined) return { ...primary, via: 'sel' };

  const fallback = resolve(alt, screen);
  return fallback.ok ? { ...fallback, via: 'alt' } : { ...primary, via: 'sel' };
}
