import type { Screen } from '../shared/types.js';

/**
 * Deciding whether a request was actually carried out.
 *
 * The executor's own word is not evidence ([ADR 0009](../../docs/adr/0009-runner-judges-not-executor.md)),
 * and until now only the eval acted on that — it has a task file with a written
 * assertion and counts `falseClaims` when the two disagree. A real request has
 * no such file, so `nubi run` took the model's `done` at face value.
 *
 * That gap has a shape: exploring "추천 노래 하나 틀어줘" in YouTube Music
 * navigated to a song, left the player showing a 재생 button — the control you
 * press to *start* — and reported success.
 *
 * The check cannot come from the screen the run ended on. An assertion derived
 * from that screen and then tested against it passes by construction. It has to
 * be a separate reading of the goal against what is there, which is the role
 * [ADR 0006](../../docs/adr/0006-model-tiering.md) already assigned to the
 * cheap tier: "지금 화면이 재생 중인가" is a classification, not a judgement.
 */

export interface Verdict {
  /** Whether the screen shows the request was carried out. */
  ok: boolean;
  why: string;
  /** Undefined when the judge answered without a model. */
  usage?: import('../shared/types.js').ModelUsage;
}

export interface Judge {
  readonly name: string;
  verdict(goal: string, screen: Screen): Promise<Verdict>;
}

/** Fixed answers, so the judging path can be exercised offline. */
export class ScriptedJudge implements Judge {
  readonly name = 'scripted-judge';
  private at = 0;
  readonly asked: { goal: string; screen: Screen }[] = [];

  constructor(private readonly answers: boolean[]) {}

  async verdict(goal: string, screen: Screen): Promise<Verdict> {
    this.asked.push({ goal, screen });
    const ok = this.answers[this.at++] ?? false;
    return { ok, why: ok ? 'scripted yes' : 'scripted no' };
  }
}

/**
 * Accepts whatever it is told, for callers that have their own check.
 *
 * Replay does: a macro carries the assertion it was extracted with, and that
 * assertion was written from a run someone judged. Asking twice would spend a
 * model call to re-derive an answer already on disk.
 */
export class TrustingJudge implements Judge {
  readonly name = 'trusting';
  async verdict(): Promise<Verdict> {
    return { ok: true, why: '판정 없음' };
  }
}
