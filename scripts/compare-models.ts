#!/usr/bin/env tsx
/**
 * Compare explore runs across model tiers.
 *
 * The eval table says what each tier cost. It does not say whether a cheaper
 * tier bought the same behaviour — two models can both reach the goal while
 * one wanders and the other walks straight there, and only the route says
 * which. [ADR 0006](../docs/adr/0006-model-tiering.md) picks a tier for
 * planning; this is what would justify or overturn it.
 *
 *   npm run compare -- traces-claude-opus-5 traces-claude-sonnet-5
 */
import { readFileSync, readdirSync } from 'node:fs';
import type { TraceEvent } from '../src/shared/types.js';
import { costOf } from '../src/trace/cost.js';

interface Run {
  task: string;
  model: string;
  ok: boolean;
  ms: number;
  calls: number;
  usd: number;
  tokens: number;
  /** One entry per planned action, in order. */
  route: string[];
}

function loadDir(dir: string): Run[] {
  const runs: Run[] = [];
  for (const file of readdirSync(dir).filter((f) => f.endsWith('.jsonl'))) {
    const events = readFileSync(`${dir}/${file}`, 'utf8')
      .split('\n')
      .filter(Boolean)
      .map((l) => JSON.parse(l) as TraceEvent);
    const setup = events.find((e) => e.detail.op === 'setup');
    if (setup?.detail.executor !== 'explore') continue;

    const end = events.find((e) => e.kind === 'end');
    // The decision, not the action it produced: `done` and `stuck` never reach
    // the device, and a run that gave up looks identical to one that finished
    // if you only count taps.
    const decisions = events.filter((e) => e.kind === 'observe' && e.detail.action !== undefined);
    const models = events.filter((e) => e.kind === 'model');
    runs.push({
      task: String(setup.detail.task),
      model: String(models[0]?.detail.model ?? 'unknown'),
      ok: end?.detail.ok === true,
      // The end event is already timed from `beginAttempt`, so setup is out.
      // Summing every event instead double-counts: an observe sits inside an
      // act, and a model call inside the step that made it.
      ms: end?.durationMs ?? 0,
      calls: models.length,
      usd: costOf(events).usd,
      tokens: models.reduce(
        (a, e) => a + Number(e.detail.inputTokens ?? 0) + Number(e.detail.outputTokens ?? 0),
        0,
      ),
      route: decisions.map((e) => String(e.detail.action)),
    });
  }
  return runs;
}

const dirs = process.argv.slice(2);
if (dirs.length < 2) {
  console.error('usage: npm run compare -- <traceDir> <traceDir> [...]');
  process.exit(1);
}

const byDir = new Map(dirs.map((d) => [d, loadDir(d)]));
const tasks = [...new Set([...byDir.values()].flat().map((r) => r.task))].sort();

const pad = (s: string, n: number) => s.padEnd(n);
const rpad = (s: string, n: number) => s.padStart(n);

for (const task of tasks) {
  console.log(`\n${task}`);
  console.log(
    `  ${pad('model', 20)} ${rpad('ok', 5)} ${rpad('ms', 8)} ${rpad('calls', 6)} ` +
      `${rpad('tok', 7)} ${rpad('$/run', 9)}  route`,
  );
  for (const dir of dirs) {
    const runs = (byDir.get(dir) ?? []).filter((r) => r.task === task);
    if (runs.length === 0) continue;
    const ok = runs.filter((r) => r.ok).length;
    const ms = Math.round(runs.reduce((a, r) => a + r.ms, 0) / runs.length);
    const calls = runs.reduce((a, r) => a + r.calls, 0) / runs.length;
    // Distinct routes, so a tier that sometimes wanders is visible as more
    // than one shape rather than averaged into a tidy number.
    const shapes = [...new Set(runs.map((r) => r.route.join(' → ')))];
    const usd = runs.reduce((a, r) => a + r.usd, 0) / runs.length;
    const tok = Math.round(runs.reduce((a, r) => a + r.tokens, 0) / runs.length);
    console.log(
      `  ${pad(runs[0]?.model ?? '?', 20)} ${rpad(`${ok}/${runs.length}`, 5)} ${rpad(`${ms}`, 8)} ` +
        `${rpad(calls.toFixed(1), 6)} ${rpad(`${tok}`, 7)} ${rpad(`$${usd.toFixed(4)}`, 9)}  ` +
        `${shapes[0] ?? '—'}`,
    );
    for (const extra of shapes.slice(1)) console.log(`  ${' '.repeat(60)}${extra}`);
  }
}
console.log();
