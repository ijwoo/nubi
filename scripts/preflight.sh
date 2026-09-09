#!/usr/bin/env bash
# Check everything a real-device run needs, before spending a build on it.
#
# A device build fails in places a simulator build cannot: an unpaired phone,
# Developer Mode off, no signing identity, no iproxy. Each surfaces as a wall
# of xcodebuild output several minutes in. This asks the same questions in two
# seconds, and says what to do about each answer.
#
#   scripts/preflight.sh
set -uo pipefail

ok=0
bad=0
pass() { printf '\033[32m✓\033[0m %s\n' "$*"; ok=$((ok + 1)); }
fail() { printf '\033[31m✗\033[0m %s\n' "$*"; bad=$((bad + 1)); }
hint() { printf '    %s\n' "$*"; }

echo
echo "실기기 사전점검"
echo

# --- Mac side -------------------------------------------------------------

if xcodebuild -version >/dev/null 2>&1; then
  pass "Xcode  $(xcodebuild -version | head -1)"
else
  fail "Xcode 없음"
  hint "App Store 에서 설치하고 'sudo xcode-select -s /Applications/Xcode.app'"
fi

TEAM="${NUBI_TEAM_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"Apple Develop.*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -1)}"
if [[ -n "$TEAM" ]]; then
  pass "서명 팀  $TEAM"
else
  fail "코드 서명 인증서 없음"
  hint "Xcode > Settings > Accounts 에서 Apple ID 추가 (무료 계정도 됩니다)"
fi

if command -v iproxy >/dev/null; then
  pass "iproxy  $(command -v iproxy)"
else
  fail "iproxy 없음"
  hint "brew install libimobiledevice"
  hint "기기의 8100 포트를 맥으로 넘겨주는 도구라, 없으면 에이전트가 죽은 것처럼 보입니다"
fi

# --- Phone side -----------------------------------------------------------

DEVICES="$(xcrun xctrace list devices 2>/dev/null \
  | awk '/^== Devices ==/{d=1;next} /^== Devices Offline ==|^== Simulators ==/{d=0} d' \
  | grep -v 'Mac')"
UDID="$(printf '%s\n' "$DEVICES" | sed -n 's/.*(\([0-9A-Fa-f-]\{25,\}\)).*/\1/p' | head -1)"

if [[ -n "$UDID" ]]; then
  pass "아이폰  $(printf '%s\n' "$DEVICES" | head -1 | sed 's/ *(.*//')"
else
  fail "연결된 아이폰 없음"
  hint "케이블 연결 → 잠금 해제 → '이 컴퓨터를 신뢰'"
  OFFLINE="$(xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices Offline ==/{d=1;next} /^== Simulators ==/{d=0} d' | grep -v '^$' | head -2)"
  [[ -n "$OFFLINE" ]] && hint "페어링된 적 있는 기기: $(printf '%s' "$OFFLINE" | head -1 | sed 's/ *(.*//')"
  hint "설정 > 개인정보 보호 및 보안 > 개발자 모드 가 켜져 있어야 목록에 나옵니다"
fi

# --- Nubi side ------------------------------------------------------------

if [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -f .env ]]; then
  pass "API 키  (탐색과 복구에 필요)"
else
  fail "ANTHROPIC_API_KEY 없음"
  hint ".env 에 넣거나 export 하세요. 재생만 할 거면 없어도 됩니다."
fi

if curl -s -m 2 http://127.0.0.1:8100/status >/dev/null 2>&1; then
  pass "에이전트가 이미 8100 에서 돌고 있음"
  hint "시뮬레이터용이면 먼저 끄세요 — 같은 포트를 씁니다"
else
  printf '\033[33m·\033[0m %s\n' "에이전트 미실행 (정상 — 아래 순서대로 띄웁니다)"
fi

echo
if [[ $bad -eq 0 ]]; then
  echo "준비됨. 다음 순서:"
  echo "  1) scripts/wda.sh --device        에이전트 (첫 실행은 빌드에 몇 분)"
  echo "  2) npm run live                   다른 창에서 스모크 테스트"
  echo "  3) npm run nubi -- run \"...\" --app com.apple.Preferences"
else
  echo "$bad 개 해결하고 다시 실행하세요."
  exit 1
fi
