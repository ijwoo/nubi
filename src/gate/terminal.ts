import { createInterface } from 'node:readline/promises';
import type { Approval, ApprovalRequest, Gate } from './gate.js';

/**
 * The fallback [ADR 0007](../../docs/adr/0007-approval-gate-off-device.md)
 * calls for when the relay is not available.
 *
 * It is on the Mac rather than the phone, which is the point: the gate has to
 * be somewhere the agent cannot reach. WDA drives the phone's screen, so an
 * approval drawn there is one the agent could press itself — by a bug, by an
 * injected instruction, or simply because the button looked like the next
 * step. A terminal on the machine running the loop is outside that reach in a
 * way the phone's own screen is not.
 *
 * Everything about it defaults to no. No TTY, no answer, a timeout, an
 * unrecognised reply — all refusals. The one thing that grants is a person
 * typing the word.
 */

export interface TerminalGateOptions {
  /** How long to wait before treating silence as a refusal. */
  timeoutMs?: number;
  input?: NodeJS.ReadableStream & { isTTY?: boolean };
  output?: NodeJS.WritableStream;
}

/** Typed in full, so it cannot be reached by leaning on the return key. */
const CONSENT = '승인';

export class TerminalGate implements Gate {
  readonly name = 'terminal';

  private readonly timeoutMs: number;
  private readonly input: NodeJS.ReadableStream & { isTTY?: boolean };
  private readonly output: NodeJS.WritableStream;

  constructor(options: TerminalGateOptions = {}) {
    this.timeoutMs = options.timeoutMs ?? 60_000;
    this.input = options.input ?? process.stdin;
    this.output = options.output ?? process.stdout;
  }

  async ask(request: ApprovalRequest): Promise<Approval> {
    if (this.input.isTTY !== true) {
      // A cron job or a piped run has nobody to ask. Reading from a non-TTY
      // would either block forever or take whatever the pipe happened to hold.
      return { granted: false, by: this.name, why: '터미널이 없어 물어볼 사람이 없습니다' };
    }

    this.output.write(prompt(request));

    const rl = createInterface({ input: this.input, output: this.output });
    const timeout = new Promise<undefined>((resolve) =>
      setTimeout(() => resolve(undefined), this.timeoutMs).unref(),
    );

    try {
      const answer = await Promise.race([rl.question(`${CONSENT} 라고 입력: `), timeout]);
      if (answer === undefined) {
        return { granted: false, by: this.name, why: '시간 초과 — 답이 없는 것은 승인이 아닙니다' };
      }
      if (answer.trim() !== CONSENT) {
        return { granted: false, by: this.name, why: '승인하지 않음' };
      }
      return { granted: true, by: this.name };
    } finally {
      rl.close();
    }
  }
}

/** What the person is being asked, with the controls named. */
export function prompt(request: ApprovalRequest): string {
  const lines = [
    '',
    '  ┌─ 승인이 필요합니다',
    `  │  요청: ${request.utterance}`,
    `  │  경로: ${request.macro.id}`,
  ];
  for (const reason of request.reasons) {
    lines.push(`  │  누릅니다: ${reason}`);
  }
  lines.push('  └─ 되돌릴 수 없는 동작입니다', '');
  return lines.join('\n');
}
