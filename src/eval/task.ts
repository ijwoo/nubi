import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { z } from 'zod';
import { SelectorSchema } from '../shared/types.js';

/**
 * What a task is, and what counts as having done it.
 *
 * A task states the goal and the evidence, never the route. Encoding the steps
 * here would make every measurement a measurement of the steps someone wrote
 * down — the point is to compare different ways of reaching the same end.
 *
 * YAML rather than JSON because these are written by hand and the reason a
 * task exists belongs in a comment next to it.
 */
export const TaskSchema = z.object({
  id: z.string().regex(/^[a-z0-9-]+$/),
  /** What a person would say. Explore receives this verbatim. */
  prompt: z.string(),
  /** Optional note about why this task is in the set. */
  note: z.string().optional(),

  /** Brought to a known state before every run — otherwise run 2 inherits run 1. */
  setup: z.object({
    bundleId: z.string(),
    restart: z.boolean().default(true),
    /** Settling time after launch, before the run starts. */
    settleMs: z.number().int().nonnegative().default(1200),
  }),

  /**
   * Evidence the task was done, checked by the runner rather than the
   * executor. Something that decides whether it succeeded cannot also be the
   * thing being measured.
   */
  assert: z.object({
    selector: SelectorSchema,
    withinMs: z.number().int().positive().default(10_000),
  }),

  /** Repetitions per mode. More runs, tighter p95. */
  runs: z.number().int().positive().default(3),

  /** Macro the scripted executor replays, when this task supports that mode. */
  scripted: z.object({ macro: z.string() }).optional(),
});
export type Task = z.infer<typeof TaskSchema>;

export function loadTask(file: string): Task {
  return TaskSchema.parse(parse(readFileSync(file, 'utf8')));
}
