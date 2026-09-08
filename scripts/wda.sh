#!/usr/bin/env bash
# Build and run WebDriverAgent against an iOS Simulator.
#
# Simulator builds need no code signing, no cable, and no GUI, so this works
# over SSH — which is the point. The same HTTP surface is what a real device
# serves, so nothing above Hands changes when the target does.
#
#   scripts/wda.sh            run against the first booted simulator
#   scripts/wda.sh <udid>     run against a specific one
#   scripts/wda.sh --setup    clone and build only, do not run
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

UDID="${1:-}"
if [[ -z "$UDID" || "$UDID" == "--setup" ]]; then
  UDID="$(pick_simulator)"
fi
log "simulator $UDID"

BUILD_ARGS=(
  -project "$WDA_DIR/WebDriverAgent.xcodeproj"
  -scheme WebDriverAgentRunner
  -destination "id=$UDID"
  -derivedDataPath "$DERIVED"
  CODE_SIGNING_ALLOWED=NO
)

if [[ "${1:-}" == "--setup" ]]; then
  log "build-for-testing"
  xcodebuild "${BUILD_ARGS[@]}" build-for-testing
  log "done — run scripts/wda.sh to start the agent"
  exit 0
fi

log "starting agent on http://127.0.0.1:8100 (ctrl-c to stop)"
exec xcodebuild "${BUILD_ARGS[@]}" test-without-building
