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
  /**
   * Element type. Recent WDA sends the short form ("Button"); older builds send
   * "XCUIElementTypeButton". `shortType` normalizes both.
   */
  type: string;
  /**
   * The real `accessibilityIdentifier`, or null when the app set none.
   *
   * Verified against WDA 16.12.5: this field is authoritative, so there is no
   * need to infer an identifier from `name`. Older builds omit it entirely,
   * which is the only case where `identifierOf` falls back to guessing.
   */
  rawIdentifier?: string | null;
  /**
   * WDA reports `accessibilityIdentifier` here when the app sets one, and
   * silently falls back to the label when it does not — which is why `name` is
   * only consulted when `rawIdentifier` is absent.
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
 * The element's accessibilityIdentifier, or undefined when it has none.
 *
 * An identifier is a selector that survives redesigns; a label is not
 * (ADR 0004). Filing a label under the most stable rung would put the most
 * fragile value in the place the replay engine trusts most, so this reads the
 * authoritative field rather than inferring one.
 *
 * `rawIdentifier` is that field. When it is present — even as null — it is
 * believed outright. Only a build that omits the key entirely falls back to
 * the older `name !== label` heuristic, and that fallback errs strict: a `name`
 * indistinguishable from the label is reported as no identifier at all.
 */
export function identifierOf(node: WdaNode): string | undefined {
  if ('rawIdentifier' in node) {
    const raw = node.rawIdentifier?.trim();
    return raw ? raw : undefined;
  }
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
