#!/usr/bin/env tsx
/**
 * Nubi CLI — the Brain entry point.
 * Hands is imported in-process; there is no HTTP layer between them.
 * See docs/architecture.md.
 */
import { fileURLToPath } from 'node:url';
import { FakeHands } from '../src/hands/index.js';
import { estimateTokens } from '../src/hands/index.js';

const SCENARIO = fileURLToPath(
  new URL('../src/hands/fixtures/music.scenario.json', import.meta.url),
);

/**
 * Walk a route against recorded screens. No device, no API key, no network —
 * `npm run nubi -- demo` works on a fresh clone.
 */
async function demo(): Promise<void> {
  const hands = FakeHands.fromScenario(SCENARIO);

  // Labels describe the action, not the content it happens to carry.
  const route = [
    { label: '앱 실행', run: () => hands.launch({ url: 'music://' }) },
    { label: '검색 탭', run: () => hands.tap({ id: 'tab_search' }) },
    { label: '검색어 입력', run: () => hands.type('음악', { submit: true }) },
    { label: '첫 결과 선택', run: () => hands.tap({ label: '트랙 1' }) },
    { label: '재생 확인', run: () => hands.assert({ label: '일시정지' }) },
  ];

  for (const step of route) {
    const before = hands.screenName;
    const r = await step.run();
    const mark = r.ok ? '✓' : '✗';
    console.log(`${mark} ${step.label.padEnd(18)} ${before} -> ${hands.screenName}`);
  }

  const screen = await hands.screen();
  console.log(
    `\n${screen.elements.length} elements, ~${estimateTokens(screen.elements)} tokens, hash ${screen.hash}`,
  );
  for (const e of screen.elements) {
    console.log(`  ${e.t.padEnd(12)} ${e.l ?? ''}${e.e ? '' : '  (disabled)'}`);
  }
}

async function main(): Promise<void> {
  const [, , command] = process.argv;
  switch (command) {
    case 'demo':
      await demo();
      return;
    case undefined:
      console.log('nubi — phase 01 in progress.');
      console.log('  nubi demo    walk a recorded route with no device attached');
      console.log('\nDesign: docs/README.md   Progress: docs/journal/');
      return;
    default:
      console.log(`nubi: unknown command "${command}"`);
      process.exitCode = 1;
  }
}

await main();
