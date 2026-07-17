#!/usr/bin/env bash
set -euo pipefail

# Build, install, and launch FlextunnelApp on a paired physical iOS device.
#
# The device identifier is REQUIRED (there is usually more than one device
# paired, and picking the wrong one silently is worse than asking). Find it with:
#     scripts/list-devices-ios.sh
# and pass the IDENTIFIER column (the CoreDevice UUID, not the hardware UDID).
#
# By default this links a LOCALLY built libflextunnel.xcframework
# (FLEXTUNNEL_LOCAL_XCFRAMEWORK=1) so you test the Rust FFI in ../flextunnel as
# it stands on disk — build it first with `(cd ../flextunnel && ./build-ios.sh
# release)`. Pass --pinned to link the released xcframework from Package.swift
# instead. The choice is baked in at `xcodegen generate` time, so the project is
# always regenerated (skip with --no-generate if you know it already matches).

APP_NAME="flextunnel"
PROJECT_NAME="Flextunnel"
SCHEME="FlextunnelApp"
BUNDLE_ID="dev.flexaccess.flextunnel"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/run-device-ios.sh <DEVICE_ID> [options]
  scripts/run-device-ios.sh --device <DEVICE_ID> [options]

Builds FlextunnelApp, installs it on the given paired device, and launches it.
Find DEVICE_ID (the CoreDevice IDENTIFIER) with scripts/list-devices-ios.sh.

Options:
  -d, --device DEVICE_ID      CoreDevice identifier of the target device (required).
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to DEVELOPMENT_TEAM from Developer.local.xcconfig.
  -c, --configuration NAME    Build configuration. Defaults to Debug.
      --pinned                Link the released xcframework (Package.swift default)
                              instead of a local ../flextunnel/dist/ios build.
      --no-generate           Skip 'xcodegen generate' (use the project as-is).
      --no-launch             Install but do not launch.
      --allow-provisioning-updates
                              Let xcodebuild create/update signing assets (default on).
  -h, --help                  Show this help.

Environment overrides:
  DEVICE_ID, TEAM_ID, CONFIGURATION
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

DEVICE_ID="${DEVICE_ID:-}"
TEAM_ID="${TEAM_ID:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"
USE_LOCAL_XCFRAMEWORK=1
GENERATE=1
LAUNCH=1
ALLOW_PROVISIONING_UPDATES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DEVICE_ID="$2"; shift 2 ;;
    -t|--team-id)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TEAM_ID="$2"; shift 2 ;;
    -c|--configuration)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CONFIGURATION="$2"; shift 2 ;;
    --pinned)        USE_LOCAL_XCFRAMEWORK=0; shift ;;
    --no-generate)   GENERATE=0; shift ;;
    --no-launch)     LAUNCH=0; shift ;;
    --allow-provisioning-updates) ALLOW_PROVISIONING_UPDATES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              usage >&2; die "unknown option: $1" ;;
    *)
      [[ -z "$DEVICE_ID" ]] || { usage >&2; die "unexpected argument: $1"; }
      DEVICE_ID="$1"; shift ;;
  esac
done

[[ -n "$DEVICE_ID" ]] || {
  usage >&2
  die "a device identifier is required — list them with scripts/list-devices-ios.sh"
}

# Reuse the same DEVELOPMENT_TEAM detection as create-archive-ios.sh.
detect_project_team_id() {
  local xcconfig="$PROJECT_ROOT/Developer.local.xcconfig"
  [[ -f "$xcconfig" ]] || return 1
  /usr/bin/awk '
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      sub(/\/\/.*$/, "")
      sub(/.*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*/, "")
      gsub(/[[:space:]"]+$/, ""); gsub(/^[[:space:]"]+/, "")
      if ($0 != "") { print $0; found = 1; exit 0 }
    }
    END { if (!found) exit 1 }
  ' "$xcconfig"
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_project_team_id || true)"
fi
[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required: set DEVELOPMENT_TEAM in Developer.local.xcconfig (copy Developer.local.xcconfig.sample) or pass --team-id"
}

# Validate the id against the paired-device list so a typo fails fast with the
# available choices, rather than deep in an xcodebuild/devicectl error.
LIST_SCRIPT="$PROJECT_ROOT/scripts/list-devices-ios.sh"
if [[ -x "$LIST_SCRIPT" ]]; then
  if ! "$LIST_SCRIPT" --identifiers | /usr/bin/grep -qxF "$DEVICE_ID"; then
    echo "Paired devices:" >&2
    "$LIST_SCRIPT" >&2 || true
    die "device '$DEVICE_ID' is not a paired CoreDevice identifier (see list above)"
  fi
fi

export_local_env() {
  if [[ "$USE_LOCAL_XCFRAMEWORK" == "1" ]]; then
    local link="$PROJECT_ROOT/Packages/Flextunnel/local/libflextunnel.xcframework"
    [[ -e "$link" ]] || die "local xcframework not found at $link — build it with '(cd ../flextunnel && ./build-ios.sh release)'"
    export FLEXTUNNEL_LOCAL_XCFRAMEWORK=1
  else
    unset FLEXTUNNEL_LOCAL_XCFRAMEWORK || true
  fi
}
export_local_env

if [[ "$GENERATE" == "1" ]]; then
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  echo "Generating project (local xcframework: $USE_LOCAL_XCFRAMEWORK) ..."
  ( cd "$PROJECT_ROOT" && xcodegen generate )
fi

[[ -e "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" ]] || \
  die "${PROJECT_NAME}.xcodeproj not found — drop --no-generate or run 'xcodegen generate'"

DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"

provisioning_args=()
[[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]] && provisioning_args=(-allowProvisioningUpdates)

echo "Building ${SCHEME}:"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  team:          %s\n' "$TEAM_ID"
printf '  device:        %s\n' "$DEVICE_ID"

# generic/platform=iOS + -sdk iphoneos builds the device arm64 slice without
# needing the hardware UDID; devicectl then installs by CoreDevice identifier.
( cd "$PROJECT_ROOT" && xcodebuild build \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED_DATA" \
    "${provisioning_args[@]}" \
    DEVELOPMENT_TEAM="$TEAM_ID" )

[[ -d "$APP_PATH" ]] || die "build did not produce an app at $APP_PATH"

echo "Installing on $DEVICE_ID ..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

if [[ "$LAUNCH" == "1" ]]; then
  echo "Launching $BUNDLE_ID ..."
  # A locked device refuses the launch (CoreDeviceError 10002); the install still
  # succeeded, so treat that as a soft failure with a hint rather than aborting.
  launch_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/flextunnel-launch.XXXXXX")"
  if xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | /usr/bin/tee "$launch_log"; then
    /bin/rm -f "$launch_log"
  else
    if /usr/bin/grep -qi "unlock" "$launch_log"; then
      echo "note: installed OK, but the device is locked — unlock it and tap the app, or re-run this script." >&2
    else
      echo "note: installed OK, but launch failed (see above) — open the app from the home screen." >&2
    fi
    /bin/rm -f "$launch_log"
  fi
else
  echo "Skipping launch (--no-launch). Open the app from the home screen."
fi
