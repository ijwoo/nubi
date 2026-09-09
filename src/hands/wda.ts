import type { Screen, Selector } from '../shared/types.js';
import { compact } from './compact.js';
import { resolveWithFallback } from './selector.js';
import type { ActResult, AssertResult, FindResult, Hands, Health, Point } from './types.js';
import type { WdaNode } from './wda-types.js';

/**
 * Hands backed by a real WebDriverAgent.
 *
 * Same contract as `FakeHands`, so nothing above this line knows whether it is
 * driving a simulator, a device, or a recording. Session lifecycle lives here
 * and is invisible to callers by design (ADR 0005).
 */

export interface WdaOptions {
  /** Simulator serves this directly; a device needs `iproxy` forwarding to it. */
  baseUrl?: string;
  /** App to attach the session to. Omit to drive whatever is in the foreground. */
  bundleId?: string;
  /** Per-request ceiling. Source dumps on a busy screen are the slow case. */
  timeoutMs?: number;
}

/** WDA replied, and said no. Distinct from the transport failing. */
export class WdaError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = 'WdaError';
  }

  /**
   * The session is gone — the app was killed, the runner restarted, or WDA
   * timed out the session. Recoverable by creating a new one, which is why it
   * is separated from every other error rather than surfaced to the caller.
   */
  get isSessionLost(): boolean {
    return (
      this.code === 'invalid session id' ||
      this.code === 'no such session' ||
      this.status === 404 ||
      /session (does not exist|is not open|terminated)/i.test(this.message)
    );
  }
}

interface WdaEnvelope<T> {
  value: T;
  sessionId?: string | null;
}

export class WdaHands implements Hands {
  private readonly baseUrl: string;
  private readonly bundleId: string | undefined;
  private readonly timeoutMs: number;

  private sessionId: string | undefined;
  private recoveries = 0;

  constructor(options: WdaOptions = {}) {
    this.baseUrl = (options.baseUrl ?? 'http://127.0.0.1:8100').replace(/\/$/, '');
    this.bundleId = options.bundleId;
    this.timeoutMs = options.timeoutMs ?? 30_000;
  }

  /**
   * The live session id, or undefined before one is created.
   *
   * Exposed for traces — knowing which session a run used is what makes a
   * recovery legible after the fact — and so tests can end a session out from
   * under the client and watch it rebuild.
   */
  get activeSessionId(): string | undefined {
    return this.sessionId;
  }

  /* ---- transport -------------------------------------------------- */

  private async request<T>(
    method: 'GET' | 'POST' | 'DELETE',
    path: string,
    body?: unknown,
  ): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res: Response;
    try {
      res = await fetch(`${this.baseUrl}${path}`, {
        method,
        signal: controller.signal,
        ...(body === undefined
          ? {}
          : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }),
      });
    } finally {
      clearTimeout(timer);
    }

    const text = await res.text();
    let parsed: WdaEnvelope<unknown>;
    try {
      parsed = JSON.parse(text) as WdaEnvelope<unknown>;
    } catch {
      throw new WdaError('malformed-response', text.slice(0, 200), res.status);
    }

    const value = parsed.value as { error?: string; message?: string } | null;
    if (!res.ok || (value !== null && typeof value === 'object' && 'error' in value)) {
      throw new WdaError(
        value?.error ?? `http-${res.status}`,
        value?.message ?? `WDA ${method} ${path} failed`,
        res.status,
      );
    }
    return parsed.value as T;
  }

  /* ---- session ---------------------------------------------------- */

  /**
   * The session id, creating one if needed.
   *
   * Sessions are created lazily and cached. Callers never pass one in and never
   * see one — a dropped session is infrastructure, not a step in the task.
   */
  private async session(): Promise<string> {
    if (this.sessionId) return this.sessionId;
    const created = await this.request<{ sessionId: string }>('POST', '/session', {
      capabilities: {
        alwaysMatch: this.bundleId ? { bundleId: this.bundleId } : {},
      },
    });
    this.sessionId = created.sessionId;
    return created.sessionId;
  }

  /**
   * Run an operation against the current session, rebuilding it once if WDA
   * says the session is gone.
   *
   * A single retry, not a loop: if a fresh session fails the same way, the
   * problem is not the session and hiding it would turn a hard failure into a
   * hang. Retrying is only safe because the operation never ran — WDA rejected
   * it on the session id before touching the device.
   */
  private async withSession<T>(op: (sessionId: string) => Promise<T>): Promise<T> {
    try {
      return await op(await this.session());
    } catch (err) {
      if (!(err instanceof WdaError) || !err.isSessionLost) throw err;
      this.sessionId = undefined;
      this.recoveries += 1;
      return op(await this.session());
    }
  }

  /* ---- Hands ------------------------------------------------------ */

  async screen(): Promise<Screen> {
    return this.withSession(async (id) => {
      const root = await this.request<WdaNode>('GET', `/session/${id}/source?format=json`);
      const app = await this.activeApp(id);
      const screen = compact(root, { app });
      const alert = await this.readAlert(id);
      return alert ? { ...screen, alert } : screen;
    });
  }

  /**
   * The raw source tree, uncompacted.
   *
   * For recording fixtures. Everything else works from `screen()` — saving a
   * compacted tree would bake today's compaction rules into the fixture and
   * stop it from catching tomorrow's mistakes.
   */
  async rawSource(): Promise<WdaNode> {
    return this.withSession((id) =>
      this.request<WdaNode>('GET', `/session/${id}/source?format=json`),
    );
  }

  async find(sel: Selector, alt?: Selector): Promise<FindResult> {
    const screen = await this.screen();
    const r = resolveWithFallback(sel, alt, screen);
    if (!r.ok) return { ok: false, reason: r.reason, screen };
    return { ok: true, element: r.element, rung: r.rung, via: r.via, matched: r.matched };
  }

  async screenshot(): Promise<string | undefined> {
    try {
      return await this.withSession((id) =>
        this.request<string>('GET', `/session/${id}/screenshot`),
      );
    } catch {
      // A screenshot is never load-bearing; failing to take one must not fail
      // whatever asked for it.
      return undefined;
    }
  }

  async health(): Promise<Health> {
    try {
      const status = await this.request<{ ready?: boolean; message?: string }>('GET', '/status');
      return {
        ready: status.ready === true,
        recoveries: this.recoveries,
        ...(status.message === undefined ? {} : { detail: status.message }),
      };
    } catch (err) {
      return {
        ready: false,
        recoveries: this.recoveries,
        detail: err instanceof Error ? err.message : String(err),
      };
    }
  }

  async close(): Promise<void> {
    if (!this.sessionId) return;
    const id = this.sessionId;
    this.sessionId = undefined;
    // Best effort: the session may already be gone, which is not an error worth
    // propagating out of a teardown path.
    await this.request('DELETE', `/session/${id}`).catch(() => undefined);
  }

  /* ---- actions ---------------------------------------------------- */

  async tap(sel: Selector, alt?: Selector): Promise<ActResult> {
    const screen = await this.screen();
    if (screen.alert)
      return { ok: false, reason: 'blocked-by-alert', screen, detail: screen.alert.text };

    const r = resolveWithFallback(sel, alt, screen);
    if (!r.ok) return { ok: false, reason: r.reason, screen };

    const [x, y, w, h] = r.element.r;
    await this.withSession((id) => this.pointer(id, [{ x: x + w / 2, y: y + h / 2 }], 60));

    return {
      ok: true,
      screen: await this.screen(),
      element: r.element,
      rung: r.rung,
      via: r.via,
      matched: r.matched,
    };
  }

  /**
   * Type into whatever currently has focus.
   *
   * WDA sends keys to the focused element, so a macro taps the field first —
   * the same two steps a person performs. Typing without focus is a caller
   * error, and it surfaces as one rather than being silently swallowed.
   */
  async type(text: string, opts: { submit?: boolean } = {}): Promise<ActResult> {
    const blocking = await this.screen();
    if (blocking.alert) {
      return {
        ok: false,
        reason: 'blocked-by-alert',
        screen: blocking,
        detail: blocking.alert.text,
      };
    }
    const value = opts.submit ? [...text, '\n'] : [...text];
    try {
      await this.withSession((id) => this.request('POST', `/session/${id}/wda/keys`, { value }));
    } catch (err) {
      return {
        ok: false,
        reason: 'unsupported',
        screen: await this.screen(),
        detail: err instanceof Error ? err.message : String(err),
      };
    }
    return { ok: true, screen: await this.screen() };
  }

  async swipe(from: Point, to: Point, durationMs = 300): Promise<ActResult> {
    const screen = await this.screen();
    if (screen.alert)
      return { ok: false, reason: 'blocked-by-alert', screen, detail: screen.alert.text };
    const abs = (p: Point) => ({ x: p[0] * screen.size.w, y: p[1] * screen.size.h });
    await this.withSession((id) => this.pointer(id, [abs(from), abs(to)], durationMs));
    return { ok: true, screen: await this.screen() };
  }

  /**
   * Go back.
   *
   * iOS has no back button, so this is the system edge-swipe — the gesture a
   * person uses. Tapping a navigation bar's back button would be more precise
   * where one exists, but its label and position differ per app, and a macro
   * that wants that specific control can name it as an ordinary tap step.
   */
  async back(): Promise<ActResult> {
    return this.swipe([0.01, 0.5], [0.6, 0.5], 250);
  }

  /**
   * Bring an app to the foreground.
   *
   * A URL scheme is preferred when the macro carries one: it lands on a
   * specific screen and skips the taps that would otherwise be needed to get
   * there. Falling back to a plain launch only reaches the app's own start
   * screen.
   */
  async launch(target: { url?: string; bundleId?: string; restart?: boolean }): Promise<ActResult> {
    try {
      if (target.restart && target.bundleId) {
        // Terminating first is what makes "start from the app's home screen"
        // mean anything; a plain launch reveals the screen it was left on.
        await this.withSession((id) =>
          this.request('POST', `/session/${id}/wda/apps/terminate`, { bundleId: target.bundleId }),
        ).catch(() => undefined); // not running is not a failure
      }
      if (target.url) {
        await this.withSession((id) =>
          this.request('POST', `/session/${id}/url`, { url: target.url }),
        );
      } else if (target.bundleId) {
        await this.withSession((id) =>
          this.request('POST', `/session/${id}/wda/apps/launch`, { bundleId: target.bundleId }),
        );
      } else {
        return {
          ok: false,
          reason: 'unsupported',
          screen: await this.screen(),
          detail: 'launch needs a url or bundleId',
        };
      }
    } catch (err) {
      return {
        ok: false,
        reason: 'unsupported',
        screen: await this.screen(),
        detail: err instanceof Error ? err.message : String(err),
      };
    }
    return { ok: true, screen: await this.screen() };
  }

  /**
   * Wait for a selector to resolve.
   *
   * Polls rather than sleeping a fixed time: a fixed wait is wrong on both
   * ends, too short on a loaded device and wasted on a fast one. This is why
   * macros are written with `assert` instead of `wait`.
   */
  async assert(sel: Selector, timeoutMs = 8000): Promise<AssertResult> {
    const started = Date.now();
    let screen = await this.screen();

    for (;;) {
      const r = resolveWithFallback(sel, undefined, screen);
      const waitedMs = Date.now() - started;
      if (r.ok) return { ok: true, screen, element: r.element, waitedMs };
      if (waitedMs >= timeoutMs) return { ok: false, screen, waitedMs, reason: 'timeout' };
      await new Promise((done) => setTimeout(done, WdaHands.POLL_MS));
      screen = await this.screen();
    }
  }

  /**
   * Answer a system alert by its button label.
   *
   * Never called automatically. Alerts ask consequential questions, and a
   * caller that wants one answered has to say which button (ADR 0007).
   */
  async answerAlert(button: string): Promise<ActResult> {
    const screen = await this.screen();
    if (!screen.alert) {
      return { ok: false, reason: 'no-match', screen, detail: 'no alert is showing' };
    }
    if (!screen.alert.buttons.includes(button)) {
      return {
        ok: false,
        reason: 'no-match',
        screen,
        detail: `alert has no button "${button}" (has: ${screen.alert.buttons.join(', ')})`,
      };
    }
    await this.withSession((id) =>
      this.request('POST', `/session/${id}/alert/accept`, { name: button }),
    );
    return { ok: true, screen: await this.screen() };
  }

  /* ---- internals -------------------------------------------------- */

  /**
   * Read a system alert, if one is up.
   *
   * Costs an extra request per observation. Worth it: the tree gives no hint
   * that a modal is present, so without this an agent taps into a void and
   * blames its selectors. That failure is not hypothetical — it is how this
   * function came to exist.
   */
  private async readAlert(
    sessionId: string,
  ): Promise<{ text: string; buttons: string[] } | undefined> {
    let text: string;
    try {
      text = await this.request<string>('GET', `/session/${sessionId}/alert/text`);
    } catch {
      return undefined; // WDA errors when nothing is showing
    }
    if (!text) return undefined;
    const buttons = await this.request<string[]>(
      'GET',
      `/session/${sessionId}/wda/alert/buttons`,
    ).catch(() => [] as string[]);
    return { text, buttons };
  }

  /** How often `assert` re-observes while waiting. */
  private static readonly POLL_MS = 250;

  /**
   * One finger, moved through the given absolute points.
   *
   * W3C actions rather than WDA's older `/wda/tap` and `/wda/dragfromtoforduration`:
   * one request shape covers taps and swipes, and it is the surface WDA is
   * least likely to change under us.
   */
  private async pointer(
    sessionId: string,
    points: { x: number; y: number }[],
    durationMs: number,
  ): Promise<void> {
    const [first, ...rest] = points;
    if (!first) throw new Error('pointer: no points');

    const actions: Record<string, unknown>[] = [
      { type: 'pointerMove', duration: 0, x: Math.round(first.x), y: Math.round(first.y) },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: rest.length === 0 ? durationMs : 0 },
    ];
    for (const p of rest) {
      actions.push({
        type: 'pointerMove',
        duration: durationMs,
        x: Math.round(p.x),
        y: Math.round(p.y),
      });
    }
    actions.push({ type: 'pointerUp', button: 0 });

    await this.request('POST', `/session/${sessionId}/actions`, {
      actions: [{ type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' }, actions }],
    });
  }

  /** Bundle id of the foreground app; the tree does not carry it reliably. */
  private async activeApp(sessionId: string): Promise<string> {
    try {
      const info = await this.request<{ bundleId?: string }>(
        'GET',
        `/session/${sessionId}/wda/activeAppInfo`,
      );
      return info.bundleId ?? this.bundleId ?? 'unknown';
    } catch {
      return this.bundleId ?? 'unknown';
    }
  }
}
