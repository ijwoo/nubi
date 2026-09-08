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
check('no system alert is blocking input', screen.alert === undefined, screen.alert?.text.slice(0, 40) ?? '');
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

// ---- actions -------------------------------------------------------
// Driven against Settings, whose rows carry stable reverse-DNS identifiers.
console.log('\nactions');

const launched = await hands.launch({ bundleId: BUNDLE });
check('launch', launched.ok, launched.ok ? '' : launched.detail ?? launched.reason);

const root = await hands.screen();
const tapped = await hands.tap({ id: 'com.apple.settings.general' });
check('tap resolves and acts', tapped.ok, tapped.ok ? String(tapped.element?.l) : tapped.reason);
check('tap changed the screen', tapped.ok && tapped.screen.hash !== root.hash, tapped.ok ? `${root.hash} → ${tapped.screen.hash}` : '');

const arrived = await hands.assert({ label: '일반', type: 'StaticText' }, 5000);
check('assert waits for the new screen', arrived.ok, `waited ${arrived.waitedMs}ms`);

const back = await hands.back();
check('back returns', back.ok);
const returned = await hands.assert({ id: 'com.apple.settings.general' }, 5000);
check('back landed on the list again', returned.ok, `waited ${returned.waitedMs}ms`);

// Typing goes to whatever holds focus, so the field is tapped first — the same
// two steps a person performs.
const search = await hands.find({ label: '검색', type: 'SearchField' });
if (search.ok) {
  await hands.tap({ label: '검색', type: 'SearchField' });
  const typed = await hands.type('소리');
  check('type into the focused field', typed.ok, typed.ok ? '' : typed.detail ?? typed.reason);
  const echoed = typed.ok && typed.screen.elements.some((e) => e.v === '소리' || e.l === '소리');
  check('typed text appears on screen', echoed);
} else {
  console.log('  … no search field on this screen, skipping type');
}

const failedTap = await hands.tap({ id: 'definitely-not-here' });
check('a missing selector reports no-match with the screen', !failedTap.ok && failedTap.reason === 'no-match' && failedTap.screen.elements.length > 0);

const timedOut = await hands.assert({ id: 'definitely-not-here' }, 600);
check('assert times out rather than hanging', !timedOut.ok && timedOut.reason === 'timeout', `waited ${timedOut.waitedMs}ms`);

await hands.close();
check('releases the session', hands.activeSessionId === undefined);

console.log(
  failures === 0 ? '\n\x1b[32mall checks passed\x1b[0m\n' : `\n\x1b[31m${failures} failed\x1b[0m\n`,
);
process.exit(failures === 0 ? 0 : 1);
