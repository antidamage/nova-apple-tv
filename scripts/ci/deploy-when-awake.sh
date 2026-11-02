#!/bin/bash
# Install and launch the newest staged Nova TV build on the Home Theatre Apple
# TV - but only while that Apple TV is awake, and only when the staged build is
# newer than the build already on the device.
#
# Runs as the LaunchAgent nz.co.skull.nova-appletv-deployer (installed by
# scripts/ci/install-ci.sh). Two modes:
#
#   deploy-when-awake.sh          poll forever: the LaunchAgent's loop
#   deploy-when-awake.sh --once   one cycle, for the pipeline's check step
#
# Why the awake gate works the way it does: see nova_atv_awake in
# scripts/ci/ci-config.sh. Every devicectl call wakes a sleeping Apple TV, so
# the awake test is a passive Home Assistant read and nothing else touches the
# device until that read says the TV is on. A sleeping set is therefore left
# completely alone, and the staged build waits for the next time it is switched
# on. Because only the newest staged build is ever installed, a burst of pushes
# collapses into one deployment when the set wakes.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/ci/ci-config.sh
. "$here/ci-config.sh"

state_file=$NOVA_ATV_CI_HOME/deployer-state.json

state_get() {
    python3 - "$state_file" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        value = json.load(fh).get(sys.argv[2], "")
except Exception:
    value = ""
print(value)
PY
}

state_set() { # state_set key=value key=value ...
    python3 - "$state_file" "$@" <<'PY'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        state = json.load(fh)
except Exception:
    state = {}
for pair in sys.argv[2:]:
    key, _, value = pair.partition("=")
    state[key] = int(value) if value.lstrip("-").isdigit() else value
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(state, fh, indent=1, sort_keys=True)
os.replace(tmp, path)
PY
}

install_staged() {
    local attempt=1
    while [ "$attempt" -le 4 ]; do
        if xcrun devicectl device install app --device "$NOVA_ATV_DEVICE_ID" \
            --timeout 240 "$NOVA_ATV_STAGED_APP"; then
            return 0
        fi
        nova_atv_log "install attempt $attempt of 4 failed"
        attempt=$((attempt + 1))
        sleep 5
    done
    return 1
}

launch_and_verify() {
    local out rc attempt
    out=$(xcrun devicectl device process launch --device "$NOVA_ATV_DEVICE_ID" \
        --timeout 120 "$NOVA_ATV_BUNDLE_ID" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$out" in
            *asleep*|*Asleep*)
                nova_atv_log "the Apple TV went to sleep before the launch; build $NOVA_ATV_STAGED_STAMP is installed and will be launched the next time it is awake"
                state_set "deployed_stamp=$NOVA_ATV_STAGED_STAMP" "pending_launch=true" \
                    "last_check_at=$(date +%s)"
                return 0
                ;;
            *)
                nova_atv_log "launch failed: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
                state_set "pending_launch=true" "last_error=launch failed" \
                    "last_error_at=$(date +%s)"
                return 1
                ;;
        esac
    fi

    # Confirm it is actually up, the same way the deploy scripts do. Each probe
    # has its own bounded timeout, so a wedged device cannot hold the lock past
    # the pipeline step's own timeout.
    for attempt in 1 2 3; do
        sleep 5
        if xcrun devicectl device info processes --device "$NOVA_ATV_DEVICE_ID" \
            --timeout 120 2>/dev/null | grep -q NovaAppleTVDashboard; then
            nova_atv_log "deployed build $NOVA_ATV_STAGED_STAMP ($NOVA_ATV_STAGED_SHA); process verified on the Home Theatre Apple TV"
            state_set "deployed_stamp=$NOVA_ATV_STAGED_STAMP" \
                "deployed_sha=$NOVA_ATV_STAGED_SHA" "deployed_at=$(date +%s)" \
                "pending_launch=false" "last_check_at=$(date +%s)" "last_error="
            rm -f "$NOVA_ATV_CI_HOME"/.note-*
            return 0
        fi
    done
    nova_atv_log "the app did not appear in the device process list after the launch"
    state_set "pending_launch=true" "last_error=not running after launch"
    return 1
}

# Runs with the lock held. Returns 0 when the device carries the staged build
# (or the staged build is older than what it already has), 1 when a genuine
# failure needs reporting.
deploy_locked() {
    local installed pending
    pending=$(state_get pending_launch)
    if ! installed=$(nova_atv_installed_build); then
        nova_atv_log "cannot read the installed app list from the Apple TV"
        state_set "last_error=app list unreadable" "last_error_at=$(date +%s)"
        return 1
    fi
    nova_atv_log "Apple TV awake (power state '$NOVA_ATV_POWER_STATE'); installed build $installed, staged build $NOVA_ATV_STAGED_STAMP"

    if [ "$installed" -ge "$NOVA_ATV_STAGED_STAMP" ] && [ "$pending" != true ]; then
        # Nothing to do - and record the device's own build number rather than
        # ours, so a build installed by hand is not fought over.
        state_set "deployed_stamp=$installed" "last_check_at=$(date +%s)" "last_error="
        return 0
    fi

    if [ "$installed" -lt "$NOVA_ATV_STAGED_STAMP" ]; then
        if ! install_staged; then
            nova_atv_log "could not install build $NOVA_ATV_STAGED_STAMP"
            state_set "pending_launch=true" "last_error=install failed" \
                "last_error_at=$(date +%s)"
            return 1
        fi
        nova_atv_log "installed build $NOVA_ATV_STAGED_STAMP"
    fi
    launch_and_verify
}

cycle() {
    local deployed pending last_check staged_at now rc

    nova_atv_read_staged
    NOVA_ATV_STAGED_STAMP=$(nova_atv_int "$NOVA_ATV_STAGED_STAMP")
    if [ "$NOVA_ATV_STAGED_STAMP" -eq 0 ]; then
        nova_atv_note nothing-staged "no build has been staged yet; nothing to deploy"
        return 0
    fi

    deployed=$(nova_atv_int "$(state_get deployed_stamp)")
    last_check=$(nova_atv_int "$(state_get last_check_at)")
    staged_at=$(nova_atv_int "$NOVA_ATV_STAGED_AT")
    pending=$(state_get pending_launch)
    now=$(date +%s)

    if [ "$NOVA_ATV_STAGED_STAMP" -le "$deployed" ] && [ "$pending" != true ] &&
        [ "$((now - last_check))" -lt "$NOVA_ATV_RECHECK_SECONDS" ]; then
        return 0 # the newest staged build is already on the Apple TV
    fi

    # Let a burst settle. Builds arriving while the set is awake would otherwise
    # each be installed in turn, one launch stealing the screen at a time; this
    # waits for the newest build instead, so a burst still deploys once. An
    # install that already happened and is only waiting to be launched is not
    # held up by it.
    if [ "$pending" != true ] && [ "$staged_at" -gt 0 ] &&
        [ "$((now - staged_at))" -lt "$NOVA_ATV_SETTLE_SECONDS" ]; then
        nova_atv_note settling "build $NOVA_ATV_STAGED_STAMP was staged $((now - staged_at))s ago; letting it settle for ${NOVA_ATV_SETTLE_SECONDS}s so a burst deploys once"
        return 0
    fi

    nova_atv_awake
    case $? in
        0) ;;
        10)
            nova_atv_note asleep "the Apple TV is not awake (power state '$NOVA_ATV_POWER_STATE'); staged build $NOVA_ATV_STAGED_STAMP waits for it to be switched on"
            return 0
            ;;
        *)
            nova_atv_note cannot-tell "cannot tell whether the Apple TV is awake: $NOVA_ATV_POWER_STATE; not touching the device"
            return 0
            ;;
    esac

    if ! nova_atv_lock; then
        nova_atv_note locked "a build or deploy is already running on this Mac"
        return 0
    fi
    # Release it however this process leaves - the pipeline's --once run can be
    # killed by its step timeout, and a lock held to staleness would block every
    # build and deploy for an hour.
    trap 'nova_atv_unlock' EXIT
    if deploy_locked; then rc=0; else rc=1; fi
    nova_atv_unlock
    trap - EXIT
    return $rc
}

if [ "${1:-}" = "--awake-check" ]; then
    # What the deployer's own awake test says, for an operator asking the
    # question by hand. Prints the power state and exits 0/10/1.
    nova_atv_awake
    rc=$?
    case "$rc" in
        0) echo "awake (power state '$NOVA_ATV_POWER_STATE')" ;;
        10) echo "not awake (power state '$NOVA_ATV_POWER_STATE')" ;;
        *) echo "cannot tell ($NOVA_ATV_POWER_STATE)" ;;
    esac
    exit "$rc"
fi

if [ "${1:-}" = "--once" ]; then
    cycle
    rc=$?
    # If the only thing in the way is the settle window - a build staged less
    # than NOVA_ATV_SETTLE_SECONDS ago - wait it out and try once more, so this
    # run really is the deploy attempt its pipeline step claims to be. The wait
    # is bounded by the window itself.
    _remaining=$(( $(nova_atv_int "${NOVA_ATV_STAGED_AT:-0}") + NOVA_ATV_SETTLE_SECONDS - $(date +%s) ))
    if [ "$rc" -eq 0 ] && [ "$_remaining" -gt 0 ] && [ "$_remaining" -le "$NOVA_ATV_SETTLE_SECONDS" ]; then
        nova_atv_log "waiting ${_remaining}s for staged build $NOVA_ATV_STAGED_STAMP to settle, then trying once more"
        sleep "$_remaining"
        cycle
        rc=$?
    fi
    exit "$rc"
fi

nova_atv_log "watching for staged builds every ${NOVA_ATV_POLL_SECONDS}s (bundle $NOVA_ATV_BUNDLE_ID)"
while :; do
    if ! cycle; then
        nova_atv_log "cycle failed; retrying in ${NOVA_ATV_POLL_SECONDS}s"
    fi
    sleep "$NOVA_ATV_POLL_SECONDS"
done
