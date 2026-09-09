#!/usr/bin/env tsx
/**
 * Nubi CLI — the Brain entry point.
 * Hands is imported in-process; there is no HTTP layer between them.
 * See docs/architecture.md.
 */
import { fileURLToPath } from 'node:url';
import { ClaudePlanner } from '../src/brain/index.js';
import { FakeHands, estimateTokens } from '../src/hands/index.js';
import { WdaHands } from '../src/hands/wda.js';
import { ClaudeRepairer, MacroStore, matchMacro } from '../src/macro/index.js';
import { run as runRequest } from '../src/run.js';
import { hasApiKey, loadEnv } from '../src/shared/env.js';

const SCENARIO = fileURLToPath(
  new URL('../src/hands/fixtures/music.scenario.json', import.meta.url),
);
const MACRO_DIR = fileURLToPath(new URL('../macros/', import.meta.url));

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

/**
 * The macro library, as a table.
 *
 * These files are the actual output of the project — a route found once and
 * kept — so being able to see what has accumulated, what is failing, and when
 * something last healed matters more than it sounds.
 */
function macros(sub: string | undefined): void {
  const store = new MacroStore(MACRO_DIR);
  const all = store.all().sort((a, b) => a.id.localeCompare(b.id));

  if (all.length === 0) {
    console.log('아직 매크로가 없습니다.');
    return;
  }

  if (sub && sub !== 'list') {
    const macro = all.find((m) => m.id === sub);
    if (!macro) {
      console.log(`매크로 "${sub}" 없음`);
      process.exitCode = 1;
      return;
    }
    console.log(JSON.stringify(macro, null, 2));
    return;
  }

  const demoted = new Set(store.demoted().map((m) => m.id));
  const rows = all.map((m) => {
    const { runs, fails, avgMs, healedAt } = m.stats;
    return [
      m.id,
      m.risk === 'safe' ? '' : m.risk,
      String(runs),
      String(fails),
      avgMs > 0 ? `${(avgMs / 1000).toFixed(1)}s` : '—',
      healedAt ? healedAt.slice(0, 10) : '—',
      demoted.has(m.id) ? '강등' : '',
    ];
  });

  const head = ['id', 'risk', '실행', '실패', '평균', '마지막 치유', ''];
  const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => (r[i] ?? '').length)));
  const line = (cells: string[]) =>
    cells
      .map((c, i) => c.padEnd(w[i] ?? 0))
      .join('  ')
      .trimEnd();

  console.log(line(head));
  console.log(
    w
      .map((n) => '─'.repeat(n))
      .join('  ')
      .trimEnd(),
  );
  for (const r of rows) console.log(line(r));

  if (all.every((m) => m.stats.runs === 0)) {
    // Deliberate: eval is measurement, not use. A benchmark of fifty
    // iterations would dominate the history, and eval runs deliberately broken
    // macros. Stats are written by the routing path, which does not exist yet.
    console.log('\n실행 통계는 라우팅을 통한 실사용에서만 쌓입니다.');
    console.log('eval 은 측정이지 사용이 아니라서 통계를 남기지 않습니다.');
  }

  if (demoted.size > 0) {
    console.log(`\n강등된 ${demoted.size}개는 라우팅에서 빠집니다. 지워지지는 않습니다 —`);
    console.log('스텝은 여전히 가장 좋은 출발점이고, 복구가 되살릴 수 있습니다.');
  }
}

/**
 * One request against a real device.
 *
 * Saved route → replay. No saved route → explore, and keep what it found.
 */
async function request(args: string[]): Promise<void> {
  loadEnv();
  const utterance = args.find((a) => !a.startsWith('--'));
  const appAt = args.indexOf('--app');
  const app = appAt === -1 ? undefined : args[appAt + 1];

  if (!utterance) {
    console.log('사용법: nubi run "<시킬 일>" --app <bundleId>');
    console.log('  --app 은 저장된 경로가 없을 때 탐색할 앱입니다.');
    process.exitCode = 1;
    return;
  }

  const store = new MacroStore(MACRO_DIR);
  // Only exploration needs a model, and only exploration needs to be told
  // which app: a saved route carries its own. Asked through the same matcher
  // the run uses — comparing against the trigger as a string misses every
  // macro with a parameter, since `{arg1}` never equals what anyone said.
  const known = matchMacro(utterance, store.all()) !== undefined;
  if (!known && !app) {
    console.log('저장된 경로가 없습니다. 탐색할 앱을 --app 으로 알려주세요.');
    process.exitCode = 1;
    return;
  }
  if (!known && !hasApiKey()) {
    console.log('저장된 경로가 없어 탐색이 필요한데 ANTHROPIC_API_KEY 가 없습니다.');
    process.exitCode = 1;
    return;
  }

  const hands = new WdaHands({ bundleId: app ?? 'com.apple.Preferences' });
  const health = await hands.health();
  if (!health.ready) {
    console.log(`에이전트 준비 안 됨: ${health.detail ?? ''}`);
    console.log('  npm run wda 로 띄우세요.');
    process.exitCode = 1;
    return;
  }

  console.log(`\n> ${utterance}\n`);
  const outcome = await runRequest(utterance, {
    hands,
    store,
    planner: new ClaudePlanner(),
    repairer: new ClaudeRepairer(),
    app: app ?? 'com.apple.Preferences',
  });
  await hands.close();

  const cost = `$${outcome.usd.toFixed(4)}`;
  if (outcome.kind === 'replayed') {
    console.log(`${outcome.ok ? '✓' : '✗'} 재생  ${outcome.macroId}`);
    console.log(
      `  ${outcome.ms}ms  ${cost}${outcome.repairs ? `  복구 ${outcome.repairs}회` : ''}`,
    );
  } else {
    console.log(`${outcome.ok ? '✓' : '✗'} 탐색  ${outcome.ms}ms  ${cost}`);
    if (outcome.saved) {
      console.log(`  경로를 "${outcome.saved}" 로 저장했습니다 — 다음부터는 모델 없이 재생합니다.`);
    } else if (outcome.why) {
      console.log(`  저장 안 함: ${outcome.why}`);
    }
  }
  if (!outcome.ok) process.exitCode = 1;
}

async function main(): Promise<void> {
  const [, , command, sub] = process.argv;
  switch (command) {
    case 'demo':
      await demo();
      return;
    case 'run':
      await request(process.argv.slice(3));
      return;
    case 'macros':
      macros(sub);
      return;
    case undefined:
      console.log('nubi');
      console.log('  nubi run "<시킬 일>"  경로가 있으면 재생, 없으면 탐색하고 저장');
      console.log('  nubi demo          기기 없이 녹화된 경로를 재생합니다');
      console.log('  nubi macros        매크로 라이브러리와 통계');
      console.log('  nubi macros <id>   매크로 하나를 그대로 출력');
      console.log('\n설계: docs/README.md   진행 기록: docs/journal/');
      return;
    default:
      console.log(`nubi: 알 수 없는 명령 "${command}"`);
      process.exitCode = 1;
  }
}

await main();
