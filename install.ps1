# One-line Windows installer: irm https://raw.githubusercontent.com/alexnguyen03/local-server-bot/main/install.ps1 | iex
# No git clone needed. Makes sure WSL is available, then runs the Linux installer (install.sh) inside
# it. This only installs the code/dependencies — it does not generate config or start the bot. From
# a WSL shell afterwards: lsb init, fill in the config, then lsb start.
# Piped through iex, so this file must work with no local path of its own ($PSScriptRoot does not
# exist here) and takes overrides through env vars instead of parameters:
#   $env:LSB_REPO          GitHub "owner/repo" to install from (default: alexnguyen03/local-server-bot)
#   $env:LSB_DISTRO        WSL distro name to use (default: WSL's own default distro)
#   $env:LSB_NO_KEEPALIVE  set to "1" to skip the Scheduled Task that keeps WSL alive after reboot
$ErrorActionPreference = "Stop"

$Repo = if ($env:LSB_REPO) { $env:LSB_REPO } else { "alexnguyen03/local-server-bot" }
$Distro = $env:LSB_DISTRO
$LinuxUrl = "https://raw.githubusercontent.com/$Repo/main/install.sh"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw "WSL not found. Install it with: wsl --install -d Ubuntu (needs admin, reboot), then run this again."
}

$dArgs = @(); if ($Distro) { $dArgs = @("-d", $Distro) }

# Pipe wsl.exe's own output to Out-Host: it still prints live, but none of those lines leak into
# this script's own return value (a native command's stdout otherwise becomes pipeline output too,
# which would corrupt $rc below into an array instead of a plain exit code).
& wsl.exe @dArgs -u root -- bash -c "curl -fsSL '$LinuxUrl' | bash" | Out-Host
$rc = $LASTEXITCODE
if ($rc -ne 0) { throw "install failed (code $rc). See the log above." }

if ($env:LSB_NO_KEEPALIVE -ne "1") {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($admin) {
    $name = if ($Distro) { $Distro } else { ((& wsl.exe -l -q) -join "" -replace "`0", "") -split "\s+" | Where-Object { $_ } | Select-Object -First 1 }
    $action    = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $name -u root -e sh -c 'exec sleep infinity'"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType S4U -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "WSL-DeployBot-Keepalive" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName "WSL-DeployBot-Keepalive" | Out-Null
    Write-Host ">> Registered a Scheduled Task so WSL comes up again after a reboot."
  } else {
    Write-Warning "Did not create the Scheduled Task that keeps WSL alive after reboot (needs Administrator). Re-run as Administrator, or set `$env:LSB_NO_KEEPALIVE='1'` to skip it."
  }
}

Write-Host ">> Install done. Next, from a WSL shell: lsb init"
