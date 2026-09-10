#!/usr/bin/env tsx
/**
 * Find exported code that only its own tests ever call.
 *
 * Twice now a piece of this project has been finished, tested, and never
 * connected. `extractMacro` turned routes into macros correctly and nothing
 * called it, so exploration threw away everything it found. `recordRun`
 * maintained the statistics demotion reads and nothing called it, so no macro
 * could ever be demoted.
 *
 * Neither is a coverage gap — both functions were covered. What was uncovered
 * is that anything calls them, which is not the subject of any unit test. This
 * asks that question directly: is there a path from `bin/` or `scripts/` to
 * this export, or does it only exist to be tested?
 *
 * A re-export in an index file does not count as a use — passing that bar is
 * how dead code hides in a library. Being called by its own module does count:
 * the question is whether the code runs in the product, not whether it needed
 * to be exported.
 *
 *   npm run check:wiring
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const DIRS = ['src', 'bin', 'scripts'];

/**
 * Exports that exist for tests, and are supposed to.
 *
 * Each needs a reason. The list being short is the point: it is where a real
 * finding gets waved away, so every entry should be something a reader would
 * agree about without argument.
 */
const EXPECTED_UNUSED = new Map([
  ['ScriptedPlanner', '테스트용 계획자 — 모델 없이 explore 루프를 돌린다'],
  ['ScriptedRepairer', '테스트용 복구자 — 모델 없이 복구 흐름을 돌린다'],
  ['CONTRACT', '두 백엔드에 같은 케이스를 돌리는 계약 목록'],
  ['ScriptedGate', '테스트용 승인 게이트 — 사람 없이 승인 흐름을 돌린다'],
  ['goto', '가짜 백엔드를 특정 화면에 놓는다 — 테스트가 전환을 건너뛸 때 쓴다'],
  ['showAlert', '가짜 백엔드에 시스템 알림을 띄운다 — 실기에서는 재현이 어렵다'],
]);

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...walk(path));
    else if (name.endsWith('.ts')) out.push(path);
  }
  return out;
}

const files = DIRS.flatMap((d) => walk(join(ROOT, d)));
const isTest = (f: string) => f.endsWith('.test.ts');
const isIndex = (f: string) => f.endsWith('/index.ts');

interface Export {
  name: string;
  file: string;
}

const EXPORT_RE = /^export\s+(?:async\s+)?(?:function|class|const)\s+([A-Za-z_$][\w$]*)/gm;

/**
 * Public methods of exported classes, which the pattern above cannot see.
 *
 * Not a completeness flourish. `recordRun` — the method that keeps the
 * statistics demotion reads — is a method, and the first version of this check
 * missed the very case that prompted writing it.
 */
const METHOD_RE = /^ {2}(?:async )?([a-z][\w$]*)\s*(?:<[^>]*>)?\(/gm;
const NOT_A_METHOD = new Set(['if', 'for', 'while', 'switch', 'catch', 'return', 'constructor']);

const exports: Export[] = [];
for (const file of files) {
  if (isTest(file) || isIndex(file)) continue;
  const source = readFileSync(file, 'utf8');
  for (const m of source.matchAll(EXPORT_RE)) {
    const name = m[1];
    if (name !== undefined) exports.push({ name, file });
  }
  if (/^export\s+(?:abstract\s+)?class\s/m.test(source)) {
    for (const m of source.matchAll(METHOD_RE)) {
      const name = m[1];
      if (name !== undefined && !NOT_A_METHOD.has(name)) exports.push({ name, file });
    }
  }
}

/**
 * A name written in prose is not a call.
 *
 * This file explains itself by naming the functions that went unwired, and
 * that alone was enough to report them as reachable — the check documented
 * away its own findings.
 */
function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
}

/** Every file's code, so a name can be counted without parsing imports. */
const text = new Map(files.map((f) => [f, withoutComments(readFileSync(f, 'utf8'))]));

/** Mentions outside the line that declares it, which is the only free one. */
function usesOutsideDeclaration(source: string, name: string): number {
  const word = new RegExp(`\\b${name}\\b`);
  const declares = new RegExp(
    `^(?:export\\s+(?:async\\s+)?(?:function|class|const)\\s+${name}\\b` +
      `| {2}(?:async )?${name}\\s*[(<])`,
  );
  return source.split('\n').filter((line) => word.test(line) && !declares.test(line)).length;
}

const orphans = exports.filter(({ name, file }) => {
  if (EXPECTED_UNUSED.has(name)) return false;
  for (const [other, source] of text) {
    if (isTest(other) || isIndex(other)) continue;
    if (usesOutsideDeclaration(source, name) > 0) return false;
  }
  return true;
});

if (orphans.length === 0) {
  console.log(`wiring ok — ${exports.length} exports, all reachable`);
  process.exit(0);
}

console.error(`\n${orphans.length} export(s) only their own tests call:\n`);
for (const { name, file } of orphans) {
  console.error(`  ${name}  —  ${file.replace(ROOT, '')}`);
}
console.error('\n연결하거나, 지우거나, EXPECTED_UNUSED 에 이유와 함께 넣으세요.\n');
process.exit(1);
