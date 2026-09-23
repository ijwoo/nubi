# 온디바이스 이식 조사

맥 없이 아이폰 단독으로 도는 앱으로 옮길 수 있는가. 조사와 설계만 담습니다 — 코드는 없습니다.

결론부터: **엔진의 절반은 그대로 옮길 수 있고, 절반은 옮길 수 없습니다.** 옮길 수 없는 쪽이 하필 이 프로젝트의 이름값을 하는 부분(화면을 보고 누르는 것)입니다.

## 1. 모듈 인벤토리

| 모듈 | 분류 | 근거 |
| --- | --- | --- |
| `src/shared/types.ts` | **로직 그대로** — Swift 포팅 필요 | zod 스키마와 순수 타입. `Macro`·`Step`·`Selector`·`Screen`·`isDemoted`. Codable + 검증 코드로 1:1 대응 |
| `src/shared/risk.ts` | **로직 그대로** — Swift 포팅 필요 | 단어 목록 + `isIrreversible`. 순수 문자열 판정 |
| `src/macro/match.ts` | **로직 그대로** — Swift 포팅 필요 | 정규식 매칭뿐. `Hands` 를 임포트하지 않음 |
| `src/macro/store.ts` | **로직 그대로** — Swift 포팅 필요 | 임시파일+rename, 통계, 강등. 파일 API 만 다름 |
| `src/macro/extract.ts` | **개념만** | `deriveAssertion` 이 `Screen` 의 요소 좌표·식별자에 기대고 있음. intent 실행에는 "화면"이 없어 검증 기준의 의미 자체가 달라짐 |
| `src/macro/repair.ts`·`claude-repairer.ts` | **개념만** | 셀렉터를 고치는 일. intent 세계에는 셀렉터가 없고 "파라미터가 안 맞음"이 대응물 |
| `src/gate/` | **로직 그대로** — Swift 포팅 필요 | `verdictFor`·`reasonsToAsk`·기본값 거절. `TerminalGate` 만 맥 전용이고 인터페이스는 그대로 |
| `src/judge/judge.ts` | **로직 그대로** — Swift 포팅 필요 | 인터페이스와 `TrustingJudge`. `Hands` 비의존 |
| `src/judge/claude-judge.ts` | **개념만** | 프롬프트는 화면 렌더링(`renderScreen`)을 전제. intent 결과를 판정하려면 입력이 화면이 아니라 실행 결과가 됨 |
| `src/trace/trace.ts`·`summary.ts`·`cost.ts` | **로직 그대로** — Swift 포팅 필요 | JSONL 기록, 집계, 단가표. 파일 API 만 다름 |
| `src/trace/traced-hands.ts` | **개념만** | `Hands` 의 11개 메서드를 감싸는 데코레이터. 실행기가 바뀌면 감쌀 표면이 바뀜 |
| `src/eval/runner.ts`·`task.ts` | **로직 그대로** — Swift 포팅 필요 | 시도 반복, 판정, 집계. `hands.assert` 한 곳만 실행기에 닿음 |
| `src/eval/executor.ts` | **개념만** | `Executor.run(hands, ...)` 시그니처가 `Hands` 를 박아둠. 3장이 이걸 푸는 제안 |
| `src/brain/prompt.ts` | **개념만** | 화면을 모델에게 보여주는 렌더러. intent 목록을 보여주는 것으로 대체 |
| `src/brain/explore.ts`·`claude-planner.ts` | **개념만** | 관찰→계획→행동 루프. 구조는 같고 어휘(탭/입력/스와이프)가 통째로 바뀜 |
| `src/hands/**` (8파일) | **맥 전용 유지** | WDA HTTP 클라이언트, 접근성 트리 압축, 셀렉터 해석. 아래 2장 참조 |
| `src/macro/replay.ts` | **맥 전용 유지** | 스크롤 탐색, 도달 가능 판정, 복구 승급 — 전부 화면 좌표 위에서 성립 |
| `scripts/wda.sh`·`record.ts`·`report.ts` | **맥 전용 유지** | xcodebuild·iproxy·스크린샷 |

**요약**: 15개 중 8개가 포팅 가능(스키마·매칭·저장소·게이트·판정 인터페이스·트레이스·러너), 5개는 개념만, 3개 묶음은 맥에 남습니다.

## 2. 제약 검증

### 확인됨 — 서드파티 앱은 다른 앱 UI를 조작할 수 없다

[Apple 플랫폼 보안 문서](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)가 명시합니다: 서드파티 앱은 샌드박스에 갇히고, 자기 것 외의 정보에 접근하려면 **OS가 명시적으로 제공하는 서비스를 통해서만** 가능합니다. 접근성 API 를 통한 타 앱 제어는 그 서비스에 없습니다.

**Hands / Explore / Replay 는 단독 이식 불가**가 맞습니다.

### 확인됨 — 실행 수단은 App Intents / 단축어 / URL 스킴

[App Intents](https://developer.apple.com/documentation/appintents)가 앱 기능을 Siri·단축어·Spotlight·위젯·제어 센터에 노출합니다. `AppEntity`·`EntityQuery`·`AppShortcutsProvider` 가 프레임워크의 실제 구성입니다.

**다만 중요한 반박이 있습니다.** 앱 A 가 앱 B 의 App Intent 를 **프로그램적으로 직접 부를 수 없습니다.** 조합은 단축어 앱이 하고, 서드파티 앱이 할 수 있는 것은 `shortcuts://run-shortcut?name=…` 같은 [URL 스킴](https://support.apple.com/guide/shortcuts/intro-to-url-schemes-apd621a1ad7a/ios)으로 **단축어 앱을 띄우는 것**입니다.

즉 "온디바이스 intent 조합 에이전트"는 실제로는 **단축어를 만들고 실행시키는 앱**이 되고, 스텝마다 앱 전환이 눈에 보입니다. 이건 설계의 전제를 바꿉니다.

### 확인됨 — ReplayKit Broadcast Extension 메모리 약 50MB

[여러 보고](https://developer.apple.com/forums/thread/651367)가 50MB 하드 리밋과 초과 시 jetsam 종료를 일치해서 말합니다. iPad 는 프레임이 커서 더 쉽게 넘깁니다.

**다만 관찰 수단으로는 부적합합니다.** ReplayKit 이 주는 것은 **픽셀**이지 접근성 트리가 아닙니다. 이 프로젝트가 [ADR 0002](adr/0002-ax-tree-over-screenshots.md)에서 스크린샷을 버린 이유(토큰 1/1000, 셀렉터로 적을 수 있음)가 그대로 되살아납니다. 화면을 "볼" 수는 있어도 **누를 수는 없으므로** 관찰만 가능한 눈이고, 그 눈으로 할 수 있는 일이 없습니다.

### 확인됨 — Live Activity 4KB, 잠금화면 버튼

푸시 페이로드는 `aps` 래퍼 포함 4KB 이고, ContentState 는 ID 만 담고 본문은 앱이 복원하는 것이 권장됩니다. iOS 26 의 Live Activity 는 [App Intent 버튼](https://swiftcrafted.dev/article/live-activities-dynamic-island-ios-26-swiftui-activitykit-guide)을 지원해 잠금 상태에서 동작합니다.

**승인 게이트 용도로는 충분합니다.** 게이트가 보내야 할 것은 "무엇을 누르는가" 한 줄과 예/아니오뿐이라 4KB 안에 들어갑니다.

### 미확인

- `LiveActivityIntent` 와 일반 `AppIntent` 의 차이, 그리고 잠금화면에서 **앱을 깨우지 않고** 처리되는 범위
- 단축어 실행이 사용자 확인 없이 완주하는 조건 (자동화 종류·"실행 전 묻기" 설정)
- App Intents 로 노출된 **타 앱의** intent 를 단축어 앱을 거치지 않고 열거할 수 있는지

## 3. Executor 경계 제안

지금 경계가 잘못 그어져 있는 곳은 한 군데입니다.

```ts
// 현재 — src/eval/executor.ts
export interface Executor {
  readonly name: string;
  run(hands: Hands, task: Task, trace: Trace): Promise<boolean>;
}
```

`Hands` 가 시그니처에 박혀 있어서, 화면이 없는 실행기는 이 인터페이스를 만족할 수 없습니다. 반면 **Router·Judge·Trace 는 이미 `Hands` 를 모릅니다** — `match.ts` 는 `Macro` 만, `judge.ts` 는 `Screen` 만, `trace.ts` 는 파일 API 만 씁니다. 바꿀 곳이 적습니다.

제안:

```ts
/** 실행기가 무엇 위에서 도는지. 실행기만 이 타입의 실체를 안다. */
export interface Surface {
  readonly kind: 'screen' | 'intent';
  health(): Promise<Health>;
  close(): Promise<void>;
}

export interface ScreenSurface extends Surface {   // = 현재 Hands
  readonly kind: 'screen';
  screen(): Promise<Screen>;
  tap(sel: Selector, alt?: Selector): Promise<ActResult>;
  // … 나머지 9개
}

export interface IntentSurface extends Surface {
  readonly kind: 'intent';
  /** 이 기기에서 실행 가능한 것들. AppEntity 로 노출되는 목록. */
  catalogue(): Promise<IntentDescriptor[]>;
  run(id: string, params: Record<string, string>): Promise<IntentResult>;
}

export interface Executor<S extends Surface = Surface> {
  readonly name: string;
  run(surface: S, task: Task, trace: Trace): Promise<Outcome>;
}

/** 실행기가 남기는 것. 지금의 boolean 을 넓힌 것. */
export interface Outcome {
  claimed: boolean;
  /** 판정자가 볼 것. 화면이거나, 실행 결과이거나. */
  evidence: { kind: 'screen'; screen: Screen } | { kind: 'intent'; results: IntentResult[] };
}
```

**판정자 시그니처도 같이 넓혀야 합니다.** 지금은 `verdict(goal, screen)` 인데 intent 세계에는 화면이 없습니다:

```ts
verdict(goal: string, evidence: Outcome['evidence']): Promise<Verdict>;
```

**러너가 실행기 종류를 모르게 하려면 한 곳만 더 고치면 됩니다.** `runner.ts` 가 판정을 위해 `hands.assert(...)` 를 직접 부르는데(현재 유일한 실행기 의존), 그것도 `Surface` 에 맡기거나 `Outcome.evidence` 로 대체합니다.

**게이트는 손댈 필요가 없습니다.** `ApprovalRequest` 는 이미 `utterance` + `reasons: string[]` 이고 `macro` 는 선택입니다. intent 이름을 `reasons` 에 넣으면 그대로 동작합니다.

## 4. 최소 수직 슬라이스

제안된 순서를 그대로 두되, 두 가지를 조정합니다.

1. **매크로를 `AppEntity` 로 노출** — `MacroStore` 를 Swift 로 포팅하고 `EntityQuery` 를 붙입니다. 정확 매칭은 유지합니다(라우터는 기준선 목적).
2. **App Shortcut / Control 위젯이 진입점** — "누비로 〈매크로〉 실행" 문구 하나.
3. **`IntentExecutor`** — 매크로의 스텝을 intent 호출로 해석. **이 슬라이스에서는 자체 앱의 intent 만** 대상으로 합니다(아래 이유).
4. **Live Activity 진행 표시** — ContentState 는 매크로 id + 스텝 인덱스만. 4KB 안에 여유롭습니다.
5. **결과** — `Outcome` 을 기록하고 Live Activity 를 닫습니다.

### Judge 는 넣습니다

**빼면 이 슬라이스가 무엇을 증명했는지 말할 수 없습니다.** 실행기가 "했다"고 하면 그대로 성공이 되는 상태로 돌아가는데, 그건 [ADR 0009](adr/0009-runner-judges-not-executor.md)가 금지한 것이고 실제로 한 번 물린 적이 있습니다(유튜브 뮤직에서 재생을 안 누르고 done).

단, intent 세계의 판정은 화면이 아니라 **실행 결과**를 봅니다. `IntentResult` 가 성공/실패와 반환값을 주므로 모델 없이 시작할 수 있고, 그게 `TrustingJudge` 보다 훨씬 나은 기준선입니다.

### relay 는 뺍니다

**하이브리드를 첫 슬라이스에 넣으면 무엇이 되는지 알 수 없게 됩니다.** relay 를 붙이는 순간 "intent 로 되는 일"과 "맥으로 넘긴 일"이 섞이고, 온디바이스 단독으로 어디까지 가능한지가 이 조사의 질문인데 그 답이 흐려집니다.

먼저 자체 앱 intent 만으로 슬라이스를 닫고, **"intent 로 안 되는 것 목록"이 실제로 무엇인지** 본 뒤에 relay 를 붙일지 정하는 편이 낫습니다.

## 5. 이 조사가 바꾸는 전제

원 제안은 "온디바이스 intent 조합 에이전트"였습니다. 조사 결과 **조합의 주체가 될 수 없습니다** — 타 앱 intent 를 직접 부를 수 없고, 단축어 앱을 URL 로 띄우는 것이 한계입니다.

그래서 현실적인 형태는 셋 중 하나입니다.

| | 무엇 | 대가 |
| --- | --- | --- |
| **자체 앱 intent 에이전트** | 내 앱의 기능만 조합. Siri·단축어·위젯에서 호출 | "아무 앱이나"를 포기. 이 프로젝트의 원래 주장이 사라짐 |
| **단축어 생성기** | 매크로를 단축어로 내보내고 URL 로 실행 | 스텝마다 앱 전환이 보임. 사용자가 단축어를 직접 고칠 수 있다는 장점 |
| **하이브리드** | 위 둘 + 안 되는 것은 relay 로 맥에 | 맥 의존이 남음. 원래 목표("맥 없이")와 정면으로 충돌 |

## 6. 결정이 필요한 것

1. **"아무 앱이나"를 포기할 수 있는가.** 온디바이스 단독은 자체 앱 intent 로 좁혀집니다. 그러면 nubi 의 원래 주장([overview](overview.md)의 "아이폰은 아무 방법도 없다")이 성립하지 않습니다 — 다른 제품이 됩니다.

2. **맥 엔진을 남기는가 버리는가.** 남기면 하이브리드고 "맥 없이"가 아닙니다. 버리면 실기기에서 검증한 것들(45런, 자가치유, 스크롤)이 포폴 기록으로만 남습니다.

3. **단축어 앱 경유의 앱 전환을 허용하는가.** 스텝마다 화면이 튀는 것을 사용자 경험으로 받아들일 수 있는지에 따라 2안의 가치가 갈립니다.

4. **Swift 포팅의 범위.** 8개 모듈을 옮기는 것은 사실상 재작성 분량입니다. TypeScript 엔진을 온디바이스에서 굴릴 방법(JavaScriptCore)을 먼저 재볼 가치가 있는지.

5. **ADR 0011 을 지금 쓸 것인가.** 위 1·2 가 정해지기 전에는 "결정"이 아니라 "조사 결과"입니다. 이 문서가 그 역할을 하고, 방향이 정해지면 ADR 로 올리는 편이 [ADR 규약](adr/README.md)("결정한 시점의 판단을 그대로 둔다")에 맞습니다.
