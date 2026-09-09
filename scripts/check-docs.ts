#!/usr/bin/env tsx
/**
 * Check that the docs still describe the code.
 *
 * Documentation breaks silently — no type checker or test notices when a doc
 * describes a schema that no longer exists. This caught `eval-design.md`
 * documenting field names the task schema never had, a flag that was never
 * implemented, and two sections duplicated by an earlier edit.
 *
 *   npm run check:docs
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));

function markdownFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return markdownFiles(full);
    return name.endsWith('.md') ? [full] : [];
  });
}

const docs = [
  ...readdirSync(ROOT)
    .filter((f) => f.endsWith('.md'))
    .map((f) => join(ROOT, f)),
  ...markdownFiles(join(ROOT, 'docs')),
];

const problems: string[] = [];
const note = (file: string, msg: string) => problems.push(`  ${file.replace(ROOT, '')}: ${msg}`);

for (const file of docs) {
  const text = readFileSync(file, 'utf8');
  // The ADR template's placeholder link is meant to be unresolvable.
  const isTemplate = file.endsWith('template.md');

  if (!isTemplate) {
    for (const [, label, target] of text.matchAll(/\[([^\]]+)\]\(([^)]+)\)/g)) {
      if (!target || /^(https?:|#|mailto:)/.test(target)) continue;
      const path = target.split('#')[0];
      if (!path) continue;
      if (!existsSync(resolve(dirname(file), path))) note(file, `dead link [${label}](${target})`);
    }
  }

  // A repeated heading means an edit added a section next to the one it meant
  // to replace.
  const headings = [...text.matchAll(/^## (.+)$/gm)].map((m) => m[1]);
  const seen = new Set<string>();
  for (const h of headings) {
    if (h && seen.has(h)) note(file, `duplicate section "${h}"`);
    if (h) seen.add(h);
  }

  // A path in backticks reads as a claim that it exists — except in an ADR,
  // which records a decision including structure that has not been built yet.
  // Rewriting one to match today's tree would defeat the point of keeping the
  // judgement as it was made.
  if (!file.includes('/adr/')) {
    for (const [, path] of text.matchAll(/`((?:src|scripts|macros|bin)\/[\w./-]+)`/g)) {
      if (path && !existsSync(join(ROOT, path))) note(file, `references missing path ${path}`);
    }
  }
}

// Every npm command a doc tells someone to run has to exist.
const scripts = new Set(
  Object.keys(JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')).scripts),
);
for (const file of docs) {
  for (const [, name] of readFileSync(file, 'utf8').matchAll(/npm run ([\w:]+)/g)) {
    if (name && !scripts.has(name)) note(file, `npm run ${name} does not exist`);
  }
}

// A document nobody links to is a document nobody reads.
const indexed = (index: string, dir: string) => {
  const listed = readFileSync(join(ROOT, index), 'utf8');
  for (const f of readdirSync(join(ROOT, dir))) {
    if (!f.endsWith('.md') || f === 'README.md' || f === 'template.md') continue;
    if (!listed.includes(f)) note(index, `${f} is not listed`);
  }
};
indexed('docs/adr/README.md', 'docs/adr');
indexed('docs/journal/README.md', 'docs/journal');
indexed('docs/benchmarks/README.md', 'docs/benchmarks');

if (problems.length === 0) {
  console.log(`docs ok — ${docs.length} files`);
} else {
  console.log(`${problems.length} problem(s):`);
  console.log(problems.join('\n'));
  process.exitCode = 1;
}
