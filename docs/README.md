# Nubi 문서

저장소의 모든 문서는 한국어로 씁니다. 코드 주석과 커밋 메시지는 영어입니다 — 코드를 읽는 사람과 문서를 읽는 사람이 다르고, 오픈소스 저장소의 코드 표면은 영어가 표준이기 때문입니다.

이 폴더는 두 가지를 담습니다. **왜 이렇게 만들었는지**(설계·ADR), 그리고 **실제로 뭐가 일어났는지**(journal).

## 설계

| 문서 | 내용 |
| --- | --- |
| [overview.md](overview.md) | 문제 정의, 접근, 이 프로젝트가 주장하는 것 |
| [architecture.md](architecture.md) | 구성 요소와 경계 |
| [execution-paths.md](execution-paths.md) | route / replay / repair / explore |
| [macro-format.md](macro-format.md) | 매크로 스키마와 수명주기 |
| [selector-strategy.md](selector-strategy.md) | 요소를 찾는 방법과 우선순위 |
| [eval-design.md](eval-design.md) | 무엇을 어떻게 측정하는가 |
| [real-device.md](real-device.md) | 시뮬레이터가 아닌 진짜 아이폰에서 돌리기 |

## 기록

- [adr/](adr/) — 되돌리기 어려운 결정과 그 이유. 결정된 시점의 판단을 그대로 남깁니다.
- [journal/](journal/) — 단계별 작업 기록. 안 된 것, 바꾼 것, 왜 바꿨는지.
- [benchmarks/](benchmarks/) — 측정 조건과 함께 커밋한 실측 스냅샷.

## 두 기록의 차이

ADR은 **결론**입니다. "무엇을 골랐고 왜 골랐나." 나중에 그 결정을 뒤집으려는 사람이 읽습니다.

journal은 **과정**입니다. "뭘 해봤고 어디서 막혔고 어떻게 돌아갔나." 결론만 남으면 사라지는 정보가 여기 남습니다.

둘 다 없으면 6개월 뒤의 내가 같은 실수를 반복합니다.
