# 2026-09-08 — phase 01: 가짜 백엔드

## 왜 진짜 클라이언트보다 먼저

실기기를 붙이려면 WDA 설치, 개발자 서명(무료 계정은 7일마다 재설치), `iproxy` 세팅이 필요하다. 그걸 먼저 하면 **그 뒤 모든 개발이 기기 연결에 묶인다.** CI에서도 못 돌린다.

순서를 뒤집었다. 녹화된 화면을 재생하는 `Hands` 구현체를 먼저 만들면 위층(Brain, 매크로 리플레이, Repair)을 전부 기기 없이 개발할 수 있고, 실기기는 나중에 같은 인터페이스로 갈아끼우면 된다.

대가는 "진짜 폰이 움직이는" 순간이 뒤로 밀리는 것. 감수할 만하다고 봤다.

## 인터페이스를 먼저 못 박았다

가짜를 만들려면 뭘 흉내낼지가 먼저 정해져야 해서 `Hands` 인터페이스를 확정했다.

```ts
interface Hands {
  screen(): Promise<Screen>;
  find(sel, alt?): Promise<FindResult>;
  tap(sel, alt?): Promise<ActResult>;
  type(text, opts?): Promise<ActResult>;
  swipe(from, to, ms?): Promise<ActResult>;
  back(): Promise<ActResult>;
  launch(target): Promise<ActResult>;
  assert(sel, timeoutMs?): Promise<AssertResult>;
  health(): Promise<Health>;
  close(): Promise<void>;
}
```

두 가지를 의식적으로 넣고 뺐다.

**세션 복구는 인터페이스에 없다.** [ADR 0005](../adr/0005-session-recovery-in-infra.md)의 결정대로, WDA 세션이 죽는 건 인프라 문제지 작업의 일부가 아니다. 호출자가 신경 쓸 자리를 아예 안 만들었다.

**실패할 때 화면을 같이 돌려준다.** `ActResult`가 실패해도 `screen`을 싣는다. Repair가 바로 필요한 정보고, 따로 조회하면 이미 움직인 화면을 보게 된다. 실패 응답에 후속 조치에 필요한 걸 전부 담는 게 왕복도 줄이고 경합도 없앤다.

## 모든 상태 변화를 명시적 녹화 화면으로

가짜의 설계에서 제일 중요한 결정이었다.

처음엔 트리를 변형하는 걸 생각했다 — 검색창에 타이핑하면 그 요소의 `value`를 바꾸는 식으로. 그러면 픽스처 하나로 여러 상태를 만들 수 있다.

안 했다. **그러면 테스트가 보는 화면이 진짜 기기에서 나온 게 아니라 이 파일이 지어낸 게 된다.** 압축 로직이나 셀렉터 해석이 실제 트리에서만 나타나는 구조를 못 다루는 걸 놓치게 된다.

대신 상태마다 화면을 따로 녹화한다.

```
home  →(tap tab_search)→  search-empty  →(type)→  search-results  →(tap Hype Boy)→  playing
```

타이핑 전후가 다른 녹화 파일이다. 픽스처는 늘어나지만 전부 진짜 화면이다.

## 매칭되지 않는 액션은 실패가 아니다

이미 있는 탭을 다시 누르면? 아무 일도 안 일어난다. 그게 진짜 폰의 동작이다.

그래서 전이가 매칭 안 되면 화면을 그대로 두고 `ok: true`를 돌려준다. 실패로 만들면 "죽은 영역 탭"과 "셀렉터 미스"가 구분이 안 된다. 후자만 Repair를 부를 자격이 있다.

## 와일드카드 우선순위

`{ from: "*", back: true, to: "home" }` 같은 catch-all이 있으면, 파일 순서에 따라 구체적인 전이를 가려버릴 수 있다.

매칭된 후보 중 `from`이 `"*"`가 아닌 걸 먼저 고르게 했다. 픽스처 작성자가 순서를 신경 안 써도 된다.

## failNext

`hands.failNext('session-lost')`로 다음 호출 하나만 실패시킬 수 있다. 세션 복구와 Repair 경로를 기기 없이 테스트하려고 넣었다.

실패한 호출은 **상태를 바꾸지 않는다.** 액션이 일어나지 않은 것이므로. 이게 나중에 세션 슈퍼바이저의 멱등 재시도를 검증할 때 필요하다.

## 클론하면 바로 돌아간다

`npm run nubi -- demo`가 기기·API 키·네트워크 없이 경로 하나를 걸어간다.

```
✓ launch             home -> home
✓ tap 검색 탭           home -> search-empty
✓ type "뉴진스"         search-empty -> search-results
✓ tap Hype Boy       search-results -> playing
✓ assert 재생 중        playing -> playing

4 elements, ~99 tokens, hash f0209c5c237c
  Button       닫기
  StaticText   Hype Boy
  StaticText   NewJeans
  Button       일시정지
```

포폴 관점에서 이게 꽤 중요하다고 생각한다. "돌려볼 수 있는 repo"와 "영상만 있는 repo"는 다르다.

## 지금 상태

```
✓ WDA 파싱 · 트리 압축 · 화면 해시
✓ 셀렉터 해석 (5단계 + alt 폴백)
✓ Hands 인터페이스
✓ 가짜 백엔드 + 시나리오 4화면
✓ CLI 데모
✓ 테스트 58개
□ WDA HTTP 클라이언트     ← 기기 필요
□ 세션 슈퍼바이저
```

## 아직 모르는 것

가짜가 흉내내는 게 **내가 상상한 폰**이지 진짜 폰이 아니다. 픽스처를 손으로 썼기 때문에 실제 WDA 응답과 다를 수 있다.

실기기를 붙이면 제일 먼저 할 일은 **진짜 트리를 덤프해서 픽스처를 교체하는 것.** 그때 압축 규칙이나 `identifierOf` 가정이 틀렸다는 게 드러날 가능성이 높다. 그러라고 인터페이스를 먼저 고정해둔 거다 — 픽스처만 갈아끼우면 위층은 안 건드려도 된다.
