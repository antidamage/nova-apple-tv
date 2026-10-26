on run argv
	set developmentTeam to item 1 of argv
	set bundleIdentifier to item 2 of argv
	-- The build tree. Optional, so the existing two-argument callers are
	-- unchanged; the CI passes its own tree explicitly.
	if (count of argv) > 2 then
		set projectDir to item 3 of argv
	else
		set projectDir to (POSIX path of (path to home folder)) & "Build/NovaAppleTVDashboard"
	end if
	tell application "Terminal"
		activate
		do script "cd " & quoted form of projectDir & " && NOVA_ATV_BUILD_TREE=" & quoted form of projectDir & " scripts/device-build.command " & quoted form of developmentTeam & " " & quoted form of bundleIdentifier
	end tell
end run
