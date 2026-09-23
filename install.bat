@echo off
rem OmnyShell installer launcher for cmd.exe.
rem
rem   curl -fsSLo %TEMP%\omnyshell-install.bat https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.bat && %TEMP%\omnyshell-install.bat
rem
rem Runs install.ps1 (which does the work) with the same arguments: the copy
rem next to this file when there is one, otherwise the latest from GitHub.
rem Run "install.bat --help" for the options.
setlocal

set "OMNY_PS1="
rem Only trust a neighbouring install.ps1 that is ours (%TEMP% may hold others).
if exist "%~dp0install.ps1" findstr /c:"OmnyShell installer for Windows" "%~dp0install.ps1" >nul 2>&1 && set "OMNY_PS1=%~dp0install.ps1"
if not defined OMNY_PS1 (
  set "OMNY_PS1=%TEMP%\omnyshell-install.ps1"
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.ps1' -OutFile $env:OMNY_PS1"
  if errorlevel 1 (
    echo omnyshell-install: error: could not download install.ps1 1>&2
    exit /b 1
  )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%OMNY_PS1%" %*
exit /b %ERRORLEVEL%
