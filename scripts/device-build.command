#!/bin/zsh
cd "$HOME/Build/NovaAppleTVDashboard" || exit 1

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

xcodebuild \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -project NovaAppleTVDashboard.xcodeproj \
  -scheme NovaAppleTVDashboard \
  -configuration Debug \
  -destination generic/platform=tvOS \
  -derivedDataPath ./DerivedData \
  "${signing_args[@]}" \
  build 2>&1 | tee gui-build.log

build_status=${pipestatus[1]}
echo "${build_status}" > gui-build.status
echo
echo "Nova Apple TV device build exited with status ${build_status}."
exit "${build_status}"
