import { createHash } from 'node:crypto';
import type { Element, Screen } from '../shared/types.js';
import { type WdaNode, contentOf, identifierOf, labelOf, shortType, wdaBool } from './wda-types.js';

/**
 * Turn a raw WebDriverAgent source tree into the compact observation the rest
 * of the system works against.
 *
 * Measured against real trees from the iOS Simulator, one screen of Settings is
 * 62KB across 168 nodes — WDA repeats every frame as both a string and an
 * object and ships traits, focus state, and custom actions besides. Sending
 * that to a model costs a screen's worth of context per step and buries the
 * handful of controls that matter. Compaction targets 300-600 tokens per
 * screen (ADR 0002); `estimateTokens` exists so tests can hold that line.
 *
 * The rules below are shaped by one thing real trees do that a hand-written
 * fixture does not: **a container speaks for its children.** iOS builds a
 * row's accessibility label by joining the text of everything inside it, and
 * wraps each row in an untitled Cell. Judging nodes one at a time keeps all
 * three copies.
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
 * Types a tap can be aimed at. Used to decide which of two nested elements is
 * the real target.
 */
const TAPPABLE = new Set([
  'Button',
  'Cell',
  'TextField',
  'SecureTextField',
  'SearchField',
  'TextView',
  'Switch',
  'Slider',
  'Link',
  'MenuItem',
  'Tab',
  'Key',
  'SegmentedControl',
  'CheckBox',
  'RadioButton',
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

/**
 * The on-screen keyboard.
 *
 * A keyboard adds twenty-six or more elements and, on a search screen, pushes
 * the observation past its whole budget — measured at 828 tokens against a
 * target of 600. None of it is actionable here: text is entered with a `type`
 * action that goes to whatever holds focus, never by tapping letters. Showing
 * the model keys it cannot usefully press costs the budget twice, in tokens
 * and in what it crowds out.
 *
 * Only `Key` is dropped. A custom keypad drawn as Buttons survives, because
 * there the buttons really are the way in.
 */
const KEYBOARD = new Set(['Key']);

/**
 * Labels longer than this are cut.
 *
 * Real rows run past 60 characters — a single Settings cell reads "Apple 계정,
 * iCloud 데이터, App Store, Apple 서비스 등에 접근하려면 로그인하십시오." A
 * handful of those blows the per-screen budget on prose the model does not need
 * to identify the control. Truncation is safe for selectors because the live
 * screen and any macro extracted from one both pass through this function, so
 * they are cut identically.
 */
const MAX_LABEL = 64;

export interface CompactOptions {
  /** Foreground bundle id, from the session rather than the tree. */
  app: string;
  /** Safety cap. Screens past this are truncated and flagged. */
  maxElements?: number;
}

type Rect = { x: number; y: number; w: number; h: number };

interface Node {
  wda: WdaNode;
  parent: number;
  type: string;
  rect: Rect;
  text: string | undefined;
  value: string | undefined;
  id: string | undefined;
  keep: boolean;
}

export function compact(root: WdaNode, opts: CompactOptions): Screen {
  const max = opts.maxElements ?? 120;
  const size = { w: root.rect?.width ?? 0, h: root.rect?.height ?? 0 };

  const nodes = flatten(root);
  // Read before the keys are dropped: their presence is the observable part,
  // and their top edge is where everything else the keyboard draws begins.
  const keys = nodes.filter((n) => KEYBOARD.has(n.type));
  const keyboard = keys.length === 0 ? undefined : { top: Math.min(...keys.map((n) => n.rect.y)) };
  for (const n of nodes) n.keep = isAddressable(n, size);
  dropSubsumed(nodes);
  dropPresentation(nodes);
  dropRedundantContainers(nodes);
  dropExactDuplicates(nodes);

  const survivors = nodes.filter((n) => n.keep);
  const truncated = survivors.length > max;

  const elements: Element[] = survivors.slice(0, max).map((n, i) => {
    const el: Element = {
      i,
      t: n.type,
      r: [n.rect.x, n.rect.y, n.rect.w, n.rect.h],
      e: enabled(n),
    };
    if (n.text !== undefined) el.l = clip(n.text);
    if (n.value !== undefined) el.v = clip(n.value);
    if (n.id !== undefined) el.id = n.id;
    return el;
  });

  const screen: Screen = {
    app: opts.app,
    elements,
    size,
    hash: hashElements(elements, keyboard !== undefined),
    capturedAt: new Date().toISOString(),
  };
  if (keyboard) screen.keyboard = keyboard;
  if (truncated) screen.truncated = true;
  return screen;
}

/* ---- passes ------------------------------------------------------- */

function flatten(root: WdaNode): Node[] {
  const nodes: Node[] = [];
  const visit = (wda: WdaNode, parent: number): void => {
    const self = nodes.length;
    nodes.push({
      wda,
      parent,
      type: shortType(wda.type),
      rect: {
        x: Math.round(wda.rect?.x ?? 0),
        y: Math.round(wda.rect?.y ?? 0),
        w: Math.round(wda.rect?.width ?? 0),
        h: Math.round(wda.rect?.height ?? 0),
      },
      text: labelOf(wda),
      value: contentOf(wda),
      id: identifierOf(wda),
      keep: false,
    });
    // The whole tree is walked regardless of what is kept: an invisible or
    // scaffolding node can still contain visible controls.
    for (const child of wda.children ?? []) visit(child, self);
  };
  visit(root, -1);
  return nodes;
}

function isAddressable(n: Node, size: { w: number; h: number }): boolean {
  if (!wdaBool(n.wda.isVisible, false)) return false;
  if (n.rect.w <= 0 || n.rect.h <= 0) return false;
  if (!intersectsScreen(n.rect, size)) return false;
  if (KEYBOARD.has(n.type)) return false;

  const named = n.text !== undefined || n.value !== undefined || n.id !== undefined;
  if (INTERACTIVE.has(n.type)) return true;
  return named && (wdaBool(n.wda.isAccessible, false) || !CONTAINER.has(n.type));
}

/**
 * Drop text an ancestor already speaks for.
 *
 * iOS composes a row's label by joining its children's, so a Settings row
 * appears three times: the Button carrying the joined sentence, and a
 * StaticText for each fragment. Containment rather than equality is what
 * catches that — matching only identical strings leaves the fragments behind.
 *
 * A node with its own identifier is exempt: the app deliberately made it
 * addressable, so it is a target in its own right.
 */
function dropSubsumed(nodes: Node[]): void {
  for (const n of nodes) {
    if (!n.keep || n.id !== undefined) continue;
    const own = n.text ?? n.value;
    if (own === undefined) continue;

    for (let a = n.parent; a !== -1; a = nodes[a]?.parent ?? -1) {
      const anc = nodes[a];
      if (!anc?.keep) continue;
      const ancText = anc.text ?? anc.value;
      if (ancText?.includes(own) && contains(anc.rect, n.rect)) {
        n.keep = false;
        break;
      }
    }
  }
}

/**
 * Drop the wordless parts of a control's appearance.
 *
 * A Settings row is a Button wrapping a chevron Image and its text. The
 * chevron carries an identifier — `chevron.forward`, once per row — and is
 * kept by every rule that only asks whether an element can be addressed. It is
 * how the button looks, not a thing to tap, and nine of them cost more budget
 * than the untitled cells did.
 *
 * The rule only removes elements with **no text of their own**. An earlier
 * version dropped anything inside a tappable ancestor, and a fixture caught
 * what that costs: a row labelled with a song title also holds the artist's
 * name, and swallowing it loses the only thing distinguishing two rows. Text
 * an ancestor genuinely repeats is already handled by `dropSubsumed`, so the
 * conservative rule gives up nothing except a little budget on wordy icons.
 */
function dropPresentation(nodes: Node[]): void {
  for (const n of nodes) {
    if (!n.keep || TAPPABLE.has(n.type)) continue;
    if (n.text !== undefined || n.value !== undefined) continue;

    for (let a = n.parent; a !== -1; a = nodes[a]?.parent ?? -1) {
      const anc = nodes[a];
      if (!anc?.keep || !TAPPABLE.has(anc.type)) continue;
      const named = anc.text !== undefined || anc.value !== undefined || anc.id !== undefined;
      if (named && contains(anc.rect, n.rect)) {
        n.keep = false;
        break;
      }
    }
  }
}

/**
 * Drop a container that has nothing to be addressed by, once something inside
 * it survived.
 *
 * A list row is an untitled Cell wrapping a labelled Button. Both are
 * interactive by type, but only one can be named in a selector — keeping the
 * Cell adds an element the model cannot refer to and a tap target that is
 * strictly worse than the Button inside it. An untitled Cell wrapping nothing
 * is kept: positional selectors still reach it.
 */
function dropRedundantContainers(nodes: Node[]): void {
  const hasKeptDescendant = new Array<boolean>(nodes.length).fill(false);
  for (const [i, n] of nodes.entries()) {
    if (!n.keep) continue;
    for (let a = n.parent; a !== -1; a = nodes[a]?.parent ?? -1) {
      if (hasKeptDescendant[a]) break; // ancestors above are already marked
      hasKeptDescendant[a] = true;
    }
    void i;
  }

  for (const [i, n] of nodes.entries()) {
    if (!n.keep) continue;
    const nameless = n.text === undefined && n.value === undefined && n.id === undefined;
    if (nameless && hasKeptDescendant[i]) n.keep = false;
  }
}

/**
 * Drop an element WDA reported twice.
 *
 * Real trees contain elements identical in type, identifier, text, and rect —
 * Settings reports its dictation button twice, Calendar its date heading. Two
 * things at the same place with the same identity are one thing.
 *
 * The cost is not the handful of tokens. A duplicate makes the resolver report
 * two matches for a selector that names exactly one control, and `matched > 1`
 * is the signal macro extraction uses to warn that a selector is
 * under-specified — so leaving them in manufactures false warnings.
 */
function dropExactDuplicates(nodes: Node[]): void {
  const seen = new Set<string>();
  for (const n of nodes) {
    if (!n.keep) continue;
    const key = [
      n.type,
      n.id ?? '',
      n.text ?? '',
      n.value ?? '',
      n.rect.x,
      n.rect.y,
      n.rect.w,
      n.rect.h,
    ].join('|');
    if (seen.has(key)) n.keep = false;
    else seen.add(key);
  }
}

/* ---- helpers ------------------------------------------------------ */

function enabled(n: Node): boolean {
  return wdaBool(n.wda.isEnabled, true);
}

function clip(s: string): string {
  return s.length <= MAX_LABEL ? s : `${s.slice(0, MAX_LABEL - 1)}…`;
}

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
export function hashElements(elements: Element[], keyboard = false): string {
  const q = (n: number) => Math.round(n / 4) * 4;
  const body = elements
    .map(
      (e) =>
        `${e.t}|${e.id ?? ''}|${e.l ?? ''}|${e.v ?? ''}|${q(e.r[0])},${q(e.r[1])},${q(e.r[2])},${q(e.r[3])}`,
    )
    .join('\n');
  // Part of the hash because opening the keyboard is often the only thing a tap
  // changes, and a screen that hashes the same reads as a tap that did nothing.
  return createHash('sha1')
    .update(keyboard ? `kb\n${body}` : body)
    .digest('hex')
    .slice(0, 12);
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
