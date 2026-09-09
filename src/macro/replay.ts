import { selectorFor } from '../brain/explore.js';
import type { Executor } from '../eval/executor.js';
import type { Task } from '../eval/task.js';
import type { Hands } from '../hands/types.js';
import type { Macro } from '../shared/types.js';
import type { Trace } from '../trace/index.js';
import { type Repairer, isWorthKeeping, repairedStep } from './repair.js';
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
}

export class ReplayExecutor implements Executor {
  readonly name = 'replay';

  private readonly store: MacroStore;
  private readonly repairer: Repairer;
  private readonly maxRepairs: number;
  private macro: Macro;

  /** Repairs written into the macro during the last run. */
  repairs = 0;

  constructor(options: ReplayOptions) {
    this.macro = options.macro;
    this.store = options.store;
    this.repairer = options.repairer;
    this.maxRepairs = options.maxRepairs ?? 2;
  }

  async run(hands: Hands, _task: Task, trace: Trace): Promise<boolean> {
    this.repairs = 0;

    for (let i = 0; i < this.macro.steps.length; i++) {
      const step = this.macro.steps[i];
      if (!step) break;

      if (await this.perform(hands, step)) continue;

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

  private async repair(hands: Hands, trace: Trace, stepIndex: number): Promise<boolean> {
    const step = this.macro.steps[stepIndex];
    if (!step || step.op !== 'tap') return false;

    const screen = await hands.screen();
    const started = Date.now();
    const suggestion = await this.repairer.suggest({
      macro: this.macro,
      stepIndex,
      broken: step.sel,
      reason: 'no-match',
      screen,
    });

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
