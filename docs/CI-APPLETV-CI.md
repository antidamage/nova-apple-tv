# The Apple TV app's CI: a Forgejo Action on Indium

The Nova Apple TV dashboard (`nova-appletv-dashboard`, tvOS) is built on the
"Indium" Mac by the household's own Forgejo runner, and installed on the Home
Theatre Apple TV by a deployer that waits for the set to be switched on. All of
it is in the house: the repository, the job scheduling, the build, the logs and
the deployment.

`main` is the trunk: the branch the set is built from, the branch CI builds,
and the branch every change is merged into (`NOVA_ATV_BRANCH`). A work branch
is a temporary artifact of one change - created for a pull request, deleted
when that pull request is merged - so `main` is the only branch that should
exist here.

It carries the app's history from the 2026-07-27 publication (root `a6c5621`)
onward. The July 2026 private lineage that used to sit on `main` (root
`719eae1`, 2026-05-15) shares no ancestor with it; it is kept as an ancestor
of `main` with its content superseded, because the set runs the published
lineage's tree and nothing of the private one's.

**Agents let the CI deploy.** Push the change (pull request, then merge into
`main`) and the run builds it, stages it, and the deployer installs it the next
time the set is awake. Do not hand-deploy to finish a change, and never wake the
set to make a deploy happen.

The manual path still exists, for putting a specific build on the set by hand:
`scripts/deploy-via-build-host.ps1` and the workspace's
`deploy-nova-appletv.ps1` / `deploy-nova-appletv-fast.ps1` all still work. The one
difference for them is that every build now carries a real `CFBundleVersion`
build number (below), so the set can tell which build it is running.

## The shape of it

    forge push ──▶ Forgejo Action ──▶ runner on Indium ──▶ build + stage ──▶ deployer ──▶ Apple TV
    (in the house)   (.forgejo/)        (mac-appletv)        (Indium)          (Indium)     (Home Theatre)

| Piece | Where | What it does |
| --- | --- | --- |
| `.forgejo/workflows/appletv-ci.yml` | this repo | The job: check out the branch, build and stage, refresh the deployer, one deploy attempt |
| `scripts/ci/build-and-stage.sh` | Indium, run by the runner | Mirrors the checkout into `~/Build/NovaAppleTVDashboard`, runs the signed device build, stages the `.app` |
| `scripts/ci/deploy-when-awake.sh` | Indium, `nz.co.skull.nova-appletv-deployer` | Every 30s: installs and launches the newest staged build, but only while the Apple TV is awake |
| `forgejo-runner` | Indium, `nz.co.skull.forgejo-runner` | Runs the workflow's jobs in host mode, one at a time |

On Indium:

- build tree `/Users/<build-user>/Build/NovaAppleTVDashboard` (the same tree the
  manual path uses, so `DerivedData` and therefore the incremental build are
  shared)
- CI home `/Users/<build-user>/Build/nova-appletv-ci` (scripts, the runner, the pyatv
  virtualenv, state, logs)
- staging `/Users/<build-user>/Build/nova-appletv-staging/<build-number>` plus
  `current.json`, which names the build the deployer should install
- private configuration `/Users/<build-user>/.config/nova-apple-tv/`: `deploy.env`
  (signing team, camera overrides), `atv-credentials.json` (the set's pyatv
  pairing), `forgejo-runner-token` (one-time registration token, deletable after)

## Why the deployer, and not a deploy step

The Apple TV is deployed to **only while it is awake**. A build that wanted to
deploy could not wait for that: an evening push would hold the job all night,
and a build that installs while the set is asleep leaves the app installed but
not running. So the build ends at the staging directory, and a long-running
deployer watches for the moment the set is switched on. Nothing in the pipeline
ever turns the TV on.

**The awake test is pyatv's power-state query, and it has to be passive.** Every
`devicectl` call wakes a sleeping Apple TV - measured on 2026-09-21, `device
info details` brought the set out of standby within five seconds, and
`info displays` reports `backlightState: activeOn` while it is suspended, so it
cannot tell you anything - which means a device-side probe would switch the TV
on rather than observe it. Instead the deployer asks the set's own companion
service over pyatv:

```sh
atvremote --scan-hosts <address> -t 5 --id <mac> \
    --companion-credentials "$(…)" power_state      # PowerState.Off | On | Idle
```

`Off` is what a suspended set reports (and answering while suspended is exactly
what it does for Home Assistant too), so the query never wakes it: verified on
2026-09-21 by polling the set three times while it slept and watching Home
Assistant's `media_player.home_theatre` - its state had not changed since the
set was last switched off hours earlier. A sleeping set is left completely
alone, and the staged build simply waits.

If the query cannot answer - no pyatv, no pairing, a timeout, an unrecognised
power state - the deployer treats it as "cannot tell" and does **not** touch the
device. That direction is deliberate: a missed deployment is recoverable, a
deployment while the set is asleep is what this whole design exists to prevent.

## Deploying the newest build, once, for every change

- The deployer installs only when the staged build number is **higher than the
  build already on the device**, and only ever installs the newest staged build.
  A burst of pushes therefore ends in one deployment carrying all of them.
- A staged build must also **settle** for `NOVA_ATV_SETTLE_SECONDS` (120) before
  it is installed, so a burst that lands while the set is awake still deploys
  once - as the newest build - instead of once per commit, each one stealing the
  screen in turn.
- The runner runs one job at a time, and a build is built from **the commit that
  triggered it**, not the branch tip. A run whose commit has been superseded on
  the branch stops before it clones anything, so a burst of five pushes costs one
  compilation rather than five - verified by the skip line appearing in a run's
  log while the newer commit's own run builds.
- The build step holds a lock while it works and waits up to 900s for a deploy
  in progress to finish, so a commit is never dropped just because the deployer
  was mid-install.
- Every build carries a monotonically increasing `CFBundleVersion` - seconds
  since the epoch, written by `scripts/device-build.command` - which is what
  "newer than what the Apple TV has" compares. The manual path stamps too, so a
  build installed by hand is respected rather than fought over: if the device
  reports a higher number than the staged build, nothing is installed. Seconds
  rather than minutes so no two builds can share a number: a staged build whose
  number matched the device's would be treated as already installed, and the
  newer commit would silently never arrive.

The branch the set is built from appears in: the job-level `env` in
`.forgejo/workflows/appletv-ci.yml`, which is what the guard compares against;
the `on.push.branches` list beside it; `NOVA_ATV_BRANCH` in
`scripts/ci/ci-config.sh`, the fallback for whatever sources that file
directly (the deployer's own shell); the `GITHUB_REF_NAME` fallback in the
workflow's build step; and this document. A build whose checkout branch is not
`NOVA_ATV_BRANCH` says so in its log. The workflow setting the value matters on
the first run after the branch changes: the copy installed on Indium is
refreshed by `install-ci.sh`, which runs after that run's build has already
sourced it, so a stale installed value would refuse the new branch exactly
once, and it would be the run that would have fixed it.

## Who can run what

Automatic runs come only from `main`. A manual run (`workflow_dispatch`)
can build another ref, but only when the run is started with
`allow_other_branch=yes`: the ref a run builds is the code that job executes, and
its build number is stamped "now", so it would outrank whatever is on the set and
be installed.

That guard is against accidents, not against malice. The job runs the checkout's
own scripts as the login user, because signing needs that session's keychain -
so anyone who can push a branch to this repository can, in practice, run code on
Indium. That is the same trust level the manual deploy scripts have always had,
and the reason this runner is on a household machine rather than a shared one.

## Operating it

```sh
# are the services up?
ssh indium-nova-ha-tasks 'launchctl print gui/501/nz.co.skull.nova-appletv-deployer \
  gui/501/nz.co.skull.forgejo-runner >/dev/null && echo up'

# what has the deployer been doing?
ssh indium-nova-ha-tasks 'tail -40 ~/Build/nova-appletv-ci/deploy-when-awake.sh.log'

# deploy right now if the set is awake; waits out the settle window (<=120s)
ssh indium-nova-ha-tasks '~/Build/nova-appletv-ci/deploy-when-awake.sh --once'

# ask the set directly - this is the deployer's own awake test, and it does not
# wake the set (0 = awake, 10 = not awake, 1 = cannot tell)
ssh indium-nova-ha-tasks '~/Build/nova-appletv-ci/deploy-when-awake.sh --awake-check'

# the deploy path itself, without needing the Apple TV: the device and the set's
# power state are stubbed, and the test asserts that a newer staged build really
# is installed and launched, and that a sleeping set is never touched at all
ssh indium-nova-ha-tasks '~/Build/nova-appletv-ci/test-deploy-path.sh'

# build a revision by hand. NOVA_ATV_BUILD_VIA_TERMINAL=1 matters: an ssh session
# has no GUI session, so Xcode cannot reach the signing keychain without it.
ssh indium-nova-ha-tasks 'rm -rf /tmp/atv-manual && git clone --quiet --depth 1 \
  --branch main \
  ssh://git@forge.example:2222/antidamage/nova-appletv-dashboard.git \
  /tmp/atv-manual && NOVA_ATV_BUILD_VIA_TERMINAL=1 \
  /tmp/atv-manual/scripts/ci/build-and-stage.sh /tmp/atv-manual'
```

State files worth knowing: `~/Build/nova-appletv-ci/deployer-state.json`
(`deployed_stamp`, `deployed_sha`, `pending_launch`, `last_error`). Deleting it
makes the deployer re-check the device on its next cycle.

A build or install holds `~/Build/nova-appletv-ci/lock`; the manual PowerShell
path predates that lock and does not take it, so do not run
`deploy-nova-appletv.ps1` while a CI build is going. If the lock is ever left
behind by a killed process it is taken over immediately (the holder's pid is
checked) or after an hour on age alone, and deleting the directory also clears
it.

## Setting it up from scratch (a rebuilt Indium)

1. `brew install go` then build the runner, because Forgejo publishes Linux
   binaries only:
   `git clone --branch v13.2.0 --depth 1 https://code.forgejo.org/forgejo/runner && cd runner && go build -o /usr/local/bin/forgejo-runner .`
2. Get this repository onto the box by whatever credential is to hand, then run
   `scripts/ci/install-ci.sh --with-runner`. Add the printed
   `~/.ssh/id_ed25519.pub` to the repository as a **read-only deploy key** - the
   runner clones with it.
3. Register the runner: take a token from
   `GET /api/v1/repos/antidamage/nova-appletv-dashboard/actions/runners/registration-token`
   on the forge, put it in `~/.config/nova-apple-tv/forgejo-runner-token`, and
   re-run `scripts/ci/install-ci.sh --with-runner`. The label is
   `mac-appletv:host`: jobs run directly on this Mac (there is no Docker here,
   and the build needs the logged-in session's signing keychain for Xcode).
4. Let `install-ci.sh` build the pyatv virtualenv (it does this when
   `~/Build/nova-appletv-ci/venv` is missing) and put the set's pairing
   credentials in `~/.config/nova-apple-tv/atv-credentials.json` as
   `{"address": ..., "identifiers": [<mac>], "credentials": {"4": <companion>}}`
   - Home Assistant's stored pairing for the same set can be copied straight
     across (it is `credentials` in the `apple_tv` config entry, keyed by pyatv
     protocol number).
5. Confirm both LaunchAgents are running, then push something small to `main`
   and watch the run.

Everything after step 5 is re-applied by the workflow itself, which re-runs
`install-ci.sh` each time so a change to `scripts/ci/` reaches the Mac on the
next build. The runner is deliberately not reloaded from inside a job; use
`--with-runner` by hand for that.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No run after a push | The workflow's `on.push.branches` list, and the Actions tab on the repository (Actions must be enabled for the repo) |
| "refusing to build '<ref>'" | A manual run on a branch other than `NOVA_ATV_BRANCH` without `allow_other_branch=yes` - the guard doing its job |
| "not building <sha> (a newer run will)" | The run was superseded by a newer push; correct, and nothing is staged |
| Run queued forever | Is the runner up (`launchctl print gui/501/nz.co.skull.forgejo-runner`) and registered with the `mac-appletv` label? Its log is `~/Build/nova-appletv-ci/runner/runner.log` |
| Build fails at `osascript` | Only the `NOVA_ATV_BUILD_VIA_TERMINAL=1` path uses Terminal; the runner builds directly, in the session whose keychain Xcode needs |
| "is mid-install (lock held)" | `install-ci.sh` left the deployer alone because it was installing; the next build restarts it with the new scripts |
| Build fails to sign, "No Accounts" | The build is running outside the GUI session (an ssh hand-run without `NOVA_ATV_BUILD_VIA_TERMINAL=1`) |
| `No route to host` from python | macOS Local Network Privacy is refusing that interpreter. It must be `/usr/bin/python3`; Homebrew's Python is blocked from the local network in a launchd context |
| Build succeeded, device unchanged | The deployer's log: asleep is expected - it deploys when the set is next switched on |
| "cannot tell whether the Apple TV is awake" | `deploy-when-awake.sh --awake-check`; is the pairing in `atv-credentials.json` (address, identifiers, key `"4"` for the companion)? |
| "letting it settle" over and over | A build is landing inside `NOVA_ATV_SETTLE_SECONDS` each time; it deploys once the pushes stop |
| Everything waits, "waiting for …/lock" | A build or install holds the lock; if no such process exists, delete `~/Build/nova-appletv-ci/lock` |
