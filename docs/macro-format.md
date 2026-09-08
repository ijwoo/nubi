# Macro Format

매크로는 **한 번 찾아낸 경로**입니다. `macros/*.json`에 저장되고 git으로 추적됩니다.

## 스키마

```json
{
  "id": "yt-music-play",
  "version": 3,
  "triggers": [
    "유튜브 뮤직에서 {artist} 틀어줘",
    "{artist} 재생"
  ],
  "app": "com.google.ios.youtubemusic",
  "risk": "safe",
  "params": {
    "artist": { "type": "string", "required": true }
  },
  "steps": [
    { "op": "launch", "url": "youtubemusic://" },
    { "op": "tap",    "sel": { "id": "search" }, "alt": { "label": "검색" } },
    { "op": "type",   "text": "{{artist}}", "submit": true },
    { "op": "tap",    "sel": { "index": { "type": "Cell", "n": 0 } } },
    { "op": "assert", "sel": { "label": "일시정지" }, "timeout": 10000 }
  ],
  "stats": {
    "runs": 47,
    "fails": 2,
    "avgMs": 11200,
    "lastRun": "2026-09-08T04:12:00Z",
    "healedAt": "2026-09-01T22:03:00Z"
  }
}
```

## 필드

| 필드 | 설명 |
| --- | --- |
| `id` | 파일명과 일치. 안정적이어야 함 |
| `version` | Repair가 패치할 때마다 증가 |
| `triggers` | 라우팅에 쓰이는 발화 패턴. `{param}`으로 파라미터 위치 표시 |
| `app` | 번들 ID. 실행 전 확인용 |
| `risk` | `safe` / `confirm` / `blocked` |
| `params` | 파라미터 스키마 |
| `steps` | 실행 스텝 배열 |
| `stats` | 실행 통계. 신뢰도 판단에 사용 |

## risk

| 값 | 동작 |
| --- | --- |
| `safe` | 바로 실행 |
| `confirm` | 실행 전 relay를 통해 아이폰 승인 요청 |
| `blocked` | 실행 거부. 사람이 직접 해야 하는 것 |

결제·삭제·전송·외부 발신은 자동으로 `confirm` 이상이 됩니다. 매크로 추출 단계에서 해당 동작이 감지되면 사람이 `safe`로 낮출 수 없게 합니다.

## 스텝 연산

| `op` | 인자 | 설명 |
| --- | --- | --- |
| `launch` | `url` 또는 `bundleId` | 앱 실행. URL 스킴 우선 |
| `tap` | `sel`, `alt?` | 요소 탭. `alt`는 1차 폴백 |
| `type` | `text`, `submit?` | 텍스트 입력 |
| `swipe` | `from`, `to`, `duration?` | 스와이프 |
| `back` | — | 뒤로 |
| `wait` | `ms` | 고정 대기. **최후의 수단** — 가능하면 `assert`를 쓸 것 |
| `assert` | `sel`, `timeout` | 조건 충족까지 폴링. 성공 판정에도 사용 |

`wait`을 쓰지 않는 게 원칙입니다. 고정 대기는 느린 기기에서 깨지고 빠른 기기에서 시간을 낭비합니다. `assert`로 조건을 기다리세요.

## 파라미터

`{{param}}` 형태로 스텝 안에 치환됩니다. 치환은 문자열 값에만 적용되고, 셀렉터 구조 자체는 바꾸지 않습니다.

```json
{ "op": "type", "text": "{{artist}}" }
{ "op": "assert", "sel": { "labelContains": "{{artist}}" } }
```

## stats와 자동 강등

매 실행마다 갱신됩니다. 실패율이 임계치를 넘으면 라우터가 그 매크로를 건너뛰고 Explore로 보냅니다.

```
fails / runs > 0.3  &&  runs >= 5   →  강등
```

썩은 매크로가 조용히 계속 실패하는 걸 막습니다. 강등된 매크로는 지우지 않고 남겨두고, Explore가 새 경로를 찾으면 교체합니다.

## 수명주기

```
Explore 성공
   ↓
궤적에서 매크로 추출 (Opus)
   ↓
사용자 확인 — 이름, 파라미터로 뺄 것
   ↓
macros/*.json 저장                    version: 1
   ↓
Replay로 반복 사용                     stats 누적
   ↓
앱 업데이트로 셀렉터 깨짐
   ↓
Repair가 고쳐서 되씀                   version: 2, healedAt 갱신
   ↓
계속 사용
```

매크로 파일은 **커밋합니다.** 프로젝트의 실제 산출물이고, 시간에 따라 어떻게 치유됐는지 git 히스토리에 남습니다. 그 히스토리 자체가 블로그 소재입니다.
