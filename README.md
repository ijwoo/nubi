# Nubi

**A voice-driven iPhone agent that learns a path once, then replays it without the model.**

> `nubi` — from the Korean verb *누비다 (nubida)*, "to roam across." It roams your app
> screens and taps for you.

Say what you want. Nubi drives your actual iPhone — reading the accessibility tree,
finding the right control, tapping it. The first time it has to figure the route out.
Every time after that, it just remembers.

---

## The problem

Every "AI controls your phone" demo hits the same wall: a screenshot → model → tap
round trip costs seconds, and real tasks are 15–25 steps deep. One request takes five
minutes and the context window fills with screenshots.

That is a fun demo. Nobody uses it twice.

To be usable daily, **the second time has to be fast** — the way it is for a person.

## The idea

Nubi separates *finding* a route from *following* one.

The first run is a full agent loop: observe the screen, decide, act, repeat. Slow, and
it costs tokens. But when it succeeds, Nubi extracts the route as a **selector-based
macro** and files it away.

The next run replays that macro directly. No model call. When a selector breaks — the
app shipped a redesign — only *that step* escalates back to the model, which repairs the
selector and writes the fix back into the macro.

Find once. Replay forever. Repair on contact.

## Results

| Same task | First run (explore) | After learning (replay) |
| --- | --- | --- |
| Model calls | ~20 | **0** |
| Input tokens | ~120k | **0** |
| Cost per run | measuring | **$0** |
| Wall clock | measuring | measuring |
| Success rate | measuring | measuring |

Zero model calls, tokens, and cost on replay are **structural** — the replay path never
opens a socket to the API. Wall clock and success rate need Explore to exist before there
is a first-run column to compare against; they land with phase 04.

The harness itself works and has a floor to measure against. Replaying a hand-written
route on a simulator, five runs:

| Task | Executor | Success | p50 | p95 | Model calls |
| --- | --- | --- | ---: | ---: | ---: |
| settings-open-accessibility | scripted | 5/5 | 8787ms | 8942ms | 0 |

Conditions and how to read that in
[`docs/benchmarks/`](docs/benchmarks/2026-09-09-scripted-baseline.md). A number without
its conditions is not reproducible, and one that is not reproducible is worse than none.

## How it works

A request takes one of three paths.

**Route** *(Haiku, ~300ms)* — match the utterance against the macro registry, extract
parameters. Hit → Replay. Miss → Explore.

**Replay** *(no model)* — run the stored steps. Each step resolves a selector against the
live accessibility tree, then acts. This is the path that turns five minutes into ten
seconds.

**Repair** *(Opus, 1–2 calls)* — fires only when a selector misses. The model gets the
current tree plus the intent that failed, proposes a replacement, and the working
selector is patched back into the macro file.

**Explore** *(Opus, N calls)* — no macro exists yet. Full observe-decide-act loop. On
success the trajectory is distilled into a macro candidate. **This is what feeds the
replay path** — the whole design is a loop from Explore back into Replay.

## Try it without a phone

Screens recorded from a real device are replayed by a fake backend, so a fresh
clone can walk a route with no device, no API key, and no network.

```bash
npm install
npm run nubi -- demo
```

```
✓ launch             home -> home
✓ tap 검색 탭           home -> search-empty
✓ type "뉴진스"         search-empty -> search-results
✓ tap Hype Boy       search-results -> playing
✓ assert 재생 중        playing -> playing
```

## Commands

| | Needs a device | |
| --- | --- | --- |
| `npm test` | no | Pure logic and the fake backend |
| `npm run nubi -- demo` | no | Replay a recorded route |
| `npm run eval -- --fake` | no | Run the task set over recorded screens |
| `npm run wda` | simulator | Build and start WebDriverAgent |
| `npm run live` | yes | Contract and action checks against a real agent |
| `npm run record -- settings` | yes | Walk an app and record a scenario |
| `npm run eval` | yes | Run the task set and measure it |

A simulator is enough for all of these. WebDriverAgent needs no code signing there, so
`npm run wda` works over SSH with no cable and no GUI.

## Architecture

```
Mac                                    iPhone
┌────────────────────────────┐
│  Orb      voice in, state  │
│   ↕                        │
│  Brain    route · replay   │        ┌──────────────┐
│   │       · repair         │        │  WDA         │
│   │       ↘ Anthropic API  │        │  (XCUITest)  │
│   ↓                        │        │      ↓       │
│  Hands    WDA client       │──USB──▶│  target app  │
│           session recovery │        └──────────────┘
│           tree compaction  │
└────────────────────────────┘               ▲
              │                              │
              └──── relay ──▶ approval on the phone
```

Hands is a library, not a service — Brain imports it in-process. It is also exposed as an
MCP server so Claude Code can drive the phone directly during development.

Two implementations satisfy that interface: one driving WebDriverAgent, one replaying
screens recorded off a device. A shared contract suite runs against both — `npm test`
against the fake, `npm run live` against a real agent — because implementing the same
interface proves nothing about behaving the same way.

Risky actions (payment, deletion, sending) never auto-execute. They pause and ask for
approval **on the phone**, through the existing
[pip-any](https://github.com/imjaewoo/pip-any) relay and Live Activity.

## Status

Built in five phases, each ending in something measurable.

| | Phase | Delivers | State |
| --- | --- | --- | --- |
| 01 | Hands | tap/type/assert against the simulator; session auto-recovery | done |
| 02 | Trace + Eval | the harness, and a floor to measure against | done |
| 03 | Brain · Explore | cold success rate and real token cost | |
| 04 | Macro · Replay + Repair | the before/after table | |
| 05 | Orb + approval gate | the demo | |

Eval comes before macros on purpose: proving the speedup needs a measured baseline, and
you only get one chance to record it.

## Docs

Design notes and decision records live in [`docs/`](docs/) (written in Korean).

- [Overview](docs/overview.md) — problem, approach, what this claims
- [Architecture](docs/architecture.md)
- [Execution paths](docs/execution-paths.md) — route / replay / repair / explore
- [Macro format](docs/macro-format.md)
- [Selector strategy](docs/selector-strategy.md)
- [Eval design](docs/eval-design.md)
- [ADRs](docs/adr/) — why things are the way they are
- [Journal](docs/journal/) — what actually happened, including what did not work

## Limitations

Stated up front, because they are real.

- **iOS shows an "Automation Running" banner** for the whole session, and the phone is
  occupied — you cannot use it by hand while Nubi drives.
- **A free Apple developer account requires reinstalling WDA every 7 days.** A paid
  account gets a year.
- **Biometric prompts cannot be passed.** That is deliberate, not a gap; the approval
  gate takes that role.
- **Macros are brittle against app redesigns.** Repair softens this but does not remove
  it, and apps with a thin accessibility tree fall back to coordinates, which break more.
- Demos target apps with clean terms of service (music, notes, reminders, maps,
  settings). Automating commerce checkout is out of scope.

## License

MIT
