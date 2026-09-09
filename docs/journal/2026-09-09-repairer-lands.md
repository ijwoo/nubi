# 2026-09-09 — 복구자가 붙었고, 세는 게 없다는 걸 알았다

[자가치유 확인](2026-09-09-self-healing.md) 때 남겨둔 게 `ClaudeRepairer`였다. 인터페이스와 거절 규칙은 있었고 프롬프트가 없었다.

## 복구자에게 목표를 알려주지 않는다

계획자는 "다음에 뭘 할까"를 묻는다. 복구자는 **한 스텝에 대한 한 질문**을 받는다 — 이 화면에서 매크로가 의도했던 컨트롤이 어느 것인가.

그래서 프롬프트에 매크로의 `triggers`를 넣지 않았다. 목표를 아는 복구자는 스텝이 아니라 태스크를 풀기 시작하고, **즉흥적으로 만든 새 경로가 원래 경로인 것처럼 매크로에 저장된다.** 복구는 저장되기 때문에 이게 계획의 실수와 다르다.

주는 것: 깨진 셀렉터 원본(모양이 증거다 — 사라진 `id`와 사라진 `label`은 다른 이야기다), 앞뒤 스텝, 지금 화면. 도구는 둘, `found`와 `gone`.

```
- Say gone whenever you are guessing. A route that fails gets found again by
  exploration, which is slower and cheaper than a route that succeeds at the
  wrong thing.
```

## 위험 승급은 프롬프트로 안 막는다

복구는 "사라진 것과 가장 닮은 것"을 고른다. **닮음에는 결과에 대한 개념이 없다.** 재설계된 화면에서 사라진 `저장` 옆에 `삭제`가 있으면, 레이아웃상으로도 의미상으로도 그게 가장 가까운 후보다.

프롬프트에도 적었지만 거기서 끝내지 않았다.

```ts
export function escalatesRisk(broken: Selector, element: Element): boolean {
  const wasDangerous = isIrreversible(...);
  if (wasDangerous) return false;
  return isIrreversible(element.l, element.v, element.id);
}
```

한 방향이다. 원래 되돌릴 수 없던 스텝은 같은 종류로 복구돼도 된다 — [승인 게이트](../adr/0007-approval-gate-off-device.md)가 이미 앞에 있다. **안전했던 스텝이 그렇게 되는 것만 막는다.**

코드로 막는 이유는 복구가 저장되기 때문이다. 잘못된 계획은 런 하나를 버린다. 잘못된 복구는 **그 뒤의 모든 런을, 사람이 안 보는 동안, 이미 안전하다고 승인한 경로에서** 망친다.

위험 단어 목록은 매크로 추출이 쓰던 걸 `shared/risk.ts`로 옮겨 같이 쓴다. 두 곳이 같은 질문을 한다.

## 실기: 0/2 대 2/2

```
  복구 없음 (scripted)  0/2
  복구 있음 (replay)    2/2

  매크로  v1 → v2
  now  {"id":"com.apple.settings.accessibility"}
  alt  {"id":"com.apple.settings.accessibility.RENAMED"}
```

세 매크로 전부 됐다. `id`가 깨진 경우도, `label`+`type`이 깨진 경우도.

## $0.0000이 이상했다

첫 실행이 복구 비용을 **$0.0000**으로 찍었다. 모델을 불러놓고.

`ClaudeRepairer.suggest()`가 사용량을 반환하지 않았다. 계획자는 `PlanResult.usage`로 넘기고 `explore`가 트레이스에 기록하는데, 복구 경로에는 그게 없었다.

고치면서 반환 타입을 바꿨다.

```ts
export interface RepairResult {
  suggestion?: RepairSuggestion;
  usage?: ModelUsage;
}
```

`RepairSuggestion | undefined`가 아니라 이렇게 한 이유는 **거절도 호출 비용이 든다**는 것이다. 제안만 있을 때 기록하면, 모델에게 묻고 "없다"를 들은 런이 공짜로 잡힌다.

["재생은 $0"](../adr/0003-macro-replay-without-model.md)이 이 프로젝트의 구조적 주장인데, **그 예외가 복구다.** 예외를 안 재면 주장이 검증되는 게 아니라 그냥 반올림된다.

## 그리고 복구를 세는 지표가 없었다

비용을 고치고 나니 이번엔 `복구 0회`가 이상했다. 매크로는 v1에서 v2로 갔는데.

`recoveries`는 **WDA 세션 재생성** 수였다. 인프라가 자기를 복구한 횟수 — [설계상 보이지 않아야 하는 것](../adr/0005-session-recovery-in-infra.md)이다. 매크로 복구와 이름만 같고 정반대 개념이다. 매크로 복구는 저장된 경로를 바꾸므로 보이지 않으면 안 된다.

`repairs`를 따로 만들었다.

```
1런  $0.0069  모델 1회  복구 1회  14915ms
2런  $0.0000  모델 0회  복구 0회   8912ms
```

**자가치유가 이 프로젝트의 핵심 주장인데 그걸 세는 숫자가 없었다.** 지금까지는 매크로 파일을 열어보고 확인했다. 확인은 됐지만 집계는 안 됐고, 집계되지 않는 건 회귀를 못 잡는다.

## 배운 것

오늘 네 번째다. 숫자가 나오고, 그럴듯하고, 틀렸다.

다만 이번 둘은 앞의 셋과 종류가 다르다. [중복 집계](2026-09-09-counting-twice.md)와 [가짜 백엔드 0/5](2026-09-09-fake-covered-one-third.md), [Haiku 0/15](2026-09-09-tier-sweep.md)는 **잘못된 값**이었다. 이번 둘은 **없는 값**이다 — $0과 0회는 계기가 그 자리를 안 보고 있다는 뜻이었고, 0은 언제나 그럴듯하다.

없는 값이 더 오래 산다. 틀린 값은 언젠가 누가 이상하다고 느끼지만, 0은 아무도 안 쳐다본다.
