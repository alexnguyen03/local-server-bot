@echo off
rem Install or update LS inside WSL with one command. Safe to run again any number of times.
rem Example: install.cmd   |   install.cmd -Distro Ubuntu-22.04   |   install.cmd -NoKeepalive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ops\wsl\install.ps1" %*
exit /b %ERRORLEVEL%
