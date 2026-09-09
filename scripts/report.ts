#!/usr/bin/env tsx
/**
 * Run a macro and produce a readable account of what happened.
 *
 * The trace already says what a run did; this pairs each step with what the
 * screen looked like when it ran. That combination is what makes a failure
 * explainable — a selector miss reads very differently next to a screenshot of
 * a modal than it does as a line of JSON.
 *
 *   scripts/wda.sh &
 *   npm run report -- settings-open-accessibility
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WdaHands } from '../src/hands/wda.js';
import { type Macro, MacroSchema } from '../src/shared/types.js';
import { Trace, summarize, traced } from '../src/trace/index.js';

const MACRO_DIR = fileURLToPath(new URL('../macros/', import.meta.url));
const OUT = fileURLToPath(new URL('../report.html', import.meta.url));

const name = process.argv[2] ?? 'settings-open-accessibility';
const macro: Macro = MacroSchema.parse(
  JSON.parse(readFileSync(`${MACRO_DIR}${name}.json`, 'utf8')),
);

/**
 * Shrink a device-resolution PNG before it goes in the page.
 *
 * Full-size shots are megabytes each and a report is meant to be opened on a
 * phone. `sips` ships with macOS, so this needs no image dependency.
 */
function thumbnail(base64: string, width = 340): string {
  const dir = mkdtempSync(join(tmpdir(), 'nubi-shot-'));
  try {
    const src = join(dir, 'in.png');
    const dst = join(dir, 'out.png');
    writeFileSync(src, Buffer.from(base64, 'base64'));
    execFileSync('sips', ['-Z', String(width), src, '--out', dst], { stdio: 'ignore' });
    return readFileSync(dst).toString('base64');
  } catch {
    return base64;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

interface Shot {
  label: string;
  png: string | undefined;
  screenHash: string;
  elements: number;
  alert?: string;
}

const hands = new WdaHands({ bundleId: macro.app });
const health = await hands.health();
if (!health.ready) {
  console.error(`agent not ready: ${health.detail ?? ''}\nStart it with: npm run wda`);
  process.exit(1);
}

const trace = Trace.start();
const watched = traced(hands, trace, () => 'replay');
const shots: Shot[] = [];

async function capture(label: string): Promise<void> {
  const [screen, png] = await Promise.all([hands.screen(), hands.screenshot()]);
  const shot: Shot = {
    label,
    png: png ? thumbnail(png) : undefined,
    screenHash: screen.hash,
    elements: screen.elements.length,
  };
  if (screen.alert) shot.alert = screen.alert.text;
  shots.push(shot);
  console.log(`  ${label.padEnd(34)} ${screen.elements.length} elements  ${screen.hash}`);
}

console.log(`\nreport: ${macro.id}\n`);
await hands.launch({ bundleId: macro.app, restart: true });
await new Promise((r) => setTimeout(r, 1500));
trace.beginAttempt();
await capture('start');

let ok = true;
for (const step of macro.steps) {
  const label = describe(step);
  const result = await runStep(step);
  ok = ok && result;
  await capture(label + (result ? '' : '  ✗'));
  if (!result) break;
}
trace.end(ok, { macro: macro.id });
await hands.close();

writeFileSync(OUT, render());
console.log(`\n${ok ? 'completed' : 'failed'} — wrote ${OUT}`);

/* ---------------------------------------------------------------- */

async function runStep(step: Macro['steps'][number]): Promise<boolean> {
  switch (step.op) {
    case 'launch':
      return (
        await watched.launch({
          ...(step.url === undefined ? {} : { url: step.url }),
          ...(step.bundleId === undefined ? {} : { bundleId: step.bundleId }),
          ...(step.restart === undefined ? {} : { restart: step.restart }),
        })
      ).ok;
    case 'tap':
      return (await watched.tap(step.sel, step.alt)).ok;
    case 'type':
      return (await watched.type(step.text, { submit: step.submit ?? false })).ok;
    case 'swipe':
      return (await watched.swipe(step.from, step.to, step.duration)).ok;
    case 'back':
      return (await watched.back()).ok;
    case 'wait':
      await new Promise((r) => setTimeout(r, step.ms));
      return true;
    case 'assert':
      return (await watched.assert(step.sel, step.timeout)).ok;
  }
}

function describe(step: Macro['steps'][number]): string {
  switch (step.op) {
    case 'launch':
      return `launch ${step.url ?? step.bundleId ?? ''}`;
    case 'tap':
      return `tap ${target(step.sel)}`;
    case 'type':
      return `type "${step.text}"`;
    case 'assert':
      return `assert ${target(step.sel)}`;
    default:
      return step.op;
  }
}

function target(sel: Record<string, unknown>): string {
  if ('id' in sel) return `#${String(sel.id)}`;
  if ('label' in sel) return `"${String(sel.label)}"`;
  if ('labelContains' in sel) return `~"${String(sel.labelContains)}"`;
  if ('point' in sel) return `at ${JSON.stringify(sel.point)}`;
  return JSON.stringify(sel);
}

function esc(s: string): string {
  return s.replace(
    /[&<>"]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c] ?? c,
  );
}

function render(): string {
  const s = summarize(trace.events);
  const events = trace.events.filter((e) => e.kind !== 'end');

  const stats = [
    ['outcome', s.ok ? 'completed' : 'failed'],
    ['duration', `${s.durationMs} ms`],
    ['actions', String(s.actions)],
    ['observations', String(s.observations)],
    ['model calls', String(s.modelCalls)],
    ['input tokens', String(s.inputTokens)],
    ['session recoveries', String(s.recoveries)],
  ];

  return `<title>Nubi run — ${esc(macro.id)}</title>
<style>
:root{--bg:#F6F8F8;--card:#fff;--ink:#12191A;--body:#2C3739;--muted:#5F6E70;--line:#DCE4E4;--accent:#0B6E75;--bad:#9E2B22;--mono:"SF Mono",Menlo,Consolas,monospace}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0E1414;--card:#161E1F;--ink:#EDF3F3;--body:#C8D3D4;--muted:#93A2A3;--line:#263233;--accent:#4FC5CE;--bad:#E5877E}}
:root[data-theme="dark"]{--bg:#0E1414;--card:#161E1F;--ink:#EDF3F3;--body:#C8D3D4;--muted:#93A2A3;--line:#263233;--accent:#4FC5CE;--bad:#E5877E}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--body);font:16px/1.6 "Iowan Old Style",Charter,Georgia,serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:900px;margin:0 auto;padding:40px 20px 80px}
h1{font-family:"Avenir Next",Avenir,system-ui,sans-serif;font-weight:600;font-size:30px;letter-spacing:-.02em;color:var(--ink);margin:0 0 4px}
.sub{font-family:var(--mono);font-size:12px;color:var(--muted);margin:0 0 28px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:1px;background:var(--line);border:1px solid var(--line);border-radius:5px;overflow:hidden;margin-bottom:32px}
.stats div{background:var(--card);padding:11px 14px}
.stats dt{font-family:var(--mono);font-size:10px;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);margin:0 0 3px}
.stats dd{font-family:var(--mono);font-size:16px;color:var(--ink);margin:0;font-variant-numeric:tabular-nums}
.steps{display:flex;flex-direction:column;gap:16px}
.step{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:5px;padding:14px 16px;display:grid;grid-template-columns:1fr 180px;gap:18px;align-items:start}
.step.bad{border-left-color:var(--bad)}
.step h2{font-family:"Avenir Next",Avenir,system-ui,sans-serif;font-size:15px;font-weight:600;color:var(--ink);margin:0 0 6px}
.meta{font-family:var(--mono);font-size:11.5px;color:var(--muted);line-height:1.7}
.meta b{color:var(--accent);font-weight:400}
.shot{width:100%;border:1px solid var(--line);border-radius:6px;display:block}
.noshot{font-family:var(--mono);font-size:11px;color:var(--muted);text-align:center;padding:30px 8px;border:1px dashed var(--line);border-radius:6px}
.ev{margin-top:32px;border:1px solid var(--line);border-radius:5px;overflow-x:auto;background:var(--card)}
table{border-collapse:collapse;width:100%;min-width:520px;font-family:var(--mono);font-size:12px}
th{text-align:left;padding:9px 12px;background:var(--bg);border-bottom:1px solid var(--line);font-size:10px;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);white-space:nowrap}
td{padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top;color:var(--body)}
tr:last-child td{border-bottom:0}
td.n{text-align:right;font-variant-numeric:tabular-nums;color:var(--ink);white-space:nowrap}
tr.bad td{color:var(--bad)}
.note{margin-top:28px;font-family:var(--mono);font-size:11.5px;color:var(--muted);line-height:1.8}
@media(max-width:640px){.step{grid-template-columns:1fr}.step .shotwrap{max-width:220px}}
</style>
<div class="wrap">
<h1>${esc(macro.id)}</h1>
<p class="sub">${esc(macro.app)} · ${new Date().toISOString()} · scripted replay, no model</p>

<dl class="stats">
${stats.map(([k, v]) => `<div><dt>${esc(k ?? '')}</dt><dd>${esc(v ?? '')}</dd></div>`).join('\n')}
</dl>

<div class="steps">
${shots
  .map(
    (sh) => `<div class="step${sh.label.includes('✗') ? ' bad' : ''}">
  <div>
    <h2>${esc(sh.label)}</h2>
    <div class="meta">
      screen <b>${esc(sh.screenHash)}</b><br>
      ${sh.elements} addressable elements
      ${sh.alert ? `<br>alert: ${esc(sh.alert.slice(0, 60))}` : ''}
    </div>
  </div>
  <div class="shotwrap">${
    sh.png
      ? `<img class="shot" alt="${esc(sh.label)}" src="data:image/png;base64,${sh.png}">`
      : '<div class="noshot">no pixels<br>(recorded target)</div>'
  }</div>
</div>`,
  )
  .join('\n')}
</div>

<div class="ev">
<table>
<thead><tr><th>#</th><th>kind</th><th>ms</th><th>detail</th></tr></thead>
<tbody>
${events
  .map(
    (e) =>
      `<tr${e.failed ? ' class="bad"' : ''}><td class="n">${e.seq}</td><td>${esc(e.kind)}</td><td class="n">${e.durationMs}</td><td>${esc(
        Object.entries(e.detail)
          .filter(([k]) => k !== 'screen')
          .map(([k, v]) => `${k}=${typeof v === 'object' ? JSON.stringify(v) : String(v)}`)
          .join('  ')
          .slice(0, 110),
      )}</td></tr>`,
  )
  .join('\n')}
</tbody>
</table>
</div>

<p class="note">
Screens are read as an accessibility tree, not as pixels — these images exist to explain the run,<br>
not to drive it. A full-resolution screenshot costs roughly a thousand times the tokens of the tree.<br>
Model calls are zero because replay never opens a socket to the API.
</p>
</div>`;
}
