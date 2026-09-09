#!/usr/bin/env tsx
/**
 * Nubi CLI — the Brain entry point.
 * Hands is imported in-process; there is no HTTP layer between them.
 * See docs/architecture.md.
 */
import { fileURLToPath } from 'node:url';
import { FakeHands, estimateTokens } from '../src/hands/index.js';
import { MacroStore } from '../src/macro/index.js';

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

async function main(): Promise<void> {
  const [, , command, sub] = process.argv;
  switch (command) {
    case 'demo':
      await demo();
      return;
    case 'macros':
      macros(sub);
      return;
    case undefined:
      console.log('nubi');
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
