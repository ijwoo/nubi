import { describe, expect, it } from 'vitest';
import type { Macro } from '../shared/types.js';
import { matchMacro } from './match.js';

function macro(id: string, triggers: string[], params: string[] = []): Macro {
  return {
    id,
    version: 1,
    triggers,
    app: 'com.apple.Preferences',
    risk: 'safe',
    params: Object.fromEntries(params.map((p) => [p, { type: 'string' as const, required: true }])),
    steps: [{ op: 'launch', bundleId: 'com.apple.Preferences', restart: true }],
    stats: { runs: 0, fails: 0, avgMs: 0 },
  } as Macro;
}

const library = [
  macro('open-about', ['아이폰 정보 보여줘']),
  macro('search', ['설정에서 {arg1} 검색해줘'], ['arg1']),
];

describe('matchMacro', () => {
  it('finds the route saved for this phrasing', () => {
    expect(matchMacro('아이폰 정보 보여줘', library)?.macro.id).toBe('open-about');
  });

  it('ignores trailing punctuation and doubled spaces', () => {
    // What someone types and what was saved differ in ways the words do not.
    expect(matchMacro('  아이폰   정보 보여줘!  ', library)?.macro.id).toBe('open-about');
  });

  it('captures what was said in a parameter slot', () => {
    const found = matchMacro('설정에서 손쉬운 사용 검색해줘', library);
    expect(found?.macro.id).toBe('search');
    expect(found?.args).toEqual({ arg1: '손쉬운 사용' });
  });

  it('returns nothing rather than guessing at a paraphrase', () => {
    // Loose matching here would route confidently to the wrong route, and a
    // miss costs one exploration — which is the thing that recovers from it.
    expect(matchMacro('정보 화면 열어봐', library)).toBeUndefined();
  });

  it('matches a parameterised trigger, which string equality never would', () => {
    // The CLI checked `trigger === utterance` to decide whether a route
    // existed. `설정에서 {arg1} 검색해줘` equals nothing anyone says, so every
    // macro with a parameter looked unsaved and was explored again.
    const trigger = library[1]?.triggers[0] as string;
    expect(trigger).toContain('{arg1}');
    expect(matchMacro('설정에서 화면 검색해줘', library)?.macro.id).toBe('search');
  });

  it('does not let a slot swallow the literal that follows it', () => {
    expect(matchMacro('설정에서 검색해줘', library)).toBeUndefined();
  });
});
