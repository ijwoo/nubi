#!/usr/bin/env bash
# Build and run WebDriverAgent against an iOS Simulator.
#
# Simulator builds need no code signing, no cable, and no GUI, so this works
# over SSH — which is the point. The same HTTP surface is what a real device
# serves, so nothing above Hands changes when the target does.
#
#   scripts/wda.sh                 run against the first booted simulator
#   scripts/wda.sh <udid>          run against a specific one
#   scripts/wda.sh --setup         clone and build only, do not run
#   scripts/wda.sh --device        run against a connected iPhone
#   scripts/wda.sh --device <udid> against a specific one
#
# A device build needs three things a simulator build does not: a signing
# identity, a bundle id nobody else has registered, and a way to reach port
# 8100 — which on a device is the device's own port, not the Mac's. The last
# is what `iproxy` is for, and forgetting it looks exactly like an agent that
# failed to start.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WDA_DIR="$ROOT/.wda"
DERIVED="$WDA_DIR/DerivedData"
WDA_REPO="https://github.com/appium/WebDriverAgent.git"

log() { printf '\033[36m▸\033[0m %s\n' "$*"; }

if [[ ! -d "$WDA_DIR/WebDriverAgent.xcodeproj" ]]; then
  log "cloning WebDriverAgent into .wda"
  rm -rf "$WDA_DIR"
  git clone --depth 1 "$WDA_REPO" "$WDA_DIR"
fi

pick_simulator() {
  xcrun simctl list devices booted -j \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for rt in d.values():
    for dev in rt:
        if dev.get("state")=="Booted" and "iPhone" in dev.get("name",""):
            print(dev["udid"]); raise SystemExit
raise SystemExit("no booted iPhone simulator")'
}

# Bring the developer tunnel up before asking who is connected.
#
# On iOS 17+ the tunnel closes when nothing is using it, and a phone with a
# working cable then reports exactly as one that is not plugged in at all:
# absent from `xctrace`'s online list, `tunnelState: disconnected`. Asking
# `devicectl` for anything reopens it. Without this the first build after a
# quiet minute fails with "no iPhone connected" while the cable is fine.
wake_devices() {
  # Written to a file rather than /dev/stdout: `devicectl` prints its
  # human-readable table to stdout regardless, so the two interleave and the
  # JSON no longer parses.
  local json
  json="$(mktemp)"
  xcrun devicectl list devices -j "$json" >/dev/null 2>&1 || true
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for dev in d.get("result", {}).get("devices", []):
    udid = dev.get("hardwareProperties", {}).get("udid")
    if udid:
        print(udid)' "$json" 2>/dev/null \
    | while read -r udid; do
        xcrun devicectl device info details --device "$udid" >/dev/null 2>&1 || true
      done
  rm -f "$json"
}

# The first iPhone Xcode can see over the cable. Offline ones are listed too,
# so a phone that is plugged in but locked or untrusted is excluded here rather
# than failing later inside xcodebuild.
pick_device() {
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{d=1;next} /^== Devices Offline ==|^== Simulators ==/{d=0} d' \
    | grep -v 'Mac' \
    | sed -n 's/.*(\([0-9A-Fa-f-]\{25,\}\)).*/\1/p' \
    | head -1
}

# Read off the installed signing certificates rather than asked for: the team
# is in each identity's name, and getting it wrong fails deep inside a build
# log with a message about accounts rather than about teams.
#
# The one with the most certificates wins. A Mac that has shipped anything
# accumulates several identities per real team and often a lone stragglers from
# an old personal one — picking the first match found exactly that straggler
# here, and the build failed with `No Account for Team` while the account was
# signed in and perfectly valid. NUBI_TEAM_ID overrides when the guess is wrong.
pick_team() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"Apple [A-Za-z]*: .*(\([A-Z0-9]\{10\}\))".*/\1/p' \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

MODE="simulator"
if [[ "${1:-}" == "--device" ]]; then
  MODE="device"
  shift
fi

UDID="${1:-}"
if [[ -z "$UDID" || "$UDID" == "--setup" ]]; then
  if [[ "$MODE" == "device" ]]; then
    wake_devices
    UDID="$(pick_device)"
    [[ -n "$UDID" ]] || {
      echo "연결된 아이폰이 없습니다." >&2
      echo "  케이블로 연결하고, 잠금 해제한 뒤, '이 컴퓨터를 신뢰' 를 눌러주세요." >&2
      echo "  설정 > 개인정보 보호 및 보안 > 개발자 모드 도 켜져 있어야 합니다." >&2
      exit 1
    }
  else
    UDID="$(pick_simulator)"
  fi
fi

BUILD_ARGS=(
  -project "$WDA_DIR/WebDriverAgent.xcodeproj"
  -scheme WebDriverAgentRunner
  -destination "id=$UDID"
  -derivedDataPath "$DERIVED"
)

if [[ "$MODE" == "device" ]]; then
  TEAM="${NUBI_TEAM_ID:-$(pick_team)}"
  [[ -n "$TEAM" ]] || {
    echo "코드 서명 인증서를 찾지 못했습니다." >&2
    echo "  Xcode > Settings > Accounts 에서 Apple ID 를 추가하세요." >&2
    echo "  이미 있다면 NUBI_TEAM_ID 로 직접 지정할 수 있습니다." >&2
    exit 1
  }
  log "device $UDID  team $TEAM"
  # The stock bundle id belongs to Facebook and cannot be provisioned under
  # anyone else's team; both the runner and the app it hosts need their own.
  BUILD_ARGS+=(
    -allowProvisioningUpdates
    DEVELOPMENT_TEAM="$TEAM"
    CODE_SIGN_STYLE=Automatic
    PRODUCT_BUNDLE_IDENTIFIER="com.$TEAM.WebDriverAgentRunner"
  )
else
  log "simulator $UDID"
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

if [[ "${1:-}" == "--setup" ]]; then
  log "build-for-testing"
  xcodebuild "${BUILD_ARGS[@]}" build-for-testing
  log "done — run scripts/wda.sh to start the agent"
  exit 0
fi

# `test-without-building` means it. A device that has never been built for
# fails inside the installer with "the file doesn't exist" — several layers
# below anything that mentions building — so check for the product first.
if [[ "$MODE" == "device" && ! -d "$DERIVED/Build/Products/Debug-iphoneos" ]]; then
  log "no device build yet — building first"
  xcodebuild "${BUILD_ARGS[@]}" build-for-testing
fi

if [[ "$MODE" == "device" ]]; then
  command -v iproxy >/dev/null || {
    echo "iproxy 가 없습니다 — brew install libimobiledevice" >&2
    exit 1
  }
  # On a device the agent listens on the device's 8100. Without this everything
  # above Hands sees a connection refused and reads it as a dead agent.
  log "forwarding 127.0.0.1:8100 -> device 8100"
  iproxy 8100 8100 -u "$UDID" &
  IPROXY=$!
  trap 'kill "$IPROXY" 2>/dev/null || true' EXIT
fi

log "starting agent on http://127.0.0.1:8100 (ctrl-c to stop)"
exec xcodebuild "${BUILD_ARGS[@]}" test-without-building
