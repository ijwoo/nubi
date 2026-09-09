import type { Element, Macro, Screen, Selector } from '../shared/types.js';

/**
 * Finding a control again after the screen it lived on changed.
 *
 * The cost of dropping the model from replay (ADR 0003) is that a macro breaks
 * when an app is redesigned. Repair is what keeps that cost manageable: only
 * the step that missed goes back to a model, and the replacement is written
 * into the macro so the next run is fast again.
 *
 * Behind an interface for the same reason planning is — the escalation, the
 * patching, and the give-up conditions can all be tested without a network.
 */
export interface RepairContext {
  macro: Macro;
  /** Which step failed. */
  stepIndex: number;
  /** The selector that no longer resolves. */
  broken: Selector;
  /** Why it failed. `point-outside` means the layout moved, not that the control is gone. */
  reason: 'no-match' | 'point-outside';
  /** The screen as it is now. */
  screen: Screen;
}

export interface RepairSuggestion {
  /** The element the repairer believes was meant. */
  element: number;
  why: string;
}

export interface Repairer {
  readonly name: string;
  /** Undefined when nothing on this screen looks like the missing control. */
  suggest(ctx: RepairContext): Promise<RepairSuggestion | undefined>;
}

/** Returns fixed answers, so the repair flow can be exercised offline. */
export class ScriptedRepairer implements Repairer {
  readonly name = 'scripted-repairer';
  private at = 0;

  constructor(private readonly answers: (RepairSuggestion | undefined)[]) {}

  async suggest(): Promise<RepairSuggestion | undefined> {
    return this.answers[this.at++];
  }
}

/**
 * What a repaired step should look like.
 *
 * The selector that broke becomes `alt` rather than being thrown away: a
 * rolled-back release or an A/B bucket puts the old screen back, and a macro
 * that keeps succeeding through `alt` is evidence the repair was wrong.
 */
export function repairedStep(
  step: Macro['steps'][number],
  replacement: Selector,
): Macro['steps'][number] {
  if (step.op !== 'tap') return step;
  return { ...step, sel: replacement, alt: step.sel };
}

/**
 * Whether a suggestion is worth writing into the macro.
 *
 * A repair that lands on a coordinate has replaced a named control with the
 * most fragile rung of the ladder (ADR 0004). It will work once and break
 * again, and it will have overwritten whatever the step used to say. Better to
 * fail the run and let exploration find a real route.
 */
export function isWorthKeeping(replacement: Selector, element: Element): boolean {
  if ('point' in replacement) return false;
  // A control nobody can name is one nothing can reliably find again.
  return element.id !== undefined || element.l !== undefined || element.v !== undefined;
}
