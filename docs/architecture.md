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
├── hands/     WDA 클라이언트 · 세션 슈퍼바이저 · 트리 압축 · 셀렉터 해석
├── brain/     라우팅 · 재생 · 복구 · 탐색 루프
├── macro/     스키마 · 리플레이 엔진 · 궤적에서 매크로 추출
├── eval/      태스크 정의 · 러너 · 리포트
├── trace/     JSONL 기록 · 뷰어
└── shared/    타입 · 설정 · 로깅

macros/        매크로 라이브러리 (*.json, 커밋됨)
bin/           진입점
```
