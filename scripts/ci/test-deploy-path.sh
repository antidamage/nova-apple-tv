#!/bin/bash
# Does the deploy path actually get as far as installing?
#
# This test exists because the interesting failure of this path cannot be seen on
# a sleeping Apple TV: every live run returns at the awake check, long before the
# point where the deployer has something to install. A stale variable there
# (deploy_locked reading a name the code no longer sets) aborted the deployer
# under `set -u` exactly when a deploy was finally due, and no real run could
# show it.
#
# It stubs only the outside world - the device (xcrun) and the set's power state
# (atvremote) - and runs the deployer's real code, so an unbound variable, a bad
# comparison or a wrong path fails the test.
#
# Usage: scripts/ci/test-deploy-path.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/nova-atv-deploy-test.XXXXXX")
failures=0

note() { printf '%s\n' "$*"; }
check() { # check <what> <expected-substring> <file>
    if grep -q -- "$2" "$3" 2>/dev/null; then
        note "  ok: $1"
    else
        note "  FAIL: $1 (no '$2' in $3)"
        failures=$((failures + 1))
    fi
}

pyatv_python=$(command -v python3)
for candidate in "$HOME/Build/nova-appletv-ci/venv/bin/python" /usr/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c 'import pyatv.const' 2>/dev/null; then
        pyatv_python=$candidate
        break
    fi
done
if ! "$pyatv_python" -c 'import pyatv.const' 2>/dev/null; then
    note "SKIP: no python with pyatv available (the deployer's credential helper needs it)"
    exit 0
fi

export NOVA_ATV_CI_HOME=$work/ci
export NOVA_ATV_STAGING=$work/staging
export NOVA_ATV_LOCK_PATH=$work/ci/lock
export NOVA_ATV_PYATV=$work/bin/atvremote
export NOVA_ATV_PYATV_PYTHON=$pyatv_python
export NOVA_ATV_ATV_CREDENTIALS=$work/atv-credentials.json
export NOVA_ATV_DEPLOY_ENV=$work/deploy.env
export PATH="$work/bin:$PATH"
mkdir -p "$NOVA_ATV_CI_HOME" "$work/bin" "$NOVA_ATV_STAGING/9001/NovaAppleTVDashboard.app"

# The set is awake, and the device is running an older build than the staged one.
cat > "$NOVA_ATV_PYATV" <<'SH'
#!/bin/bash
echo "PowerState.On"
exit 0
SH
chmod +x "$NOVA_ATV_PYATV"

cat > "$NOVA_ATV_ATV_CREDENTIALS" <<'JSON'
{"address": "127.0.0.1", "identifiers": ["aa:bb:cc:dd:ee:ff"], "credentials": {"4": "fixture"}}
JSON

cat > "$work/bin/xcrun" <<'SH'
#!/bin/bash
log="$NOVA_ATV_CI_HOME/xcrun-calls.log"
printf '%s\n' "$*" >> "$log"
case "$*" in
    *"info apps"*)
        out=""
        prev=""
        for arg in "$@"; do
            [ "$prev" = "--json-output" ] && out=$arg
            prev=$arg
        done
        [ -n "$out" ] && cat > "$out" <<JSON
{"result": {"apps": [{"bundleIdentifier": "nz.co.skull.NovaAppleTVDashboard", "bundleVersion": "1", "version": "0.1.0"}]}}
JSON
        exit 0
        ;;
    *"info processes"*)
        echo "  1234  /private/var/containers/Bundle/Application/X/NovaAppleTVDashboard.app/NovaAppleTVDashboard"
        exit 0
        ;;
    *"install app"*|*"process launch"*)
        echo "ok"
        exit 0
        ;;
esac
exit 0
SH
chmod +x "$work/bin/xcrun"

echo "NOVA_APPLE_DEVELOPMENT_TEAM=ABCDE12345" > "$NOVA_ATV_DEPLOY_ENV"

staged_at=$(($(date +%s) - 600)) # older than the settle window, so it is due now
cat > "$NOVA_ATV_STAGING/current.json" <<JSON
{"schema": 1, "sha": "fixture0000000000", "short_sha": "fixture00", "branch": "test",
 "build_number": 9001, "subject": "test fixture", "staged_at": "fixture",
 "staged_at_epoch": $staged_at,
 "app_path": "$NOVA_ATV_STAGING/9001/NovaAppleTVDashboard.app"}
JSON

note "== running the deployer against a stubbed device =="
# shellcheck source=scripts/ci/deploy-when-awake.sh
"$here/deploy-when-awake.sh" --once
rc=$?
note "  exit status: $rc"
[ "$rc" -eq 0 ] || failures=$((failures + 1))

check "the device was asked what it has installed" "info apps" "$NOVA_ATV_CI_HOME/xcrun-calls.log"
check "the staged build was installed" "install app" "$NOVA_ATV_CI_HOME/xcrun-calls.log"
check "the app was launched" "process launch" "$NOVA_ATV_CI_HOME/xcrun-calls.log"
check "the launch was verified" "info processes" "$NOVA_ATV_CI_HOME/xcrun-calls.log"
check "the deploy was recorded" '"deployed_stamp": 9001' "$NOVA_ATV_CI_HOME/deployer-state.json"
check "no error was recorded" '"last_error": ""' "$NOVA_ATV_CI_HOME/deployer-state.json"

# The operator-facing entry point must answer the same way the deployer does.
note "== --awake-check says what the deployer sees =="
awake_out=$("$here/deploy-when-awake.sh" --awake-check)
awake_rc=$?
note "  '$awake_out' (exit $awake_rc)"
case "$awake_out" in
    awake*)
        note "  ok: reports awake while the stub says On"
        [ "$awake_rc" -eq 0 ] || failures=$((failures + 1))
        ;;
    *)
        note "  FAIL: expected an awake report while the stub says On"
        failures=$((failures + 1))
        ;;
esac

# The same run with the set asleep must not touch the device at all.
note "== the same run while the set is asleep =="
cat > "$NOVA_ATV_PYATV" <<'SH'
#!/bin/bash
echo "PowerState.Off"
exit 0
SH
chmod +x "$NOVA_ATV_PYATV"
rm -f "$NOVA_ATV_CI_HOME/xcrun-calls.log"
: > "$NOVA_ATV_STAGING/current.json"
cat > "$NOVA_ATV_STAGING/current.json" <<JSON
{"schema": 1, "sha": "fixture1111111111", "short_sha": "fixture11", "branch": "test",
 "build_number": 9002, "subject": "test fixture", "staged_at": "fixture",
 "staged_at_epoch": $staged_at,
 "app_path": "$NOVA_ATV_STAGING/9001/NovaAppleTVDashboard.app"}
JSON
"$here/deploy-when-awake.sh" --once >/dev/null 2>&1
rc=$?
note "  exit status: $rc (0 = correctly held)"
[ "$rc" -eq 0 ] || failures=$((failures + 1))
if [ -s "$NOVA_ATV_CI_HOME/xcrun-calls.log" ]; then
    note "  FAIL: the device was touched while the set was asleep:"
    sed 's/^/    /' "$NOVA_ATV_CI_HOME/xcrun-calls.log"
    failures=$((failures + 1))
else
    note "  ok: the device was never touched"
fi

asleep_out=$("$here/deploy-when-awake.sh" --awake-check)
asleep_rc=$?
note "  '$asleep_out' (exit $asleep_rc)"
case "$asleep_out" in
    not\ awake*)
        note "  ok: reports not awake while the stub says Off"
        [ "$asleep_rc" -eq 10 ] || failures=$((failures + 1))
        ;;
    *)
        note "  FAIL: expected a not-awake report while the stub says Off"
        failures=$((failures + 1))
        ;;
esac

if [ "$failures" -eq 0 ]; then
    note "PASS"
else
    note "FAILED ($failures)"
fi
rm -rf "$work"
[ "$failures" -eq 0 ]
