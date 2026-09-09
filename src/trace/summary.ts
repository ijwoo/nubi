import { readFileSync } from 'node:fs';
import type { TraceEvent } from '../shared/types.js';

/**
 * What a run cost and how it went, derived from its trace.
 *
 * Every claim this project makes about learning being cheaper is a difference
 * between two of these, so the numbers are counted from what actually happened
 * rather than reported by the code that did it.
 */
export interface RunSummary {
  runId: string;
  ok: boolean;
  durationMs: number;
  /** Touch actions. Observations and asserts are counted separately. */
  actions: number;
  observations: number;
  asserts: number;
  modelCalls: number;
  inputTokens: number;
  outputTokens: number;
  /** Sessions rebuilt underneath the caller. Should be invisible; is not free. */
  recoveries: number;
  /**
   * Selectors mended and written back into the macro.
   *
   * Distinct from `recoveries`, which counts WDA sessions rebuilt underneath
   * the run — infrastructure papering over itself, invisible by design (ADR
   * 0005). A repair changes the saved route, so it is the opposite of
   * invisible: it is the thing self-healing claims to do, and until it had its
   * own number the claim was measured by reading the macro file afterwards.
   */
  repairs: number;
  /** Decisions handed to a person. */
  approvals: number;
  failures: number;
  /** The event that ended it, when it ended badly. */
  failedAt?: { seq: number; kind: string; detail: Record<string, unknown> };
}

export function summarize(events: readonly TraceEvent[]): RunSummary {
  const first = events[0];
  const end = events.find((e) => e.kind === 'end');
  // The `end` marker is flagged when a run failed, but it is the summary of
  // the failure, not a step that went wrong. Counting it would double every
  // failed run and make it the thing `failedAt` points at.
  const failures = events.filter((e) => e.failed && e.kind !== 'end');

  // A run's duration is the `end` event's own span, which the writer sets to
  // wall time since the run opened. Falling back to the event range keeps a
  // trace that was cut short — the interesting kind — readable.
  const durationMs =
    end?.durationMs ??
    (first && events.length > 1
      ? Date.parse(events[events.length - 1]?.at ?? first.at) - Date.parse(first.at)
      : 0);

  // The failure worth naming is the last real step that went wrong, not the
  // first recoverable stumble on the way there — and not the end marker.
  const fatal = end?.failed ? (failures[failures.length - 1] ?? end) : undefined;

  return {
    runId: first?.runId ?? '',
    ok: end?.detail.ok === true,
    durationMs,
    actions: count(events, 'act'),
    observations: count(events, 'observe'),
    asserts: count(events, 'assert'),
    modelCalls: count(events, 'model'),
    inputTokens: sum(events, 'model', 'inputTokens'),
    outputTokens: sum(events, 'model', 'outputTokens'),
    recoveries: Math.max(
      0,
      ...events
        .filter((e) => e.kind === 'recover' && e.path !== 'repair')
        .map((e) => num(e.detail.recoveries)),
    ),
    repairs: events.filter((e) => e.kind === 'recover' && e.path === 'repair').length,
    approvals: count(events, 'approve'),
    failures: failures.length,
    ...(fatal ? { failedAt: { seq: fatal.seq, kind: fatal.kind, detail: fatal.detail } } : {}),
  };
}

/** Read a trace back off disk. Malformed lines are skipped, not fatal. */
export function readTrace(file: string): TraceEvent[] {
  return readFileSync(file, 'utf8')
    .split('\n')
    .filter((l) => l.trim())
    .flatMap((line) => {
      try {
        return [JSON.parse(line) as TraceEvent];
      } catch {
        // A run killed mid-write leaves a torn last line. Everything before it
        // is still the record of why it was killed.
        return [];
      }
    });
}

function count(events: readonly TraceEvent[], kind: TraceEvent['kind']): number {
  return events.filter((e) => e.kind === kind).length;
}

function sum(events: readonly TraceEvent[], kind: TraceEvent['kind'], field: string): number {
  return events.filter((e) => e.kind === kind).reduce((a, e) => a + num(e.detail[field]), 0);
}

function num(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}
