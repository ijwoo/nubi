#!/usr/bin/env tsx
/**
 * Smoke-test WdaHands against a running WebDriverAgent.
 *
 * Kept out of `npm test` on purpose: it needs a simulator and an agent, so it
 * cannot run in CI. What CI covers is the pure logic — compaction, selector
 * resolution, the fake backend. What only a live agent can tell us is whether
 * the HTTP surface and the session lifecycle behave as assumed.
 *
 *   scripts/wda.sh &        # in another shell
 *   npm run live
 */
import { estimateTokens } from '../src/hands/index.js';
import { WdaHands } from '../src/hands/wda.js';

let failures = 0;
function check(label: string, ok: boolean, detail = ''): void {
  console.log(
    `${ok ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m'} ${label}${detail ? `  ${detail}` : ''}`,
  );
  if (!ok) failures += 1;
}

const BUNDLE = process.env.NUBI_BUNDLE_ID ?? 'com.apple.Preferences';
const hands = new WdaHands({ bundleId: BUNDLE });

console.log(`\nWdaHands live check — ${BUNDLE}\n`);

const health = await hands.health();
check('agent is ready', health.ready, health.detail ?? '');
if (!health.ready) {
  console.error('\nStart the agent first: scripts/wda.sh');
  process.exit(1);
}

const screen = await hands.screen();
const tokens = estimateTokens(screen.elements);
check('reports the foreground app', screen.app === BUNDLE, screen.app);
check('returns elements', screen.elements.length > 0, `${screen.elements.length}`);
check(
  'every element is addressable',
  screen.elements.every((e) => e.l ?? e.v ?? e.id),
);
check('stays inside the observation budget', tokens < 800, `${tokens} tokens`);
check('produces a screen hash', /^[0-9a-f]{12}$/.test(screen.hash), screen.hash);
check(
  'reads screen size',
  screen.size.w > 0 && screen.size.h > 0,
  `${screen.size.w}x${screen.size.h}`,
);

// Session recovery, the claim ADR 0005 makes: a dropped session is rebuilt
// underneath the caller, who sees an ordinary successful call.
const before = hands.activeSessionId;
check('opened a session', before !== undefined, before?.slice(0, 8) ?? '');
await fetch(`http://127.0.0.1:8100/session/${before}`, { method: 'DELETE' });
console.log('  … ended that session from outside the client');

const after = await hands.screen();
const recovered = await hands.health();
check('recovers transparently', after.elements.length > 0, `${after.elements.length} elements`);
check(
  'opened a replacement session',
  hands.activeSessionId !== before,
  `${before?.slice(0, 8)} → ${hands.activeSessionId?.slice(0, 8)}`,
);
check('counts the recovery', recovered.recoveries === 1, `recoveries=${recovered.recoveries}`);

await hands.close();
check('releases the session', hands.activeSessionId === undefined);

console.log(
  failures === 0 ? '\n\x1b[32mall checks passed\x1b[0m\n' : `\n\x1b[31m${failures} failed\x1b[0m\n`,
);
process.exit(failures === 0 ? 0 : 1);
