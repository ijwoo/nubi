import { describe, expect, it } from 'vitest';
import { WdaError, WdaHands, sessionCapabilities } from './wda.js';

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

  /**
   * Run with NUBI_WDA_URL set, then put the environment back.
   *
   * Restored by removing the key rather than assigning undefined: in Node that
   * assignment stores the string "undefined", which is a valid-looking address
   * that every later test in the process would then try to use.
   */
  function withAgentUrl<T>(url: string, body: () => T): T {
    const before = process.env.NUBI_WDA_URL;
    process.env.NUBI_WDA_URL = url;
    try {
      return body();
    } finally {
      if (before === undefined) Reflect.deleteProperty(process.env, 'NUBI_WDA_URL');
      else process.env.NUBI_WDA_URL = before;
    }
  }

  it('takes the agent address from the environment, for a phone on Wi-Fi', () => {
    // Over the cable the device's 8100 arrives on 127.0.0.1 through iproxy;
    // over Wi-Fi it is the phone's own address. Nothing above Hands should
    // care which, and rebuilding to change a hostname is not a workflow.
    withAgentUrl('http://192.168.0.42:8100/', () => {
      expect(new WdaHands().agentUrl).toBe('http://192.168.0.42:8100');
    });
  });

  it('prefers an explicit address over the environment', () => {
    withAgentUrl('http://192.168.0.42:8100', () => {
      expect(new WdaHands({ baseUrl: 'http://127.0.0.1:8100' }).agentUrl).toBe(
        'http://127.0.0.1:8100',
      );
    });
  });

  it('attaches to the app rather than restarting it', () => {
    // WDA relaunches whatever a session names unless told not to, which makes
    // opening a session destructive. Checking whether a song was playing
    // stopped it, and the reading that followed reported that it had never
    // started — the tool changed the thing it measured, then believed the
    // measurement.
    expect(sessionCapabilities('com.google.ios.youtubemusic')).toEqual({
      bundleId: 'com.google.ios.youtubemusic',
      forceAppLaunch: false,
      shouldTerminateApp: false,
    });
  });

  it('asks for nothing in particular when no app is named', () => {
    // Driving whatever is in the foreground, which should not disturb it.
    expect(sessionCapabilities(undefined)).toEqual({});
  });
});
