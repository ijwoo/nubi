import type { Executor } from '../eval/executor.js';
import type { Task } from '../eval/task.js';
import { DenyingGate, type Gate } from '../gate/index.js';
import type { Hands, Point } from '../hands/types.js';
import { isIrreversible } from '../shared/risk.js';
import type { Element, Screen, Selector } from '../shared/types.js';
import type { Trace } from '../trace/index.js';
import type { PlanResult, PlannedAction, Planner } from './planner.js';

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
  /**
   * Asked before an action that cannot be undone.
   *
   * The approval gate started out guarding replay, which is the half that
   * cannot need it first: a saved route is only saved after some run performed
   * it, and that run was an exploration. "카카오톡으로 메시지 보내줘" has no
   * macro the first time and never will if the first time is refused — so
   * without this, the gate is absent from the only moment it matters.
   *
   * Defaults to refusing, like every other caller of a gate. Exploration that
   * has not been given one does not get to send anything.
   */
  gate?: Gate;
  /** What the person asked for, shown to whoever approves. */
  goal?: string;
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
  private readonly gate: Gate;
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
  private first: Screen | undefined;
  private last: Screen | undefined;
  private beforeLast: Screen | undefined;

  constructor(options: ExploreOptions) {
    this.planner = options.planner;
    this.gate = options.gate ?? new DenyingGate();
    this.maxSteps = options.maxSteps ?? 25;
    this.timeoutMs = options.timeoutMs ?? 300_000;
    this.maxConsecutiveFailures = options.maxConsecutiveFailures ?? 3;
  }

  get route(): readonly RouteStep[] {
    return this.trail;
  }

  /**
   * The screen the run started on and the one it finished on.
   *
   * Kept because a route alone cannot say what it achieved. Turning one into a
   * macro needs a check the replay can make afterwards, and the only evidence
   * available is what the last screen has that the first one did not.
   */
  get firstScreen(): Screen | undefined {
    return this.first;
  }
  get finalScreen(): Screen | undefined {
    return this.last;
  }

  /**
   * The screen as it was just before the last action that worked.
   *
   * The difference between this and the final screen is what that action
   * produced, which is a sharper question than what the whole run produced.
   * Typing into a search field that was already open changes little; measured
   * from the start of the run, the search field's own furniture looks like an
   * achievement.
   */
  get screenBeforeLastAction(): Screen | undefined {
    return this.beforeLast;
  }

  async run(hands: Hands, task: Task, trace: Trace): Promise<boolean> {
    const deadline = Date.now() + this.timeoutMs;
    const history: PlannedAction[] = [];
    this.trail = [];
    this.first = undefined;
    this.last = undefined;
    this.beforeLast = undefined;

    let failures = 0;
    let lastFailure: string | undefined;
    /**
     * The screen the last action produced, used instead of observing again.
     *
     * Every action already ends by reading the screen — that is what the trace
     * records as the action's result — and the loop then read it a second
     * time, back to back, with nothing in between. On a simulator that was
     * 0.6s of waste per step. On a phone it is 2.2s, because a real Settings
     * tree is 349KB of JSON over a cable.
     *
     * Carried only when it differs from the screen before the action. An
     * unchanged screen means either the action did nothing or it was read too
     * early, and both are worth a fresh look rather than a saved round trip.
     */
    let carried: Screen | undefined;

    for (let step = 0; step < this.maxSteps; step++) {
      if (Date.now() > deadline) {
        trace.event('error', 'explore', { reason: 'timeout', step }, 0, true);
        return false;
      }

      const screen = carried ?? (await hands.screen());
      carried = undefined;
      // Both ends of the walk, kept for extraction: the first is the baseline
      // an assertion is judged against, the last is where the run claims to
      // have arrived.
      this.first ??= screen;
      this.last = screen;

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

      // One event per model call, carrying both its duration and its usage.
      // Timing it with `span` and recording usage separately produced two
      // `model` events per call, which doubled every reported call count.
      const started = Date.now();
      let plan: PlanResult;
      try {
        plan = await this.planner.next({
          goal: task.prompt,
          screen,
          history,
          stepsRemaining: this.maxSteps - step,
          ...(lastFailure === undefined ? {} : { lastFailure }),
        });
      } catch (err) {
        trace.event(
          'model',
          'explore',
          { step, error: err instanceof Error ? err.message : String(err) },
          Date.now() - started,
          true,
        );
        throw err;
      }
      trace.model(
        'explore',
        plan.usage ?? { model: this.planner.name, inputTokens: 0, outputTokens: 0 },
        Date.now() - started,
        { step },
      );

      const action = plan.action;
      history.push(action);
      trace.event('observe', 'explore', { step, action: action.kind, why: action.why });

      if (action.kind === 'done') return true;
      if (action.kind === 'stuck') {
        trace.event('error', 'explore', { reason: 'planner gave up', why: action.why }, 0, true);
        return false;
      }

      const outcome = await this.act(hands, action, screen.elements, task.prompt);
      if (outcome.ok) {
        // Observed this iteration, so it is the screen this action acted on.
        this.beforeLast = screen;
        if (outcome.screen && outcome.screen.hash !== screen.hash) carried = outcome.screen;
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

  /**
   * Perform one planned action.
   *
   * Hands back the screen the action produced as well as whether it worked:
   * the caller is about to want exactly that, and asking the device for it
   * again is the single most expensive thing this loop does.
   */
  /**
   * Whether a control may be pressed, when pressing it cannot be undone.
   *
   * Judged from the control's own name rather than from the request, for the
   * same reason macro extraction judges risk that way: what a step does is
   * better evidenced by what it targets than by what someone said they wanted.
   */
  private async permitted(element: Element, goal: string): Promise<string | undefined> {
    if (!isIrreversible(element.l, element.v, element.id)) return undefined;
    const approval = await this.gate.ask({
      utterance: goal,
      reasons: [element.l ?? element.v ?? element.id ?? ''],
    });
    return approval.granted ? undefined : (approval.why ?? '승인되지 않음');
  }

  private async act(
    hands: Hands,
    action: PlannedAction,
    elements: readonly Element[],
    goal: string,
  ): Promise<{ ok: boolean; why?: string; selector?: Selector; screen?: Screen }> {
    switch (action.kind) {
      case 'tap': {
        const element = elements[action.element];
        if (!element) {
          return { ok: false, why: `no element ${action.element} on screen` };
        }
        const selector = selectorFor(element, elements);
        const refusal = await this.permitted(element, goal);
        if (refusal) return { ok: false, why: refusal };
        const r = await hands.tap(selector);
        return r.ok ? { ok: true, selector, screen: r.screen } : { ok: false, why: r.reason };
      }
      case 'type': {
        const r = await hands.type(action.text, { submit: action.submit });
        return r.ok ? { ok: true, screen: r.screen } : { ok: false, why: r.reason };
      }
      case 'swipe': {
        const [from, to] = SWIPES[action.direction];
        const r = await hands.swipe(from, to);
        return r.ok ? { ok: true, screen: r.screen } : { ok: false, why: r.reason };
      }
      case 'back': {
        const r = await hands.back();
        return r.ok ? { ok: true, screen: r.screen } : { ok: false, why: r.reason };
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
