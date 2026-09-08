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
  /** Name the screen reached by this move. */
  screen: string;
  tap?: Selector;
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
    moves: [
      { screen: 'general', tap: { id: 'com.apple.settings.general' } },
      { screen: 'root-again', back: true },
      { screen: 'accessibility', tap: { id: 'com.apple.settings.accessibility' } },
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
 * Save the raw tree, not the compacted one — compaction is what we test.
 * Written in WDA's own envelope so a recording is indistinguishable from a
 * dump taken by hand with curl.
 */
async function capture(screenName: string): Promise<string> {
  const raw = await hands.rawSource();
  writeFileSync(`${outDir}${screenName}.json`, JSON.stringify({ value: raw }, null, 0));
  screens[screenName] = `./${screenName}.json`;
  const compacted = await hands.screen();
  console.log(
    `  ${screenName.padEnd(16)} ${compacted.elements.length} elements  ${compacted.hash}`,
  );
  return compacted.hash;
}

console.log(`recording ${name} (${recipe.bundleId})\n`);
await hands.launch({ bundleId: recipe.bundleId, restart: true });
await new Promise((r) => setTimeout(r, 1500));

let current = recipe.start;
let hash = await capture(current);

for (const move of recipe.moves) {
  const result = move.back ? await hands.back() : await hands.tap(move.tap as Selector);
  if (!result.ok) {
    console.error(`  ✗ move to ${move.screen} failed: ${result.reason}`);
    process.exit(1);
  }
  await new Promise((r) => setTimeout(r, 800));

  const nextHash = await capture(move.screen);
  if (nextHash === hash) {
    // A move that changes nothing would record a transition the fake could
    // never distinguish from doing nothing at all.
    console.error(`  ✗ ${move.screen} looks identical to ${current} — nothing moved`);
    process.exit(1);
  }

  const key = move.back
    ? { back: true }
    : {
        tap:
          (move.tap as { id?: string; label?: string }).id ??
          (move.tap as { label?: string }).label,
      };
  transitions.push({ from: current, ...key, to: move.screen });
  current = move.screen;
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
