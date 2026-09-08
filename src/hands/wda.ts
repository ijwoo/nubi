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
      return compact(root, { app });
    });
  }

  async find(sel: Selector, alt?: Selector): Promise<FindResult> {
    const screen = await this.screen();
    const r = resolveWithFallback(sel, alt, screen);
    if (!r.ok) return { ok: false, reason: r.reason, screen };
    return { ok: true, element: r.element, rung: r.rung, via: r.via, matched: r.matched };
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

  /* ---- not yet implemented ---------------------------------------- */

  async tap(): Promise<ActResult> {
    throw new Error('WdaHands.tap: not implemented yet');
  }
  async type(): Promise<ActResult> {
    throw new Error('WdaHands.type: not implemented yet');
  }
  async swipe(_from: Point, _to: Point): Promise<ActResult> {
    throw new Error('WdaHands.swipe: not implemented yet');
  }
  async back(): Promise<ActResult> {
    throw new Error('WdaHands.back: not implemented yet');
  }
  async launch(): Promise<ActResult> {
    throw new Error('WdaHands.launch: not implemented yet');
  }
  async assert(): Promise<AssertResult> {
    throw new Error('WdaHands.assert: not implemented yet');
  }

  /* ---- internals -------------------------------------------------- */

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
