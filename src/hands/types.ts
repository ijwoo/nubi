import type { Element, Screen, Selector } from '../shared/types.js';
import type { Rung } from './selector.js';

/**
 * The contract between Nubi and a phone.
 *
 * Two implementations satisfy it: one driving a real device over
 * WebDriverAgent, and one replaying recorded screens (`FakeHands`). Everything
 * above this line — replay, repair, explore — is written against the interface,
 * so the whole system is developable and CI-testable without a device.
 *
 * Session recovery is deliberately absent from this surface. A dropped WDA
 * session is infrastructure, not a step in the task, and callers must not have
 * to think about it (ADR 0005).
 */
export interface Hands {
  /** Current screen, already compacted. */
  screen(): Promise<Screen>;

  /** Resolve a selector without acting on it. */
  find(sel: Selector, alt?: Selector): Promise<FindResult>;

  tap(sel: Selector, alt?: Selector): Promise<ActResult>;
  type(text: string, opts?: { submit?: boolean }): Promise<ActResult>;
  swipe(from: Point, to: Point, durationMs?: number): Promise<ActResult>;
  back(): Promise<ActResult>;
  /**
   * Bring an app to the foreground.
   *
   * `restart: true` kills it first. Without that, launching an app that is
   * already running just reveals whatever screen it was left on — fine for
   * resuming, useless for starting from a known place.
   */
  launch(target: { url?: string; bundleId?: string; restart?: boolean }): Promise<ActResult>;

  /** Wait until a selector resolves, or the timeout elapses. */
  assert(sel: Selector, timeoutMs?: number): Promise<AssertResult>;

  /**
   * Answer a system alert by button label.
   *
   * Deliberately explicit rather than automatic. Alerts ask consequential,
   * often irreversible questions — grant location, allow notifications, delete
   * — and silently accepting one is exactly what the approval gate exists to
   * prevent (ADR 0007). Making it a named action also puts the decision in the
   * trace, where it can be reviewed.
   */
  answerAlert(button: string): Promise<ActResult>;

  health(): Promise<Health>;
  close(): Promise<void>;
}

/** Normalized to 0..1 against screen size, never absolute pixels (ADR 0004). */
export type Point = readonly [number, number];

export interface Health {
  ready: boolean;
  /** How many times the session has been rebuilt underneath the caller. */
  recoveries: number;
  detail?: string;
}

/**
 * Why a selector did not resolve.
 *
 * `point-outside` is kept distinct from `no-match` because they call for
 * different repairs: the control is not gone, the layout moved.
 *
 * `blocked-by-alert` is not a selector problem at all — the control is there
 * and the selector found it, but a modal is absorbing the touch. Reported
 * separately because repairing the selector would be repairing the wrong
 * thing.
 */
export type MissReason = 'no-match' | 'point-outside' | 'blocked-by-alert';

export type FindResult =
  | { ok: true; element: Element; rung: Rung; via: 'sel' | 'alt'; matched: number }
  | { ok: false; reason: MissReason; screen: Screen };

/**
 * The screen rides along on failure. Repair needs it immediately, and fetching
 * it separately would show a screen that had moved on.
 */
export type ActResult =
  | {
      ok: true;
      screen: Screen;
      element?: Element;
      rung?: Rung;
      via?: 'sel' | 'alt';
      matched?: number;
    }
  | {
      ok: false;
      reason: MissReason | 'unsupported' | 'session-lost';
      screen: Screen;
      detail?: string;
    };

export type AssertResult =
  | { ok: true; screen: Screen; element: Element; waitedMs: number }
  | { ok: false; screen: Screen; waitedMs: number; reason: MissReason | 'timeout' };
