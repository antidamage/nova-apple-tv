#!/bin/sh
# Shared configuration and helpers for the Nova Apple TV CI on the "Indium"
# build Mac. Sourced by the scripts in this directory; not run directly.
#
# Every path and identifier can be overridden from the environment. The
# household's private values (signing team, camera proxy token, Apple TV pairing
# credentials) live in ~/.config/nova-apple-tv/ and never in this repository.

NOVA_ATV_BUNDLE_ID=${NOVA_ATV_BUNDLE_ID:-nz.co.skull.NovaAppleTVDashboard}
NOVA_ATV_DEVICE_ID=${NOVA_ATV_DEVICE_ID:-06ADB44E-EB13-50E7-BC36-01B908606CD5}
NOVA_ATV_BUILD_TREE=${NOVA_ATV_BUILD_TREE:-$HOME/Build/NovaAppleTVDashboard}
NOVA_ATV_CI_HOME=${NOVA_ATV_CI_HOME:-$HOME/Build/nova-appletv-ci}
NOVA_ATV_STAGING=${NOVA_ATV_STAGING:-$HOME/Build/nova-appletv-staging}
NOVA_ATV_DEPLOY_ENV=${NOVA_ATV_DEPLOY_ENV:-$HOME/.config/nova-apple-tv/deploy.env}
NOVA_ATV_REPO_URL=${NOVA_ATV_REPO_URL:-ssh://git@forge.example:2222/antidamage/nova-appletv-dashboard.git}
# The trunk the app is built and deployed from. A work branch is temporary: it
# exists for one pull request and is deleted when that is merged.
# The workflow sets this too, so a run is judged against the branch it is for
# even before install-ci.sh refreshes this file on the build Mac.
NOVA_ATV_BRANCH=${NOVA_ATV_BRANCH:-main}
NOVA_ATV_POLL_SECONDS=${NOVA_ATV_POLL_SECONDS:-30}
NOVA_ATV_RECHECK_SECONDS=${NOVA_ATV_RECHECK_SECONDS:-900}
NOVA_ATV_NOTE_SECONDS=${NOVA_ATV_NOTE_SECONDS:-600}
# A staged build is only installed once it has settled for this long, so a burst
# of pushes that lands while the set is awake still deploys once, as the newest
# build, rather than once per commit.
NOVA_ATV_SETTLE_SECONDS=${NOVA_ATV_SETTLE_SECONDS:-120}
# The build/deploy lock: one build or install at a time on this Mac.
NOVA_ATV_LOCK_PATH=${NOVA_ATV_LOCK_PATH:-$NOVA_ATV_CI_HOME/lock}
NOVA_ATV_STAGED_KEEP=${NOVA_ATV_STAGED_KEEP:-3}
NOVA_ATV_LOCK_STALE_SECONDS=${NOVA_ATV_LOCK_STALE_SECONDS:-3600}

# How the "is the Apple TV awake?" question is answered.
NOVA_ATV_PYATV=${NOVA_ATV_PYATV:-$NOVA_ATV_CI_HOME/venv/bin/atvremote}
NOVA_ATV_PYATV_PYTHON=${NOVA_ATV_PYATV_PYTHON:-$NOVA_ATV_CI_HOME/venv/bin/python}
NOVA_ATV_ATV_CREDENTIALS=${NOVA_ATV_ATV_CREDENTIALS:-$HOME/.config/nova-apple-tv/atv-credentials.json}
# The newest pyatv that still supports the Mac's own /usr/bin/python3 (3.9), and
# the newest whose wheels install without a Rust toolchain.
NOVA_ATV_PYATV_VERSION=${NOVA_ATV_PYATV_VERSION:-0.14.5}
NOVA_ATV_SCAN_TIMEOUT=${NOVA_ATV_SCAN_TIMEOUT:-5}
NOVA_ATV_POWER_TIMEOUT=${NOVA_ATV_POWER_TIMEOUT:-25}

# The signing team and the camera overrides come from the same private file the
# manual deploy path uses (scripts/device-build.command sources it too).
if [ -f "$NOVA_ATV_DEPLOY_ENV" ]; then
    # shellcheck disable=SC1090
    . "$NOVA_ATV_DEPLOY_ENV"
fi

export NOVA_ATV_BUNDLE_ID NOVA_ATV_DEVICE_ID NOVA_ATV_BUILD_TREE NOVA_ATV_CI_HOME \
    NOVA_ATV_STAGING NOVA_ATV_REPO_URL NOVA_ATV_BRANCH NOVA_ATV_POLL_SECONDS \
    NOVA_ATV_STAGED_KEEP NOVA_ATV_LOCK_STALE_SECONDS NOVA_ATV_LOCK_PATH \
    NOVA_ATV_SETTLE_SECONDS NOVA_ATV_PYATV NOVA_ATV_PYATV_PYTHON \
    NOVA_ATV_ATV_CREDENTIALS

nova_atv_log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# A repeated note (an asleep Apple TV, a broken pairing) is only logged every
# NOVA_ATV_NOTE_SECONDS so a poll loop cannot bury the log.
nova_atv_note() {
    _key=$1
    shift
    mkdir -p "$NOVA_ATV_CI_HOME" 2>/dev/null || true
    _marker=$NOVA_ATV_CI_HOME/.note-$_key
    _now=$(date +%s)
    _last=$(cat "$_marker" 2>/dev/null || echo 0)
    if [ "$((_now - _last))" -ge "$NOVA_ATV_NOTE_SECONDS" ]; then
        printf '%s\n' "$_now" > "$_marker"
        nova_atv_log "$*"
    fi
}

# Coerce anything to a non-negative integer. Every comparison in these scripts
# runs on values that came off disk or out of JSON, so nothing is trusted to be
# numeric: an unset or hand-edited field must not turn into an arithmetic error
# or a comparison that silently means something else.
nova_atv_int() {
    case "${1:-}" in
        '' | *[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# The staged build's metadata, as written by scripts/ci/build-and-stage.sh.
# Sets NOVA_ATV_STAGED_STAMP / _SHA / _APP / _AT; all empty when nothing is
# staged.
nova_atv_read_staged() {
    NOVA_ATV_STAGED_STAMP=
    NOVA_ATV_STAGED_SHA=
    NOVA_ATV_STAGED_APP=
    NOVA_ATV_STAGED_AT=
    [ -f "$NOVA_ATV_STAGING/current.json" ] || return 0
    eval "$(python3 - "$NOVA_ATV_STAGING/current.json" <<'PY'
import json, shlex, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    raise SystemExit(0)
for key, out in (("build_number", "NOVA_ATV_STAGED_STAMP"),
                 ("sha", "NOVA_ATV_STAGED_SHA"),
                 ("app_path", "NOVA_ATV_STAGED_APP"),
                 ("staged_at_epoch", "NOVA_ATV_STAGED_AT")):
    print("%s=%s" % (out, shlex.quote(str(d.get(key, "")))))
PY
)"
}

# The Apple TV's address, from the pairing credentials file.
nova_atv_address() {
    python3 - "$NOVA_ATV_ATV_CREDENTIALS" 2>/dev/null <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print((json.load(fh).get("address") or "").strip())
except Exception:
    pass
PY
}

# Its pyatv identifier (the device's MAC), which pins a query to this set even
# if something else on the network answers a scan.
nova_atv_identifier() {
    python3 - "$NOVA_ATV_ATV_CREDENTIALS" 2>/dev/null <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        ids = json.load(fh).get("identifiers") or []
except Exception:
    raise SystemExit(0)
if isinstance(ids, str):
    ids = [part.strip().strip("'") for part in ids.strip("[]").split(",")]
print(ids[0].strip() if ids else "")
PY
}

# The pyatv credentials to hand atvremote, as alternating flag/value lines so a
# POSIX shell can read them into an argument array. Companion answers a
# power-state query; the others follow because a pairing that lacks it should
# still be asked rather than assumed to be missing.
nova_atv_pyatv_credential_args() {
    "$NOVA_ATV_PYATV_PYTHON" - "$NOVA_ATV_ATV_CREDENTIALS" <<'PY' 2>/dev/null
import json, sys
from pyatv.const import Protocol
try:
    with open(sys.argv[1]) as fh:
        creds = json.load(fh).get("credentials") or {}
except Exception:
    raise SystemExit(0)
for protocol, flag in ((Protocol.Companion, "--companion-credentials"),
                       (Protocol.AirPlay, "--airplay-credentials"),
                       (Protocol.MRP, "--mrp-credentials"),
                       (Protocol.RAOP, "--raop-credentials")):
    value = creds.get(str(protocol.value))
    if value:
        print(flag)
        print(value)
PY
}

# Is the Home Theatre Apple TV awake? 0 = yes, 10 = asleep, 1 = cannot tell.
#
# pyatv asks the set's companion service for its power state, which it answers
# while suspended: the same query Home Assistant used to make, but straight from
# this Mac and with no other host involved. It matters that the test is passive.
# Every devicectl call - even `device info apps` - brings a sleeping Apple TV
# out of standby (measured 2026-09-21: the set woke within five seconds of an
# otherwise idle call), so a device-side probe would switch the TV on rather
# than observe it. `off` is what a suspended set reports; anything else means it
# is running. Nothing is ever deployed on a "cannot tell".
nova_atv_awake() {
    local address identifier args=() line out rc waited pid

    NOVA_ATV_POWER_STATE=cannot-tell
    if [ ! -x "$NOVA_ATV_PYATV" ]; then
        NOVA_ATV_POWER_STATE="no pyatv at $NOVA_ATV_PYATV"
        return 1
    fi
    address=$(nova_atv_address)
    if [ -z "$address" ]; then
        NOVA_ATV_POWER_STATE="no address in $NOVA_ATV_ATV_CREDENTIALS"
        return 1
    fi
    identifier=$(nova_atv_identifier)
    _argsfile=${TMPDIR:-/tmp}/nova-atv-args.$$.txt
    nova_atv_pyatv_credential_args > "$_argsfile" 2>/dev/null || true
    while IFS= read -r line; do
        args+=("$line")
    done < "$_argsfile"
    rm -f "$_argsfile"
    if [ "${#args[@]}" -eq 0 ]; then
        NOVA_ATV_POWER_STATE="no pairing credential in $NOVA_ATV_ATV_CREDENTIALS"
        return 1
    fi

    # atvremote has no timeout of its own and macOS has no coreutils timeout, so
    # the query is watched instead of trusted to return.
    _cmd=("$NOVA_ATV_PYATV" --scan-hosts "$address" -t "$NOVA_ATV_SCAN_TIMEOUT")
    if [ -n "$identifier" ]; then
        _cmd+=(--id "$identifier")
    fi
    _cmd+=("${args[@]}" power_state)
    out=${TMPDIR:-/tmp}/nova-atv-power.$$.txt
    "${_cmd[@]}" > "$out" 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$NOVA_ATV_POWER_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$out"
        NOVA_ATV_POWER_STATE="timed out after ${NOVA_ATV_POWER_TIMEOUT}s"
        return 1
    fi
    wait "$pid"
    rc=$?

    NOVA_ATV_POWER_STATE=$(tail -1 "$out" 2>/dev/null | sed -E 's/.*[Pp]ower[Ss]tate[.:]//' | tr -d '\r' | tr 'A-Z' 'a-z')
    [ -n "$NOVA_ATV_POWER_STATE" ] || NOVA_ATV_POWER_STATE="no answer (exit $rc)"
    rm -f "$out"
    if [ "$rc" -ne 0 ]; then
        NOVA_ATV_POWER_STATE="$NOVA_ATV_POWER_STATE (exit $rc)"
        return 1
    fi
    case "$NOVA_ATV_POWER_STATE" in
        off | standby | suspended) return 10 ;;
        on | idle | playing | paused) return 0 ;;
    esac
    return 1 # anything unrecognised is a "cannot tell", never an awake
}

# CFBundleVersion of the app installed on the Apple TV, or 0 when it is not
# installed. Wakes a sleeping Apple TV, so it is only ever called after
# nova_atv_awake has said yes.
nova_atv_installed_build() {
    _out=${TMPDIR:-/tmp}/nova-atv-apps.$$.json
    rm -f "$_out"
    if ! xcrun devicectl device info apps --device "$NOVA_ATV_DEVICE_ID" \
        --timeout 90 --json-output "$_out" >/dev/null 2>&1; then
        rm -f "$_out"
        return 1
    fi
    python3 - "$_out" "$NOVA_ATV_BUNDLE_ID" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        apps = json.load(fh)["result"]["apps"]
except Exception as exc:
    print("cannot read the device app list: %s" % exc, file=sys.stderr)
    raise SystemExit(1)
for app in apps:
    if app.get("bundleIdentifier") == sys.argv[2]:
        match = re.match(r"^(\d+)", str(app.get("bundleVersion", "")))
        print(match.group(1) if match else 0)
        break
else:
    print(0)
PY
    _rc=$?
    rm -f "$_out"
    return $_rc
}

# One build or deploy at a time: the build writes the staged bundle the deployer
# installs from, and two xcodebuilds would share one DerivedData. The manual
# PowerShell path predates this lock and does not take it, so do not run
# .\deploy-nova-appletv.ps1 while a CI build is going.
#
# `wait` (seconds, default 0) makes the caller queue behind a live lock instead
# of failing: a poller has another cycle coming, a build does not. A lock whose
# owner has died is taken over at once (by an atomic rename, so two contenders
# cannot both win), and one nobody can speak for is taken over on age alone.
nova_atv_lock() {
    _lock=$NOVA_ATV_LOCK_PATH
    _wait=${1:-0}
    _waited=0
    mkdir -p "$NOVA_ATV_CI_HOME" 2>/dev/null || true
    while :; do
        if mkdir "$_lock" 2>/dev/null; then
            printf '%s\n' "$$" > "$_lock/pid" 2>/dev/null || true
            return 0
        fi
        # Gone again between the mkdir and here: try again rather than conclude
        # anything about it.
        if [ ! -d "$_lock" ]; then
            continue
        fi

        # A lock whose owner is gone is recoverable immediately - no SIGKILLed
        # deployer should cost an hour of blocked builds. A live pid that is not
        # ours means someone is working, even if it has been a while.
        _holder=$(nova_atv_int "$(cat "$_lock/pid" 2>/dev/null)")
        _stale=false
        if [ "$_holder" -gt 0 ] && [ "$_holder" != "$$" ] && ! kill -0 "$_holder" 2>/dev/null; then
            _stale=true
        elif [ "$_holder" -eq 0 ]; then
            _mtime=$(nova_atv_int "$(stat -f %m "$_lock" 2>/dev/null)")
            if [ "$_mtime" -gt 0 ] && [ "$(($(date +%s) - _mtime))" -gt "$NOVA_ATV_LOCK_STALE_SECONDS" ]; then
                _stale=true
            fi
        fi

        if [ "$_stale" = true ]; then
            # Rename it aside to claim it: of two contenders only one rename can
            # win, so the takeover itself cannot be done twice, and the loser
            # just loops back to the mkdir.
            if mv "$_lock" "$_lock.stale.$$" 2>/dev/null; then
                rm -rf "$_lock.stale.$$"
                nova_atv_log "took over $_lock from a lock left by pid ${_holder:-unknown}"
            fi
            continue
        fi

        [ "$_waited" -lt "$_wait" ] || return 1
        [ "$_waited" -eq 0 ] && nova_atv_log "waiting for $_lock (held by pid ${_holder:-unknown})"
        sleep 5
        _waited=$((_waited + 5))
    done
}

nova_atv_unlock() {
    rm -rf "$NOVA_ATV_LOCK_PATH"
}
