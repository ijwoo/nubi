import type { TraceEvent } from '../shared/types.js';

/**
 * What a run cost in dollars.
 *
 * Computed from the usage the API reported, not from an estimate. The first
 * estimate this project made was wrong by half in one direction and missed
 * cache tokens entirely in the other, which is the usual fate of a number
 * nobody measured.
 */

/** $ per million tokens. Cached from the pricing page; check before quoting. */
const PRICES: Record<string, { input: number; output: number }> = {
  'claude-opus-5': { input: 5, output: 25 },
  'claude-opus-4-8': { input: 5, output: 25 },
  'claude-sonnet-5': { input: 3, output: 15 },
  'claude-sonnet-4-6': { input: 3, output: 15 },
  'claude-haiku-4-5': { input: 1, output: 5 },
};

/** A 5-minute cache entry costs 1.25x to write and 0.1x to read. */
const CACHE_WRITE = 1.25;
const CACHE_READ = 0.1;

export interface CostBreakdown {
  usd: number;
  /** Tokens billed at full input price. */
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  /** Models seen, so an unpriced one is visible rather than counted as free. */
  models: string[];
  /** True when some model had no price and its share is missing from `usd`. */
  incomplete: boolean;
}

export function costOf(events: readonly TraceEvent[]): CostBreakdown {
  let usd = 0;
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let incomplete = false;
  const models = new Set<string>();

  for (const e of events) {
    if (e.kind !== 'model') continue;
    const d = e.detail;
    const model = typeof d.model === 'string' ? d.model : '';
    const i = num(d.inputTokens);
    const o = num(d.outputTokens);
    const cr = num(d.cacheReadTokens);
    const cw = num(d.cacheWriteTokens);

    input += i;
    output += o;
    cacheRead += cr;
    cacheWrite += cw;
    if (model) models.add(model);

    const price = PRICES[model] ?? PRICES[stripDate(model)];
    if (!price) {
      // Counting an unknown model as free would understate every total that
      // includes it, silently.
      incomplete = true;
      continue;
    }
    usd +=
      (i * price.input + cr * price.input * CACHE_READ + cw * price.input * CACHE_WRITE) / 1e6 +
      (o * price.output) / 1e6;
  }

  return {
    usd,
    inputTokens: input,
    outputTokens: output,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    models: [...models],
    incomplete,
  };
}

/** `claude-opus-5-20260101` and `claude-opus-5` are the same price. */
function stripDate(model: string): string {
  return model.replace(/-\d{8}$/, '');
}

function num(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}
