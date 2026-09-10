import Anthropic from '@anthropic-ai/sdk';
import { renderScreen } from '../brain/prompt.js';
import { supportsEffort } from '../shared/model.js';
import type { ModelUsage } from '../shared/types.js';
import type { RepairContext, RepairResult, Repairer } from './repair.js';

/**
 * Finds a control again after the screen it lived on changed.
 *
 * This is a narrower job than planning, and the prompt is written to keep it
 * narrow. The planner is asked what to do next; the repairer is asked one
 * question about one step — which control on this screen is the one the macro
 * meant — and is not told what the route is for. A repairer that knows the
 * goal starts solving the task instead of the step, and a repair that
 * improvises a new route gets written into the macro as though it were the
 * old one.
 */

export interface ClaudeRepairerOptions {
  model?: string;
  effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  maxTokens?: number;
  client?: Anthropic;
}

const TOOLS: Anthropic.Beta.BetaToolUnion[] = [
  {
    name: 'found',
    description:
      'The control the broken step meant is on this screen, renamed or moved. ' +
      'Use the number shown beside it.',
    input_schema: {
      type: 'object',
      properties: {
        element: { type: 'integer', description: 'The number beside the control.' },
        why: {
          type: 'string',
          description: 'Why this is the same control, in one sentence.',
        },
      },
      required: ['element', 'why'],
    },
  },
  {
    name: 'gone',
    description:
      'Nothing on this screen is the control the step meant. Prefer this whenever ' +
      'you are guessing.',
    input_schema: {
      type: 'object',
      properties: {
        why: { type: 'string', description: 'What is missing, in one sentence.' },
      },
      required: ['why'],
    },
  },
];

const SYSTEM_PROMPT = `A saved route stopped working. One step points at a control that is no longer there — the app was redesigned, the label was translated, an identifier changed.

You are given the step that broke and the screen as it is now. Decide which control on this screen is the same one, or say it is gone.

Rules:
- Same control, not similar purpose. "설정" renamed to "환경설정" is the same control. A different button that would also make progress is not.
- Your answer is written into the saved route and used unattended from then on. A wrong answer is not one failed run; it is every run after it, doing the wrong thing quietly.
- Say gone whenever you are guessing. A route that fails gets found again by exploration, which is slower and cheaper than a route that succeeds at the wrong thing.
- Never answer with a control that deletes, sends, posts, buys, or pays unless the broken step was already one of those.`;

export class ClaudeRepairer implements Repairer {
  readonly name = 'claude-repairer';

  private readonly client: Anthropic;
  private readonly model: string;
  private readonly effort: NonNullable<ClaudeRepairerOptions['effort']>;
  private readonly maxTokens: number;

  constructor(options: ClaudeRepairerOptions = {}) {
    this.client = options.client ?? new Anthropic();
    // ADR 0006 still governs this row. ADR 0010 moved planning to Sonnet on
    // measured evidence, and deliberately did not extend that to repair: it is
    // a different question on a different input, and nobody has run the sweep.
    this.model = options.model ?? 'claude-opus-5';
    this.effort = options.effort ?? 'high';
    this.maxTokens = options.maxTokens ?? 1024;
  }

  async suggest(ctx: RepairContext): Promise<RepairResult> {
    const response = await this.client.beta.messages.create({
      model: this.model,
      max_tokens: this.maxTokens,
      ...(supportsEffort(this.model) ? { output_config: { effort: this.effort } } : {}),
      system: [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
      tools: TOOLS,
      // Prose here would be read as neither a repair nor a refusal.
      tool_choice: { type: 'any' },
      messages: [{ role: 'user', content: renderRepair(ctx) }],
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
    if (!call || call.name !== 'found') return { usage };

    const input = call.input as Record<string, unknown>;
    const element = Number(input.element);
    // An index that is not on the screen is a refusal that arrived in the
    // wrong shape. Replay checks this too; failing here keeps the reason.
    if (!Number.isInteger(element) || element < 0 || element >= ctx.screen.elements.length) {
      return { usage };
    }
    return {
      suggestion: { element, why: typeof input.why === 'string' ? input.why : '' },
      usage,
    };
  }
}

/**
 * What the repairer is shown.
 *
 * The broken selector verbatim, because its shape is the evidence — an `id`
 * that vanished means something different from a label that did. The steps
 * around it, because "the control after 일반" is often the only thing left to
 * recognise it by. Not the triggers, which say what the route is for.
 */
export function renderRepair(ctx: RepairContext): string {
  const step = ctx.macro.steps[ctx.stepIndex];
  const near = ctx.macro.steps
    .map((s, i) => {
      const mark = i === ctx.stepIndex ? '>>' : '  ';
      const what = s.op === 'tap' ? `tap ${JSON.stringify(s.sel)}` : s.op;
      return `${mark} ${i}. ${what}`;
    })
    .join('\n');

  return [
    `Broken step: ${ctx.stepIndex}`,
    `Selector that no longer resolves: ${JSON.stringify(ctx.broken)}`,
    `Failure: ${ctx.reason === 'no-match' ? 'no control matched' : 'the saved point is off screen'}`,
    step?.op === 'tap' && step.alt !== undefined
      ? `This step was repaired before; it used to be ${JSON.stringify(step.alt)}.`
      : '',
    '',
    'The route:',
    near,
    '',
    'The screen now:',
    renderScreen(ctx.screen),
  ]
    .filter(Boolean)
    .join('\n');
}
