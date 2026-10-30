# Install/update LS inside WSL from Windows with one command: install.cmd (repo root).
# Calls ops/install.sh (Linux) inside WSL, which defaults to the 'install' step only (code and
# dependencies, no config, no service running yet). From a WSL shell afterwards: lsb init, fill in
# the config, then lsb start. Safe to run install.cmd again any number of times.
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

# Pipe wsl.exe's own output to Out-Host: it still prints live, but none of those lines leak into
# this script's own return value (a native command's stdout otherwise becomes pipeline output too,
# which would corrupt $rc below into an array instead of a plain exit code).
& wsl.exe @dArgs -u root -- bash "$lx/ops/install.sh" | Out-Host
$rc = $LASTEXITCODE
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

Write-Host ">> Install done. Next, from a WSL shell: lsb init"
