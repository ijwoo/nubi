# 스파이크를 TestFlight 로 올리기

스파이크는 **잠금화면**에서만 답이 나옵니다. 그런데 잠금화면 동작을 보려면 Xcode 를 떼야 하고, Xcode 를 떼면 콘솔이 없습니다. TestFlight 로 받으면 케이블도 콘솔도 없이 폰만 들고 확인할 수 있습니다 — 그래서 앱 안의 [기록 화면](../spikes/LockScreenSpike/README.md)이 유일한 출구입니다.

업로드 자체는 **새로 만들지 않았습니다.** pip-any 의 `scripts/release.sh` 가 xcodegen → archive → export → altool 을 이미 합니다. 거기에 `APP` / `PROJECT_DIR` / `EXPORT_PLIST` / `BUILD` 만 붙여 다른 프로젝트도 태울 수 있게 했고, 인자를 안 주면 PiPAny 는 이전과 한 바이트도 다르지 않습니다.

```
APP=LockScreenSpike \
PROJECT_DIR=../nubi/spikes/LockScreenSpike \
EXPORT_PLIST=build-signing/exportOptions-spike.plist \
NUBI_TEAM_ID=… SPIKE_BUILD=1 BUILD=1 scripts/release.sh
```

**서명 자료는 pip-any 에 남습니다.** 이 저장소는 공개이고, 팀 ID·API 키·export 설정이 들어갈 수 없습니다 ([ADR 0001](adr/0001-separate-public-repo.md)). 이 문서에는 식별자와 절차만 적습니다.

## 플레이북에 없던 것

PiPAny 에도 위젯 확장이 있어서 **확장 타깃 자체는 새롭지 않았습니다.** 확장마다 번들 ID 와 App Store 프로파일이 따로 필요한 것도 이미 그렇게 돼 있었습니다. 스파이크에서 처음 나온 것은 셋입니다.

| | 무엇 | PiPAny 는 왜 겪지 않았나 |
| --- | --- | --- |
| 1 | **App Group** — 두 타깃이 공유하는 컨테이너 | PiPAny 는 App Group 을 아예 쓰지 않습니다. 확인함: `bundleIdCapabilities` 에 `IN_APP_PURCHASE` 하나뿐 |
| 2 | **자동 서명이 이 맥에서는 안 됨** | PiPAny 는 처음부터 이름 붙은 수동 프로파일을 씁니다 |
| 3 | **배포 인증서가 두 장** | PiPAny 프로파일에는 쓰는 한 장이 들어 있습니다 |

### 1. App Group 은 API 로 만들 수 없다

App Store Connect API 에 **App Group 엔드포인트가 없습니다.** 직접 확인했습니다 — `GET /v1/appGroups` 는 `404 NOT_FOUND / The path provided does not match a defined resource type` 입니다.

API 로 되는 데까지는 다음과 같습니다.

- `POST /v1/bundleIds` — 번들 ID 생성. **됨**
- `POST /v1/bundleIdCapabilities` (`APP_GROUPS`) — 기능 켜기. **됨**
- `POST /v1/profiles` — App Store 프로파일 생성. **됨**

여기까지 하고 프로파일을 열어보면 `application-groups` 키는 있는데 **배열이 비어 있습니다.** 그룹이 존재하지도, 번들 ID 에 붙지도 않았기 때문입니다. 그 상태로 archive 하면 이렇게 끝납니다.

```
error: Provisioning profile "NubiSpike_AppStore" doesn't support the
       group.dev.jaewoo.nubispike App Group.
```

**그룹을 만들고 붙이는 것만 사람이 해야 합니다.** 아래 체크리스트 1 번입니다.

### 2. 이 맥에는 Xcode 계정이 없다

`-allowProvisioningUpdates` 는 이미 `release.sh` 에 들어 있었지만, 실제로는 한 번도 쓰인 적이 없습니다. 스파이크를 자동 서명으로 태우자 드러났습니다.

```
error: No Accounts: Add a new account in Accounts settings.
DVTDeveloperAccountManager: Invalid credentials in keychain … missing Xcode-Username
```

ASC API 키를 `-authenticationKeyPath` 로 넘겨도 `Authentication failed` 입니다. 같은 키로 `asc.mjs` 는 잘 도는데도 그렇습니다.

**자동 서명은 접었습니다.** 어차피 자동 서명이 됐어도 App Group 은 못 만듭니다. PiPAny 와 같은 수동 프로파일로 맞췄습니다. 다만 Xcode 로 폰에 직접 꽂는 경로는 살려야 해서, 설정을 구성별로 나눴습니다.

| 구성 | 서명 | 쓰는 곳 |
| --- | --- | --- |
| Debug | Automatic | Xcode 에서 폰에 직접 설치 |
| Release | Manual + 이름 붙은 프로파일 | archive → TestFlight |

### 3. 배포 인증서가 두 장이다

키체인에 `Apple Distribution: Jae Woo Im` 이 두 장 있습니다. `CODE_SIGN_IDENTITY` 가 이름만 가리키면 Xcode 는 **둘 중 하나를 고르고**, 프로파일에 그 장이 없으면 이렇게 됩니다.

```
error: Provisioning profile "NubiSpike_AppStore" doesn't include
       signing certificate "Apple Distribution: Jae Woo Im (…)".
```

프로파일을 만들 때 **두 장을 다 넣습니다.** 프로파일은 수정이 안 되므로 지우고 다시 만듭니다 — 어차피 App Group 을 붙인 뒤 한 번 더 만들어야 합니다.

## 내가 한 것

| | 상태 |
| --- | --- |
| 번들 ID `dev.jaewoo.nubispike` | 생성 |
| 번들 ID `dev.jaewoo.nubispike.widget` | 생성 |
| 두 번들 ID 에 `APP_GROUPS` 기능 | 켬 |
| 프로파일 `NubiSpike_AppStore` / `NubiSpike_Widget_AppStore` | 생성 (App Group 이 빈 채) |
| 프로파일 로컬 설치 | 완료 |
| `project.yml` 구성별 서명 | 반영 |
| `exportOptions-spike.plist` (pip-any) | 작성 |
| `release.sh` 파라미터화 | 완료 |

## 내가 못 하는 것 — 직접 해야 하는 단계

### 1. App Group 만들고 붙이기 (이게 막고 있는 것)

[developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers/list/applicationGroup)

1. [ ] **Identifiers › App Groups › +** → Description `Nubi Spike`, Identifier `group.dev.jaewoo.nubispike`
2. [ ] **Identifiers › App IDs › `dev.jaewoo.nubispike`** → App Groups 옆 **Edit** → 방금 만든 그룹 체크 → Save
3. [ ] **`dev.jaewoo.nubispike.widget`** 에도 똑같이

2·3 번을 빠뜨리면 그룹은 있는데 프로파일은 여전히 빈 배열입니다. **기능을 켜는 것과 그룹을 고르는 것은 다른 동작입니다.**

### 2. App Store Connect 앱 등록

`altool --upload-app` 은 앱 레코드가 없으면 거절합니다. 그리고 **앱 생성은 ASC API 에 없습니다** — 웹에서만 됩니다.

[appstoreconnect.apple.com/apps](https://appstoreconnect.apple.com/apps) → **+ › 새로운 앱**

| 칸 | 값 |
| --- | --- |
| 플랫폼 | iOS |
| 이름 | `Nubi Spike` (계정 안에서 안 겹치면 됩니다) |
| 기본 언어 | 한국어 |
| 번들 ID | `dev.jaewoo.nubispike` — 1 번을 먼저 해야 목록에 뜹니다 |
| SKU | `nubispike` |
| 사용자 액세스 | 전체 액세스 |

**심사에 제출하지 않습니다.** 내부 테스트는 심사 없이 바로 설치됩니다.

### 3. 내부 테스터 그룹

1. [ ] TestFlight 탭 → **내부 테스팅 › +** → 그룹 이름 `내부`
2. [ ] 본인 계정을 테스터로 추가
3. [ ] 빌드가 처리되면(보통 5~15 분) 그 그룹에 붙이기

### 4. 폰에서

1. [ ] iPhone 18 Pro 에 **TestFlight** 설치, 같은 Apple 계정으로 로그인
2. [ ] 초대 메일의 링크로 Spike 설치
3. [ ] [README 의 A / B 체크리스트](../spikes/LockScreenSpike/README.md) 진행
4. [ ] 기록 화면에서 **전체 복사** 또는 **결과 내보내기**

## 1 번이 끝나면 남는 일

프로파일을 다시 만들고(그룹 + 인증서 두 장), 다시 설치하고, `release.sh` 를 돌리는 것까지입니다. 빌드 1 번으로 올립니다.

## 치운 뒤

스파이크가 끝나면 [치우기 절차](../spikes/LockScreenSpike/README.md#치우기) 와 함께 **계정에서도 지웁니다.**

1. [ ] ASC 에서 `Nubi Spike` 앱 삭제
2. [ ] 프로파일 둘 삭제
3. [ ] 번들 ID 둘 삭제
4. [ ] App Group `group.dev.jaewoo.nubispike` 삭제

**여기 적힌 세 가지 발견은 남깁니다.** 슬라이스 1 이 실기기로 나갈 때 같은 벽을 다시 만납니다 — 그때는 App Group 도 확장도 진짜입니다.
