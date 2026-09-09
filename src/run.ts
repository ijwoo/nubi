import { ExploreExecutor } from './brain/explore.js';
import type { Planner } from './brain/planner.js';
import type { Task } from './eval/task.js';
import type { Hands } from './hands/types.js';
import { deriveAssertion, extractMacro } from './macro/extract.js';
import { matchMacro } from './macro/match.js';
import type { Repairer } from './macro/repair.js';
import { ReplayExecutor } from './macro/replay.js';
import type { MacroStore } from './macro/store.js';
import { isDemoted } from './shared/types.js';
import { costOf } from './trace/cost.js';
import { Trace, traced } from './trace/index.js';

/**
 * One request, start to finish.
 *
 * This is the loop the project is about, and until now its two halves ran only
 * from the eval harness: exploration found routes that were measured and
 * thrown away, and replay ran macros written by hand. Nothing called
 * `extractMacro`, so "한 번 찾고, 계속 재생한다" was two working halves and a
 * gap between them.
 *
 * A request either matches a saved route or it does not. Matching means
 * replay, with repair for the step that no longer resolves. Not matching means
 * exploration, and — if it worked and can prove it worked — a macro saved
 * under what was asked, so the next identical request takes the fast path.
 */

export interface RunOptions {
  hands: Hands;
  store: MacroStore;
  planner: Planner;
  repairer: Repairer;
  /** The app to explore in when nothing matches. */
  app: string;
  /** Skip saving a newly found route. */
  noSave?: boolean;
}

export type RunOutcome =
  | { kind: 'replayed'; macroId: string; ok: boolean; repairs: number; usd: number; ms: number }
  | { kind: 'explored'; ok: boolean; saved?: string; why?: string; usd: number; ms: number };

export async function run(utterance: string, opts: RunOptions): Promise<RunOutcome> {
  const trace = Trace.start();
  const watched = traced(opts.hands, trace, () => 'route');

  // Demoted macros are excluded rather than deleted: a route that fails a
  // third of the time costs a run before exploration takes over anyway.
  const routable = opts.store.all().filter((m) => !isDemoted(m));
  const match = matchMacro(utterance, routable);

  trace.beginAttempt();

  if (match) {
    const executor = new ReplayExecutor({
      macro: match.macro,
      store: opts.store,
      repairer: opts.repairer,
    });
    const ok = await executor.run(watched, taskFor(utterance, match.macro.app), trace);
    trace.end(ok, { macro: match.macro.id });
    return {
      kind: 'replayed',
      macroId: match.macro.id,
      ok,
      repairs: executor.repairs,
      usd: costOf(trace.events).usd,
      ms: elapsed(trace),
    };
  }

  const explorer = new ExploreExecutor({ planner: opts.planner });
  const ok = await explorer.run(watched, taskFor(utterance, opts.app), trace);
  const usd = () => costOf(trace.events).usd;

  if (!ok) {
    trace.end(false, { goal: utterance });
    return { kind: 'explored', ok: false, why: '경로를 찾지 못함', usd: usd(), ms: elapsed(trace) };
  }

  if (opts.noSave) {
    trace.end(true, { goal: utterance });
    return { kind: 'explored', ok: true, usd: usd(), ms: elapsed(trace) };
  }

  const first = explorer.firstScreen;
  const last = explorer.finalScreen;
  // The control the route last tapped is the best hint available for which of
  // the new elements actually names the destination.
  const lastTap = [...explorer.route].reverse().find((r) => r.selector !== undefined)?.selector;
  // Whatever the run typed is what varies between runs, so nothing echoing it
  // can serve as the check.
  const typed = explorer.route
    .map((r) => (r.action.kind === 'type' ? r.action.text : undefined))
    .filter((t): t is string => t !== undefined);
  const assertion =
    first && last
      ? deriveAssertion({
          start: first,
          final: last,
          ...(explorer.screenBeforeLastAction === undefined
            ? {}
            : { beforeLastAction: explorer.screenBeforeLastAction }),
          ...(lastTap === undefined ? {} : { arrivedVia: lastTap }),
          typed,
        })
      : undefined;
  if (!assertion) {
    // The run worked; what it cannot do is prove it worked on the next
    // machine, next week. Saving anyway would produce a macro that passes for
    // having pressed buttons.
    trace.end(true, { goal: utterance });
    return {
      kind: 'explored',
      ok: true,
      why: '끝난 화면이 시작 화면과 구별되지 않아 검증 기준을 못 만듦',
      usd: usd(),
      ms: elapsed(trace),
    };
  }

  const macro = extractMacro(explorer.route, {
    id: idFor(utterance, (id) => opts.store.has(id)),
    goal: utterance,
    app: opts.app,
    assert: { selector: assertion },
  });
  opts.store.save(macro);
  trace.end(true, { goal: utterance, saved: macro.id });
  return { kind: 'explored', ok: true, saved: macro.id, usd: usd(), ms: elapsed(trace) };
}

/**
 * Explore and replay both take a `Task`, which the eval harness reads from a
 * file. A request has no file, and only the prompt and the app are ever read
 * off it here — the assertion in a real run is the macro's own.
 */
function taskFor(utterance: string, app: string): Task {
  return {
    id: 'request',
    prompt: utterance,
    setup: { bundleId: app, restart: true, settleMs: 1200 },
    assert: { selector: { label: utterance }, withinMs: 10_000 },
    runs: 1,
  } as Task;
}

/**
 * A filename from what was asked, kept unique so a second route is not lost.
 *
 * Macro ids are `[a-z0-9-]` because they are filenames and go in URLs, which
 * leaves nothing of a Korean request — and Korean is what this will mostly be
 * asked in. Rather than transliterate, a request that slugifies to nothing
 * becomes `route`, numbered. The trigger keeps the actual words; the id only
 * has to be a name.
 */
export function idFor(utterance: string, taken: (id: string) => boolean): string {
  const base =
    utterance
      .toLowerCase()
      .replace(/[^a-z0-9]+/gu, '-')
      .replace(/^-|-$/gu, '')
      .slice(0, 40) || 'route';
  if (!taken(base)) return base;
  for (let n = 2; ; n++) {
    const candidate = `${base}-${n}`;
    if (!taken(candidate)) return candidate;
  }
}

function elapsed(trace: Trace): number {
  return trace.events.find((e) => e.kind === 'end')?.durationMs ?? 0;
}
