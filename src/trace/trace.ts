import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { ModelUsage, Path, TraceEvent, TraceKind } from '../shared/types.js';

/**
 * A record of one run, written as it happens.
 *
 * Written line by line rather than buffered and flushed at the end: the runs
 * worth reading are the ones that hung or crashed, and those never reach a
 * flush. A partial trace of a wedged run is the whole point.
 *
 * JSONL because the interesting operations are `grep` and "stream the tail
 * while it runs", neither of which a single JSON document supports.
 */
export class Trace {
  readonly runId: string;
  private seq = 0;
  private readonly path: string | undefined;
  private readonly buffer: TraceEvent[] = [];
  private startedAt = Date.now();

  private constructor(runId: string, path: string | undefined) {
    this.runId = runId;
    this.path = path;
  }

  /**
   * Begin a run. Without `dir` the trace is kept in memory only, which is what
   * tests and the eval harness want — thousands of runs should not litter disk.
   */
  static start(opts: { dir?: string; runId?: string } = {}): Trace {
    const runId = opts.runId ?? `run_${Date.now().toString(36)}${randomSuffix()}`;
    let path: string | undefined;
    if (opts.dir) {
      mkdirSync(opts.dir, { recursive: true });
      path = join(opts.dir, `${runId}.jsonl`);
    }
    return new Trace(runId, path);
  }

  event(
    kind: TraceKind,
    path: Path,
    detail: Record<string, unknown> = {},
    durationMs = 0,
    failed = false,
  ): void {
    const ev: TraceEvent = {
      runId: this.runId,
      seq: this.seq++,
      at: new Date().toISOString(),
      path,
      kind,
      durationMs: Math.round(durationMs),
      ...(failed ? { failed: true } : {}),
      detail,
    };
    this.buffer.push(ev);
    if (this.path) appendFileSync(this.path, `${JSON.stringify(ev)}\n`);
  }

  /**
   * Time an operation and record it, whether it returns or throws.
   *
   * A step that threw is exactly the one a reader is looking for, so it is
   * recorded and then re-thrown rather than swallowed.
   */
  async span<T>(
    kind: TraceKind,
    path: Path,
    detail: Record<string, unknown>,
    op: () => Promise<T>,
  ): Promise<T> {
    const started = Date.now();
    try {
      const result = await op();
      this.event(kind, path, detail, Date.now() - started);
      return result;
    } catch (err) {
      this.event(
        kind,
        path,
        { ...detail, error: err instanceof Error ? err.message : String(err) },
        Date.now() - started,
        true,
      );
      throw err;
    }
  }

  /** Record a model call with its usage, so cost is reconstructable per run. */
  model(
    path: Path,
    usage: ModelUsage,
    durationMs: number,
    detail: Record<string, unknown> = {},
  ): void {
    this.event('model', path, { ...detail, ...usage }, durationMs);
  }

  /**
   * Start the clock, discarding whatever came before.
   *
   * Setup belongs in the trace — a run that failed while being prepared is
   * still a run worth reading — but it must not be in the measurement. Without
   * this the reported duration includes relaunching the app to a known state,
   * which is work every approach pays equally and none of them chose.
   */
  beginAttempt(): void {
    this.startedAt = Date.now();
  }

  /** Close the run. `ok` is the outcome, not whether anything went wrong on the way. */
  end(ok: boolean, detail: Record<string, unknown> = {}): void {
    this.event('end', 'route', { ok, ...detail }, Date.now() - this.startedAt, !ok);
  }

  /** Everything recorded so far. */
  get events(): readonly TraceEvent[] {
    return this.buffer;
  }

  /** Where the trace was written, if anywhere. */
  get file(): string | undefined {
    return this.path;
  }
}

function randomSuffix(): string {
  return Math.floor(Math.random() * 0xfffff)
    .toString(36)
    .padStart(4, '0');
}
