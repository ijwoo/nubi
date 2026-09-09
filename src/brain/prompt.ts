import type { Screen } from '../shared/types.js';
import type { PlanContext } from './planner.js';

/**
 * How the phone is described to the model.
 *
 * Not as pixels. The compacted accessibility tree is roughly a thousandth the
 * tokens of a screenshot and names controls in a way that survives being
 * written into a macro (ADR 0002), so the model is given a list of what can be
 * acted on and nothing else.
 *
 * Rects are left out. Compaction has already dropped anything off-screen, so
 * document order tracks visual order closely enough to reason about, and
 * coordinates would invite the model to do arithmetic that only ever produces
 * the most fragile kind of selector.
 */
export function renderScreen(screen: Screen): string {
  const lines = screen.elements.map((e) => {
    const parts = [String(e.i).padStart(3), e.t.padEnd(12)];
    if (e.l !== undefined) parts.push(`"${e.l}"`);
    if (e.v !== undefined) parts.push(`= "${e.v}"`);
    if (e.id !== undefined) parts.push(`#${e.id}`);
    if (!e.e) parts.push('(disabled)');
    return parts.join(' ');
  });

  return [
    `app: ${screen.app}`,
    `screen: ${screen.hash}  (${screen.elements.length} elements)`,
    ...(screen.keyboard ? ['note: the keyboard is open, so a text field has focus'] : []),
    ...(screen.truncated ? ['note: element list was truncated'] : []),
    '',
    ...lines,
  ].join('\n');
}

export const SYSTEM_PROMPT = `You operate an iPhone on someone's behalf.

Each turn you are shown the controls currently on screen and you choose one
action. You cannot see the screen as an image — the list is everything you
know about it. Elements are numbered; you act on a number.

How to work:

- One action at a time. After it runs you will see the new screen. Do not plan
  several steps ahead: on a phone the first result is usually not what was
  imagined, and the rest of the plan is then wasted.
- Text goes to whatever has focus. Tap a field to focus it — but only once: if
  the keyboard is already open, a field is focused, so type instead of tapping
  again.
- Prefer a control whose purpose is unambiguous from its label or identifier.
- If a screen has no control that moves toward the goal, look for a way to
  scroll or go back rather than tapping something at random.
- Say why in one short clause. It is read by a person looking at a failed run,
  not by you.

When to stop:

- Call done when the goal is achieved. Something else verifies this, so a
  premature done is caught — but it wastes the run, so only claim it when the
  screen actually shows the result.
- Call stuck when no available action would help: the app is asking for
  something you cannot provide, the goal needs a screen you cannot reach, or
  you have tried what there is. Stopping is better than tapping until the step
  budget runs out.

You are acting on a real device belonging to a real person. Anything that
sends, deletes, pays, or grants a permission is not yours to decide — stop and
say so instead.`;

/** The turn's user message: the goal, what has been tried, and the screen. */
export function renderTurn(ctx: PlanContext): string {
  const parts = [`Goal: ${ctx.goal}`];

  if (ctx.history.length > 0) {
    const done = ctx.history.map((a, i) => {
      const what =
        a.kind === 'tap'
          ? `tap element ${a.element}`
          : a.kind === 'type'
            ? `type "${a.text}"`
            : a.kind === 'swipe'
              ? `swipe ${a.direction}`
              : a.kind;
      return `  ${i + 1}. ${what} — ${a.why}`;
    });
    parts.push(`\nAlready tried:\n${done.join('\n')}`);
  }

  if (ctx.lastFailure) {
    parts.push(`\nThe last action failed: ${ctx.lastFailure}`);
  }

  parts.push(`\nSteps left: ${ctx.stepsRemaining}`);
  parts.push(`\n${renderScreen(ctx.screen)}`);

  return parts.join('\n');
}
