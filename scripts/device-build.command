#!/bin/zsh
# The build tree. The CI's Terminal call passes its own path through
# scripts/run-device-build-in-terminal.applescript, which cd's here and exports
# NOVA_ATV_BUILD_TREE, so this script and its caller can never disagree about
# which tree is being built; the manual path gets the default.
cd "${NOVA_ATV_BUILD_TREE:-$HOME/Build/NovaAppleTVDashboard}" || exit 1

set -o pipefail

deploy_env="${NOVA_APPLE_TV_DEPLOY_ENV:-$HOME/.config/nova-apple-tv/deploy.env}"
if [[ -f "$deploy_env" ]]; then
  source "$deploy_env"
fi

if [[ -n "${1:-}" ]]; then
  NOVA_APPLE_DEVELOPMENT_TEAM="$1"
fi
if [[ -n "${2:-}" ]]; then
  NOVA_APPLE_BUNDLE_IDENTIFIER="$2"
fi

signing_args=()
if [[ -n "${NOVA_APPLE_DEVELOPMENT_TEAM:-}" ]]; then
  signing_args+=("DEVELOPMENT_TEAM=${NOVA_APPLE_DEVELOPMENT_TEAM}")
fi
if [[ -n "${NOVA_APPLE_BUNDLE_IDENTIFIER:-}" ]]; then
  signing_args+=("PRODUCT_BUNDLE_IDENTIFIER=${NOVA_APPLE_BUNDLE_IDENTIFIER}")
fi

# Household camera-proxy override, same private deploy.env this script
# already sources for signing. Empty when unset, matching the public build's
# no-override default (Info.plist's $(NOVA_CAMERA_BASE_URL)/$(NOVA_CAMERA_TOKEN)
# substitute to "", and AppConfig.swift treats an empty string as unset).
camera_args=(
  "NOVA_CAMERA_BASE_URL=${NOVA_CAMERA_BASE_URL:-}"
  "NOVA_CAMERA_TOKEN=${NOVA_CAMERA_TOKEN:-}"
)

# Every build carries a monotonically increasing CFBundleVersion, so the CI
# deploy gate can tell whether the build it has staged is newer than the one on
# the Apple TV (scripts/ci/deploy-when-awake.sh installs only when it is).
# Seconds since the epoch: ten digits, a valid CFBundleVersion integer, and no
# two builds can share one - which matters, because two builds carrying the same
# number would make the second look already-installed to the deployer.
# NOVA_APPLE_BUILD_NUMBER overrides it. The number is written to gui-build.stamp
# so callers can read it back.
build_number="${NOVA_APPLE_BUILD_NUMBER:-$(date -u +%s)}"
printf '%s\n' "${build_number}" > gui-build.stamp

xcodebuild \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -project NovaAppleTVDashboard.xcodeproj \
  -scheme NovaAppleTVDashboard \
  -configuration Debug \
  -destination generic/platform=tvOS \
  -derivedDataPath ./DerivedData \
  "CURRENT_PROJECT_VERSION=${build_number}" \
  "${signing_args[@]}" \
  "${camera_args[@]}" \
  build 2>&1 | tee gui-build.log

build_status=${pipestatus[1]}
echo "${build_status}" > gui-build.status
echo
echo "Nova Apple TV device build ${build_number} exited with status ${build_status}."

# The GUI Terminal is needed for Xcode's signing/keychain context, but it does
# not need to linger after a successful unattended build. Find this exact tab
# by TTY so another Terminal window is never closed. Set the variable to 0 to
# retain the tab for inspection.
if [[ "${build_status}" -eq 0 && "${NOVA_APPLE_TV_CLOSE_TERMINAL_ON_SUCCESS:-1}" == "1" ]]; then
  terminal_tty="$(tty)"
  (
    sleep 1
    osascript - "${terminal_tty}" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
	set targetTty to item 1 of argv
	tell application "Terminal"
		repeat with terminalWindow in windows
			repeat with terminalTab in tabs of terminalWindow
				if tty of terminalTab is targetTty then
					close terminalTab
					return
				end if
			end repeat
		end repeat
	end tell
end run
APPLESCRIPT
  ) &
  disown
fi

exit "${build_status}"
