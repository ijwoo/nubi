# 2026-09-09 — 가짜 백엔드는 셋 중 하나만 돌리고 있었다

포커스 문제를 고치고 회귀를 보려고 가짜 백엔드를 돌렸다.

```
settings-open-about          scripted  0/5
settings-open-accessibility  scripted  5/5
settings-search-open         scripted  0/5
```

내 변경 때문인 줄 알고 `git stash`로 확인했다. **변경 전에도 똑같았다.** 실기가 5/5라 계속 가려져 있었다.

## 왜 못 갔나

기록된 전환은 이랬다.

```
root       --tap accessibility-->  accessibility
accessibility  --back-->           root-again
root-again --tap general-->        general
general    --back-->               root-third
```

매크로는 이렇게 간다.

```
settings-open-about:  launch → tap general → tap About
settings-search-open: launch → tap 검색 → type
```

`launch`는 `root`에 놓는다. **`root`에서 나가는 전환은 accessibility 하나뿐이다.** general로 가는 전환은 `root-again`에서만 출발한다. About 화면과 검색 화면은 아예 기록에 없다.

레코더가 accessibility 경로만 걷고 있었다. 나머지 둘은 매크로만 있고 기록이 없었다.

## 0/5는 잘못된 신호다

여기가 진짜 문제다. 경로가 없으면 가짜가 못 움직이고, 러너는 그걸 **실패**로 센다. `0/5`는 "매크로가 깨졌다"와 글자 하나 다르지 않다. 기록이 없다는 사실은 아무 데도 안 나온다.

숫자가 있으면 검증되고 있다고 믿게 된다. **없는 것보다 나쁜 종류의 숫자였다.**

## 같은 화면을 세 번 기록하고 있었다

`root`, `root-again`, `root-third`. 상세로 들어갔다 나오면 원래 화면이지 새 화면이 아닌데, 레코더는 매번 새 이름으로 썼다. 걸어간 순서를 그대로 적었을 뿐 그래프가 아니었다.

해시로 중복을 접었다.

```
general-back  = general
root-back-2   = root-back
```

7개 화면, 8개 전환. 그런데 `root`와 `root-back`은 **안 접힌다.**

```
root 에만:       (없음)
root-back 에만:  Button com.apple.settings.passcodeAndBiometrics "암호" @825
```

돌아올 때 목록이 한 줄만큼 더 스크롤돼서 아래에 행 하나가 더 걸린다. [처음 기록할 때](2026-09-09-recorded-scenarios.md) 이미 본 현상이다. 실기가 그렇게 동작하니 해시로는 못 접는다.

## 탭 전환의 from을 넓혔다

```ts
const key = move.back
  ? { from: current, back: true }
  : move.type !== undefined
    ? { from: current, type: true }
    : { from: '*', tap: ... };
```

**탭은 어느 화면에서든, 뒤로가기와 입력은 기록된 화면에서만.**

넓혀도 잃는 게 없는 이유가 있다. 가짜는 전환을 따르기 전에 **셀렉터를 지금 화면에서 먼저 해석하고**, 없으면 `no-match`로 거절한다. `from`은 같은 문에 걸린 두 번째 자물쇠였다. 반대로 뒤로가기와 입력은 어디서 출발했는지가 도착지를 결정하므로 그대로 뒀다.

같은 컨트롤이 화면마다 다른 데로 가면 넓힌 `from`이 구별 못 하니, 레코더가 그 경우 기록을 거부한다.

```ts
if (clash) {
  console.error(`  ✗ "${edge.tap}" already goes to ${clash.to}, now ${edge.to}`);
  process.exit(1);
}
```

## 결과

```
settings-open-about          scripted  5/5
settings-open-accessibility  scripted  5/5
settings-search-open         scripted  5/5
```

`macros/`의 세 경로가 전부 오프라인에서 돈다. 테스트도 하나 박았다 — **매크로가 요구하는 화면에 실제로 도달하는지**를 계약 테스트로 검사한다. 경로를 빼먹으면 이제 0/5가 아니라 테스트가 깨진다.

기록된 검색 화면에는 키보드가 그대로 실려 있다.

```
search-focused    14 elements  0fbaf8770520  +키보드
search-results    11 elements  db0108f6ce27  +키보드
```

원시 트리를 저장하고 읽을 때 압축하니까, 이 비트는 시나리오 파일이 주장하는 값이 아니라 키가 진짜로 거기 있어야만 나온다.

## 덤으로 하나

레코더는 JSON을 압축해서 쓰는데 커밋된 픽스처는 정렬돼 있었다. 누군가 `biome check --write`로 한 번 밀어놓은 것이고, **기록할 때마다 포매터가 깨지는 상태**였다. 레코더가 처음부터 정렬해서 쓰도록 바꿨다.

## 배운 것

가짜 백엔드는 실기가 없을 때 도는 안전망인데, 실기가 잘 돌면 **안전망이 찢어진 걸 알 방법이 없다.** 두 백엔드로 같은 케이스를 돌리는 이유가 이건데, 한쪽이 조용히 0을 뱉는 동안 다른 쪽 5/5만 보고 있었다.

**어떤 실패는 실패로 보이지만 실은 부재다.** 둘을 구별할 수 없는 지표는 그만큼 덜 유용하다.
