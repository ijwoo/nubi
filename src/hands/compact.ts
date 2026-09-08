import { createHash } from 'node:crypto';
import type { Element, Screen } from '../shared/types.js';
import { type WdaNode, contentOf, identifierOf, labelOf, shortType, wdaBool } from './wda-types.js';

/**
 * Turn a raw WebDriverAgent source tree into the compact observation the rest
 * of the system works against.
 *
 * A raw tree for one screen runs to hundreds of nodes, most of them layout
 * wrappers. Sending that to a model costs a screen's worth of context per step
 * and buries the handful of controls that matter. Compaction targets 300–600
 * tokens per screen (ADR 0002); `estimateTokens` exists so tests can hold that
 * line.
 */

/** Interactive regardless of whether they carry text. */
const INTERACTIVE = new Set([
  'Button',
  'Cell',
  'TextField',
  'SecureTextField',
  'SearchField',
  'TextView',
  'Switch',
  'Slider',
  'Link',
  'PickerWheel',
  'SegmentedControl',
  'Stepper',
  'MenuItem',
  'Key',
  'Tab',
  'CheckBox',
  'RadioButton',
  'DatePicker',
  'Picker',
]);

/**
 * Layout scaffolding. Dropped even when it carries text, unless the app marked
 * it accessible — which is how React Native and Flutter expose real controls.
 */
const CONTAINER = new Set([
  'Application',
  'Window',
  'Other',
  'ScrollView',
  'Table',
  'CollectionView',
  'StackView',
  'NavigationBar',
  'TabBar',
  'Toolbar',
  'StatusBar',
  'Group',
]);

export interface CompactOptions {
  /** Foreground bundle id, from the session rather than the tree. */
  app: string;
  /** Safety cap. Screens past this are truncated and flagged. */
  maxElements?: number;
}

interface Candidate {
  node: WdaNode;
  rect: { x: number; y: number; w: number; h: number };
  text: string | undefined;
  value: string | undefined;
}

export function compact(root: WdaNode, opts: CompactOptions): Screen {
  const max = opts.maxElements ?? 120;
  const size = {
    w: root.rect?.width ?? 0,
    h: root.rect?.height ?? 0,
  };

  const kept: Candidate[] = [];
  walk(root, size, [], kept);

  const truncated = kept.length > max;
  const elements: Element[] = kept.slice(0, max).map((c, i) => {
    const el: Element = {
      i,
      t: shortType(c.node.type),
      r: [c.rect.x, c.rect.y, c.rect.w, c.rect.h],
      e: wdaBool(c.node.isEnabled, true),
    };
    if (c.text !== undefined) el.l = c.text;
    if (c.value !== undefined) el.v = c.value;
    const id = identifierOf(c.node);
    if (id !== undefined) el.id = id;
    return el;
  });

  const screen: Screen = {
    app: opts.app,
    elements,
    size,
    hash: hashElements(elements),
    capturedAt: new Date().toISOString(),
  };
  if (truncated) screen.truncated = true;
  return screen;
}

function walk(
  node: WdaNode,
  size: { w: number; h: number },
  keptAncestors: Candidate[],
  out: Candidate[],
): void {
  const rect = {
    x: Math.round(node.rect?.x ?? 0),
    y: Math.round(node.rect?.y ?? 0),
    w: Math.round(node.rect?.width ?? 0),
    h: Math.round(node.rect?.height ?? 0),
  };
  const text = labelOf(node);
  const value = contentOf(node);
  const candidate: Candidate = { node, rect, text, value };

  const keep = shouldKeep(candidate, size, keptAncestors);
  if (keep) out.push(candidate);

  // Traverse the whole tree regardless. An invisible or scaffolding node can
  // still contain visible controls, so pruning subtrees loses real elements.
  const nextAncestors = keep ? [...keptAncestors, candidate] : keptAncestors;
  for (const child of node.children ?? []) {
    walk(child, size, nextAncestors, out);
  }
}

function shouldKeep(
  c: Candidate,
  size: { w: number; h: number },
  keptAncestors: Candidate[],
): boolean {
  if (!wdaBool(c.node.isVisible, false)) return false;
  if (c.rect.w <= 0 || c.rect.h <= 0) return false;
  if (!intersectsScreen(c.rect, size)) return false;

  const type = shortType(c.node.type);
  const accessible = wdaBool(c.node.isAccessible, false);

  const hasText = c.text !== undefined || c.value !== undefined;
  const interactive = INTERACTIVE.has(type) || (hasText && (accessible || !CONTAINER.has(type)));
  if (!interactive) return false;

  // WDA nests a Button around a StaticText carrying the same label. Keeping
  // both doubles the element count and gives the model two ways to say the
  // same thing.
  if (
    c.text !== undefined &&
    keptAncestors.some((a) => a.text === c.text && contains(a.rect, c.rect))
  ) {
    return false;
  }

  return true;
}

type Rect = { x: number; y: number; w: number; h: number };

function intersectsScreen(r: Rect, size: { w: number; h: number }): boolean {
  if (size.w <= 0 || size.h <= 0) return true; // unknown screen size — do not filter
  return r.x < size.w && r.y < size.h && r.x + r.w > 0 && r.y + r.h > 0;
}

function contains(outer: Rect, inner: Rect): boolean {
  return (
    inner.x >= outer.x &&
    inner.y >= outer.y &&
    inner.x + inner.w <= outer.x + outer.w &&
    inner.y + inner.h <= outer.y + outer.h
  );
}

/**
 * Identity of a screen, for change detection without a model call.
 *
 * Rects are quantized to 4pt so a one-pixel layout jitter — or a scroll that
 * settles a hair differently — does not read as a different screen.
 */
export function hashElements(elements: Element[]): string {
  const q = (n: number) => Math.round(n / 4) * 4;
  const body = elements
    .map(
      (e) =>
        `${e.t}|${e.id ?? ''}|${e.l ?? ''}|${q(e.r[0])},${q(e.r[1])},${q(e.r[2])},${q(e.r[3])}`,
    )
    .join('\n');
  return createHash('sha1').update(body).digest('hex').slice(0, 12);
}

/**
 * Rough token count for the serialized observation.
 *
 * A proxy, not a measurement — real counts come from the API's token counting
 * endpoint. The divisor is deliberately pessimistic because Korean labels
 * tokenize worse than English ones, so a passing budget test stays passing
 * against the real tokenizer.
 */
export function estimateTokens(elements: Element[]): number {
  return Math.ceil(JSON.stringify(elements).length / 3);
}
