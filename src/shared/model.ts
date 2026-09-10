/**
 * What a given model will and will not accept.
 *
 * Small enough to look like it belongs next to whichever call needs it, which
 * is how the same set ended up written twice — and how sending `effort` to a
 * model that rejects it turned a whole tier sweep into 0/15 with no tokens
 * spent, a result indistinguishable from the model failing the task.
 */

/** Models that reject `output_config.effort` with a 400 before reading anything. */
const NO_EFFORT = new Set(['claude-haiku-4-5', 'claude-haiku-4-5-20251001']);

export function supportsEffort(model: string): boolean {
  return !NO_EFFORT.has(model);
}
