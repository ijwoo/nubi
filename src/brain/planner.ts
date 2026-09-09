import type { Screen } from '../shared/types.js';

/**
 * What the model is allowed to do next.
 *
 * One action per turn, deliberately. Planning several steps ahead reads well
 * and is wasted the moment the first result differs from what was imagined —
 * which on a phone is most of the time. The loop re-observes instead.
 *
 * Targets are element indices from the observation the model was just given,
 * not selectors. The model should not have to know which selector survives a
 * redesign; picking the element is its job, and deriving a durable selector
 * from it is the code's (ADR 0004). That derivation is also what later turns a
 * successful exploration into a macro.
 */
export type PlannedAction =
  | { kind: 'tap'; element: number; why: string }
  | { kind: 'type'; text: string; submit: boolean; why: string }
  | { kind: 'swipe'; direction: 'up' | 'down' | 'left' | 'right'; why: string }
  | { kind: 'back'; why: string }
  /** The goal looks achieved. The runner still checks (ADR 0009). */
  | { kind: 'done'; why: string }
  /** No action would help. Better than flailing until the step budget runs out. */
  | { kind: 'stuck'; why: string };

export interface PlanContext {
  /** What the user asked for, verbatim. */
  goal: string;
  screen: Screen;
  /** Actions already taken, oldest first — what has been tried. */
  history: PlannedAction[];
  /** Why the previous action failed, when it did. */
  lastFailure?: string;
  stepsRemaining: number;
}

export interface PlanResult {
  action: PlannedAction;
  usage?: {
    model: string;
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
  };
}

/**
 * Decides the next action.
 *
 * An interface for the same reason Hands is one: the loop, the prompt, the
 * termination rules, and the trace can all be exercised without a network or
 * an API key. Only `ClaudePlanner` needs either.
 */
export interface Planner {
  readonly name: string;
  next(ctx: PlanContext): Promise<PlanResult>;
}

/**
 * Returns a fixed sequence of actions.
 *
 * Lets the explore loop be tested for the things that actually go wrong —
 * running out of steps, repeating itself, giving up, claiming success it did
 * not achieve — none of which need a real model to reproduce.
 */
export class ScriptedPlanner implements Planner {
  readonly name = 'scripted-planner';
  private at = 0;

  constructor(private readonly actions: PlannedAction[]) {}

  async next(): Promise<PlanResult> {
    const action = this.actions[this.at++];
    if (!action) return { action: { kind: 'stuck', why: 'script exhausted' } };
    return { action };
  }
}
