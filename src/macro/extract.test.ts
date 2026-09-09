import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { RouteStep } from '../brain/index.js';
import { loadTask } from '../eval/task.js';
import { extractMacro } from './extract.js';

const task = loadTask(
  fileURLToPath(new URL('../eval/tasks/settings-open-accessibility.yaml', import.meta.url)),
);

const extract = (route: RouteStep[], goal = '설정에서 손쉬운 사용 열어줘') =>
  extractMacro(route, { id: 'extracted', task, goal });

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
