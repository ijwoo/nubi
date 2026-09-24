# 폰 클라이언트

[슬라이스 1 — 빠른 모드](../docs/ios-client-slices.md#슬라이스-1--빠른-모드) 입니다. **맥도 relay 도 없이 폰 혼자 돕니다.** 엔진 코드(`src/`)에 의존하지 않습니다.

## 지금 되는 것

| | 어디서 | 모델을 쓰는가 |
| --- | --- | --- |
| 오늘·내일·이번 주 일정 조회 | 앱, 음성, 잠금화면 버튼 | **안 씁니다** |
| 미리알림 추가 | 앱, 음성 | **안 씁니다** |
| 그 밖의 질문 | 앱, 음성 | 씁니다 (Haiku 급) |
| 답을 잠금화면에서 읽기 | Live Activity | — |

**일정과 미리알림에 모델을 부르지 않는 것**이 이 슬라이스의 성격입니다. 일정 세 건을 읽어주는 데 왕복 1 초를 쓸 이유가 없고, API 키가 없어도 비행기 모드여도 그 둘은 돌아야 합니다. 의도 판별도 코드가 합니다 — 맥의 Router 와 같은 규칙입니다.

## 스파이크가 정한 것

[잠금화면 스파이크](../docs/benchmarks/2026-09-24-lockscreen-spike.md)에서 나온 규칙이 코드에 그대로 박혀 있습니다.

| 규칙 | 어디에 |
| --- | --- |
| 확장은 권한을 요청하지 않는다 — 요청하면 대화상자 없이 거부로 굳는다 | `Shared/Events.swift` |
| 권한은 앱이 받는다 | `App/NubiApp.swift` 의 설정 화면 |
| 확장이 잠금 상태에서 EventKit 에 닿는다 | `Shared/TodayIntent.swift` |
| TestFlight 에는 콘솔이 없다 — App Group 기록이 유일한 출구다 | `Shared/NubiLog.swift` |

그 기록이 빌드 1 에서 바로 값을 했습니다. 잠금화면 버튼이 일정은 읽는데 화면에는
아무것도 안 떴고, 기록에만 이유가 있었습니다.

```
[활동] 시작 실패 … Target does not include NSSupportsLiveActivities plist key
[오늘] 오늘 추석 (종일) — 42ms
```

**`NSSupportsLiveActivities` 는 앱에만 두면 부족합니다.** 잠금화면 버튼은 확장
프로세스에서 `Activity.request` 를 부르고, 그 타깃의 Info.plist 를 봅니다. 앱에서
띄울 때는 멀쩡하기 때문에 앱만 써보면 드러나지 않습니다.

## API 키

**저장소에 들어가지 않습니다.** 앱 설정 화면에서 붙여넣으면 키체인에 저장됩니다 ([ADR 0001](../docs/adr/0001-separate-public-repo.md)). 빌드에 넣으면 `.ipa` 안에 들어갑니다.

확장과 공유하지 않습니다. 키가 필요한 것은 앱의 자유 질문뿐이고, 잠금화면 버튼은 EventKit 만 씁니다.

## 빌드

서명 자료도 저장소 밖입니다. 환경변수로 받습니다.

```bash
cd ios/Nubi
NUBI_TEAM_ID=... NUBI_BUILD=1 NUBI_SIGN_ID=... xcodegen generate
```

TestFlight 배포는 [플레이북](../docs/ops-testflight.md)에 있습니다. 구성별로 서명이 갈립니다 — Debug 는 자동(Xcode 로 폰에 직접 꽂는 경로), Release 는 수동 + 이름 붙은 프로파일(archive).

## 아직 없는 것

작업 모드입니다. relay 도, 맥과의 페어링도, 승인 게이트도 없습니다 — [슬라이스 2](../docs/ios-client-slices.md#슬라이스-2--작업-모드) 이고, 그 앞에 조작 폰 준비가 있습니다.
