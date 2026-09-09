import type { RouteStep } from '../brain/index.js';
import type { Task } from '../eval/task.js';
import { type Macro, MacroSchema, type Risk, type Step } from '../shared/types.js';

/**
 * Turn a route that worked into a macro that can be replayed.
 *
 * This is where exploration pays for itself. Everything before it — the
 * compaction, the selector ladder, the action vocabulary — exists so that what
 * the model found on one screen can be written down in a form that finds the
 * same control next week.
 */

export interface ExtractOptions {
  /** Filename and identity. Must survive being a filename. */
  id: string;
  /** The task that was accomplished. Supplies the launch and the assertion. */
  task: Task;
  /** What the person asked for, which becomes the trigger. */
  goal: string;
}

/**
 * Words that mean an action cannot be taken back.
 *
 * A heuristic, and one deliberately biased toward caution: a false positive
 * costs a confirmation the person taps through, a false negative spends their
 * money or deletes their data. Kept narrow enough to avoid flagging every
 * screen — "확인" alone is too common to mean anything.
 */
const IRREVERSIBLE = [
  '결제',
  '구매',
  '주문',
  '결재',
  '송금',
  '이체',
  '삭제',
  '지우기',
  '제거',
  '탈퇴',
  '전송',
  '보내기',
  '발송',
  '게시',
  'pay',
  'buy',
  'purchase',
  'checkout',
  'subscribe',
  'delete',
  'remove',
  'erase',
  'send',
  'post',
  'publish',
];

export function extractMacro(route: readonly RouteStep[], opts: ExtractOptions): Macro {
  const { params, steps } = buildSteps(route, opts.goal);

  const macro = {
    id: opts.id,
    version: 1,
    triggers: [parameterize(opts.goal, params)],
    app: opts.task.setup.bundleId,
    risk: riskOf(route),
    params: Object.fromEntries(
      Object.keys(params).map((name) => [name, { type: 'string' as const, required: true }]),
    ),
    steps: [
      // The macro opens the app itself. In use nothing else guarantees it is
      // running, and `restart` is what makes "from the app's own first screen"
      // mean anything.
      { op: 'launch' as const, bundleId: opts.task.setup.bundleId, restart: true },
      ...steps,
      // The task's own check, carried into the macro. Without it a replay
      // reports success for having performed the steps rather than for having
      // achieved anything.
      { op: 'assert' as const, sel: opts.task.assert.selector, timeout: opts.task.assert.withinMs },
    ],
    stats: { runs: 0, fails: 0, avgMs: 0 },
  };

  return MacroSchema.parse(macro);
}

/**
 * Convert actions into steps, pulling typed text out as parameters.
 *
 * Text the person said and the model then typed is the one part of a route
 * that obviously varies between runs — "손쉬운 사용 열기" and "카메라 열기"
 * are the same route with one word changed. Anything typed that does not
 * appear in the goal is left literal, since it was the model's own doing
 * rather than the person's input.
 */
function buildSteps(
  route: readonly RouteStep[],
  goal: string,
): { steps: Step[]; params: Record<string, string> } {
  const params: Record<string, string> = {};
  const steps: Step[] = [];

  for (const entry of route) {
    const a = entry.action;
    switch (a.kind) {
      case 'tap':
        if (entry.selector) steps.push({ op: 'tap', sel: entry.selector });
        break;
      case 'type': {
        let text = a.text;
        if (text && goal.includes(text)) {
          const name = `arg${Object.keys(params).length + 1}`;
          params[name] = text;
          text = `{{${name}}}`;
        }
        steps.push({ op: 'type', text, submit: a.submit });
        break;
      }
      case 'swipe':
        steps.push({ op: 'swipe', ...SWIPE_POINTS[a.direction] });
        break;
      case 'back':
        steps.push({ op: 'back' });
        break;
      default:
        break; // done and stuck end a run rather than being part of it
    }
  }

  return { steps, params };
}

/** The same directions the explore loop uses, so a replay retraces the run. */
const SWIPE_POINTS: Record<
  'up' | 'down' | 'left' | 'right',
  { from: [number, number]; to: [number, number] }
> = {
  up: { from: [0.5, 0.7], to: [0.5, 0.3] },
  down: { from: [0.5, 0.3], to: [0.5, 0.7] },
  left: { from: [0.8, 0.5], to: [0.2, 0.5] },
  right: { from: [0.2, 0.5], to: [0.8, 0.5] },
};

/** Put the placeholders back into the phrase that will match this macro. */
function parameterize(goal: string, params: Record<string, string>): string {
  let trigger = goal;
  for (const [name, value] of Object.entries(params)) {
    trigger = trigger.replace(value, `{${name}}`);
  }
  return trigger;
}

/**
 * How much trust a macro gets by default.
 *
 * Judged from what the route touched, not from what it was asked to do — the
 * label on the control that was tapped is the closest thing to evidence of
 * what the step actually does. A macro that pressed something reading "결제"
 * asks before it runs (ADR 0007), and a person can raise the level later but
 * this never lowers one it set.
 */
function riskOf(route: readonly RouteStep[]): Risk {
  for (const entry of route) {
    const sel = entry.selector;
    if (!sel) continue;
    const named = [
      'label' in sel ? sel.label : undefined,
      'labelContains' in sel ? sel.labelContains : undefined,
      'id' in sel ? sel.id : undefined,
    ]
      .filter((s): s is string => s !== undefined)
      .join(' ')
      .toLowerCase();

    if (IRREVERSIBLE.some((word) => named.includes(word))) return 'confirm';
  }
  return 'safe';
}
