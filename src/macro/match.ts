import type { Macro } from '../shared/types.js';

/**
 * Which saved route, if any, an utterance is asking for.
 *
 * Deliberately not a model. [ADR 0006](../../docs/adr/0006-model-tiering.md)
 * puts routing on Haiku, and it will need to be one once there are dozens of
 * macros phrased loosely — but a model here would run on every request, and
 * putting one in before knowing what plain matching fails at means never
 * finding out. This is the thing to beat, not a placeholder to tolerate.
 *
 * Matching is on the trigger the macro was saved with. Parameter slots stand
 * in for whatever the person said in that position, so "음악 재생해줘" and
 * "팟캐스트 재생해줘" reach the same route with a different argument.
 */
export interface Match {
  macro: Macro;
  /** Values captured from the `{param}` slots, by name. */
  args: Record<string, string>;
}

export function matchMacro(utterance: string, macros: readonly Macro[]): Match | undefined {
  const said = normalize(utterance);
  for (const macro of macros) {
    for (const trigger of macro.triggers) {
      const args = capture(said, normalize(trigger));
      if (args) return { macro, args };
    }
  }
  return undefined;
}

/**
 * Spacing and punctuation vary between what someone types and what was saved;
 * the words are the part that carries the request.
 */
function normalize(text: string): string {
  return text
    .trim()
    .replace(/[.!?~]+$/u, '')
    .replace(/\s+/gu, ' ')
    .toLowerCase();
}

/**
 * Match a trigger with `{param}` slots against what was said.
 *
 * A slot matches one run of characters up to whatever literal follows it, so
 * the literal parts have to line up exactly. Loose paraphrase is what the
 * model tier is for; guessing here would route confidently to the wrong route.
 */
function capture(said: string, trigger: string): Record<string, string> | undefined {
  const names: string[] = [];
  const pattern = trigger
    .replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
    .replace(/\\\{(\w+)\\\}/gu, (_, name: string) => {
      names.push(name);
      return '(.+?)';
    });

  const found = new RegExp(`^${pattern}$`, 'u').exec(said);
  if (!found) return undefined;

  const args: Record<string, string> = {};
  names.forEach((name, i) => {
    const value = found[i + 1];
    if (value !== undefined) args[name] = value;
  });
  return args;
}
