/**
 * Shapes returned by WebDriverAgent's `GET /source?format=json`.
 *
 * WDA is loose about types across versions: booleans come back as `true`,
 * `"true"`, or `"1"` depending on the field and the build. Everything here is
 * parsed defensively rather than trusted.
 */

export interface WdaRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface WdaNode {
  /** e.g. "XCUIElementTypeButton". Prefix is stripped during compaction. */
  type: string;
  /**
   * WDA reports `accessibilityIdentifier` here when the app sets one, and
   * silently falls back to the label when it does not. That fallback is why
   * `name === label` cannot be treated as an identifier — see `identifierOf`.
   */
  name?: string | null;
  label?: string | null;
  value?: string | unknown;
  rect?: WdaRect;
  isEnabled?: boolean | string;
  isVisible?: boolean | string;
  isAccessible?: boolean | string;
  children?: WdaNode[];
}

export interface WdaSourceResponse {
  value: WdaNode;
  sessionId?: string;
}

/** WDA sends `true`, `"true"`, or `"1"` for the same field depending on build. */
export function wdaBool(v: boolean | string | undefined, fallback = false): boolean {
  if (v === undefined || v === null) return fallback;
  if (typeof v === 'boolean') return v;
  return v === 'true' || v === '1';
}

/** "XCUIElementTypeButton" -> "Button". Unknown shapes pass through unchanged. */
export function shortType(type: string): string {
  return type.startsWith('XCUIElementType') ? type.slice('XCUIElementType'.length) : type;
}

/**
 * Recover the real accessibilityIdentifier, or undefined when the app never
 * set one.
 *
 * This is the single most load-bearing assumption in the parser: an identifier
 * is a selector that survives redesigns, a label is not (ADR 0004). Getting it
 * wrong in the permissive direction files fragile selectors under the most
 * stable rung, so the check errs strict — if `name` is indistinguishable from
 * the label, we report no identifier.
 */
export function identifierOf(node: WdaNode): string | undefined {
  const name = node.name?.trim();
  if (!name) return undefined;
  const label = node.label?.trim();
  if (label && name === label) return undefined;
  return name;
}

/** The element's label. For an input control this is placeholder text. */
export function labelOf(node: WdaNode): string | undefined {
  const label = node.label?.trim();
  return label ? label : undefined;
}

/**
 * The element's current content, when it differs from the label.
 *
 * Label and value answer different questions and the model needs both: the
 * label identifies the control ("Artists, songs, lyrics"), the value says what
 * state it is in ("NewJeans"). Collapsing them into one field forces a choice
 * that is wrong for one control type or the other — placeholder text for a
 * filled field, or a bare "1" for a switch with no hint of what it toggles.
 */
export function contentOf(node: WdaNode): string | undefined {
  const value = node.value;
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed === node.label?.trim() ? undefined : trimmed;
}
