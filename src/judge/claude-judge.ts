import Anthropic from '@anthropic-ai/sdk';
import { renderScreen } from '../brain/prompt.js';
import { supportsEffort } from '../shared/model.js';
import type { ModelUsage, Screen } from '../shared/types.js';
import type { Judge, Verdict } from './judge.js';

/**
 * Reads the screen and says whether the request was carried out.
 *
 * On the cheap tier by design ([ADR 0006](../../docs/adr/0006-model-tiering.md)):
 * this is a classification, not a plan. "재생 버튼이 보인다" answers "is it
 * playing" without any reasoning about what to do next.
 *
 * It is deliberately not told what the run did. Given the history it would be
 * judging its own account of events, which is the thing that needed checking —
 * the planner already said `done`, and asking a model to review a story it was
 * handed produces agreement rather than evidence. It gets the request and the
 * screen, and nothing else.
 */

export interface ClaudeJudgeOptions {
  model?: string;
  maxTokens?: number;
  client?: Anthropic;
}

const TOOLS: Anthropic.Beta.BetaToolUnion[] = [
  {
    name: 'verdict',
    description: 'Say whether this screen shows the request was carried out.',
    input_schema: {
      type: 'object',
      properties: {
        done: {
          type: 'boolean',
          description: 'True only if the screen shows the request already carried out.',
        },
        why: { type: 'string', description: 'What on the screen decided it, in one sentence.' },
      },
      required: ['done', 'why'],
    },
  },
];

const SYSTEM_PROMPT = `Someone asked for something to be done on an iPhone. You are shown the request and the screen as it is now. Say whether the screen shows it was carried out.

Judge the state, not the effort. A screen that is one press away from the request is not the request: a player showing a play button is not playing, a compose window with text in it has not sent, a switch still off is still off.

Say no when the screen does not settle it. A run that cannot be shown to have worked is more useful reported as a failure than as a success — the route gets found again, which costs a little, while a wrong success is saved and repeated.`;

export class ClaudeJudge implements Judge {
  readonly name = 'claude-judge';

  private readonly client: Anthropic;
  private readonly model: string;
  private readonly maxTokens: number;

  constructor(options: ClaudeJudgeOptions = {}) {
    this.client = options.client ?? new Anthropic();
    // The cheap tier, and the one row of ADR 0006 that measurement has not
    // argued with: judging is a classification, and it runs on every request.
    this.model = options.model ?? 'claude-haiku-4-5';
    this.maxTokens = options.maxTokens ?? 512;
  }

  async verdict(goal: string, screen: Screen): Promise<Verdict> {
    const response = await this.client.beta.messages.create({
      model: this.model,
      max_tokens: this.maxTokens,
      ...(supportsEffort(this.model) ? { output_config: { effort: 'low' as const } } : {}),
      system: [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
      tools: TOOLS,
      tool_choice: { type: 'any' },
      messages: [
        {
          role: 'user',
          content: `Request: ${goal}\n\nThe screen now:\n${renderScreen(screen)}`,
        },
      ],
    });

    const usage: ModelUsage = {
      model: response.model,
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
      ...(response.usage.cache_read_input_tokens
        ? { cacheReadTokens: response.usage.cache_read_input_tokens }
        : {}),
      ...(response.usage.cache_creation_input_tokens
        ? { cacheWriteTokens: response.usage.cache_creation_input_tokens }
        : {}),
    };

    const call = response.content.find((b) => b.type === 'tool_use');
    if (!call) {
      // No answer is not a yes.
      return { ok: false, why: '판정을 받지 못했습니다', usage };
    }
    const input = call.input as Record<string, unknown>;
    return {
      ok: input.done === true,
      why: typeof input.why === 'string' ? input.why : '',
      usage,
    };
  }
}
