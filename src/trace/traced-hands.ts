import type { ActResult, AssertResult, FindResult, Hands, Health, Point } from '../hands/types.js';
import type { Screen, Selector } from '../shared/types.js';
import type { Trace } from './trace.js';

/**
 * Wrap any Hands so every call lands in a trace.
 *
 * A decorator rather than logging inside each implementation: `FakeHands` and
 * `WdaHands` would otherwise both need it, drift apart, and a third backend
 * would need it again. This way instrumentation is written once and neither
 * implementation knows it is being watched — which is also what keeps the
 * contract suite honest, since it exercises the same objects either way.
 *
 * What gets recorded is chosen for reading a failure later: the selector that
 * was asked for, which rung answered it, how many candidates matched, and the
 * screen hash before and after. Not the elements — a trace with every screen
 * inlined is unreadable and enormous.
 */
export function traced(hands: Hands, trace: Trace, path: () => Path = () => 'route'): Hands {
  const p = () => path();

  return {
    async screen(): Promise<Screen> {
      const s = await trace.span('observe', p(), {}, () => hands.screen());
      annotate(trace, { screen: s.hash, elements: s.elements.length, alert: s.alert?.text });
      return s;
    },

    async find(sel: Selector, alt?: Selector): Promise<FindResult> {
      const r = await trace.span('observe', p(), { op: 'find', sel, alt }, () =>
        hands.find(sel, alt),
      );
      annotate(trace, findDetail(r));
      return r;
    },

    async tap(sel: Selector, alt?: Selector): Promise<ActResult> {
      return record(trace, p(), 'act', { op: 'tap', sel, alt }, () => hands.tap(sel, alt));
    },

    async type(text: string, opts?: { submit?: boolean }): Promise<ActResult> {
      // The text itself is recorded: a macro that types the wrong thing is a
      // real failure mode, and it is unreadable without the value.
      return record(trace, p(), 'act', { op: 'type', text, submit: opts?.submit ?? false }, () =>
        hands.type(text, opts),
      );
    },

    async swipe(from: Point, to: Point, durationMs?: number): Promise<ActResult> {
      return record(trace, p(), 'act', { op: 'swipe', from, to, durationMs }, () =>
        hands.swipe(from, to, durationMs),
      );
    },

    async back(): Promise<ActResult> {
      return record(trace, p(), 'act', { op: 'back' }, () => hands.back());
    },

    async launch(target: {
      url?: string;
      bundleId?: string;
      restart?: boolean;
    }): Promise<ActResult> {
      return record(trace, p(), 'act', { op: 'launch', ...target }, () => hands.launch(target));
    },

    async assert(sel: Selector, timeoutMs?: number): Promise<AssertResult> {
      const started = Date.now();
      const r = await hands.assert(sel, timeoutMs);
      trace.event(
        'assert',
        p(),
        { sel, timeoutMs, ok: r.ok, waitedMs: r.waitedMs, ...(r.ok ? {} : { reason: r.reason }) },
        Date.now() - started,
        !r.ok,
      );
      return r;
    },

    async answerAlert(button: string): Promise<ActResult> {
      // Answering an alert is a decision a person would otherwise make, so it
      // is filed as an approval rather than an ordinary action (ADR 0007).
      const started = Date.now();
      const r = await hands.answerAlert(button);
      trace.event(
        'approve',
        p(),
        { op: 'answerAlert', button, ok: r.ok },
        Date.now() - started,
        !r.ok,
      );
      return r;
    },

    async health(): Promise<Health> {
      const h = await hands.health();
      if (h.recoveries > 0) {
        // Recovery is invisible to callers by design (ADR 0005). The trace is
        // the one place it has to show, or a session that died five times
        // looks the same as one that never did.
        trace.event('recover', p(), { recoveries: h.recoveries, ready: h.ready });
      }
      return h;
    },

    async close(): Promise<void> {
      await hands.close();
    },
  };
}

type Path = 'route' | 'replay' | 'repair' | 'explore';

async function record(
  trace: Trace,
  path: Path,
  kind: 'act',
  detail: Record<string, unknown>,
  op: () => Promise<ActResult>,
): Promise<ActResult> {
  const started = Date.now();
  const r = await op();
  trace.event(
    kind,
    path,
    {
      ...detail,
      ok: r.ok,
      screen: r.screen.hash,
      ...(r.ok
        ? { element: r.element?.id ?? r.element?.l, rung: r.rung, via: r.via, matched: r.matched }
        : { reason: r.reason, ...(r.detail ? { why: r.detail } : {}) }),
    },
    Date.now() - started,
    !r.ok,
  );
  return r;
}

function findDetail(r: FindResult): Record<string, unknown> {
  return r.ok
    ? {
        ok: true,
        element: r.element.id ?? r.element.l,
        rung: r.rung,
        via: r.via,
        matched: r.matched,
      }
    : { ok: false, reason: r.reason, screen: r.screen.hash };
}

/** Fold extra fields into the event just written, avoiding a second line. */
function annotate(trace: Trace, detail: Record<string, unknown>): void {
  const last = trace.events[trace.events.length - 1];
  if (!last) return;
  for (const [k, v] of Object.entries(detail)) {
    if (v !== undefined) last.detail[k] = v;
  }
}
