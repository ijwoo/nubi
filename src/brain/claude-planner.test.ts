import type Anthropic from '@anthropic-ai/sdk';
import { describe, expect, it } from 'vitest';
import type { Screen } from '../shared/types.js';
import { ClaudePlanner } from './claude-planner.js';

/**
 * The request the planner builds, checked without spending anything.
 *
 * Every field here has one live failure behind it: a parameter the model
 * rejects returns a 400 before it sees the screen, which the eval records as
 * zero actions and zero tokens — the exact shape of a small model failing the
 * task on its own merits.
 */
function capture() {
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
            content: [{ type: 'tool_use', name: 'done', input: { why: 'ok' } }],
          };
        },
      },
    },
  } as unknown as Anthropic;
  return { client, sent };
}

const screen: Screen = {
  app: 'com.apple.Preferences',
  elements: [{ i: 0, t: 'Button', l: '일반', r: [0, 0, 100, 40], e: true }],
  size: { w: 393, h: 852 },
  hash: 'abc',
  capturedAt: '2026-09-09T00:00:00.000Z',
};
const ctx = { goal: '정보 열기', screen, history: [], stepsRemaining: 20 };

describe('ClaudePlanner request', () => {
  it('asks for effort on models that take it', async () => {
    const { client, sent } = capture();
    await new ClaudePlanner({ client, model: 'claude-sonnet-5', effort: 'high' }).next(ctx);
    expect(sent[0]?.output_config).toEqual({ effort: 'high' });
  });

  it('omits effort on Haiku, which rejects it outright', async () => {
    // Live: 400 "This model does not support the effort parameter." on all 15
    // runs, reported as 0/15 with no tokens spent. Read as a capability gap in
    // the model rather than a bad request, it would have been written up as
    // evidence for keeping planning on the expensive tier.
    for (const model of ['claude-haiku-4-5', 'claude-haiku-4-5-20251001']) {
      const { client, sent } = capture();
      await new ClaudePlanner({ client, model }).next(ctx);
      expect(sent[0]?.output_config).toBeUndefined();
    }
  });

  it('plans on Sonnet unless told otherwise (ADR 0010)', async () => {
    const { client, sent } = capture();
    await new ClaudePlanner({ client }).next(ctx);
    expect(sent[0]?.model).toBe('claude-sonnet-5');
  });

  it('forces an action rather than letting a turn come back as prose', async () => {
    const { client, sent } = capture();
    await new ClaudePlanner({ client }).next(ctx);
    expect(sent[0]?.tool_choice).toEqual({ type: 'any' });
  });
});
