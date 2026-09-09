import type { Hands } from '../hands/types.js';
import type { Macro } from '../shared/types.js';
import type { Trace } from '../trace/index.js';
import type { Task } from './task.js';

/**
 * A way of attempting a task.
 *
 * The interface exists so the same tasks and the same measurements cover every
 * approach: replaying a known route, exploring with a model, repairing a
 * broken step. Comparing them is the entire point of the eval harness, and
 * that only works if the thing being compared is swappable and the thing doing
 * the judging is not.
 *
 * An executor reports whether it believes it finished. It does not decide
 * whether the task succeeded — the runner checks the task's own assertion
 * against the device. An executor that graded itself would be measuring its
 * own opinion.
 */
export interface Executor {
  readonly name: string;
  /** Attempt the task. Returning false means it gave up, not that it failed the assertion. */
  run(hands: Hands, task: Task, trace: Trace): Promise<boolean>;
}

/**
 * Replays a fixed list of steps.
 *
 * The simplest possible executor, and the baseline every other one is measured
 * against: it calls no model at all, so its cost is the floor. Phase 04's
 * replay path is this plus selector repair and macros learned rather than
 * hand-written.
 */
export class ScriptedExecutor implements Executor {
  readonly name = 'scripted';

  constructor(private readonly macro: Macro) {}

  async run(hands: Hands, _task: Task, trace: Trace): Promise<boolean> {
    for (const [i, step] of this.macro.steps.entries()) {
      const ok = await this.step(hands, step, trace);
      if (!ok) {
        trace.event('error', 'replay', { step: i, op: step.op, macro: this.macro.id }, 0, true);
        return false;
      }
    }
    return true;
  }

  private async step(hands: Hands, step: Macro['steps'][number], trace: Trace): Promise<boolean> {
    switch (step.op) {
      case 'launch': {
        const target = {
          ...(step.url === undefined ? {} : { url: step.url }),
          ...(step.bundleId === undefined ? {} : { bundleId: step.bundleId }),
          ...(step.restart === undefined ? {} : { restart: step.restart }),
        };
        return (await hands.launch(target)).ok;
      }
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
        trace.event('assert', 'replay', { op: 'wait', ms: step.ms }, step.ms);
        return true;
      case 'assert':
        return (await hands.assert(step.sel, step.timeout)).ok;
    }
  }
}
