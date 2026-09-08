# Eval Design

## 왜 필요한가

이 프로젝트의 주장은 "학습하면 빨라진다"입니다. 주장은 증명해야 합니다.

그리고 순서가 중요합니다 — **매크로를 만들기 전에 측정 인프라가 있어야** 합니다. 매크로를 먼저 만들면 "학습 전" 숫자를 잴 기회가 영영 사라집니다. 그래서 eval이 phase 02, 매크로가 phase 04입니다.

## 태스크 정의

```yaml
# src/eval/tasks/yt-music-play.yaml
id: yt-music-play
prompt: "유튜브 뮤직에서 뉴진스 틀어줘"

setup:
  app: com.google.ios.youtubemusic
  state: home          # 실행 전 앱을 홈 상태로 되돌림

assert:
  - selector: { label: "일시정지" }    # 재생 중이면 이 버튼이 뜬다
    within_ms: 30000

modes: [cold, warm]     # cold = Explore, warm = Replay
runs: 5                 # 모드당 반복
```

`setup.state`가 중요합니다. 매 실행 전 앱을 같은 상태로 되돌리지 않으면 두 번째 실행이 첫 번째 덕을 봅니다.

## 측정 항목

| 항목 | 단위 | 출처 |
| --- | --- | --- |
| 성공률 | % | assert 통과 비율 |
| 소요 시간 | ms (p50 / p95) | 벽시계 |
| 모델 호출 | 회 | trace |
| 입력 / 출력 토큰 | 개 | API usage |
| 비용 | USD | 토큰 × 모델 단가 |
| 스텝 수 | 개 | trace |
| Repair 발동 | 회 | trace |

**p50과 p95를 같이 봅니다.** 평균만 보면 가끔 5분 걸리는 걸 놓칩니다. 실사용에서 짜증나는 건 p95입니다.

## 실행

```bash
npm run eval                      # 전체
npm run eval -- --task yt-music   # 하나만
npm run eval -- --mode warm       # 재생만
```

출력은 두 가지 — 사람이 볼 마크다운 표, 기계가 볼 JSON.

```
                    cold              warm
─────────────────────────────────────────────────
success             4/5  (80%)        5/5  (100%)
p50                 measuring         measuring
p95                 measuring         measuring
model calls         21.4 avg          0
input tokens        118k avg          0
cost / run          measuring         $0
```

## 리포트를 어디에 두나

- **원시 결과**는 커밋하지 않습니다 (`.gitignore`의 `eval-results/`). 기기 상태·네트워크에 따라 흔들리는 값이라 diff가 무의미합니다.
- **큐레이션된 스냅샷**은 `docs/benchmarks/`에 날짜와 함께 커밋합니다. README 표가 여기서 나옵니다.
- 스냅샷에는 **측정 조건을 반드시 같이** 적습니다. 기기, iOS 버전, 앱 버전, 네트워크, 모델 ID. 이게 없으면 숫자가 재현 불가능하고, 재현 불가능한 숫자는 포폴에서 오히려 마이너스입니다.

## 정직성 규칙

1. **추측한 숫자를 쓰지 않습니다.** 안 재본 건 "측정 예정"입니다.
2. **실패한 실행을 빼지 않습니다.** 성공률은 전체 실행 기준입니다.
3. **구조적 사실과 측정값을 구분합니다.** "재생 시 모델 호출 0회"는 코드를 보면 확인되는 사실이고, "재생이 11초"는 측정값입니다. 표에서 둘을 섞지 않습니다.
4. **측정 조건을 항상 붙입니다.**

## 결정적 테스트

실기기 eval은 느리고 흔들립니다. CI에서 돌릴 수 없습니다.

그래서 별도로, **녹화된 트리 시퀀스를 리플레이하는** 결정적 테스트를 둡니다. 실제 세션에서 캡처한 트리를 픽스처로 저장하고 Hands를 가짜 백엔드로 물리면, 셀렉터 해석·매크로 리플레이·Repair 로직을 기기 없이 검증할 수 있습니다.

```
src/eval/fixtures/       녹화된 트리 시퀀스
src/hands/fake.ts        픽스처를 재생하는 Hands 구현
```

CI는 이걸 돌립니다. 실기기 eval은 수동으로, 릴리스 전에.
