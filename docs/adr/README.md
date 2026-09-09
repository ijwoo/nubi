# Architecture Decision Records

되돌리기 어려운 결정과 그 이유를 남깁니다. **결정한 시점의 판단을 그대로** 두고, 나중에 생각이 바뀌면 새 ADR로 뒤집습니다. 기존 것을 고쳐 쓰지 않습니다.

| # | 제목 | 상태 |
| --- | --- | --- |
| [0001](0001-separate-public-repo.md) | pip-any가 아닌 별도 퍼블릭 저장소 | accepted |
| [0002](0002-ax-tree-over-screenshots.md) | 스크린샷이 아니라 접근성 트리를 기본 관찰로 | accepted |
| [0003](0003-macro-replay-without-model.md) | 재생 경로에서 모델을 완전히 제거 | accepted |
| [0004](0004-selector-priority.md) | 셀렉터 우선순위와 좌표를 최후에 두는 이유 | accepted |
| [0005](0005-session-recovery-in-infra.md) | 세션 복구를 인프라에 두고 모델에게 숨김 | accepted |
| [0006](0006-model-tiering.md) | 역할별 모델 분리 (Haiku 라우팅 / Opus 계획) | 일부 [0010](0010-planning-on-sonnet.md)으로 대체 |
| [0007](0007-approval-gate-off-device.md) | 승인 게이트를 조작 대상 기기 바깥에 | accepted |
| [0008](0008-detect-alerts-never-answer-them.md) | 시스템 알림은 감지하되 자동으로 답하지 않는다 | accepted |
| [0009](0009-runner-judges-not-executor.md) | 성공 판정은 러너가 하고 실행기는 하지 않는다 | accepted |
| [0010](0010-planning-on-sonnet.md) | 탐색 계획을 Sonnet으로 내린다 | accepted |

새로 쓸 때는 [template.md](template.md)를 복사하세요.
