#!/usr/bin/env tsx
/**
 * Record a scenario by walking a real app.
 *
 * Fixtures written by hand describe an imagined phone. These come off a device:
 * every screen is a real WDA dump, and the transitions between them are the
 * ones that actually fired. `FakeHands` replays the result, so the fake stays
 * honest as the app it mimics changes.
 *
 *   scripts/wda.sh &
 *   npm run record -- settings
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { WdaHands } from '../src/hands/wda.js';
import type { Selector } from '../src/shared/types.js';

interface Move {
  /** Proposed name for the screen reached by this move. */
  screen: string;
  tap?: Selector;
  type?: string;
  back?: true;
}

interface Recipe {
  bundleId: string;
  start: string;
  moves: Move[];
}

/**
 * Settings is a good first recording: reverse-DNS identifiers on every row, a
 * list-to-detail transition, and a back gesture — the shape most macros have.
 */
const RECIPES: Record<string, Recipe> = {
  settings: {
    bundleId: 'com.apple.Preferences',
    start: 'root',
    // Every route a macro in macros/ takes, walked end to end. A route left
    // out is not a gap the eval reports as missing — the fake just fails to
    // move, and the task reads 0/5, indistinguishable from a broken macro.
    moves: [
      { screen: 'accessibility', tap: { id: 'com.apple.settings.accessibility' } },
      { screen: 'root-back', back: true },
      { screen: 'general', tap: { id: 'com.apple.settings.general' } },
      { screen: 'about', tap: { id: 'About', type: 'Button' } },
      { screen: 'general-back', back: true },
      { screen: 'root-back-2', back: true },
      { screen: 'search-focused', tap: { type: 'SearchField', label: '검색' } },
      { screen: 'search-results', type: '손쉬운' },
    ],
  },
};

const name = process.argv[2] ?? 'settings';
const recipe = RECIPES[name];
if (!recipe) {
  console.error(`unknown recipe "${name}" — have: ${Object.keys(RECIPES).join(', ')}`);
  process.exit(1);
}

const outDir = fileURLToPath(new URL(`../src/hands/fixtures/${name}/`, import.meta.url));
mkdirSync(outDir, { recursive: true });

const hands = new WdaHands({ bundleId: recipe.bundleId });
const transitions: Record<string, unknown>[] = [];
const screens: Record<string, string> = {};
/**
 * Screens already written, by hash.
 *
 * Coming back from a detail view lands on the screen you left, not a new one.
 * Recorded under a fresh name each time, the fake ends up with a `root`, a
 * `root-back` and a `root-back-2` that no transition leaves from — so a macro
 * that launches the app and taps lands on `root` and cannot move. Folding them
 * together turns the recording from a walk into the graph it always was.
 *
 * It only folds the exact repeats. Settings comes back scrolled a row further
 * than it started, so the second `root` really does carry one control the
 * first did not — see the note on tap transitions below for what covers that.
 */
const byHash = new Map<string, string>();

/**
 * Save the raw tree, not the compacted one — compaction is what we test.
 * Written in WDA's own envelope so a recording is indistinguishable from a
 * dump taken by hand with curl.
 */
async function capture(proposed: string): Promise<{ name: string; hash: string }> {
  const raw = await hands.rawSource();
  const compacted = await hands.screen();
  const seen = byHash.get(compacted.hash);
  if (seen !== undefined) {
    console.log(`  ${proposed.padEnd(16)} = ${seen}`);
    return { name: seen, hash: compacted.hash };
  }
  // Indented, with the trailing newline the formatter wants: a recording that
  // came out minified left `biome check` failing until someone rewrote it.
  writeFileSync(`${outDir}${proposed}.json`, `${JSON.stringify({ value: raw }, null, 2)}\n`);
  screens[proposed] = `./${proposed}.json`;
  byHash.set(compacted.hash, proposed);
  console.log(
    `  ${proposed.padEnd(16)} ${String(compacted.elements.length).padStart(3)} elements  ` +
      `${compacted.hash}${compacted.keyboard ? '  +키보드' : ''}`,
  );
  return { name: proposed, hash: compacted.hash };
}

console.log(`recording ${name} (${recipe.bundleId})\n`);
await hands.launch({ bundleId: recipe.bundleId, restart: true });
await new Promise((r) => setTimeout(r, 1500));

const first = await capture(recipe.start);
let current = first.name;
let hash = first.hash;

for (const move of recipe.moves) {
  const result = move.back
    ? await hands.back()
    : move.type !== undefined
      ? await hands.type(move.type)
      : await hands.tap(move.tap as Selector);
  if (!result.ok) {
    console.error(`  ✗ move to ${move.screen} failed: ${result.reason}`);
    process.exit(1);
  }
  await new Promise((r) => setTimeout(r, 800));

  const next = await capture(move.screen);
  const nextHash = next.hash;
  if (nextHash === hash) {
    // A move that changes nothing would record a transition the fake could
    // never distinguish from doing nothing at all.
    console.error(`  ✗ ${move.screen} looks identical to ${current} — nothing moved`);
    process.exit(1);
  }

  /**
   * Taps are recorded from any screen, back and type from the one they ran on.
   *
   * The two `root` captures differ by a single row that a returning scroll
   * brings into view, so pinning a tap to the exact capture it was recorded on
   * means a macro that launches and taps has no edge to follow. Nothing is
   * lost by widening it: the fake resolves the selector against the screen it
   * is actually on and refuses the tap when the control is not there, so the
   * `from` was only ever a second lock on the same door. Back and typing stay
   * pinned — where they land depends entirely on where they started.
   */
  const key = move.back
    ? { from: current, back: true }
    : move.type !== undefined
      ? { from: current, type: true as const }
      : {
          from: '*',
          tap:
            (move.tap as { id?: string; label?: string }).id ??
            (move.tap as { label?: string }).label,
        };
  const edge: Record<string, unknown> = { ...key, to: next.name };
  const clash = transitions.find(
    (t) => t.from === edge.from && t.tap !== undefined && t.tap === edge.tap && t.to !== edge.to,
  );
  if (clash) {
    // Two screens where the same control leads somewhere different: the widened
    // `from` cannot tell them apart, and the fake would pick one at random.
    console.error(`  ✗ "${edge.tap}" already goes to ${clash.to}, now ${edge.to}`);
    process.exit(1);
  }
  if (!transitions.some((t) => JSON.stringify(t) === JSON.stringify(edge))) {
    transitions.push(edge);
  }
  current = next.name;
  hash = nextHash;
}

const scenario = {
  app: recipe.bundleId,
  start: recipe.start,
  launch: { [recipe.bundleId]: recipe.start },
  screens,
  transitions,
};
writeFileSync(`${outDir}${name}.scenario.json`, `${JSON.stringify(scenario, null, 2)}\n`);

await hands.close();
console.log(`\nwrote ${Object.keys(screens).length} screens and ${transitions.length} transitions`);
console.log(`  ${outDir}${name}.scenario.json`);
