#!/bin/bash
# Install (or refresh) the Nova Apple TV CI on the Indium build Mac.
#
#   nz.co.skull.nova-appletv-deployer  installs the newest staged build on the
#                                      Home Theatre Apple TV, but only while the
#                                      set is awake (deploy-when-awake.sh)
#   nz.co.skull.forgejo-runner         runs this repository's Forgejo Action,
#                                      which builds and stages (--with-runner)
#
# The workflow re-runs this script on every build, so a change to scripts/ci/
# reaches the Mac without anyone logging in. The runner is only touched with
# --with-runner - it must never restart itself from inside a job it is running -
# and the agent used to drive this is gone for good: --remove-buildkite clears
# out what the earlier hosted-CI wiring left behind.
#
# Usage:
#   scripts/ci/install-ci.sh                  refresh scripts + the deployer
#   scripts/ci/install-ci.sh --with-runner    also install/refresh the runner
#   scripts/ci/install-ci.sh --remove-buildkite
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/ci/ci-config.sh
. "$here/ci-config.sh"

mode=deployer
case "${1:-}" in
    --with-runner) mode=runner ;;
    --remove-buildkite) mode=unbuildkite ;;
    '') ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

uid=$(id -u)
plist_dir=$HOME/Library/LaunchAgents
runner_dir=$NOVA_ATV_CI_HOME/runner
runner_cfg=$runner_dir/config.yaml
runner_bin=${NOVA_ATV_RUNNER_BIN:-/usr/local/bin/forgejo-runner}
forge_url=${NOVA_ATV_FORGE_URL:-https://forge.example:3300}
runner_token_file=${NOVA_ATV_RUNNER_TOKEN_FILE:-$HOME/.config/nova-apple-tv/forgejo-runner-token}
mkdir -p "$NOVA_ATV_CI_HOME" "$plist_dir"

install_script() { # install_script <name>: write only when changed, never in place
    local changed=false
    if ! cmp -s "$here/$1" "$NOVA_ATV_CI_HOME/$1"; then changed=true; fi
    if [ "$changed" = true ]; then
        # Replace by rename: the daemons execute these files out of this
        # directory, and truncating one under a running loop would end the loop
        # (or feed it half a file). A rename leaves the running process on the
        # old inode, which is why the services are restarted below.
        install -m 755 "$here/$1" "$NOVA_ATV_CI_HOME/$1.tmp.$$"
        mv -f "$NOVA_ATV_CI_HOME/$1.tmp.$$" "$NOVA_ATV_CI_HOME/$1"
        echo "$1 updated"
        return 0
    fi
    return 1
}

restart_if_running() { # restart_if_running <label>
    # SIGTERM, never `kickstart -k`: that is a SIGKILL, which the deployer cannot
    # trap, so a restart landing inside an install would strand the lock (and the
    # install) for the full staleness window. KeepAlive brings it back after it
    # exits cleanly.
    #
    # And not at all while it holds the lock: that means it is mid-install, and
    # killing it there interrupts a device install part-way (the next cycle
    # retries, but there is no reason to cause it). The next run of this script
    # picks the change up instead.
    if [ -d "$NOVA_ATV_LOCK_PATH" ]; then
        nova_atv_log "$1 is mid-install (lock held); it will take the new scripts on a later run"
        return 0
    fi
    if launchctl print "gui/$uid/$1" >/dev/null 2>&1; then
        if launchctl kill SIGTERM "gui/$uid/$1" >/dev/null 2>&1; then
            nova_atv_log "asked $1 to restart so it runs the updated scripts"
        else
            nova_atv_log "could not signal $1; it keeps running the copy it started with"
        fi
    fi
}

render_deployer_plist() {
    cat > "$NOVA_ATV_CI_HOME/nz.co.skull.nova-appletv-deployer.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>nz.co.skull.nova-appletv-deployer</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$NOVA_ATV_CI_HOME/deploy-when-awake.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$NOVA_ATV_CI_HOME</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$NOVA_ATV_CI_HOME/deploy-when-awake.sh.log</string>
    <key>StandardErrorPath</key>
    <string>$NOVA_ATV_CI_HOME/deploy-when-awake.sh.err.log</string>
</dict>
</plist>
PLIST
}

render_runner_plist() {
    cat > "$NOVA_ATV_CI_HOME/nz.co.skull.forgejo-runner.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>nz.co.skull.forgejo-runner</string>
    <key>ProgramArguments</key>
    <array>
        <string>$runner_bin</string>
        <string>daemon</string>
        <string>--config</string>
        <string>$runner_cfg</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$runner_dir</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$runner_dir/runner.log</string>
    <key>StandardErrorPath</key>
    <string>$runner_dir/runner.err.log</string>
</dict>
</plist>
PLIST
}

load_plist() { # load_plist <label>: reload on change, and restore a job that is
    # installed but not loaded (a hand `launchctl bootout` used to be permanent,
    # because a matching plist returned early and was never bootstrapped again).
    # Sets plist_just_loaded to the label when it bootstrapped the job, so the
    # caller does not signal a service it has only now started.
    local label=$1 rendered=$NOVA_ATV_CI_HOME/$1.plist
    local installed=$plist_dir/$label.plist
    local loaded=false
    plist_just_loaded=
    launchctl print "gui/$uid/$label" >/dev/null 2>&1 && loaded=true || true
    if [ -f "$installed" ] && cmp -s "$rendered" "$installed" && [ "$loaded" = true ]; then
        return 0
    fi
    cp "$rendered" "$installed"
    if [ "$loaded" = true ]; then
        launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    fi
    if launchctl bootstrap "gui/$uid" "$installed" >/dev/null 2>&1; then
        nova_atv_log "loaded $label"
        plist_just_loaded=$label
    else
        nova_atv_log "could not load $label (is a GUI session open for uid $uid?)"
        service_failures=$((service_failures + 1))
    fi
}

remove_buildkite() { # the hosted-CI wiring this repository used before
    local label=nz.co.skull.buildkite-agent
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
        nova_atv_log "unloaded $label"
    fi
    rm -f "$plist_dir/$label.plist"
    rm -f "$plist_dir/nz.co.skull.nova-appletv-trigger.plist"
    if launchctl print "gui/$uid/nz.co.skull.nova-appletv-trigger" >/dev/null 2>&1; then
        launchctl bootout "gui/$uid/nz.co.skull.nova-appletv-trigger" >/dev/null 2>&1 || true
    fi
    rm -rf "$HOME/.buildkite-agent"
    rm -f "$NOVA_ATV_CI_HOME/trigger-build.sh" "$NOVA_ATV_CI_HOME/trigger-build.sh.log" \
        "$NOVA_ATV_CI_HOME/trigger-build.sh.err.log" "$NOVA_ATV_CI_HOME/trigger-state.json" \
        "$NOVA_ATV_CI_HOME/nz.co.skull.buildkite-agent.plist" \
        "$NOVA_ATV_CI_HOME/nz.co.skull.nova-appletv-trigger.plist"
    nova_atv_log "removed the Buildkite agent, its config and the forge poller"
    if [ -d /usr/local/Cellar/buildkite-agent ] || [ -e /usr/local/bin/buildkite-agent ]; then
        export PATH=/usr/local/bin:$PATH
        HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --force buildkite-agent >/dev/null 2>&1 &&
            nova_atv_log "uninstalled the buildkite-agent formula" ||
            nova_atv_log "could not uninstall buildkite-agent; remove it by hand"
    fi
}

ensure_pyatv() {
    # pyatv is installed on the Mac's own /usr/bin/python3, not Homebrew's, for a
    # reason that cost a while to find: macOS Local Network Privacy lets a system
    # binary reach the local network from a launchd agent, and blocks a Homebrew
    # one (measured 2026-09-22: the deployer's own context got EHOSTUNREACH from
    # the Homebrew interpreter while /usr/bin/python3 and dns-sd were fine). The
    # version is the newest that still supports Python 3.9, and is installed from
    # wheels only so pip never tries to build a Rust toolchain.
    local marker=$NOVA_ATV_CI_HOME/venv/.nova-interpreter
    local wanted=/usr/bin/python3
    if [ -x "$NOVA_ATV_PYATV" ] && [ "$(cat "$marker" 2>/dev/null)" = "$wanted" ]; then
        echo "pyatv:       present ($("$NOVA_ATV_PYATV_PYTHON" -c 'import importlib.metadata as m; print(m.version("pyatv"))' 2>/dev/null || echo version unknown) on $("$NOVA_ATV_PYATV_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null))"
        return 0
    fi

    echo "pyatv:       installing into $NOVA_ATV_CI_HOME/venv on $wanted"
    rm -rf "$NOVA_ATV_CI_HOME/venv"
    "$wanted" -m venv "$NOVA_ATV_CI_HOME/venv" >/dev/null 2>&1 || true
    "$NOVA_ATV_CI_HOME/venv/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
    if "$NOVA_ATV_CI_HOME/venv/bin/pip" install --quiet --only-binary=:all: \
        "pyatv==$NOVA_ATV_PYATV_VERSION" >/dev/null 2>&1 && [ -x "$NOVA_ATV_PYATV" ]; then
        printf '%s\n' "$wanted" > "$marker"
        echo "pyatv:       installed $NOVA_ATV_PYATV_VERSION"
    else
        echo "pyatv:       install FAILED - the deployer cannot tell whether the set is awake without it"
        return 1
    fi
}

register_runner() {
    # One-time: the runner needs a registration token from the forge. Everything
    # after this is automatic, and the daemon starts on login.
    if [ -f "$runner_dir/.runner" ]; then
        echo "runner:      already registered"
        return 0
    fi
    local token=${NOVA_ATV_RUNNER_TOKEN:-}
    if [ -z "$token" ] && [ -f "$runner_token_file" ]; then
        token=$(cat "$runner_token_file")
    fi
    if [ -z "$token" ]; then
        echo "runner:      NOT registered - get a token with:"
        echo "             curl -H 'Authorization: token <forgejo token>' \\"
        echo "               '${forge_url}/api/v1/repos/antidamage/nova-appletv-dashboard/actions/runners/registration-token'"
        echo "             then: echo <token> > $runner_token_file && scripts/ci/install-ci.sh --with-runner"
        return 1
    fi
    mkdir -p "$runner_dir"
    # The registration result is written to the working directory and read back
    # from the daemon's, so register from the runner's own directory.
    if ( cd "$runner_dir" && "$runner_bin" register --no-interactive --config "$runner_cfg" \
            --instance "$forge_url" --token "$token" --name "indium-$(hostname -s)" \
            --labels "mac-appletv:host" ) >/dev/null 2>&1; then
        nova_atv_log "registered this Mac as runner mac-appletv (host mode)"
    else
        nova_atv_log "runner registration failed - check $forge_url is reachable"
        return 1
    fi
    if ! grep -q "mac-appletv" "$runner_dir/.runner" 2>/dev/null; then
        nova_atv_log "warning: $runner_dir/.runner does not list the mac-appletv label"
    fi
}

render_runner_config() {
    # Generated by the runner itself, so the file matches its version. Labels are
    # not in there: the daemon takes them from the .runner registration record,
    # and `capacity: 1` (one job at a time) is already the default.
    [ -d "$runner_dir" ] || mkdir -p "$runner_dir"
    if [ -f "$runner_cfg" ]; then
        return 0
    fi
    "$runner_bin" generate-config > "$runner_cfg" 2>/dev/null ||
        { nova_atv_log "could not generate $runner_cfg"; return 1; }
    nova_atv_log "wrote $runner_cfg (host mode, one job at a time)"
}

# --- do it ------------------------------------------------------------------

if [ "$mode" = "unbuildkite" ]; then
    remove_buildkite
    exit 0
fi

service_failures=0
deployer_stale=false
install_script ci-config.sh && deployer_stale=true || true
install_script deploy-when-awake.sh && deployer_stale=true || true
install_script test-deploy-path.sh || true

render_deployer_plist
load_plist nz.co.skull.nova-appletv-deployer
if [ "$deployer_stale" = true ] && [ "$plist_just_loaded" != nz.co.skull.nova-appletv-deployer ]; then
    restart_if_running nz.co.skull.nova-appletv-deployer
fi

if [ "$mode" = "runner" ]; then
    if [ ! -x "$runner_bin" ]; then
        nova_atv_log "no forgejo-runner at $runner_bin - Forgejo publishes Linux binaries only, so build it:"
        nova_atv_log "  git clone --branch v13.2.0 --depth 1 https://code.forgejo.org/forgejo/runner /tmp/runner-src"
        nova_atv_log "  (cd /tmp/runner-src && go build -o /usr/local/bin/forgejo-runner .)"
        service_failures=$((service_failures + 1))
    else
        render_runner_config || true
        if register_runner; then
            render_runner_plist
            load_plist nz.co.skull.forgejo-runner
        else
            service_failures=$((service_failures + 1))
        fi
    fi
fi

# The forge deploy key the runner and any hand clone use. Buildkite read keys
# from the agent user's ~/.ssh; so does everything here.
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C 'nova-appletv-ci@indium' -f "$HOME/.ssh/id_ed25519"
    nova_atv_log "generated ~/.ssh/id_ed25519 for the forge checkout"
fi

echo
echo "== Nova Apple TV CI on $(hostname -s) =="
launchctl print "gui/$uid/nz.co.skull.nova-appletv-deployer" >/dev/null 2>&1 &&
    echo "deployer:    running" || echo "deployer:    NOT running"
launchctl print "gui/$uid/nz.co.skull.forgejo-runner" >/dev/null 2>&1 &&
    echo "runner:      running" || echo "runner:      not loaded (needs --with-runner and a registration token)"
ensure_pyatv
[ -f "$NOVA_ATV_ATV_CREDENTIALS" ] &&
    echo "pairing:     present" || echo "pairing:     MISSING at $NOVA_ATV_ATV_CREDENTIALS"
echo
echo "Deploy key for the forge checkout (read-only deploy key on the repository):"
cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true

# Report a service that would not load, but only after everything else has been
# attempted: this runs on every build, and one unlucky job must not stop the
# others from being refreshed.
[ "$service_failures" -eq 0 ] || exit 1
