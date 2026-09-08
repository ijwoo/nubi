import { describe, expect, it } from 'vitest';
import { WdaError } from './wda.js';

/**
 * The device-dependent parts of WdaHands are covered by `npm run live`.
 * What is testable here is the judgement that drives recovery: deciding a
 * failure means the session is gone rather than that the command was wrong.
 * Getting it wrong in either direction is bad — a missed session loss surfaces
 * infrastructure to the caller, and a false one silently re-runs a command
 * that already reached the device.
 */
describe('WdaError.isSessionLost', () => {
  it.each([
    ['invalid session id', 200],
    ['no such session', 200],
    ['some other error', 404],
  ])('treats %s (%d) as a lost session', (code, status) => {
    expect(new WdaError(code, 'x', status).isSessionLost).toBe(true);
  });

  it('reads a session message even when the code is unfamiliar', () => {
    expect(new WdaError('unknown error', 'Session does not exist', 500).isSessionLost).toBe(true);
    expect(new WdaError('unknown error', 'session is not open', 500).isSessionLost).toBe(true);
  });

  it('leaves ordinary failures alone', () => {
    // Retrying these against a fresh session would repeat a command that
    // already ran, or hide a real bug behind a reconnect.
    expect(new WdaError('no such element', 'not found', 200).isSessionLost).toBe(false);
    expect(new WdaError('invalid argument', 'bad x', 400).isSessionLost).toBe(false);
    expect(new WdaError('unknown error', 'app crashed', 500).isSessionLost).toBe(false);
  });
});
