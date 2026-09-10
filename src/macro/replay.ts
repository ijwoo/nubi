import { selectorFor } from '../brain/explore.js';
import type { Executor } from '../eval/executor.js';
import type { Task } from '../eval/task.js';
import type { Hands } from '../hands/types.js';
import type { Element, Macro, Screen } from '../shared/types.js';
import type { Trace } from '../trace/index.js';
import { type Repairer, escalatesRisk, isWorthKeeping, repairedStep } from './repair.js';
import type { MacroStore } from './store.js';

/**
 * Replay a learned route, and mend it when the app moves underneath.
 *
 * The difference from `ScriptedExecutor` is one thing: a step that misses
 * escalates instead of ending the run. Both are kept so the eval set can
 * measure what that costs and what it buys — without the comparison, "self
 * healing" is a claim rather than a number.
 */

export interface ReplayOptions {
  macro: Macro;
  store: MacroStore;
  repairer: Repairer;
  /** Repairs allowed per run. A route needing more has changed, not shifted. */
  maxRepairs?: number;
  /**
   * Swipes allowed while looking for a control that is off screen.
   *
   * A ceiling rather than a target — the search stops as soon as the list
   * stops moving. This only bounds a list long enough to keep scrolling
   * forever, which a settings screen is not but a feed is.
   */
  maxScrolls?: number;
}

export class ReplayExecutor implements Executor {
  readonly name = 'replay';

  private readonly store: MacroStore;
  private readonly repairer: Repairer;
  private readonly maxRepairs: number;
  private readonly maxScrolls: number;
  private macro: Macro;

  /** Repairs written into the macro during the last run. */
  repairs = 0;

  constructor(options: ReplayOptions) {
    this.macro = options.macro;
    this.store = options.store;
    this.repairer = options.repairer;
    this.maxRepairs = options.maxRepairs ?? 2;
    this.maxScrolls = options.maxScrolls ?? 6;
  }

  async run(hands: Hands, _task: Task, trace: Trace): Promise<boolean> {
    this.repairs = 0;

    for (let i = 0; i < this.macro.steps.length; i++) {
      const step = this.macro.steps[i];
      if (!step) break;

      if (await this.perform(hands, step)) continue;

      // Scrolling first, because it costs nothing. A control that is simply
      // below the fold is not a broken selector, and the same route on a
      // longer list is the common case rather than an odd one: real Settings
      // puts an Apple account, an update banner and cellular above what a
      // simulator shows first, and everything the macro wants moves down.
      if (step.op === 'tap' && (await this.scrollTo(hands, trace, step, i))) {
        i -= 1;
        continue;
      }

      // Only a tap carries a selector that repair can reason about. A launch
      // or a type failing means something other than a moved control.
      if (step.op !== 'tap' || this.repairs >= this.maxRepairs) {
        trace.event('error', 'replay', { step: i, op: step.op, macro: this.macro.id }, 0, true);
        return false;
      }

      const mended = await this.repair(hands, trace, i);
      if (!mended) return false;

      // Retry the step that failed, now that it points somewhere real.
      i -= 1;
    }
    return true;
  }

  /**
   * Scroll looking for a control that is not on screen, and stop when the
   * screen stops changing.
   *
   * The stop condition is what keeps this honest. A bounded count alone would
   * swipe the same number of times whether the list has more to show or ended
   * three swipes ago; an unchanged screen means the end was reached, and then
   * the control really is gone and repair is the right next step.
   *
   * Swipes are short on purpose. A long one carries momentum and skips:
   * measuring this on a phone, one 0.7→0.3 swipe jumped from VPN straight to
   * Sounds, hiding 일반 and 손쉬운 사용 and everything between them well
   * enough that the list looked like it no longer had them.
   */
  private async scrollTo(
    hands: Hands,
    trace: Trace,
    step: Extract<Macro['steps'][number], { op: 'tap' }>,
    stepIndex: number,
  ): Promise<boolean> {
    const started = Date.now();
    let before = (await hands.screen()).hash;

    for (let swipe = 1; swipe <= this.maxScrolls; swipe++) {
      const moved = await hands.swipe([0.5, 0.62], [0.5, 0.42], 900);
      if (!moved.ok) return false;

      const after = moved.screen;
      if (after.hash === before) {
        // The list did not move: this is the end of it, not a slow load.
        trace.event(
          'observe',
          'replay',
          { step: stepIndex, op: 'scroll', reason: 'list-ended', swipes: swipe },
          Date.now() - started,
        );
        return false;
      }
      before = after.hash;

      const found = await hands.find(step.sel, step.alt);
      if (found.ok && reachable(found.element, after)) {
        trace.event(
          'recover',
          'replay',
          { step: stepIndex, op: 'scroll', sel: step.sel, swipes: swipe },
          Date.now() - started,
        );
        return true;
      }
    }

    trace.event(
      'observe',
      'replay',
      { step: stepIndex, op: 'scroll', reason: 'not-found', swipes: this.maxScrolls },
      Date.now() - started,
    );
    return false;
  }

  private async repair(hands: Hands, trace: Trace, stepIndex: number): Promise<boolean> {
    const step = this.macro.steps[stepIndex];
    if (!step || step.op !== 'tap') return false;

    const screen = await hands.screen();
    const started = Date.now();
    const result = await this.repairer.suggest({
      macro: this.macro,
      stepIndex,
      broken: step.sel,
      reason: 'no-match',
      screen,
    });

    // Recorded before the answer is judged: a refusal costs the same call as a
    // fix, and a repair that spends money and declines still spent it.
    if (result.usage) {
      trace.model('repair', result.usage, Date.now() - started, { step: stepIndex });
    }

    const suggestion = result.suggestion;
    if (!suggestion) {
      trace.event(
        'error',
        'repair',
        { step: stepIndex, reason: 'nothing on screen resembles the control' },
        Date.now() - started,
        true,
      );
      return false;
    }

    const element = screen.elements[suggestion.element];
    if (!element) {
      trace.event(
        'error',
        'repair',
        { step: stepIndex, reason: `no element ${suggestion.element} on screen` },
        Date.now() - started,
        true,
      );
      return false;
    }

    const replacement = selectorFor(element, screen.elements);
    if (!isWorthKeeping(replacement, element)) {
      // Writing a coordinate over a named control trades a step that broke
      // once for one that will break again, and loses what it used to say.
      trace.event(
        'error',
        'repair',
        { step: stepIndex, reason: 'replacement would be a coordinate', why: suggestion.why },
        Date.now() - started,
        true,
      );
      return false;
    }

    if (escalatesRisk(step.sel, element)) {
      // The nearest match to a control that vanished can be one that deletes
      // or pays. Refusing costs a failed run; accepting writes the wrong
      // target into a macro that runs unattended from then on.
      trace.event(
        'error',
        'repair',
        {
          step: stepIndex,
          reason: 'replacement is irreversible and the step was not',
          candidate: element.l ?? element.id,
          why: suggestion.why,
        },
        Date.now() - started,
        true,
      );
      return false;
    }

    this.macro = this.store.patchSelector(
      this.macro.id,
      stepIndex,
      repairedStep(step, replacement),
    );
    this.repairs += 1;

    trace.event(
      'recover',
      'repair',
      {
        step: stepIndex,
        was: step.sel,
        now: replacement,
        why: suggestion.why,
        version: this.macro.version,
      },
      Date.now() - started,
    );
    return true;
  }

  private async perform(hands: Hands, step: Macro['steps'][number]): Promise<boolean> {
    switch (step.op) {
      case 'launch':
        return (
          await hands.launch({
            ...(step.url === undefined ? {} : { url: step.url }),
            ...(step.bundleId === undefined ? {} : { bundleId: step.bundleId }),
            ...(step.restart === undefined ? {} : { restart: step.restart }),
          })
        ).ok;
      case 'tap':
        return (await hands.tap(step.sel, step.alt)).ok;
      case 'type':
        return (await hands.type(step.text, { submit: step.submit ?? false })).ok;
      case 'swipe':
        return (await hands.swipe(step.from, step.to, step.duration)).ok;
      case 'back':
        return (await hands.back()).ok;
      case 'wait':
        await new Promise((done) => setTimeout(done, step.ms));
        return true;
      case 'assert':
        return (await hands.assert(step.sel, step.timeout)).ok;
    }
  }
}

/**
 * Whether a control is far enough from the edges to actually be tappable.
 *
 * Being on screen is not the same as being reachable. Measured on an iPhone 14
 * Pro: 손쉬운 사용 sitting at y=748 of an 852pt screen is reported visible by
 * WDA, resolves fine, and a tap at its centre does nothing at all — no
 * navigation, no change of any kind. One more short scroll puts it at y=593
 * and the same tap works. The bottom band belongs to the home indicator and
 * the system's edge gestures, and a tap there is swallowed before the app sees
 * it; the top band is under the navigation bar.
 *
 * The bounds are deliberately conservative, and they come from that one
 * measured failure rather than from any documented number: 774/852 = 0.91 did
 * not work, 619/852 = 0.73 did. Scrolling one row further costs a second and
 * a tap that vanishes costs the run.
 */
export function reachable(element: Element, screen: Screen): boolean {
  const centre = element.r[1] + element.r[3] / 2;
  const height = screen.size.h;
  if (height <= 0) return true;
  const fraction = centre / height;
  return fraction > 0.12 && fraction < 0.8;
}
