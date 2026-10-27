# Run in PowerShell (Run as Administrator). Makes Windows start WSL automatically at boot,
# even before anyone logs in, so systemd inside WSL can start the bot.
# Check the distro name with: wsl -l -v
param([string]$distro = "Ubuntu")
$action    = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $distro -u root -e sh -c 'exec sleep infinity'"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType S4U -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "WSL-DeployBot-Keepalive" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
Start-ScheduledTask -TaskName "WSL-DeployBot-Keepalive"
