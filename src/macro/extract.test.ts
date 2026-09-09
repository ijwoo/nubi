import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { RouteStep } from '../brain/index.js';
import { loadTask } from '../eval/task.js';
import type { Element, Screen } from '../shared/types.js';
import { deriveAssertion, extractMacro } from './extract.js';

const task = loadTask(
  fileURLToPath(new URL('../eval/tasks/settings-open-accessibility.yaml', import.meta.url)),
);

const extract = (route: RouteStep[], goal = '설정에서 손쉬운 사용 열어줘') =>
  extractMacro(route, {
    id: 'extracted',
    goal,
    app: task.setup.bundleId,
    assert: { selector: task.assert.selector, withinMs: task.assert.withinMs },
  });

const tap = (sel: RouteStep['selector'], why = ''): RouteStep => ({
  action: { kind: 'tap', element: 0, why },
  ...(sel ? { selector: sel } : {}),
});

describe('extractMacro — shape', () => {
  const macro = extract([tap({ id: 'com.apple.settings.accessibility' })]);

  it('opens the app itself, from its own first screen', () => {
    // In use nothing else guarantees the app is running, and `restart` is what
    // makes starting from a known place mean anything.
    expect(macro.steps[0]).toEqual({
      op: 'launch',
      bundleId: 'com.apple.Preferences',
      restart: true,
    });
  });

  it('carries the task assertion into the macro', () => {
    // Otherwise a replay reports success for having performed the steps rather
    // than for having achieved anything.
    expect(macro.steps.at(-1)).toMatchObject({
      op: 'assert',
      sel: { id: 'ACCESSIBILITY_PLACARD' },
    });
  });

  it('keeps the selectors the route resolved, not the element numbers', () => {
    // Indices only mean something on the screen they came from.
    expect(macro.steps[1]).toEqual({ op: 'tap', sel: { id: 'com.apple.settings.accessibility' } });
  });

  it('produces something the schema accepts, so it can be saved and reloaded', () => {
    expect(macro.version).toBe(1);
    expect(macro.stats.runs).toBe(0);
  });
});

describe('extractMacro — actions other than tapping', () => {
  it('keeps typed text, which a tap-only route would silently drop', () => {
    const macro = extract([
      tap({ type: 'SearchField', label: '검색' }),
      { action: { kind: 'type', text: 'abc', submit: true, why: '' } },
    ]);
    expect(macro.steps[2]).toEqual({ op: 'type', text: 'abc', submit: true });
  });

  it('records a swipe as the same points the explore loop used', () => {
    const macro = extract([{ action: { kind: 'swipe', direction: 'up', why: '' } }]);
    expect(macro.steps[1]).toMatchObject({ op: 'swipe', from: [0.5, 0.7], to: [0.5, 0.3] });
  });

  it('records going back', () => {
    const macro = extract([{ action: { kind: 'back', why: '' } }]);
    expect(macro.steps[1]).toEqual({ op: 'back' });
  });

  it('leaves out done and stuck, which end a run rather than being part of it', () => {
    const macro = extract([tap({ id: 'a' }), { action: { kind: 'done', why: '' } }]);
    expect(macro.steps).toHaveLength(3); // launch, tap, assert
  });
});

describe('extractMacro — parameters', () => {
  it('pulls out text the person said and the model typed', () => {
    // "설정에서 손쉬운 찾아줘" and "설정에서 카메라 찾아줘" are one route with
    // a word changed.
    const macro = extract(
      [
        tap({ type: 'SearchField', label: '검색' }),
        { action: { kind: 'type', text: '손쉬운', submit: false, why: '' } },
      ],
      '설정에서 손쉬운 찾아줘',
    );

    expect(macro.steps[2]).toMatchObject({ text: '{{arg1}}' });
    expect(macro.params.arg1).toEqual({ type: 'string', required: true });
    expect(macro.triggers[0]).toBe('설정에서 {arg1} 찾아줘');
  });

  it('leaves typing the person never asked for as a literal', () => {
    // Text the model chose on its own is part of the route, not an input to it.
    const macro = extract(
      [{ action: { kind: 'type', text: 'zzz', submit: false, why: '' } }],
      '설정 열어줘',
    );
    expect(macro.steps[1]).toMatchObject({ text: 'zzz' });
    expect(Object.keys(macro.params)).toHaveLength(0);
  });
});

describe('extractMacro — risk', () => {
  it('treats an ordinary route as safe', () => {
    expect(extract([tap({ label: '일반' })]).risk).toBe('safe');
  });

  it.each([
    ['label', { label: '결제하기' }],
    ['label', { label: '삭제' }],
    ['labelContains', { labelContains: '전송' }],
    ['identifier', { id: 'checkout_button' }],
  ])('asks first when the route touched something irreversible (%s)', (_kind, sel) => {
    // Judged from the control that was tapped rather than from the request:
    // the label is the closest thing to evidence of what the step does.
    expect(extract([tap(sel as RouteStep['selector'])]).risk).toBe('confirm');
  });

  it('does not flag a word that is merely common', () => {
    // "확인" appears on half the screens in existence; flagging it would make
    // every macro ask, and a prompt that always appears stops being read.
    expect(extract([tap({ label: '확인' })]).risk).toBe('safe');
  });
});

describe('deriveAssertion', () => {
  const el = (i: number, t: string, l?: string, id?: string): Element => ({
    i,
    t,
    r: [0, i * 44, 393, 44],
    e: true,
    ...(l === undefined ? {} : { l }),
    ...(id === undefined ? {} : { id }),
  });
  const screen = (elements: Element[]): Screen => ({
    app: 'com.apple.Preferences',
    elements,
    size: { w: 393, h: 852 },
    hash: 'h',
    capturedAt: '2026-09-09T00:00:00.000Z',
  });

  it('picks an identifier that only the destination has', () => {
    const start = screen([el(0, 'Button', '일반', 'settings.general')]);
    const final = screen([
      el(0, 'Button', '뒤로'),
      el(1, 'StaticText', 'iOS 버전', 'SW_VERSION_SPECIFIER'),
    ]);
    expect(deriveAssertion({ start, final })).toEqual({ id: 'SW_VERSION_SPECIFIER' });
  });

  it('ignores a control that was already there before anything happened', () => {
    // Asserting on it would pass having run none of the steps — an assertion
    // that cannot fail is worse than none, because it looks like one.
    const shared = el(0, 'Button', '뒤로', 'nav.back');
    const start = screen([shared, el(1, 'Button', '일반')]);
    const final = screen([shared, el(1, 'StaticText', '정보', 'about.title')]);
    expect(deriveAssertion({ start, final })).toEqual({ id: 'about.title' });
  });

  it('falls back to a label, but only one that is unique on the screen', () => {
    const start = screen([el(0, 'Button', '일반')]);
    const final = screen([
      el(0, 'Cell', '항목'),
      el(1, 'Cell', '항목'),
      el(2, 'StaticText', '텍스트 지우기'),
    ]);
    expect(deriveAssertion({ start, final })).toEqual({
      label: '텍스트 지우기',
      type: 'StaticText',
    });
  });

  it('does not settle for the back button, which every detail screen has', () => {
    // The first live run produced exactly this: BackButton is new, stable, and
    // present on every screen in Settings, so a macro asserting on it passes
    // for having navigated anywhere at all.
    const start = screen([el(0, 'Button', '손쉬운 사용', 'com.apple.settings.accessibility')]);
    const final = screen([
      el(0, 'Button', '뒤로', 'BackButton'),
      el(1, 'StaticText', '손쉬운 사용', 'ACCESSIBILITY_PLACARD'),
    ]);
    expect(
      deriveAssertion({ start, final, arrivedVia: { id: 'com.apple.settings.accessibility' } }),
    ).toEqual({
      id: 'ACCESSIBILITY_PLACARD',
    });
  });

  it('prefers the element that shares a word with the control tapped to get here', () => {
    // Both are new and neither is chrome; the one naming the destination is
    // the one the tapped control named too.
    const start = screen([el(0, 'Button', '일반')]);
    const final = screen([
      el(0, 'StaticText', '기타', 'MISC_GROUP'),
      el(1, 'StaticText', '손쉬운 사용', 'ACCESSIBILITY_PLACARD'),
    ]);
    expect(
      deriveAssertion({ start, final, arrivedVia: { id: 'com.apple.settings.accessibility' } }),
    ).toEqual({
      id: 'ACCESSIBILITY_PLACARD',
    });
  });

  it('still answers when nothing relates to the tap, rather than refusing', () => {
    const start = screen([el(0, 'Button', '일반')]);
    const final = screen([el(0, 'StaticText', '정보', 'ABOUT_TITLE')]);
    expect(
      deriveAssertion({ start, final, arrivedVia: { id: 'com.apple.settings.general' } }),
    ).toEqual({
      id: 'ABOUT_TITLE',
    });
  });

  it('does not settle for a keyboard key, which any typing brings up', () => {
    // The second live run produced {id:"shift"}: new, stable, and present on
    // every screen with a keyboard up. It proves the field took focus, not
    // that anything was typed into it.
    const start = screen([el(0, 'SearchField', '검색')]);
    const final: Screen = {
      ...screen([
        el(0, 'Button', '텍스트 지우기', 'clear'),
        { ...el(1, 'Button', 'shift', 'shift'), r: [0, 698, 40, 44] },
      ]),
      keyboard: { top: 600 },
    };
    expect(deriveAssertion({ start, final })).toEqual({ id: 'clear' });
  });

  it('does not assert on text that quotes what was typed', () => {
    // Searching for 손쉬운 left `‘손쉬운’에 대한 결과 없음` — new, specific,
    // and true only of the run that produced it. The typed word is the part a
    // parameter replaces, so an assertion quoting it breaks on the next call.
    const start = screen([el(0, 'SearchField', '검색')]);
    const final = screen([
      el(0, 'StaticText', '‘손쉬운’에 대한 결과 없음'),
      el(1, 'Button', '텍스트 지우기', 'clear'),
    ]);
    expect(deriveAssertion({ start, final, typed: ['손쉬운'] })).toEqual({ id: 'clear' });
  });

  it('names a control rather than quoting an empty-state sentence', () => {
    // `맞춤법을 확인하거나...` is true of a search that found nothing and
    // false of one that found something, so it holds for one argument only.
    const start = screen([el(0, 'SearchField', '검색')]);
    const final = screen([
      el(0, 'StaticText', '맞춤법을 확인하거나 새로운 검색을 시도하십시오.'),
      el(1, 'Button', '텍스트 지우기'),
    ]);
    expect(deriveAssertion({ start, final })).toEqual({ label: '텍스트 지우기', type: 'Button' });
  });

  it('prefers what the last action produced over what the run produced', () => {
    // Live: typing into search offered `닫기`, the field's own close button.
    // Measured from the start of the run it looks like an achievement; against
    // the screen the typing acted on, it was already there.
    const start = screen([el(0, 'SearchField', '검색')]);
    const focused = screen([el(0, 'SearchField', '검색'), el(1, 'Button', '닫기')]);
    const final = screen([
      el(0, 'SearchField', '검색'),
      el(1, 'Button', '닫기'),
      el(2, 'Button', '텍스트 지우기'),
    ]);

    expect(deriveAssertion({ start, final })).toEqual({ label: '닫기', type: 'Button' });
    expect(deriveAssertion({ start, final, beforeLastAction: focused })).toEqual({
      label: '텍스트 지우기',
      type: 'Button',
    });
  });

  it('refuses when the two screens cannot be told apart', () => {
    // A route whose end looks like its beginning has nothing to prove it
    // worked, and extraction should fail rather than invent something weaker.
    const same = screen([el(0, 'Button', '일반', 'settings.general')]);
    expect(deriveAssertion({ start: same, final: same })).toBeUndefined();
  });
});
