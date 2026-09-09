import type { RouteStep } from '../brain/index.js';
import { isIrreversible } from '../shared/risk.js';
import {
  type Element,
  type Macro,
  MacroSchema,
  type Risk,
  type Screen,
  type Selector,
  type Step,
} from '../shared/types.js';

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
  /** What the person asked for, which becomes the trigger. */
  goal: string;
  /** The app the route ran in. The macro opens it itself. */
  app: string;
  /**
   * What a replay checks to know it arrived.
   *
   * Not optional. A macro without one reports success for having performed its
   * steps, which is success at pressing buttons rather than at anything — and
   * a route that cannot check itself is the macro recorder this project exists
   * not to be. `deriveAssertion` is how a live run produces it.
   */
  assert: { selector: Selector; withinMs?: number };
}

export function extractMacro(route: readonly RouteStep[], opts: ExtractOptions): Macro {
  const { params, steps } = buildSteps(route, opts.goal);

  const macro = {
    id: opts.id,
    version: 1,
    triggers: [parameterize(opts.goal, params)],
    app: opts.app,
    risk: riskOf(route),
    params: Object.fromEntries(
      Object.keys(params).map((name) => [name, { type: 'string' as const, required: true }]),
    ),
    steps: [
      // The macro opens the app itself. In use nothing else guarantees it is
      // running, and `restart` is what makes "from the app's own first screen"
      // mean anything.
      { op: 'launch' as const, bundleId: opts.app, restart: true },
      ...steps,
      {
        op: 'assert' as const,
        sel: opts.assert.selector,
        ...(opts.assert.withinMs === undefined ? {} : { timeout: opts.assert.withinMs }),
      },
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
    const named = isIrreversible(
      'label' in sel ? sel.label : undefined,
      'labelContains' in sel ? sel.labelContains : undefined,
      'id' in sel ? sel.id : undefined,
    );
    if (named) return 'confirm';
  }
  return 'safe';
}

/**
 * What a replay should check to know it got where this run got.
 *
 * The evidence is what the destination has that its baseline did not. A
 * control that was already there proves nothing — a macro asserting on it
 * would pass having done none of its steps, which is worse than no assertion
 * because it looks like one.
 *
 * "New" is necessary but not sufficient, which three live runs showed in turn.
 * Walking into Settings › 손쉬운 사용 offered `BackButton`, on every detail
 * screen in the app. Typing into search offered `shift`, on every screen with
 * a keyboard up. Typing 손쉬운 offered `‘손쉬운’에 대한 결과 없음`, true of
 * the one word that run happened to type. Each is new, stable, and evidence of
 * a mode rather than of arrival.
 *
 * So: chrome is excluded outright — navigation by name, the keyboard by where
 * it sits — along with anything echoing what was typed, since that is the part
 * a parameter replaces. What survives is ranked by how specific it is to this
 * destination. Highest is what the *last action* produced, which is a sharper
 * question than what the whole run produced: typing into an already-open
 * search field adds a clear button, while the field's own close button was
 * there before a word was entered. Then, within that, an identifier sharing a
 * word with the control tapped to get here — the destination naming itself.
 *
 * The ladder within each rank is the selector ladder (ADR 0004): an identifier
 * survives a translation and a redesign that a label does not. A label must be
 * unique on the screen to be usable, since an assertion matching two things is
 * evidence about neither, and among labels a control beats prose — a sentence
 * is copy, and copy is rewritten and translated in ways a name is not.
 *
 * Returns undefined when nothing qualifies. That is a refusal to extract, not
 * a reason to fall back on something weaker.
 */
export interface AssertionContext {
  /** Where the run began. A control already here proves nothing. */
  start: Screen;
  /** Where it ended. */
  final: Screen;
  /** The screen the last action acted on, when there was one. */
  beforeLastAction?: Screen;
  /** The control tapped to get here, if the last step was a tap. */
  arrivedVia?: Selector;
  /** Text the run typed. Whatever echoes it changes between runs. */
  typed?: readonly string[];
}

export function deriveAssertion(ctx: AssertionContext): Selector | undefined {
  const { start, final } = ctx;
  const typed = ctx.typed ?? [];
  const atStart = new Set(start.elements.map(identity));
  const keyboardTop = final.keyboard?.top ?? Number.POSITIVE_INFINITY;
  const echoes = (e: Element) =>
    typed.some((t) => t.length > 0 && (e.l?.includes(t) || e.v?.includes(t)));

  const fresh = final.elements.filter(
    (e) => !atStart.has(identity(e)) && !isChrome(e) && e.r[1] < keyboardTop && !echoes(e),
  );

  const wanted = tokensOf(
    ctx.arrivedVia === undefined
      ? undefined
      : 'id' in ctx.arrivedVia
        ? ctx.arrivedVia.id
        : 'label' in ctx.arrivedVia
          ? ctx.arrivedVia.label
          : undefined,
  );
  const named = (e: Element) => tokensOf(e.id).concat(tokensOf(e.l));
  const relates = (e: Element) => named(e).some((t) => wanted.includes(t));

  const priorToLast = new Set((ctx.beforeLastAction ?? start).elements.map(identity));
  const caused = fresh.filter((e) => !priorToLast.has(identity(e)));

  const pools = [caused.filter(relates), caused, fresh.filter(relates), fresh];
  for (const pool of pools) {
    const byId = pool.find((e) => e.id !== undefined);
    if (byId?.id !== undefined) return { id: byId.id };
  }
  for (const pool of pools) {
    const best = pool
      .filter((e) => e.l !== undefined && final.elements.filter((o) => o.l === e.l).length === 1)
      .sort(byControlThenBrevity)[0];
    if (best?.l !== undefined) return { label: best.l, type: best.t };
  }
  return undefined;
}

/** Controls before prose, and within each the shorter name. */
function byControlThenBrevity(a: Element, b: Element): number {
  const prose = (e: Element) => (e.t === 'StaticText' ? 1 : 0);
  return prose(a) - prose(b) || (a.l?.length ?? 0) - (b.l?.length ?? 0);
}

/**
 * Controls that appear on every screen of an app and so identify none of them.
 *
 * Deliberately tiny. A long list would start excluding things that really do
 * name a screen, and the ranking above already prefers something better when
 * one exists — this only stops chrome winning by default.
 */
const CHROME = new Set(['backbutton', 'back', '뒤로']);

function isChrome(e: Element): boolean {
  return CHROME.has((e.id ?? e.l ?? '').toLowerCase());
}

/** Words shared between an identifier and a destination, ignoring boilerplate. */
const NOISE = new Set(['com', 'apple', 'settings', 'setting', 'button', 'cell', 'specifier', 'id']);

function tokensOf(text: string | undefined): string[] {
  if (!text) return [];
  return text
    .replace(/([a-z])([A-Z])/gu, '$1 $2')
    .split(/[^\p{L}\p{N}]+/u)
    .map((t) => t.toLowerCase())
    .filter((t) => t.length > 2 && !NOISE.has(t));
}

/** Identity for "was this already on screen", ignoring where it sat. */
function identity(e: Element): string {
  return e.id ?? `${e.t}|${e.l ?? ''}|${e.v ?? ''}`;
}
