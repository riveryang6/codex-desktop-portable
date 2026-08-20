@echo off
setlocal EnableExtensions DisableDelayedExpansion

if not exist "C:\Input\release\CodexPortable.exe" (
  echo LF Portable release is missing C:\Input\release\CodexPortable.exe.
  pause
  exit /b 1
)

robocopy.exe "C:\Input\release" "C:\LFPortable" /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NP /NJH /NJS
if errorlevel 8 (
  echo Unable to copy the release into Windows Sandbox.
  pause
  exit /b 1
)

mkdir "C:\LFPortable\CodexData\data\config" 2>nul
mkdir "C:\LFPortable\CodexData\data\secrets" 2>nul
>"C:\LFPortable\CodexData\data\config\custom-api-url.txt" echo http://127.0.0.1:9
>"C:\LFPortable\CodexData\data\config\custom-model.txt" echo sandbox-local-probe
>"C:\LFPortable\CodexData\data\secrets\api-key.txt" echo sandbox-local-probe

start "" /D "C:\LFPortable" "C:\LFPortable\CodexPortable.exe"
echo.
echo In the LF launcher, click Start Codex and confirm that the Codex Desktop window opens.
echo Close Windows Sandbox after the manual check is complete.
pause
