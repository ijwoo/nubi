# Architecture

## 구성

```
Mac                                          iPhone
┌──────────────────────────────────┐
│  Orb        음성 입력 · 진행 표시  │
│   ↕ WebSocket                    │
│  Brain      라우팅 · 재생 · 복구  │       ┌────────────────┐
│   │         ↘ Anthropic API      │       │  WDA           │
│   │ (in-process)                 │       │  (XCUITest)    │
│   ↓                              │       │      ↓         │
│  Hands      WDA 클라이언트        │──USB─▶│  대상 앱       │
│             세션 복구             │       └────────────────┘
│             트리 압축             │
└──────────────────────────────────┘                ▲
              │                                     │
              └───── relay :8787 ──▶ 아이폰 앱에서 승인
```

## 왜 이 경계인가

### Hands는 서비스가 아니라 라이브러리

초기 스케치에서는 Hands를 별도 프로세스로 두고 Brain이 HTTP로 호출하게 했습니다. 크래시 격리가 이유였는데, v1에서는 과합니다. HTTP 레이어 하나가 통째로 늘어나는 대신 얻는 게 없습니다.

Hands는 라이브러리입니다. Brain이 in-process로 import 합니다. 별도로 **MCP 서버 어댑터**를 얇게 얹어서, 개발 중에 Claude Code가 직접 폰을 조작할 수 있게 합니다.

프로세스는 결국 이렇습니다.

| 프로세스 | 역할 |
| --- | --- |
| `nubi` | Brain. Hands를 import. CLI 진입점 |
| `nubi-mcp` | MCP 서버. 같은 Hands를 import. 개발·디버깅용 |
| Orb | SwiftUI 떠있는 창. Brain에 WebSocket으로 붙음 (phase 05) |
| relay | 기존 pip-any 서버. 승인·알림 채널 (외부) |

### Orb와 Brain은 분리

Brain은 헤드리스로도 돌아야 합니다. CLI 테스트, eval 러너, 나중의 스케줄 실행. 오브는 얼굴일 뿐이고, 없어도 전부 동작해야 합니다.

이 분리 덕에 phase 05 전까지 UI 없이 진도를 뺄 수 있습니다.

### 세션 복구는 Hands 안에서 끝난다

WDA 세션은 자주 죽습니다. 앱 전환, 백그라운드 진입, 타임아웃에서요.

이 복구를 Brain이나 모델이 알면 안 됩니다. Hands가 모든 호출을 감싸서 세션 상태를 확인하고, 죽었으면 재생성하고 마지막 액션을 멱등 재시도합니다. 위에서 보기엔 그냥 성공한 호출입니다.

자세한 이유는 [ADR 0005](adr/0005-session-recovery-in-infra.md).

### 시스템 알림은 감지하되 답하지 않는다

iOS의 권한 요청 같은 시스템 알림은 **앱의 접근성 트리에 나타나지 않는다.** 트리는 평범한 화면을 보여주는데 모든 터치가 흡수된다.

`Screen`에 `alert` 필드를 두고 관찰할 때마다 확인한다. 터치 액션은 알림이 있으면 `blocked-by-alert`로 실패하는데, **`no-match`와 구분하는 게 핵심이다** — 컨트롤은 있고 셀렉터도 찾았다. 이걸 셀렉터 문제로 보고하면 Repair가 멀쩡한 셀렉터를 고치러 간다.

자동으로 답하지 않는 이유는 [ADR 0008](adr/0008-detect-alerts-never-answer-them.md).

### 승인은 조작 대상 바깥에서

위험한 액션의 승인을 아이폰 화면에서 받으면 안 됩니다. 그 화면은 지금 자동화가 점유하고 있고, 원리적으로 에이전트가 자기 승인 창을 누를 수 있습니다.

승인은 **별도 채널**로 나갑니다. relay를 통해 아이폰 앱의 Live Activity로 가고, 사람이 다이나믹 아일랜드에서 누릅니다. WDA가 건드리지 않는 표면입니다.

자세한 이유는 [ADR 0007](adr/0007-approval-gate-off-device.md).

## 데이터 흐름

```
발화
 └─▶ Brain.route()          매크로 매칭 + 파라미터 추출
      ├─ hit  ─▶ Brain.replay(macro)
      │            └─ 스텝마다: Hands.find() → Hands.tap()
      │                 └─ miss ─▶ Brain.repair() ─▶ 매크로에 패치 저장
      └─ miss ─▶ Brain.explore()
                   └─ 루프: Hands.screen() → 모델 → Hands.act()
                        └─ 성공 ─▶ 매크로 추출 ─▶ 사용자 승인 ─▶ 저장

모든 스텝 ─▶ Trace 기록 (JSONL)
위험 스텝 ─▶ relay ─▶ 아이폰 승인 대기
```

## 저장소 구조

```
src/
├── hands/     WDA 클라이언트 · 세션 복구 · 트리 압축 · 셀렉터 해석 · 가짜 백엔드
├── trace/     JSONL 기록 · 계측 데코레이터 · 요약
├── eval/      태스크 정의 · 실행기 · 러너 · 집계
├── brain/     라우팅 · 재생 · 복구 · 탐색 루프          (phase 03~)
├── macro/     궤적에서 매크로 추출 · 자가치유            (phase 04)
└── shared/    타입 · 스키마

macros/        매크로 라이브러리 (*.json, 커밋됨)
bin/           진입점 — nubi, nubi-mcp
scripts/       wda.sh · live-check.ts · record.ts · eval.ts
traces/        런 기록 (커밋 안 함)
```

### 명령

| | 기기 | 하는 일 |
| --- | --- | --- |
| `npm test` | 불필요 | 순수 로직 + 가짜 백엔드 |
| `npm run wda` | 시뮬레이터 | WebDriverAgent 빌드·실행 |
| `npm run live` | 필요 | 계약 + 액션을 실기에 검증 |
| `npm run record -- settings` | 필요 | 앱을 걸어다니며 시나리오 녹화 |
| `npm run eval` | 필요 | 태스크 실행 + 측정 |
| `npm run eval -- --fake` | 불필요 | 녹화 화면으로 태스크 실행 |
| `npm run nubi -- demo` | 불필요 | 녹화된 경로 재생 데모 |


## 두 구현이 같은 계약을 지키는지 확인하는 법

`FakeHands`와 `WdaHands`는 같은 인터페이스를 구현한다. **하지만 인터페이스가 같다고 동작이 같지는 않다** — TypeScript는 모양을 검사하지 실행 결과를 검사하지 않는다. 실기는 성공하는데 가짜는 미스를 반환하는 구현도 타입은 통과한다.

그래서 계약을 `src/hands/contract.ts`에 vitest와 무관한 순수 함수 배열로 두고, 두 곳에서 돌린다.

```
npm test    → CONTRACT 를 FakeHands 에 (CI)
npm run live → 같은 CONTRACT 를 WdaHands 에 (기기 필요)
```

정의가 하나라서 조용히 어긋날 수 없다.

계약은 **두 구현이 정직하게 약속할 수 있는 것만** 검사한다. 특정 앱의 화면 전환 지식이 필요한 건 각 구현의 자체 테스트로 간다.

### reset이 필요한 이유

계약 케이스마다 `ctx.reset()`을 먼저 부른다. 인터페이스로는 안 드러나는 차이가 있어서다 — **가짜는 케이스마다 새로 만들어지고, 기기는 기억한다.**

실제로 처음 실기에 돌렸을 때 4개가 실패했다. 앞선 액션 검증이 설정 앱을 검색 결과 화면에 남겨놨고, `launch`는 이미 실행 중인 앱을 포그라운드로 올릴 뿐 초기 화면으로 되돌리지 않았기 때문이다. 계약 위반이 아니라 시작 상태 문제였다.

그래서 `launch`에 `restart` 옵션이 생겼다. 매크로가 "앱의 첫 화면부터 시작"을 원할 때도 필요한 것이라, 계약 때문에 억지로 넣은 게 아니다.
