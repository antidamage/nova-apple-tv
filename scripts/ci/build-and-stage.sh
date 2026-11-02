#!/bin/bash
# Build the tvOS app from a checked-out source tree on the Indium build Mac and
# stage the signed bundle for scripts/ci/deploy-when-awake.sh.
#
# This is the build half of the repository's Forgejo Action
# (.forgejo/workflows/appletv-ci.yml). It runs the same build the manual fast
# path runs - scripts/device-build.command, driven through the GUI Terminal for
# Xcode's signing keychain - and keeps the build tree's DerivedData, so the
# device build stays incremental exactly as .\deploy-nova-appletv-fast.ps1 does.
#
# Nothing here touches the Apple TV. Builds are cheap and may run at any hour;
# installing is the deployer's job, and the deployer waits for the set to be on.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/ci/ci-config.sh
. "$here/ci-config.sh"

source_dir=${1:-${NOVA_ATV_CHECKOUT_DIR:-$PWD}}

if [ ! -d "$source_dir/NovaAppleTVDashboard.xcodeproj" ]; then
    nova_atv_log "no NovaAppleTVDashboard.xcodeproj in $source_dir"
    exit 1
fi
if [ -z "${NOVA_APPLE_DEVELOPMENT_TEAM:-}" ]; then
    nova_atv_log "NOVA_APPLE_DEVELOPMENT_TEAM is not set - expected it in $NOVA_ATV_DEPLOY_ENV"
    exit 1
fi

sha=$(git -C "$source_dir" rev-parse HEAD)
subject=$(git -C "$source_dir" log -1 --format=%s)
branch=${NOVA_ATV_CHECKOUT_BRANCH:-$(git -C "$source_dir" rev-parse --abbrev-ref HEAD)}
nova_atv_log "building $sha ($subject)"

# Say so when the checkout and the configured branch disagree: building the
# wrong branch here stages a build the deployer would install on the set without
# hesitating.
if [ -n "${NOVA_ATV_CHECKOUT_BRANCH:-}" ] && [ "$NOVA_ATV_CHECKOUT_BRANCH" != "$NOVA_ATV_BRANCH" ]; then
    nova_atv_log "WARNING: asked to build '$NOVA_ATV_CHECKOUT_BRANCH' but NOVA_ATV_BRANCH is '$NOVA_ATV_BRANCH' - one of the two is wrong"
fi

# A run that has already been overtaken by a newer commit on the branch it is
# building has nothing to stage: that commit's own run will build it, and this
# Mac should not spend ten minutes on a revision that can never be deployed.
# Opt-in, because a hand-run build wants the revision it was given.
if [ "${NOVA_ATV_SKIP_IF_SUPERSEDED:-0}" = "1" ]; then
    ref=${NOVA_ATV_CHECKOUT_BRANCH:-$NOVA_ATV_BRANCH}
    tip=$(GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new' \
        git ls-remote "$NOVA_ATV_REPO_URL" "refs/heads/$ref" 2>/dev/null | awk '{print $1}')
    if [ -n "$tip" ] && [ "$tip" != "$sha" ]; then
        nova_atv_log "$ref has moved on to $tip; not building $sha (a newer run will)"
        exit 0
    fi
fi

# Wait for a deploy in progress instead of failing: a commit gets exactly one
# build, so giving up here would silently drop the change. The deployer holds
# this lock only for an install.
if ! nova_atv_lock 900; then
    nova_atv_log "could not take the build lock within 900s; nothing done"
    exit 1
fi
trap 'nova_atv_unlock' EXIT

# 1. Mirror the checkout into the build tree. DerivedData is excluded from both
#    the copy and the delete, so the incremental device build survives; files
#    deleted upstream do not, which the tar-based fast path cannot manage.
mkdir -p "$NOVA_ATV_BUILD_TREE"
rsync -a --delete \
    --exclude '.git/' --exclude 'DerivedData/' --exclude 'DerivedDataSim/' \
    --exclude 'gui-build.log' --exclude 'gui-build.status' --exclude 'gui-build.stamp' \
    "$source_dir/" "$NOVA_ATV_BUILD_TREE/"
chmod +x "$NOVA_ATV_BUILD_TREE"/scripts/*.command "$NOVA_ATV_BUILD_TREE"/scripts/ci/*.sh 2>/dev/null || true

# 2. The signed device build, as every other deploy path does it.
#
#    The runner (and the deployer) live in the logged-in GUI session, where
#    Xcode's signing keychain is available, so the build runs here directly -
#    no Terminal, no AppleEvents, nothing to approve. A hand run over ssh has no
#    GUI session and cannot reach the keychain, so that path asks Terminal to run
#    it instead (NOVA_ATV_BUILD_VIA_TERMINAL=1), which is what the manual
#    PowerShell deploy does too.
rm -f "$NOVA_ATV_BUILD_TREE/gui-build.log" "$NOVA_ATV_BUILD_TREE/gui-build.status" \
    "$NOVA_ATV_BUILD_TREE/gui-build.stamp"
if [ "${NOVA_ATV_BUILD_VIA_TERMINAL:-0}" = "1" ]; then
    nova_atv_log "starting the signed device build through the Terminal"
    osascript "$NOVA_ATV_BUILD_TREE/scripts/run-device-build-in-terminal.applescript" \
        "$NOVA_APPLE_DEVELOPMENT_TEAM" "$NOVA_ATV_BUNDLE_ID" "$NOVA_ATV_BUILD_TREE"
else
    # A hand run over ssh lands here, and Xcode cannot reach the signing keychain
    # from an ssh session - say so now rather than after the build fails to sign.
    if [ -n "${SSH_CONNECTION:-}" ]; then
        nova_atv_log "WARNING: running over ssh without NOVA_ATV_BUILD_VIA_TERMINAL=1; Xcode cannot sign from an ssh session (see docs/CI-APPLETV-CI.md)"
    fi
    nova_atv_log "starting the signed device build (this session: $(id -un), signing via the login keychain)"
    ( cd "$NOVA_ATV_BUILD_TREE" && \
        ./scripts/device-build.command "$NOVA_APPLE_DEVELOPMENT_TEAM" "$NOVA_ATV_BUNDLE_ID" ) || true
fi

timeout=${NOVA_ATV_BUILD_TIMEOUT_SECONDS:-2400}
deadline=$(($(date +%s) + timeout))
while [ ! -f "$NOVA_ATV_BUILD_TREE/gui-build.status" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        nova_atv_log "the device build did not finish within ${timeout}s; last lines of gui-build.log:"
        tail -20 "$NOVA_ATV_BUILD_TREE/gui-build.log" 2>/dev/null || true
        exit 1
    fi
    sleep 10
done

status=$(cat "$NOVA_ATV_BUILD_TREE/gui-build.status" 2>/dev/null || echo unknown)
if [ "$status" != "0" ]; then
    nova_atv_log "the device build failed (status $status); errors:"
    grep -n 'error:' "$NOVA_ATV_BUILD_TREE/gui-build.log" 2>/dev/null | tail -40 || true
    exit 1
fi
nova_atv_log "device build succeeded"

# 3. Stage the bundle where the deployer can install it from, stamped by the
#    build its own CFBundleVersion (written by scripts/device-build.command).
app="$NOVA_ATV_BUILD_TREE/DerivedData/Build/Products/Debug-appletvos/NovaAppleTVDashboard.app"
if [ ! -d "$app" ]; then
    nova_atv_log "the build reported success but $app does not exist"
    exit 1
fi
stamp=$(plutil -extract CFBundleVersion raw -o - "$app/Info.plist" 2>/dev/null || echo)
case "$stamp" in
    ''|*[!0-9]*)
        nova_atv_log "the built bundle has no usable CFBundleVersion (got '$stamp')"
        exit 1
        ;;
esac

dest="$NOVA_ATV_STAGING/$stamp"
mkdir -p "$dest"
rsync -a --delete "$app/" "$dest/NovaAppleTVDashboard.app/"

python3 - "$NOVA_ATV_STAGING/current.json" "$sha" "$stamp" "$branch" "$subject" <<'PY'
import json, os, sys, time

path, sha, stamp, branch, subject = sys.argv[1:6]
payload = {
    "schema": 1,
    "sha": sha,
    "short_sha": sha[:9],
    "branch": branch,
    "build_number": int(stamp),
    "subject": subject,
    "app_path": os.path.join(os.path.dirname(path), stamp, "NovaAppleTVDashboard.app"),
    "staged_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "staged_at_epoch": int(time.time()),
}
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(payload, fh, indent=1, sort_keys=True)
os.replace(tmp, path)
print("staged build %s (%s) from %s" % (stamp, sha[:9], branch))
PY

# 4. Keep only the newest few staged builds; the deployer installs the newest.
python3 - "$NOVA_ATV_STAGING" "$NOVA_ATV_STAGED_KEEP" "$stamp" <<'PY'
import os, shutil, sys

staging, keep, current = sys.argv[1], int(sys.argv[2]), sys.argv[3]
entries = sorted((e for e in os.listdir(staging) if e.isdigit()), key=int, reverse=True)
for stale in entries[keep:]:
    if stale == current:  # never prune what is being staged right now
        continue
    shutil.rmtree(os.path.join(staging, stale), ignore_errors=True)
PY

nova_atv_log "done: staged $stamp at $dest"
