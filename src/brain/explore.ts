import type { Executor } from '../eval/executor.js';
import type { Task } from '../eval/task.js';
import type { Hands, Point } from '../hands/types.js';
import type { Element, Selector } from '../shared/types.js';
import type { Trace } from '../trace/index.js';
import type { PlannedAction, Planner } from './planner.js';

/**
 * Find a way to do something in an app nobody has written a route for.
 *
 * Observe, decide, act, repeat. Slow and it costs tokens — that is the point
 * of the comparison this project makes. What makes the cost worth paying is
 * that a successful exploration leaves behind the route it found, and every
 * run after that replays it without a model (ADR 0003).
 */

export interface ExploreOptions {
  planner: Planner;
  /** Hard ceiling on actions. A loop that has not finished by here will not. */
  maxSteps?: number;
  /** Wall-clock ceiling, since a step can block on a slow screen. */
  timeoutMs?: number;
  /** Consecutive failures before giving up. */
  maxConsecutiveFailures?: number;
}

export class ExploreExecutor implements Executor {
  readonly name = 'explore';

  private readonly planner: Planner;
  private readonly maxSteps: number;
  private readonly timeoutMs: number;
  private readonly maxConsecutiveFailures: number;

  /**
   * Every action that worked, in order.
   *
   * Recorded for all action kinds, not only taps: a route that typed
   * something and then dropped the typing would replay as a different task.
   * A selector rides along only where one was resolved.
   */
  private trail: RouteStep[] = [];

  constructor(options: ExploreOptions) {
    this.planner = options.planner;
    this.maxSteps = options.maxSteps ?? 25;
    this.timeoutMs = options.timeoutMs ?? 300_000;
    this.maxConsecutiveFailures = options.maxConsecutiveFailures ?? 3;
  }

  get route(): readonly RouteStep[] {
    return this.trail;
  }

  async run(hands: Hands, task: Task, trace: Trace): Promise<boolean> {
    const deadline = Date.now() + this.timeoutMs;
    const history: PlannedAction[] = [];
    this.trail = [];

    let failures = 0;
    let lastFailure: string | undefined;

    for (let step = 0; step < this.maxSteps; step++) {
      if (Date.now() > deadline) {
        trace.event('error', 'explore', { reason: 'timeout', step }, 0, true);
        return false;
      }

      const screen = await hands.screen();

      // A modal absorbs every touch while the tree underneath looks perfectly
      // ordinary (ADR 0008). Deciding an action here would produce one that
      // silently does nothing, and the model would blame its own choice.
      if (screen.alert) {
        trace.event(
          'approve',
          'explore',
          { reason: 'blocked-by-alert', alert: screen.alert.text, buttons: screen.alert.buttons },
          0,
          true,
        );
        return false;
      }

      const plan = await trace.span('model', 'explore', { step, goal: task.prompt }, () =>
        this.planner.next({
          goal: task.prompt,
          screen,
          history,
          stepsRemaining: this.maxSteps - step,
          ...(lastFailure === undefined ? {} : { lastFailure }),
        }),
      );
      if (plan.usage) {
        trace.model('explore', plan.usage, 0, { step });
      }

      const action = plan.action;
      history.push(action);
      trace.event('observe', 'explore', { step, action: action.kind, why: action.why });

      if (action.kind === 'done') return true;
      if (action.kind === 'stuck') {
        trace.event('error', 'explore', { reason: 'planner gave up', why: action.why }, 0, true);
        return false;
      }

      const outcome = await this.act(hands, action, screen.elements);
      if (outcome.ok) {
        failures = 0;
        lastFailure = undefined;
        this.trail.push(outcome.selector ? { action, selector: outcome.selector } : { action });
        continue;
      }

      failures += 1;
      lastFailure = outcome.why;
      trace.event('error', 'explore', { step, action: action.kind, why: outcome.why }, 0, true);

      // Repeating a failing action is how a loop burns its budget without
      // learning anything. Telling the planner what failed gives it a chance
      // to choose differently; a run of failures means it is not going to.
      if (failures >= this.maxConsecutiveFailures) {
        trace.event('error', 'explore', { reason: 'consecutive failures', failures }, 0, true);
        return false;
      }
    }

    trace.event(
      'error',
      'explore',
      { reason: 'step budget exhausted', steps: this.maxSteps },
      0,
      true,
    );
    return false;
  }

  private async act(
    hands: Hands,
    action: PlannedAction,
    elements: readonly Element[],
  ): Promise<{ ok: boolean; why?: string; selector?: Selector }> {
    switch (action.kind) {
      case 'tap': {
        const element = elements[action.element];
        if (!element) {
          return { ok: false, why: `no element ${action.element} on screen` };
        }
        const selector = selectorFor(element, elements);
        const r = await hands.tap(selector);
        return r.ok ? { ok: true, selector } : { ok: false, why: r.reason };
      }
      case 'type': {
        const r = await hands.type(action.text, { submit: action.submit });
        return r.ok ? { ok: true } : { ok: false, why: r.reason };
      }
      case 'swipe': {
        const [from, to] = SWIPES[action.direction];
        const r = await hands.swipe(from, to);
        return r.ok ? { ok: true } : { ok: false, why: r.reason };
      }
      case 'back': {
        const r = await hands.back();
        return r.ok ? { ok: true } : { ok: false, why: r.reason };
      }
      default:
        return { ok: false, why: `unhandled action ${action.kind}` };
    }
  }
}

/** One action that worked, with the selector it resolved to if it had one. */
export interface RouteStep {
  action: PlannedAction;
  selector?: Selector;
}

/**
 * Swipes are named, not measured.
 *
 * Asking a model for coordinates invites arithmetic it has no reason to be
 * good at, and the result would be a coordinate selector — the most fragile
 * rung — recorded into a macro. A direction is what the intent actually was.
 */
const SWIPES: Record<'up' | 'down' | 'left' | 'right', [Point, Point]> = {
  up: [
    [0.5, 0.7],
    [0.5, 0.3],
  ],
  down: [
    [0.5, 0.3],
    [0.5, 0.7],
  ],
  left: [
    [0.8, 0.5],
    [0.2, 0.5],
  ],
  right: [
    [0.2, 0.5],
    [0.8, 0.5],
  ],
};

/**
 * Turn a chosen element into the most durable selector that identifies it.
 *
 * This is where exploration becomes reusable. The model picked something on a
 * screen it can see; what gets written down has to still find that control
 * next week, so the ladder from ADR 0004 is walked here rather than left to
 * the model.
 *
 * A label is only taken when it is unique on the screen — the resolver would
 * otherwise pick by tie-break, and a selector that works today by tie-break is
 * a selector that will quietly pick differently tomorrow.
 */
export function selectorFor(element: Element, elements: readonly Element[]): Selector {
  if (element.id !== undefined) return { id: element.id };

  if (element.l !== undefined) {
    const sameLabel = elements.filter((e) => e.l === element.l);
    if (sameLabel.length === 1) return { label: element.l };
    const sameLabelAndType = sameLabel.filter((e) => e.t === element.t);
    if (sameLabelAndType.length === 1) return { label: element.l, type: element.t };
  }

  const ofType = elements.filter((e) => e.t === element.t);
  const n = ofType.indexOf(element);
  if (n >= 0) return { index: { type: element.t, n } };

  // Nothing named it and nothing counted it. Coordinates are the last rung for
  // good reason, and a macro carrying one is expected to break sooner.
  return { point: [0, 0] };
}
