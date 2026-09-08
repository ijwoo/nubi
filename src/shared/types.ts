import { z } from 'zod';

/* ------------------------------------------------------------------ *
 * Screen observation
 * ------------------------------------------------------------------ */

/**
 * A single interactive element, after tree compaction.
 * Field names are deliberately short — this shape is serialized into the
 * model's context on every observation, so bytes matter.
 * See docs/selector-strategy.md.
 */
export const ElementSchema = z.object({
  /** Stable index within this observation. */
  i: z.number().int(),
  /** XCUIElementType, e.g. "Button", "Cell", "TextField". */
  t: z.string(),
  /** Visible label. For an input this is the placeholder, not the content. */
  l: z.string().optional(),
  /** Current content: text typed into a field, a switch's on/off state. */
  v: z.string().optional(),
  /** accessibilityIdentifier, when the app sets one. */
  id: z.string().optional(),
  /** [x, y, width, height] in points. */
  r: z.tuple([z.number(), z.number(), z.number(), z.number()]),
  /** Enabled and hittable. */
  e: z.boolean(),
});
export type Element = z.infer<typeof ElementSchema>;

export interface Screen {
  /** Bundle id of the foreground app. */
  app: string;
  elements: Element[];
  /** Screen size in points, for normalizing coordinates. */
  size: { w: number; h: number };
  /** Stable hash of the element set — cheap change detection without a model. */
  hash: string;
  capturedAt: string;
  /** True when the element cap was hit and the tail was dropped. */
  truncated?: boolean;
  /**
   * A system alert sitting above the app, when one is present.
   *
   * It does not appear in the accessibility tree the app returns, so without
   * this an agent sees a perfectly ordinary screen while every tap is absorbed
   * by a modal it cannot perceive.
   */
  alert?: SystemAlert;
}

export interface SystemAlert {
  text: string;
  /** Button labels, in the order iOS presents them. */
  buttons: string[];
}

/* ------------------------------------------------------------------ *
 * Selectors
 * ------------------------------------------------------------------ */

/**
 * Ordered by stability, most stable first. Resolution tries each in order.
 * Coordinates are last and always require a following `assert` — a coordinate
 * tap never misses, it just hits the wrong thing. See ADR 0004.
 */
export const SelectorSchema = z.union([
  z.object({ id: z.string() }),
  z.object({ label: z.string(), type: z.string().optional() }),
  z.object({ labelContains: z.string(), type: z.string().optional() }),
  z.object({ index: z.object({ type: z.string(), n: z.number().int().nonnegative() }) }),
  /** Normalized to 0..1 against screen size, not absolute pixels. */
  z.object({ point: z.tuple([z.number().min(0).max(1), z.number().min(0).max(1)]) }),
]);
export type Selector = z.infer<typeof SelectorSchema>;

/* ------------------------------------------------------------------ *
 * Macro steps
 * ------------------------------------------------------------------ */

export const StepSchema = z.discriminatedUnion('op', [
  z.object({
    op: z.literal('launch'),
    url: z.string().optional(),
    bundleId: z.string().optional(),
  }),
  z.object({
    op: z.literal('tap'),
    sel: SelectorSchema,
    /** First fallback, usually a selector a previous repair replaced. */
    alt: SelectorSchema.optional(),
  }),
  z.object({
    op: z.literal('type'),
    text: z.string(),
    submit: z.boolean().optional(),
  }),
  z.object({
    op: z.literal('swipe'),
    from: z.tuple([z.number(), z.number()]),
    to: z.tuple([z.number(), z.number()]),
    duration: z.number().optional(),
  }),
  z.object({ op: z.literal('back') }),
  /** Fixed sleep. Last resort — prefer `assert`, which adapts to the device. */
  z.object({ op: z.literal('wait'), ms: z.number().int().positive() }),
  z.object({
    op: z.literal('assert'),
    sel: SelectorSchema,
    timeout: z.number().int().positive().default(8000),
  }),
]);
export type Step = z.infer<typeof StepSchema>;

/* ------------------------------------------------------------------ *
 * Macros
 * ------------------------------------------------------------------ */

/** safe: run it. confirm: ask on the phone first. blocked: refuse. */
export const RiskSchema = z.enum(['safe', 'confirm', 'blocked']);
export type Risk = z.infer<typeof RiskSchema>;

export const MacroSchema = z.object({
  id: z.string().regex(/^[a-z0-9-]+$/),
  version: z.number().int().positive().default(1),
  /** Utterance patterns for routing. `{param}` marks a parameter slot. */
  triggers: z.array(z.string()).min(1),
  app: z.string(),
  risk: RiskSchema.default('safe'),
  params: z
    .record(
      z.object({
        type: z.enum(['string', 'number']),
        required: z.boolean().default(true),
      }),
    )
    .default({}),
  steps: z.array(StepSchema).min(1),
  stats: z
    .object({
      runs: z.number().int().nonnegative().default(0),
      fails: z.number().int().nonnegative().default(0),
      avgMs: z.number().nonnegative().default(0),
      lastRun: z.string().optional(),
      healedAt: z.string().optional(),
    })
    .default({ runs: 0, fails: 0, avgMs: 0 }),
});
export type Macro = z.infer<typeof MacroSchema>;

/** A macro is demoted to Explore once it fails often enough to distrust. */
export function isDemoted(m: Macro): boolean {
  return m.stats.runs >= 5 && m.stats.fails / m.stats.runs > 0.3;
}

/* ------------------------------------------------------------------ *
 * Execution
 * ------------------------------------------------------------------ */

export type Path = 'route' | 'replay' | 'repair' | 'explore';

export interface RunResult {
  ok: boolean;
  path: Path;
  steps: number;
  durationMs: number;
  modelCalls: number;
  inputTokens: number;
  outputTokens: number;
  /** Present when ok is false. */
  error?: { kind: string; message: string; screen?: Screen };
}

/* ------------------------------------------------------------------ *
 * Trace
 * ------------------------------------------------------------------ */

/** One line of the JSONL trace. See docs/eval-design.md. */
export interface TraceEvent {
  runId: string;
  seq: number;
  at: string;
  path: Path;
  kind: 'observe' | 'act' | 'model' | 'assert' | 'recover' | 'approve' | 'error';
  durationMs: number;
  detail: Record<string, unknown>;
}
