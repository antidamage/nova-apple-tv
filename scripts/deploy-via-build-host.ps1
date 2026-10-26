# Manual deploy: build, install, launch and verify the tvOS app on the Home
# Theatre Apple TV by hand.
#
# The normal path is the CI, not this script: push the change (open a PR, merge
# it into main) and a Forgejo Action on the build Mac
# builds the merged commit and stages the signed app, and a deployer installs it
# the next time the set is awake. Agents should let that happen rather than
# deploying by hand; the owner runs this when she wants one specific build on the
# set. See docs/CI-APPLETV-CI.md.
#
# It does not take the CI's lock (~/Build/nova-appletv-ci/lock on the build Mac),
# so do not run it while a CI build is in progress.
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildHost,
    [string]$SshKey = "$env:USERPROFILE\.ssh\id_ed25519",
    [string]$RemoteProject = "~/Build/NovaAppleTVDashboard",
    [Parameter(Mandatory = $true)]
    [string]$DeviceId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z0-9]+$")]
    [string]$DevelopmentTeam,
    [ValidatePattern("^[A-Za-z0-9.-]+$")]
    [string]$BundleId = "nz.co.skull.NovaAppleTVDashboard"
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Write-Host ""
    Write-Host "==> $Title"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Title failed with exit code $LASTEXITCODE"
    }
}

function Invoke-BuildHost {
    param([string]$Command)

    ssh -i $SshKey -o IdentitiesOnly=yes $BuildHost $Command
}

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ArchivePath = Join-Path $env:TEMP ("nova-appletv-dashboard-{0}.tar" -f (Get-Date -Format "yyyyMMddHHmmss"))
$RemoteArchive = "~/Build/NovaAppleTVDashboard.tar"

Push-Location $ProjectRoot
try {
    Invoke-Step "Package local tvOS project" {
        tar -cf $ArchivePath .
    }

    Invoke-Step "Copy project archive to build host" {
        scp -i $SshKey -o IdentitiesOnly=yes $ArchivePath "${BuildHost}:$RemoteArchive"
    }

    Invoke-Step "Unpack project on build host" {
        Invoke-BuildHost "rm -rf $RemoteProject && mkdir -p $RemoteProject && tar -C $RemoteProject -xf $RemoteArchive && chmod +x $RemoteProject/scripts/*.command"
    }

    Invoke-Step "Run signing-free tvOS simulator build" {
        Invoke-BuildHost "cd $RemoteProject && xcodebuild -project NovaAppleTVDashboard.xcodeproj -scheme NovaAppleTVDashboard -configuration Debug -destination 'generic/platform=tvOS Simulator' -derivedDataPath ./DerivedDataSim CODE_SIGNING_ALLOWED=NO build"
    }

    Invoke-Step "Run signed tvOS device build through build-host Terminal" {
        Invoke-BuildHost "rm -f $RemoteProject/gui-build.log $RemoteProject/gui-build.status && osascript $RemoteProject/scripts/run-device-build-in-terminal.applescript $DevelopmentTeam $BundleId"
    }

    Invoke-Step "Wait for signed build to finish" {
        Invoke-BuildHost "for i in {1..80}; do if [ -f $RemoteProject/gui-build.status ]; then break; fi; if [ -f $RemoteProject/gui-build.log ]; then tail -n 20 $RemoteProject/gui-build.log; else echo 'waiting for gui-build.log'; fi; sleep 5; done; if [ ! -f $RemoteProject/gui-build.status ]; then echo 'signed build did not finish'; exit 1; fi; tail -n 80 $RemoteProject/gui-build.log; test `$(cat $RemoteProject/gui-build.status) -eq 0"
    }

    Invoke-Step "Install app on Apple TV" {
        Invoke-BuildHost "xcrun devicectl device install app --device $DeviceId $RemoteProject/DerivedData/Build/Products/Debug-appletvos/NovaAppleTVDashboard.app"
    }

    Invoke-Step "Launch app on Apple TV" {
        Invoke-BuildHost "xcrun devicectl device process launch --device $DeviceId $BundleId"
    }

    Invoke-Step "Verify process is alive" {
        Invoke-BuildHost "xcrun devicectl device info processes --device $DeviceId | grep NovaAppleTVDashboard"
        Start-Sleep -Seconds 10
        Invoke-BuildHost "xcrun devicectl device info processes --device $DeviceId | grep NovaAppleTVDashboard"
    }
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $ArchivePath -ErrorAction SilentlyContinue
    Invoke-BuildHost "rm -f $RemoteArchive" | Out-Null
}
