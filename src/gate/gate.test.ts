import { PassThrough } from 'node:stream';
import { describe, expect, it } from 'vitest';
import type { Macro, Risk } from '../shared/types.js';
import { DenyingGate, ScriptedGate, reasonsToAsk, verdictFor } from './gate.js';
import { TerminalGate, prompt } from './terminal.js';

function macro(risk: Risk, taps: string[] = []): Macro {
  return {
    id: 'demo',
    version: 1,
    triggers: ['t'],
    app: 'com.apple.Preferences',
    risk,
    params: {},
    steps: [
      { op: 'launch', bundleId: 'com.apple.Preferences', restart: true },
      ...taps.map((label) => ({ op: 'tap' as const, sel: { label } })),
    ],
    stats: { runs: 0, fails: 0, avgMs: 0 },
  } as Macro;
}

const request = (m: Macro) => ({ utterance: '보내줘', macro: m, reasons: reasonsToAsk(m) });

describe('verdictFor', () => {
  it('runs what is safe and asks about what is not', () => {
    expect(verdictFor('safe')).toBe('run');
    expect(verdictFor('confirm')).toBe('ask');
  });

  it('refuses a blocked route without asking', () => {
    // Asking would make a decision someone already made negotiable per run.
    expect(verdictFor('blocked')).toBe('refuse');
  });
});

describe('reasonsToAsk', () => {
  it('names the controls, because "risky" is not something you can approve', () => {
    expect(reasonsToAsk(macro('confirm', ['취소', '삭제']))).toEqual(['삭제']);
  });

  it('says nothing about a route that presses nothing irreversible', () => {
    expect(reasonsToAsk(macro('safe', ['일반', '정보']))).toEqual([]);
  });
});

describe('DenyingGate', () => {
  it('says no, which is what an unreachable gate has said', async () => {
    const answer = await new DenyingGate().ask(request(macro('confirm', ['삭제'])));
    expect(answer.granted).toBe(false);
    expect(answer.why).toBeDefined();
  });
});

describe('ScriptedGate', () => {
  it('records what it was asked, so a test can check the person saw enough', async () => {
    const gate = new ScriptedGate([true]);
    await gate.ask(request(macro('confirm', ['삭제'])));
    expect(gate.asked[0]?.reasons).toEqual(['삭제']);
  });

  it('refuses once it runs out of answers', async () => {
    // Running past the script must not become consent.
    const gate = new ScriptedGate([]);
    expect((await gate.ask(request(macro('confirm')))).granted).toBe(false);
  });
});

describe('TerminalGate', () => {
  /** A pipe that claims to be a terminal, so the TTY guard can be stepped past. */
  function tty(): PassThrough & { isTTY?: boolean } {
    const stream: PassThrough & { isTTY?: boolean } = new PassThrough();
    stream.isTTY = true;
    return stream;
  }

  it('refuses when there is no terminal to ask in', async () => {
    // A cron job or a piped run has nobody there. Reading anyway would either
    // block forever or take whatever the pipe happened to hold.
    const gate = new TerminalGate({ input: new PassThrough(), output: new PassThrough() });
    const answer = await gate.ask(request(macro('confirm', ['삭제'])));
    expect(answer.granted).toBe(false);
    expect(answer.why).toContain('터미널');
  });

  it('grants only when the word is typed in full', async () => {
    const input = tty();
    const gate = new TerminalGate({ input, output: new PassThrough() });
    const answer = gate.ask(request(macro('confirm', ['삭제'])));
    input.write('승인\n');
    expect((await answer).granted).toBe(true);
  });

  it('does not accept a bare return', async () => {
    // Consent should not be reachable by leaning on the return key.
    const input = tty();
    const gate = new TerminalGate({ input, output: new PassThrough() });
    const answer = gate.ask(request(macro('confirm', ['삭제'])));
    input.write('\n');
    expect((await answer).granted).toBe(false);
  });

  it('does not accept a yes that is not the word', async () => {
    const input = tty();
    const gate = new TerminalGate({ input, output: new PassThrough() });
    const answer = gate.ask(request(macro('confirm', ['삭제'])));
    input.write('y\n');
    expect((await answer).granted).toBe(false);
  });

  it('treats silence as refusal rather than waiting forever', async () => {
    const gate = new TerminalGate({ input: tty(), output: new PassThrough(), timeoutMs: 20 });
    const answer = await gate.ask(request(macro('confirm', ['삭제'])));
    expect(answer.granted).toBe(false);
    expect(answer.why).toContain('시간 초과');
  });
});

describe('prompt', () => {
  it('names what will be pressed', () => {
    const text = prompt(request(macro('confirm', ['삭제'])));
    expect(text).toContain('삭제');
    expect(text).toContain('보내줘');
    expect(text).toContain('되돌릴 수 없는');
  });
});
