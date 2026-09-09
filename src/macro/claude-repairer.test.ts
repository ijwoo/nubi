import type Anthropic from '@anthropic-ai/sdk';
import { describe, expect, it } from 'vitest';
import type { Element, Macro, Screen } from '../shared/types.js';
import { ClaudeRepairer, renderRepair } from './claude-repairer.js';
import { escalatesRisk } from './repair.js';

function el(i: number, l: string, id?: string): Element {
  return { i, t: 'Button', l, r: [0, i * 44, 393, 44], e: true, ...(id ? { id } : {}) };
}

const screen: Screen = {
  app: 'com.apple.Preferences',
  elements: [el(0, '환경설정', 'settings.prefs'), el(1, '삭제', 'settings.delete')],
  size: { w: 393, h: 852 },
  hash: 'abc',
  capturedAt: '2026-09-09T00:00:00.000Z',
};

const macro: Macro = {
  id: 'demo',
  version: 1,
  triggers: ['설정 열어줘'],
  app: 'com.apple.Preferences',
  risk: 'safe',
  params: {},
  stats: { runs: 0, fails: 0, avgMs: 0 },
  steps: [
    { op: 'launch', bundleId: 'com.apple.Preferences', restart: true },
    { op: 'tap', sel: { id: 'settings.old' } },
  ],
};

const ctx = {
  macro,
  stepIndex: 1,
  broken: { id: 'settings.old' } as const,
  reason: 'no-match' as const,
  screen,
};

function capture(reply: { name: string; input: Record<string, unknown> }) {
  const sent: Record<string, unknown>[] = [];
  const client = {
    beta: {
      messages: {
        create: async (params: Record<string, unknown>) => {
          sent.push(params);
          return {
            model: params.model,
            stop_reason: 'tool_use',
            usage: { input_tokens: 10, output_tokens: 5 },
            content: [{ type: 'tool_use', ...reply }],
          };
        },
      },
    },
  } as unknown as Anthropic;
  return { client, sent };
}

describe('ClaudeRepairer', () => {
  it('returns the element the model identified', async () => {
    const { client } = capture({ name: 'found', input: { element: 0, why: '이름만 바뀜' } });
    const out = await new ClaudeRepairer({ client }).suggest(ctx);
    expect(out.suggestion).toEqual({ element: 0, why: '이름만 바뀜' });
  });

  it('reports usage even when it declines', async () => {
    // A refusal costs the same call as a fix. Reporting only the fixes would
    // put a run that asked a model and got "gone" down as costing nothing.
    const { client } = capture({ name: 'gone', input: { why: '없음' } });
    const out = await new ClaudeRepairer({ client }).suggest(ctx);
    expect(out.suggestion).toBeUndefined();
    expect(out.usage).toEqual({ model: 'claude-opus-5', inputTokens: 10, outputTokens: 5 });
  });

  it('treats `gone` as no suggestion rather than a failure', async () => {
    // Refusing is a valid answer, and the common one on a screen that really
    // did lose the control. Replay turns it into a failed run, which is what
    // sends the route back to exploration.
    const { client } = capture({ name: 'gone', input: { why: '해당 컨트롤 없음' } });
    expect((await new ClaudeRepairer({ client }).suggest(ctx)).suggestion).toBeUndefined();
  });

  it('refuses an element index that is not on the screen', async () => {
    // A refusal that arrived in the wrong shape. Replay would also catch it,
    // but by then the reason is gone.
    const { client } = capture({ name: 'found', input: { element: 9, why: '' } });
    expect((await new ClaudeRepairer({ client }).suggest(ctx)).suggestion).toBeUndefined();
  });

  it('stays on Opus, which ADR 0010 deliberately did not move', async () => {
    const { client, sent } = capture({ name: 'gone', input: { why: '' } });
    await new ClaudeRepairer({ client }).suggest(ctx);
    expect(sent[0]?.model).toBe('claude-opus-5');
    expect(sent[0]?.tool_choice).toEqual({ type: 'any' });
  });

  it('omits effort on Haiku, which rejects it', async () => {
    const { client, sent } = capture({ name: 'gone', input: { why: '' } });
    await new ClaudeRepairer({ client, model: 'claude-haiku-4-5' }).suggest(ctx);
    expect(sent[0]?.output_config).toBeUndefined();
  });
});

describe('renderRepair', () => {
  it('shows the broken selector and the route, but never what it was for', () => {
    // A repairer told what the route is for starts solving the task rather
    // than the step, and an improvised new route gets saved as though it were
    // the old one.
    const text = renderRepair(ctx);
    expect(text).toContain('settings.old');
    expect(text).toContain('>> 1.');
    expect(text).toContain('환경설정');
    for (const t of macro.triggers) expect(text).not.toContain(t);
  });

  it('says when a step has been repaired before', () => {
    const patched: Macro = {
      ...macro,
      steps: [
        macro.steps[0] as Macro['steps'][number],
        { op: 'tap', sel: { id: 'settings.old' }, alt: { id: 'settings.older' } },
      ],
    };
    expect(renderRepair({ ...ctx, macro: patched })).toContain('settings.older');
  });
});

describe('escalatesRisk', () => {
  it('blocks a safe step from being repaired onto a destructive control', () => {
    // The nearest match to a control that vanished can be the one beside it,
    // and repairs are written into the macro permanently.
    expect(escalatesRisk({ id: 'settings.old' }, el(1, '삭제', 'settings.delete'))).toBe(true);
  });

  it('allows a repair that stays as dangerous as the step already was', () => {
    // Already behind the approval gate (ADR 0007); refusing here would only
    // break routes the person has already agreed to.
    expect(escalatesRisk({ label: '삭제' }, el(1, '제거'))).toBe(false);
  });

  it('allows an ordinary repair', () => {
    expect(escalatesRisk({ id: 'settings.old' }, el(0, '환경설정'))).toBe(false);
  });
});
