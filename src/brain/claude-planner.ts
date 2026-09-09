import Anthropic from '@anthropic-ai/sdk';
import type { PlanContext, PlanResult, PlannedAction, Planner } from './planner.js';
import { SYSTEM_PROMPT, renderTurn } from './prompt.js';

/**
 * Chooses the next action with Claude.
 *
 * The action vocabulary is expressed as tools rather than as JSON the model
 * writes into prose: the schema is enforced at the API rather than parsed
 * afterwards, and `tool_choice: any` makes returning nothing impossible. A
 * planner that replies with an apology instead of an action would stall the
 * loop for a whole step.
 */

export interface ClaudePlannerOptions {
  model?: string;
  /** ADR 0010 puts planning on Sonnet; `--model` overrides for a comparison. */
  effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  maxTokens?: number;
  client?: Anthropic;
}

/**
 * Models that reject `output_config.effort` outright.
 *
 * Sending it to Haiku 4.5 returns a 400 before the model sees anything, so a
 * tier sweep reads 0/5 with zero tokens spent — a result that looks exactly
 * like the small model failing the task, and would have been written up as
 * evidence for keeping planning on the expensive tier.
 */
const NO_EFFORT = new Set(['claude-haiku-4-5', 'claude-haiku-4-5-20251001']);

const TOOLS: Anthropic.Beta.BetaToolUnion[] = [
  {
    name: 'tap',
    description: 'Tap a control. Use the number shown beside it.',
    input_schema: {
      type: 'object',
      properties: {
        element: { type: 'integer', description: 'The element number to tap' },
        why: { type: 'string', description: 'One short clause, for someone reading a failed run' },
      },
      required: ['element', 'why'],
      additionalProperties: false,
    },
  },
  {
    name: 'type_text',
    description:
      'Type into whatever currently has focus. Tap a text field first — typing with nothing focused goes nowhere.',
    input_schema: {
      type: 'object',
      properties: {
        text: { type: 'string' },
        submit: { type: 'boolean', description: 'Press return afterwards' },
        why: { type: 'string' },
      },
      required: ['text', 'submit', 'why'],
      additionalProperties: false,
    },
  },
  {
    name: 'swipe',
    description: 'Scroll the screen. "up" moves the content up, revealing what is below.',
    input_schema: {
      type: 'object',
      properties: {
        direction: { type: 'string', enum: ['up', 'down', 'left', 'right'] },
        why: { type: 'string' },
      },
      required: ['direction', 'why'],
      additionalProperties: false,
    },
  },
  {
    name: 'go_back',
    description: 'Go back to the previous screen.',
    input_schema: {
      type: 'object',
      properties: { why: { type: 'string' } },
      required: ['why'],
      additionalProperties: false,
    },
  },
  {
    name: 'done',
    description:
      'The goal is achieved and the screen shows it. This is checked independently, so a premature call is caught — but it ends the run.',
    input_schema: {
      type: 'object',
      properties: { why: { type: 'string', description: 'What on screen shows the goal is met' } },
      required: ['why'],
      additionalProperties: false,
    },
  },
  {
    name: 'stuck',
    description:
      'No available action would help. Better than tapping until the step budget runs out.',
    input_schema: {
      type: 'object',
      properties: { why: { type: 'string' } },
      required: ['why'],
      additionalProperties: false,
    },
  },
];

export class ClaudePlanner implements Planner {
  readonly name = 'claude';

  private readonly client: Anthropic;
  private readonly model: string;
  private readonly effort: NonNullable<ClaudePlannerOptions['effort']>;
  private readonly maxTokens: number;

  constructor(options: ClaudePlannerOptions = {}) {
    this.client = options.client ?? new Anthropic();
    this.model = options.model ?? 'claude-sonnet-5';
    this.effort = options.effort ?? 'high';
    this.maxTokens = options.maxTokens ?? 4096;
  }

  async next(ctx: PlanContext): Promise<PlanResult> {
    const response = await this.client.beta.messages.create({
      model: this.model,
      max_tokens: this.maxTokens,
      betas: ['context-management-2025-06-27'],
      // Observations pile up fast: twenty steps of screens would fill the
      // window and force compaction, which loses detail and costs more than
      // dropping what is already stale. Only the current screen matters.
      context_management: {
        edits: [{ type: 'clear_tool_uses_20250919', clear_tool_inputs: true }],
      },
      ...(NO_EFFORT.has(this.model) ? {} : { output_config: { effort: this.effort } }),
      system: [
        {
          type: 'text',
          text: SYSTEM_PROMPT,
          // The prompt and tool list are byte-identical on every step of every
          // run, so they are the one part worth caching.
          cache_control: { type: 'ephemeral' },
        },
      ],
      tools: TOOLS,
      // Returning prose instead of an action would stall the loop for a step.
      tool_choice: { type: 'any' },
      messages: [{ role: 'user', content: renderTurn(ctx) }],
    });

    const call = response.content.find((b) => b.type === 'tool_use');
    const usage = {
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

    if (!call) {
      // `tool_choice: any` should prevent this. If it happens anyway, stopping
      // is the honest response — a made-up action would be worse than none.
      return {
        action: { kind: 'stuck', why: `no action returned (stop_reason: ${response.stop_reason})` },
        usage,
      };
    }

    return { action: toAction(call.name, call.input as Record<string, unknown>), usage };
  }
}

function toAction(name: string, input: Record<string, unknown>): PlannedAction {
  const why = typeof input.why === 'string' ? input.why : '';
  switch (name) {
    case 'tap':
      return { kind: 'tap', element: Number(input.element), why };
    case 'type_text':
      return { kind: 'type', text: String(input.text), submit: input.submit === true, why };
    case 'swipe':
      return {
        kind: 'swipe',
        direction: input.direction as 'up' | 'down' | 'left' | 'right',
        why,
      };
    case 'go_back':
      return { kind: 'back', why };
    case 'done':
      return { kind: 'done', why };
    default:
      return { kind: 'stuck', why: why || `unknown tool ${name}` };
  }
}
