import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { FakeHands } from '../hands/fake.js';
import { readTrace, summarize } from './summary.js';
import { Trace } from './trace.js';
import { traced } from './traced-hands.js';

const SCENARIO = fileURLToPath(new URL('../hands/fixtures/music.scenario.json', import.meta.url));

describe('Trace', () => {
  it('numbers events in order', () => {
    const t = Trace.start();
    t.event('observe', 'replay');
    t.event('act', 'replay');
    expect(t.events.map((e) => e.seq)).toEqual([0, 1]);
  });

  it('times an operation that succeeds', async () => {
    const t = Trace.start();
    const out = await t.span('act', 'replay', { op: 'tap' }, async () => {
      await new Promise((r) => setTimeout(r, 20));
      return 'done';
    });
    expect(out).toBe('done');
    expect(t.events[0]?.durationMs).toBeGreaterThanOrEqual(15);
    expect(t.events[0]?.failed).toBeUndefined();
  });

  it('records a thrown operation and rethrows it', async () => {
    // The step that threw is exactly the one a reader is looking for, so it is
    // recorded before the error continues on its way.
    const t = Trace.start();
    await expect(
      t.span('act', 'replay', { op: 'tap' }, async () => {
        throw new Error('boom');
      }),
    ).rejects.toThrow('boom');

    expect(t.events).toHaveLength(1);
    expect(t.events[0]?.failed).toBe(true);
    expect(t.events[0]?.detail.error).toBe('boom');
  });

  describe('written to disk', () => {
    let dir: string;
    beforeEach(() => {
      dir = mkdtempSync(join(tmpdir(), 'nubi-trace-'));
    });
    afterEach(() => rmSync(dir, { recursive: true, force: true }));

    it('is readable before the run ends', () => {
      // Runs worth reading are the ones that hung. A trace only written at the
      // end would be empty for exactly those.
      const t = Trace.start({ dir });
      t.event('observe', 'explore', { screen: 'abc' });
      const file = t.file;
      if (!file) throw new Error('no file');
      expect(readTrace(file)).toHaveLength(1);

      t.event('act', 'explore');
      expect(readTrace(file)).toHaveLength(2);
    });

    it('survives a torn final line', () => {
      const t = Trace.start({ dir });
      t.event('observe', 'explore');
      const file = t.file;
      if (!file) throw new Error('no file');
      require('node:fs').appendFileSync(file, '{"runId":"x","seq":');
      expect(readTrace(file)).toHaveLength(1);
    });
  });
});

describe('traced(hands)', () => {
  let hands: FakeHands;
  let trace: Trace;
  let subject: ReturnType<typeof traced>;

  beforeEach(() => {
    hands = FakeHands.fromScenario(SCENARIO);
    trace = Trace.start();
    subject = traced(hands, trace, () => 'replay');
  });

  it('records an action with what resolved it', async () => {
    await subject.tap({ id: 'tab_search' });
    const ev = trace.events[0];
    expect(ev?.kind).toBe('act');
    expect(ev?.detail).toMatchObject({ op: 'tap', ok: true, rung: 'id', via: 'sel' });
    expect(ev?.detail.screen).toMatch(/^[0-9a-f]{12}$/);
  });

  it('flags a failed action and says why', async () => {
    await subject.tap({ id: 'not-here' });
    expect(trace.events[0]?.failed).toBe(true);
    expect(trace.events[0]?.detail.reason).toBe('no-match');
  });

  it('files an answered alert as an approval, not an action', async () => {
    // Granting permission is a decision a person would otherwise make.
    hands.showAlert('허용하겠습니까?', ['허용']);
    await subject.answerAlert('허용');
    expect(trace.events[0]?.kind).toBe('approve');
  });

  it('surfaces session recovery, which callers never see', async () => {
    // Recovery is invisible by design (ADR 0005); without this a session that
    // died five times looks identical to one that never did.
    hands.failNext('session-lost');
    await hands.back();
    await subject.health();
    expect(trace.events.some((e) => e.kind === 'recover')).toBe(true);
  });

  it('keeps screens out of the trace, but keeps their identity', async () => {
    const s = await subject.screen();
    const ev = trace.events[0];
    expect(ev?.detail.screen).toBe(s.hash);
    expect(JSON.stringify(ev)).not.toContain('rect');
  });
});

describe('summarize', () => {
  it('counts a run by kind and reports the outcome', async () => {
    const hands = FakeHands.fromScenario(SCENARIO);
    const trace = Trace.start();
    const subject = traced(hands, trace, () => 'replay');

    await subject.launch({ url: 'musicapp://' });
    await subject.tap({ id: 'tab_search' });
    await subject.type('뉴진스', { submit: true });
    await subject.tap({ label: 'Hype Boy' });
    await subject.assert({ label: '일시정지' });
    trace.end(true);

    const s = summarize(trace.events);
    expect(s.ok).toBe(true);
    expect(s.actions).toBe(4);
    expect(s.asserts).toBe(1);
    expect(s.modelCalls).toBe(0); // replay never calls a model — ADR 0003
    expect(s.failures).toBe(0);
  });

  it('names the failure that ended the run', async () => {
    const hands = FakeHands.fromScenario(SCENARIO);
    const trace = Trace.start();
    const subject = traced(hands, trace, () => 'replay');

    await subject.tap({ id: 'tab_search' });
    await subject.tap({ id: 'gone-in-v2' });
    trace.end(false, { reason: 'step failed' });

    const s = summarize(trace.events);
    expect(s.ok).toBe(false);
    expect(s.failedAt?.detail.reason).toBe('no-match');
  });

  it('adds up model usage across calls', () => {
    const trace = Trace.start();
    trace.model('explore', { model: 'claude-opus-5', inputTokens: 1200, outputTokens: 80 }, 900);
    trace.model('explore', { model: 'claude-opus-5', inputTokens: 1400, outputTokens: 60 }, 850);
    trace.end(true);

    const s = summarize(trace.events);
    expect(s.modelCalls).toBe(2);
    expect(s.inputTokens).toBe(2600);
    expect(s.outputTokens).toBe(140);
  });
});
