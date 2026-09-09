import { readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { type Macro, MacroSchema, isDemoted } from '../shared/types.js';

/**
 * The macro library on disk.
 *
 * Macros are the actual output of this project — a route found once and kept —
 * so they live as committed JSON rather than in a database. The git history of
 * this directory is a record of how the apps underneath changed: every repair
 * shows up as a diff.
 *
 * Reading is eager. The library is small enough that scanning it costs nothing
 * measurable, and routing has to see every macro anyway.
 */
export class MacroStore {
  private readonly cache = new Map<string, Macro>();

  constructor(private readonly dir: string) {}

  /** Every macro in the directory. A malformed file is loud, not skipped. */
  all(): Macro[] {
    for (const file of readdirSync(this.dir).filter((f) => f.endsWith('.json'))) {
      const id = file.replace(/\.json$/, '');
      if (!this.cache.has(id)) this.cache.set(id, this.read(id));
    }
    return [...this.cache.values()];
  }

  get(id: string): Macro {
    const cached = this.cache.get(id);
    if (cached) return cached;
    const macro = this.read(id);
    this.cache.set(id, macro);
    return macro;
  }

  has(id: string): boolean {
    try {
      this.get(id);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Macros routing should still trust.
   *
   * A macro that fails often is worse than no macro: it wastes a run before
   * falling back to exploring, every time. Demotion takes it out of routing
   * without deleting it — the steps are still the best starting point anyone
   * has, and a repair may bring it back.
   */
  routable(): Macro[] {
    return this.all().filter((m) => !isDemoted(m));
  }

  demoted(): Macro[] {
    return this.all().filter(isDemoted);
  }

  /**
   * Write a macro, replacing any earlier version.
   *
   * Written through a temporary file and renamed into place: a run interrupted
   * mid-write would otherwise leave a truncated macro, and the next run would
   * fail to parse a route that was working an hour ago.
   */
  save(macro: Macro): void {
    const validated = MacroSchema.parse(macro);
    const target = join(this.dir, `${validated.id}.json`);
    const temp = `${target}.tmp`;
    writeFileSync(temp, `${JSON.stringify(validated, null, 2)}\n`);
    renameSync(temp, target);
    this.cache.set(validated.id, validated);
  }

  /**
   * Record how a run went.
   *
   * The running average is kept over successful runs only. A failure's
   * duration says how long it took to give up, which is a different quantity
   * and would drag the estimate somewhere that describes neither.
   */
  recordRun(id: string, outcome: { ok: boolean; durationMs: number }): Macro {
    const macro = this.get(id);
    const runs = macro.stats.runs + 1;
    const fails = macro.stats.fails + (outcome.ok ? 0 : 1);
    const successes = runs - fails;

    const avgMs = outcome.ok
      ? Math.round((macro.stats.avgMs * (successes - 1) + outcome.durationMs) / successes)
      : macro.stats.avgMs;

    const updated: Macro = {
      ...macro,
      stats: { ...macro.stats, runs, fails, avgMs, lastRun: new Date().toISOString() },
    };
    this.save(updated);
    return updated;
  }

  /**
   * Replace a step's selector after a repair, keeping the old one as `alt`.
   *
   * The previous selector is not discarded: a rolled-back release or an A/B
   * bucket puts the old screen back, and `alt` catches it. It is also how a
   * bad repair announces itself — a macro that keeps succeeding through `alt`
   * is telling you the replacement was wrong.
   */
  patchSelector(id: string, stepIndex: number, replacement: Macro['steps'][number]): Macro {
    const macro = this.get(id);
    const step = macro.steps[stepIndex];
    if (!step) throw new Error(`macro ${id} has no step ${stepIndex}`);

    const steps = [...macro.steps];
    steps[stepIndex] = replacement;

    const updated: Macro = {
      ...macro,
      version: macro.version + 1,
      steps,
      stats: { ...macro.stats, healedAt: new Date().toISOString() },
    };
    this.save(updated);
    return updated;
  }

  private read(id: string): Macro {
    const raw = readFileSync(join(this.dir, `${id}.json`), 'utf8');
    return MacroSchema.parse(JSON.parse(raw));
  }
}
