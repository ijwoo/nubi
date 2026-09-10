import { isIrreversible } from '../shared/risk.js';
import type { Macro, Risk, Selector } from '../shared/types.js';

/**
 * Asking a person before doing something that cannot be undone.
 *
 * Behind an interface for the same reason planning and repair are: the real
 * channel is a Live Activity on the phone, reached through the pip-any relay
 * ([ADR 0007](../../docs/adr/0007-approval-gate-off-device.md)), and none of
 * the deciding should have to wait for that to exist. The terminal fallback
 * the ADR already calls for is the first implementation, and it is a real one
 * rather than a stand-in.
 *
 * What must not vary between implementations is the direction of the default.
 * A gate that cannot be reached has not granted anything.
 */

export interface ApprovalRequest {
  /** What the person asked for. */
  utterance: string;
  /**
   * The saved route this is about, when there is one.
   *
   * Absent while exploring, which is when approval matters most — a route that
   * sends something has to be performed once before it can be saved, and the
   * shape of this request originally assumed the saving had already happened.
   */
  macro?: Macro;
  /**
   * The controls that made this risky, named.
   *
   * "This route is risky" is not something anyone can meaningfully approve.
   * "This route presses 삭제" is.
   */
  reasons: string[];
}

export interface Approval {
  granted: boolean;
  /** Which gate answered, so a trace says where the decision came from. */
  by: string;
  why?: string;
}

export interface Gate {
  readonly name: string;
  ask(request: ApprovalRequest): Promise<Approval>;
}

/**
 * Why a macro needs asking about, in the words on the controls it presses.
 *
 * Read off the selectors rather than the goal: what a step actually does is
 * better evidenced by the control it targets than by what someone said they
 * wanted. The same reasoning `extractMacro` uses to set `risk` in the first
 * place — this recovers the specifics that a single enum value dropped.
 */
export function reasonsToAsk(macro: Macro): string[] {
  const named: string[] = [];
  for (const step of macro.steps) {
    if (step.op !== 'tap') continue;
    const text = textOf(step.sel);
    if (text !== undefined && isIrreversible(text)) named.push(text);
  }
  return named;
}

function textOf(sel: Selector): string | undefined {
  if ('label' in sel) return sel.label;
  if ('labelContains' in sel) return sel.labelContains;
  if ('id' in sel) return sel.id;
  return undefined;
}

/**
 * A gate that says no, for anywhere a real one is not available.
 *
 * Not a placeholder to be swapped out and forgotten: it is what a headless
 * run, a cron job, or a broken relay should get. Refusing costs a run that
 * someone can start again; the other default costs whatever the route does.
 */
export class DenyingGate implements Gate {
  readonly name = 'deny';
  async ask(_request: ApprovalRequest): Promise<Approval> {
    return { granted: false, by: this.name, why: '승인을 받을 수 있는 채널이 없습니다' };
  }
}

/** Fixed answers, so the approval paths can be exercised offline. */
export class ScriptedGate implements Gate {
  readonly name = 'scripted-gate';
  private at = 0;
  readonly asked: ApprovalRequest[] = [];

  constructor(private readonly answers: boolean[]) {}

  async ask(request: ApprovalRequest): Promise<Approval> {
    this.asked.push(request);
    const granted = this.answers[this.at++] ?? false;
    return { granted, by: this.name };
  }
}

/** Whether a risk level needs asking, refuses outright, or just runs. */
export function verdictFor(risk: Risk): 'run' | 'ask' | 'refuse' {
  switch (risk) {
    case 'safe':
      return 'run';
    case 'confirm':
      return 'ask';
    case 'blocked':
      // Not a question. A blocked macro is one someone decided should not run
      // unattended, and asking would make that decision negotiable per run.
      return 'refuse';
  }
}
