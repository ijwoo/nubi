import type { Hands } from '../hands/types.js';
import { type RunSummary, Trace, summarize, traced } from '../trace/index.js';
import type { Executor } from './executor.js';
import type { Task } from './task.js';

/**
 * Run a task N times and report what each attempt cost.
 *
 * The runner owns three things the executor must not: putting the device in a
 * known state, timing the attempt, and deciding whether it worked. An executor
 * that graded itself would be reporting its own opinion, and one that skipped
 * setup would let run 2 inherit whatever run 1 left behind — the second run
 * would look faster for a reason that has nothing to do with the approach.
 */
export interface RunOptions {
  hands: Hands;
  task: Task;
  executor: Executor;
  /** Overrides the task's own count, for a quick pass. */
  runs?: number;
  /** Where to write traces. Omit to keep them in memory. */
  traceDir?: string;
}

export interface TaskResult {
  taskId: string;
  executor: string;
  runs: AttemptResult[];
}

export interface AttemptResult extends RunSummary {
  /** The task's assertion, checked against the device after the attempt. */
  asserted: boolean;
  /** What the executor claimed. Disagreement with `asserted` is worth seeing. */
  claimed: boolean;
}

export async function runTask(opts: RunOptions): Promise<TaskResult> {
  const { hands, task, executor } = opts;
  const total = opts.runs ?? task.runs;
  const runs: AttemptResult[] = [];

  for (let i = 0; i < total; i++) {
    const trace = Trace.start(opts.traceDir ? { dir: opts.traceDir } : {});
    trace.event('observe', 'route', {
      op: 'setup',
      task: task.id,
      executor: executor.name,
      attempt: i,
    });

    await hands.launch({ bundleId: task.setup.bundleId, restart: task.setup.restart });
    if (task.setup.settleMs > 0) {
      await new Promise((done) => setTimeout(done, task.setup.settleMs));
    }

    // Setup is recorded but not measured: relaunching to a known state is work
    // every approach pays equally and none of them chose. Leaving it inside the
    // duration inflated a live run by roughly a third.
    trace.beginAttempt();
    const watched = traced(hands, trace, () =>
      executor.name === 'scripted' ? 'replay' : 'explore',
    );

    let claimed = false;
    try {
      claimed = await executor.run(watched, task, trace);
    } catch (err) {
      trace.event(
        'error',
        'route',
        { error: err instanceof Error ? err.message : String(err) },
        0,
        true,
      );
    }

    const check = await hands.assert(task.assert.selector, task.assert.withinMs);
    trace.event(
      'assert',
      'route',
      { op: 'task-assert', ok: check.ok, waitedMs: check.waitedMs },
      check.waitedMs,
      !check.ok,
    );
    trace.end(check.ok, { task: task.id, executor: executor.name, claimed });

    runs.push({ ...summarize(trace.events), asserted: check.ok, claimed });
  }

  return { taskId: task.id, executor: executor.name, runs };
}

/** Aggregate across attempts. */
export interface Aggregate {
  taskId: string;
  executor: string;
  attempts: number;
  successes: number;
  successRate: number;
  /** p50 and p95 together: an average hides the run that occasionally takes a minute. */
  p50Ms: number;
  p95Ms: number;
  avgActions: number;
  avgObservations: number;
  avgModelCalls: number;
  avgInputTokens: number;
  avgOutputTokens: number;
  recoveries: number;
  /** Attempts where the executor claimed success but the assertion disagreed. */
  falseClaims: number;
}

export function aggregate(result: TaskResult): Aggregate {
  const { runs } = result;
  const durations = runs.map((r) => r.durationMs).sort((a, b) => a - b);
  const successes = runs.filter((r) => r.asserted).length;

  return {
    taskId: result.taskId,
    executor: result.executor,
    attempts: runs.length,
    successes,
    successRate: runs.length === 0 ? 0 : successes / runs.length,
    p50Ms: percentile(durations, 0.5),
    p95Ms: percentile(durations, 0.95),
    avgActions: mean(runs.map((r) => r.actions)),
    avgObservations: mean(runs.map((r) => r.observations)),
    avgModelCalls: mean(runs.map((r) => r.modelCalls)),
    avgInputTokens: mean(runs.map((r) => r.inputTokens)),
    avgOutputTokens: mean(runs.map((r) => r.outputTokens)),
    recoveries: runs.reduce((a, r) => a + r.recoveries, 0),
    falseClaims: runs.filter((r) => r.claimed && !r.asserted).length,
  };
}

/** Nearest-rank, so a small sample reports a value that actually occurred. */
function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const rank = Math.ceil(p * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))] ?? 0;
}

function mean(xs: number[]): number {
  return xs.length === 0 ? 0 : Math.round((xs.reduce((a, b) => a + b, 0) / xs.length) * 10) / 10;
}
