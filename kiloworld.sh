#!/usr/bin/env bash
# Build → install → launch → stream ERROR logs only
# Usage examples:
#   ./ios_device_build_errors.sh -w YourApp.xcworkspace -s YourScheme -b com.yourco.app
#   ./ios_device_build_errors.sh -p YourApp.xcodeproj -s YourScheme -b com.yourco.app -c Release -u <UDID>

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -s <scheme> [-w <workspace>|-p <project>] -b <bundle_id> [-c Debug] [-u <udid>]
  -w   .xcworkspace path (mutually exclusive with -p)
  -p   .xcodeproj path (mutually exclusive with -w)
  -s   Scheme name (required)
  -b   CFBundleIdentifier (required)
  -c   Configuration (Debug|Release). Default: Debug
  -u   Device UDID (optional; auto-detects first connected if omitted)
EOF
  exit 1
}

WORKSPACE=""
PROJECT=""
SCHEME=""
CONFIG="Debug"
BUNDLE_ID=""
UDID=""

while getopts ":w:p:s:c:b:u:h" opt; do
  case $opt in
    w) WORKSPACE="$OPTARG" ;;
    p) PROJECT="$OPTARG" ;;
    s) SCHEME="$OPTARG" ;;
    c) CONFIG="$OPTARG" ;;
    b) BUNDLE_ID="$OPTARG" ;;
    u) UDID="$OPTARG" ;;
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

if [[ -z "$SCHEME" || -z "$BUNDLE_ID" || ( -z "$WORKSPACE" && -z "$PROJECT" ) ]]; then usage; fi
if [[ -n "$WORKSPACE" && -n "$PROJECT" ]]; then echo "Use either -w or -p (not both)."; usage; fi

# Auto-detect the first connected physical iOS device if UDID not provided
if [[ -z "$UDID" ]]; then
  if xcrun xcdevice list >/dev/null 2>&1; then
    UDID=$(xcrun xcdevice list 2>/dev/null | awk '
      /"state" *: *"connected"/ {connected=1}
      connected && /"identifier"/ { gsub(/[",]/,""); print $3; exit }')
  fi
fi
if [[ -z "$UDID" ]]; then
  echo "No device UDID provided and none auto-detected. Plug in a device or pass -u <udid>."
  exit 1
fi

DERIVED="./build"
RESULTS="$DERIVED/Results.xcresult"
DEST="platform=iOS,id=${UDID}"
CMD=(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination "$DEST" \
     -derivedDataPath "$DERIVED" -allowProvisioningUpdates -resultBundlePath "$RESULTS")

if [[ -n "$WORKSPACE" ]]; then
  CMD+=(-workspace "$WORKSPACE")
else
  CMD+=(-project "$PROJECT")
fi

echo "▶︎ Building $SCHEME for device $UDID ($CONFIG)…"
mkdir -p "$DERIVED"

# Build, capturing full logs to file, emitting only ERROR lines to the console.
set +e
"${CMD[@]}" 2>&1 | tee "$DERIVED/build.full.log" | grep -E --line-buffered -i '(^|[[:space:]])(fatal )?error:|BUILD FAILED' || true
build_status=${PIPESTATUS[0]}
set -e

if [[ $build_status -ne 0 ]]; then
  echo "✖ Build failed. Full log: $DERIVED/build.full.log  Result bundle: $RESULTS"
  exit $build_status
fi

# Find the built .app
APP_PATH=$(find "$DERIVED/Build/Products/$CONFIG-iphoneos" -maxdepth 1 -type d -name "*.app" | head -n1)
if [[ -z "$APP_PATH" ]]; then
  echo "Could not find .app in $DERIVED/Build/Products/$CONFIG-iphoneos"
  exit 1
fi

# Get the executable name (for process filtering)
APP_EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null || true)
APP_EXEC=${APP_EXEC:-$(basename "$APP_PATH" .app)}

echo "▶︎ Installing and launching $APP_EXEC ($BUNDLE_ID)…"
if xcrun devicectl --version >/dev/null 2>&1; then
  xcrun devicectl device install app --device "$UDID" "$APP_PATH"
  xcrun devicectl device launch app --terminate-existing --device "$UDID" "$BUNDLE_ID"
elif command -v ios-deploy >/dev/null 2>&1; then
  # Fallback for older Xcode: brew install ios-deploy
  ios-deploy -i "$UDID" --bundle "$APP_PATH" --justlaunch --uninstall
else
  echo "Neither 'devicectl' (Xcode 15+) nor 'ios-deploy' found. Install one of them and retry."
  exit 1
fi

echo "📜 Streaming ERROR logs for process '$APP_EXEC' (Ctrl-C to stop)…"
xcrun log stream --device "$UDID" --style compact --level error --predicate 'process == "'"$APP_EXEC"'"'
