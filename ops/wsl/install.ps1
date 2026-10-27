# Install/update LS inside WSL from Windows with one command: install.cmd (repo root).
# Calls ops/install.sh (Linux) inside WSL. Safe to run again any number of times.
# Params: -Distro <name>  pick a distro (see: wsl -l -v), default uses WSL's default distro
#         -NoKeepalive    skip creating the Scheduled Task that keeps WSL alive after a Windows reboot
# This file uses ASCII only so PowerShell 5.1 reads it correctly.
param([string]$Distro = "", [switch]$NoKeepalive)
$ErrorActionPreference = "Stop"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw "WSL not found. Install it with: wsl --install -d Ubuntu (needs admin, reboot), then run this again."
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$dArgs = @(); if ($Distro) { $dArgs = @("-d", $Distro) }

# Convert the Windows path to a Linux path via wslpath (respects the automount config).
$lx = (& wsl.exe @dArgs -u root -- wslpath -a ($root -replace '\\', '/')) | Select-Object -First 1
$lx = "$lx".Trim()
if (-not $lx) { throw "Could not convert the path into WSL. Check the distro name: wsl -l -v" }

function Invoke-Install {
  & wsl.exe @dArgs -u root -- bash "$lx/ops/install.sh"
  return $LASTEXITCODE
}

$rc = Invoke-Install
if ($rc -eq 10) {
  Write-Host ">> Just enabled systemd for WSL. Running wsl --shutdown, then retrying..."
  & wsl.exe --shutdown
  Start-Sleep -Seconds 3
  $rc = Invoke-Install
}
if ($rc -ne 0) { throw "install.sh failed (code $rc). See the log above." }

if (-not $NoKeepalive) {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($admin) {
    $name = if ($Distro) { $Distro } else { ((& wsl.exe -l -q) -join "" -replace "`0", "") -split "\s+" | Where-Object { $_ } | Select-Object -First 1 }
    & (Join-Path $PSScriptRoot "register-wsl-keepalive.ps1") -distro $name
  } else {
    Write-Warning "Did not create the Scheduled Task that keeps WSL alive after reboot (needs Administrator). Open cmd as 'Run as administrator' and run install.cmd again, or pass -NoKeepalive to skip it."
  }
}
