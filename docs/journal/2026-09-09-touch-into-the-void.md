# 2026-09-09 — 탭이 성공하는데 아무 일도 안 일어났다

## 증상

`WdaHands`에 액션 6개(tap/type/swipe/back/launch/assert)를 붙이고 실기 검증을 돌렸다.

```
✓ launch
✓ tap resolves and acts  일반
✗ tap changed the screen  4718990ac133 → 4718990ac133
✗ assert waits for the new screen  waited 5309ms
✓ back returns
✓ back landed on the list again
✓ type into the focused field
✗ typed text appears on screen
```

HTTP는 전부 200이다. 좌표도 맞다 — `일반` 버튼 rect가 `x16 y293 w370 h52`니까 중심은 (201, 319). WDA는 `{"value": null}`로 성공을 돌려준다. 그런데 화면 해시가 그대로다.

## 세 갈래로 좁혔다

**좌표가 틀렸나?** 트리에서 rect를 직접 뽑아 curl로 W3C actions를 쐈다. 무반응.

**엔드포인트가 문제인가?** 구형 `/wda/tap`으로도 해봤다. 무반응. WDA 정석 경로인 `/element` 조회 후 `/element/{id}/click`까지 해봤다. 무반응.

**터치 주입 자체가 죽었나?** `/wda/dragfromtoforduration`으로 스크롤을 해봤다. 트리 해시가 안 변했다. **모든 터치가 안 먹는다.** 읽기는 완벽한데.

시뮬레이터가 4개 부팅돼 있어서 엉뚱한 기기를 조작하나 싶었다. `ps`로 확인하니 WDA 러너는 `4B5AA487`에 붙어 있었다. 맞는 기기다.

Simulator.app이 안 떠서 그런가 싶었다 — 헤드리스로는 접근성 서버는 살아있지만 HID 파이프라인이 없을 수 있으니까. `pgrep`으로 보니 pid 670으로 멀쩡히 실행 중이었다. 콘솔 로그인 세션도 있다.

## 화면을 찍어봤다

```
xcrun simctl io 4B5AA487... screenshot /tmp/shot.png
```

<!-- 홈 화면 위에 모달: "'지도' 앱이 사용자의 위치를 사용하도록 허용하겠습니까?" -->

**시스템 권한 알림이 떠 있었다.** 아까 지도 앱 트리를 뜨려고 세션을 만들었을 때 나온 위치 권한 요청이, 그 뒤로 계속 화면을 덮고 있었다. 모든 터치를 흡수하면서.

## 진짜 문제는 알림이 아니었다

알림 자체는 `POST /alert/accept` 한 번으로 닫힌다. 30초짜리 문제다.

진짜 문제는 이거다. **알림이 떠 있는 동안에도 `/source`는 설정 앱의 정상적인 트리를 반환했다.**

```
✓ reports the foreground app  com.apple.Preferences
✓ returns elements  16
✓ every element is addressable
```

에이전트 입장에서는 완벽하게 평범한 화면이다. 버튼도 다 보이고, 셀렉터도 다 찾아진다. 탭도 "성공"한다. 그런데 아무 일도 안 일어난다.

이 상태에서 내 설계가 하는 일을 생각해봤다. 탭이 성공했는데 화면이 안 변하면 → 다음 스텝의 `assert`가 실패 → **Repair가 발동해서 멀쩡한 셀렉터를 고치러 간다.** 고쳐도 안 되니 또 실패하고, 3연속 실패로 중단. Opus 호출을 몇 번 태우고 나서 "셀렉터를 못 찾겠다"고 보고할 것이다.

원인은 셀렉터가 아닌데.

## 고친 방식

`Screen`에 `alert` 필드를 추가하고, 관찰할 때마다 확인한다. WDA에 전용 엔드포인트가 있었다.

```
GET  /session/{id}/alert/text          → 알림 본문
GET  /session/{id}/wda/alert/buttons   → ["한 번 허용", "앱을 사용하는 동안 허용", "허용 안 함"]
POST /session/{id}/alert/accept        → {"name": "허용 안 함"}
```

터치 계열 액션(tap/type/swipe)은 알림이 떠 있으면 `blocked-by-alert`로 실패한다. **`no-match`와 구분하는 게 핵심이다.** 컨트롤은 거기 있고 셀렉터도 찾았다. 모달이 터치를 먹고 있을 뿐이다. 이걸 셀렉터 문제로 보고하면 Repair가 잘못된 곳을 고치러 간다.

## 자동으로 닫지 않기로 했다

가장 쉬운 구현은 알림이 뜨면 자동으로 첫 번째 버튼을 누르는 것이다. 그러면 이 문제가 영원히 안 보인다.

안 했다. 알림이 묻는 건 **위치 권한 허용, 알림 권한 허용, 삭제 확인** 같은 것들이다. 전부 되돌릴 수 없고, 사용자 계정에 영향을 준다. 자동 수락은 [ADR 0007](../adr/0007-approval-gate-off-device.md)이 승인 게이트를 둔 이유 그 자체를 위반한다.

`answerAlert(button)`은 버튼 이름을 명시해야 하는 별도 액션이다. 트레이스에 남고, 나중에 `risk: confirm`으로 게이트를 걸 수 있다.

## 관찰 비용이 늘었다

`screen()`마다 알림 확인 요청이 하나 더 붙는다. 관찰 요청이 두 배다.

받아들이기로 했다. 모달을 못 보는 대가가 훨씬 크다 — 방금 그 대가를 직접 치렀다.

## 검증

알림을 닫고 다시 돌렸다.

```
✓ tap changed the screen  4718990ac133 → 5e4b8307857c
✓ assert waits for the new screen  waited 563ms
✓ back landed on the list again  waited 675ms
✓ typed text appears on screen
✓ assert times out rather than hanging  waited 1739ms
```

전부 통과.

가짜 백엔드에도 `showAlert()`를 붙여서 이 경로를 CI에서 검증한다. 실기 없이 "알림이 탭을 막는다", "알림은 자동으로 안 닫힌다", "없는 버튼은 못 누른다"를 테스트할 수 있다.

## 배운 것

**성공 응답이 성공을 뜻하지 않는다.** WDA는 터치를 정상적으로 전달했다. 전달받은 쪽이 다른 곳이었을 뿐이다.

그리고 이건 픽스처로는 절대 못 찾았다. 트리는 완벽하게 정상이었으니까. 화면을 눈으로 봐야만 보이는 종류의 버그였다 — `simctl io screenshot` 한 번이 세 갈래 디버깅보다 빨랐다.

앞으로 실기 검증에서 "액션이 성공했는데 상태가 안 변했다"가 나오면 **먼저 화면을 찍어보는 것**을 기본으로 한다.
