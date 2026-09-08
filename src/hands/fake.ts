import { readFileSync } from 'node:fs';
import { dirname, resolve as resolvePath } from 'node:path';
import { z } from 'zod';
import type { Element, Screen, Selector } from '../shared/types.js';
import { compact } from './compact.js';
import { resolveWithFallback } from './selector.js';
import type {
  ActResult,
  AssertResult,
  FindResult,
  Hands,
  Health,
  MissReason,
  Point,
} from './types.js';
import type { WdaNode } from './wda-types.js';

/**
 * A Hands implementation that replays recorded screens.
 *
 * The phone is modelled as a state machine over screens captured from a real
 * device: an action either matches a transition and moves to another recorded
 * screen, or matches nothing and leaves the screen where it was — which is what
 * tapping dead space actually does.
 *
 * Every state change is an explicit recorded screen rather than a mutation of
 * the tree. That keeps the fake dumb and the fixtures honest: what a test sees
 * is a screen that really came off a device, not one this file invented.
 */

const TransitionSchema = z
  .object({
    /** Screen name, or "*" for any. */
    from: z.string(),
    /** Matches the resolved element's identifier or label. */
    tap: z.string().optional(),
    /** Matches any text entry. */
    type: z.literal(true).optional(),
    back: z.literal(true).optional(),
    to: z.string(),
  })
  .refine((t) => t.tap !== undefined || t.type === true || t.back === true, {
    message: 'a transition must be triggered by tap, type, or back',
  });

export const ScenarioSchema = z.object({
  app: z.string(),
  start: z.string(),
  /** URL scheme or bundle id -> screen name. */
  launch: z.record(z.string()).default({}),
  /** Screen name -> path to a recorded WDA source dump. */
  screens: z.record(z.string()),
  transitions: z.array(TransitionSchema).default([]),
});
export type Scenario = z.infer<typeof ScenarioSchema>;

/** One action the fake was asked to perform. Tests assert against this log. */
export interface FakeCall {
  action: 'screen' | 'find' | 'tap' | 'type' | 'swipe' | 'back' | 'launch' | 'assert';
  screenBefore: string;
  screenAfter: string;
  detail?: Record<string, unknown>;
}

export interface FakeHandsOptions {
  /** Screen to start on. Defaults to the scenario's `start`. */
  at?: string;
}

export class FakeHands implements Hands {
  readonly calls: FakeCall[] = [];

  private current: string;
  private pendingFailure: MissReason | 'session-lost' | undefined;
  private alert: { text: string; buttons: string[] } | undefined;
  private recoveries = 0;

  constructor(
    private readonly scenario: Scenario,
    private readonly trees: Record<string, WdaNode>,
    options: FakeHandsOptions = {},
  ) {
    const start = options.at ?? scenario.start;
    if (!trees[start]) throw new Error(`fake: unknown start screen "${start}"`);
    this.current = start;
  }

  /** Load a scenario file; screen paths resolve relative to it. */
  static fromScenario(scenarioPath: string, options: FakeHandsOptions = {}): FakeHands {
    const abs = resolvePath(scenarioPath);
    const scenario = ScenarioSchema.parse(JSON.parse(readFileSync(abs, 'utf8')));
    const base = dirname(abs);
    const trees: Record<string, WdaNode> = {};
    for (const [name, rel] of Object.entries(scenario.screens)) {
      const dump = JSON.parse(readFileSync(resolvePath(base, rel), 'utf8'));
      trees[name] = dump.value as WdaNode;
    }
    return new FakeHands(scenario, trees, options);
  }

  /* ---- test hooks ------------------------------------------------- */

  /** Jump to a screen without going through a transition. */
  goto(screen: string): void {
    if (!this.trees[screen]) throw new Error(`fake: unknown screen "${screen}"`);
    this.current = screen;
  }

  /** Make the next action fail. Used to exercise repair and recovery paths. */
  failNext(reason: MissReason | 'session-lost'): void {
    this.pendingFailure = reason;
  }

  get screenName(): string {
    return this.current;
  }

  /* ---- Hands ------------------------------------------------------ */

  async screen(): Promise<Screen> {
    const s = this.snapshot();
    this.log('screen', this.current);
    return s;
  }

  async find(sel: Selector, alt?: Selector): Promise<FindResult> {
    const screen = this.snapshot();
    const r = resolveWithFallback(sel, alt, screen);
    this.log('find', this.current, { sel, ok: r.ok });
    if (!r.ok) return { ok: false, reason: r.reason, screen };
    return { ok: true, element: r.element, rung: r.rung, via: r.via, matched: r.matched };
  }

  async tap(sel: Selector, alt?: Selector): Promise<ActResult> {
    const injected = this.takeFailure();
    if (injected) return this.fail(injected, 'tap', { sel });

    const screen = this.snapshot();
    if (this.alert) {
      this.log('tap', this.current, { sel, ok: false, reason: 'blocked-by-alert' });
      return { ok: false, reason: 'blocked-by-alert', screen, detail: this.alert.text };
    }

    const r = resolveWithFallback(sel, alt, screen);
    if (!r.ok) {
      this.log('tap', this.current, { sel, ok: false, reason: r.reason });
      return { ok: false, reason: r.reason, screen };
    }

    const before = this.current;
    this.applyTap(r.element);
    this.log('tap', before, { sel, ok: true, element: r.element.id ?? r.element.l });
    return {
      ok: true,
      screen: this.snapshot(),
      element: r.element,
      rung: r.rung,
      via: r.via,
      matched: r.matched,
    };
  }

  async type(text: string, opts: { submit?: boolean } = {}): Promise<ActResult> {
    const injected = this.takeFailure();
    if (injected) return this.fail(injected, 'type', { text });

    const before = this.current;
    this.move((t) => t.from === before && t.type === true);
    this.log('type', before, { text, submit: opts.submit ?? false });
    return { ok: true, screen: this.snapshot() };
  }

  async swipe(from: Point, to: Point, durationMs?: number): Promise<ActResult> {
    // No scenario transition fires on a swipe: the fixtures model navigation,
    // not scrolling. Recording a scrolled screen and adding a transition is the
    // way to cover a scroll-dependent macro.
    this.log('swipe', this.current, { from, to, durationMs });
    return { ok: true, screen: this.snapshot() };
  }

  async back(): Promise<ActResult> {
    const injected = this.takeFailure();
    if (injected) return this.fail(injected, 'back');

    const before = this.current;
    this.move((t) => (t.from === before || t.from === '*') && t.back === true);
    this.log('back', before);
    return { ok: true, screen: this.snapshot() };
  }

  async launch(target: { url?: string; bundleId?: string; restart?: boolean }): Promise<ActResult> {
    const key = target.url ?? target.bundleId ?? '';
    const named = target.restart ? undefined : this.scenario.launch[key];
    const before = this.current;
    this.current = named ?? this.scenario.start;
    this.log('launch', before, { target, matched: named !== undefined });
    return { ok: true, screen: this.snapshot() };
  }

  async assert(sel: Selector, timeoutMs = 8000): Promise<AssertResult> {
    // The fake's state only changes on an action, so there is nothing to wait
    // for: whatever is true now stays true. `waitedMs` is always 0, which keeps
    // fixture-backed tests instant.
    const screen = this.snapshot();
    const r = resolveWithFallback(sel, undefined, screen);
    this.log('assert', this.current, { sel, ok: r.ok, timeoutMs });
    if (!r.ok) return { ok: false, screen, waitedMs: 0, reason: r.reason };
    return { ok: true, screen, element: r.element, waitedMs: 0 };
  }

  /**
   * Answer a system alert. The fake raises one only when a test sets it, via
   * `showAlert`, which is how the alert-handling paths get covered in CI.
   */
  async answerAlert(button: string): Promise<ActResult> {
    const screen = this.snapshot();
    if (!this.alert) {
      return { ok: false, reason: 'no-match', screen, detail: 'no alert is showing' };
    }
    if (!this.alert.buttons.includes(button)) {
      return {
        ok: false,
        reason: 'no-match',
        screen,
        detail: `alert has no button "${button}"`,
      };
    }
    this.alert = undefined;
    this.log('assert', this.current, { answeredAlert: button });
    return { ok: true, screen: this.snapshot() };
  }

  /** Put a system alert over the current screen. */
  showAlert(text: string, buttons: string[]): void {
    this.alert = { text, buttons };
  }

  async health(): Promise<Health> {
    return { ready: true, recoveries: this.recoveries, detail: `fake @ ${this.current}` };
  }

  async close(): Promise<void> {
    /* nothing to release */
  }

  /* ---- internals -------------------------------------------------- */

  private snapshot(): Screen {
    const tree = this.trees[this.current];
    if (!tree) throw new Error(`fake: no tree for screen "${this.current}"`);
    const screen = compact(tree, { app: this.scenario.app });
    return this.alert ? { ...screen, alert: this.alert } : screen;
  }

  private applyTap(el: Element): void {
    const key = el.id ?? el.l;
    if (key === undefined) return;
    const before = this.current;
    this.move((t) => (t.from === before || t.from === '*') && t.tap === key);
  }

  /**
   * Take the first matching transition, preferring one that names this screen
   * over a `"*"` catch-all, so a wildcard cannot shadow a specific rule
   * regardless of file order.
   */
  private move(match: (t: Scenario['transitions'][number]) => boolean): void {
    const candidates = this.scenario.transitions.filter(match);
    const exact = candidates.find((t) => t.from !== '*');
    const chosen = exact ?? candidates[0];
    if (!chosen) return; // nothing moved — tapping dead space does nothing
    if (!this.trees[chosen.to])
      throw new Error(`fake: transition to unknown screen "${chosen.to}"`);
    this.current = chosen.to;
  }

  private takeFailure(): MissReason | 'session-lost' | undefined {
    const f = this.pendingFailure;
    this.pendingFailure = undefined;
    if (f === 'session-lost') this.recoveries += 1;
    return f;
  }

  private fail(
    reason: MissReason | 'session-lost',
    action: FakeCall['action'],
    detail?: Record<string, unknown>,
  ): ActResult {
    const screen = this.snapshot();
    this.log(action, this.current, { ...detail, injected: reason });
    return { ok: false, reason, screen, detail: 'injected by FakeHands.failNext' };
  }

  private log(action: FakeCall['action'], before: string, detail?: Record<string, unknown>): void {
    const call: FakeCall = { action, screenBefore: before, screenAfter: this.current };
    if (detail !== undefined) call.detail = detail;
    this.calls.push(call);
  }
}
