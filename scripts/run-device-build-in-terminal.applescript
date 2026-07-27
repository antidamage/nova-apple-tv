on run argv
	set developmentTeam to item 1 of argv
	set bundleIdentifier to item 2 of argv
	tell application "Terminal"
		activate
		do script "cd ~/Build/NovaAppleTVDashboard && scripts/device-build.command " & quoted form of developmentTeam & " " & quoted form of bundleIdentifier
	end tell
end run
