#!/usr/bin/env tsx
/**
 * Nubi CLI — the Brain entry point.
 * Hands is imported in-process; there is no HTTP layer between them.
 * See docs/architecture.md.
 */

async function main(): Promise<void> {
  const [, , ...args] = process.argv;
  if (args.length === 0) {
    console.log('nubi — nothing wired up yet. Phase 01 (Hands) is in progress.');
    console.log('See docs/README.md for the design, docs/journal/ for progress.');
    return;
  }
  console.log(`nubi: unknown command "${args[0]}"`);
  process.exitCode = 1;
}

await main();

export {};
