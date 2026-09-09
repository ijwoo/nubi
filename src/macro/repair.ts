import { isIrreversible } from '../shared/risk.js';
import type { Element, Macro, ModelUsage, Screen, Selector } from '../shared/types.js';

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

/**
 * What one repair attempt produced.
 *
 * Usage is reported separately from the suggestion because a refusal costs the
 * same call as a fix. Folding them together would report a run that asked a
 * model and got "gone" as having spent nothing — and "replay costs $0" (ADR
 * 0003) is only worth anything if the exception to it is measured.
 */
export interface RepairResult {
  /** Undefined when nothing on this screen looks like the missing control. */
  suggestion?: RepairSuggestion;
  usage?: ModelUsage;
}

export interface Repairer {
  readonly name: string;
  suggest(ctx: RepairContext): Promise<RepairResult>;
}

/** Returns fixed answers, so the repair flow can be exercised offline. */
export class ScriptedRepairer implements Repairer {
  readonly name = 'scripted-repairer';
  private at = 0;

  constructor(private readonly answers: (RepairSuggestion | undefined)[]) {}

  async suggest(): Promise<RepairResult> {
    const suggestion = this.answers[this.at++];
    return suggestion === undefined ? {} : { suggestion };
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

/**
 * Whether a replacement is more dangerous than what it replaces.
 *
 * Repair looks for the control that best matches one that disappeared, and
 * "best match" is a similarity judgement with no notion of consequence. On a
 * redesigned screen the nearest thing to a vanished "저장" can easily be
 * "삭제" — adjacent in the layout, adjacent in the model's sense of what the
 * screen is for, and catastrophic.
 *
 * What makes this worth a hard rule rather than a prompt line is that a repair
 * is written back into the macro (`patchSelector`). A bad plan costs one run;
 * a bad repair costs every run after it, silently, on a route the person
 * already approved as safe.
 *
 * So the rule is one-directional: a step that was already irreversible may be
 * repaired to another irreversible control, because the approval gate (ADR
 * 0007) is already in front of it. A step that was safe may not become one.
 */
export function escalatesRisk(broken: Selector, element: Element): boolean {
  const wasDangerous = isIrreversible(
    'label' in broken ? broken.label : undefined,
    'labelContains' in broken ? broken.labelContains : undefined,
    'id' in broken ? broken.id : undefined,
  );
  if (wasDangerous) return false;
  return isIrreversible(element.l, element.v, element.id);
}
