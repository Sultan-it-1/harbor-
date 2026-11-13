; Stops Harbor's own helper programs that are still running from the install folder, so their
; files can be replaced (update) or removed (uninstall). The installer closes the app itself,
; but on Windows its children live on when it is closed that way: the mpv.exe that makes the
; seek-bar thumbnails, a recording's mpv.exe, a download's ffmpeg or yt-dlp. A running one
; locks its .exe ("Error opening file for writing: ...\mpv.exe").
; Only copies inside this install folder are stopped: an mpv or ffmpeg the user has elsewhere
; is left alone. The folder reaches PowerShell through an environment variable, so a quote or
; any other character in the path can't break the command.
; Each process's path comes from Windows' own process list (Win32_Process), not Get-Process:
; the installer is a 32-bit program, so the PowerShell it starts is the 32-bit one, which can't
; read a 64-bit process's path through Get-Process (it comes back empty, and nothing was
; stopped). Taskkill then stops each one by its number, with its child processes.
!macro HARBOR_STOP_HELPERS
  System::Call 'Kernel32::SetEnvironmentVariable(t "HARBOR_INSTDIR", t "$INSTDIR\")'
  nsExec::Exec `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$$d = $$env:HARBOR_INSTDIR; $$names = @('mpv.exe','ffmpeg.exe','ffprobe.exe','yt-dlp.exe'); Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $$names -contains $$_.Name -and $$_.ExecutablePath -and $$_.ExecutablePath.StartsWith($$d, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { taskkill.exe /F /T /PID $$_.ProcessId | Out-Null }"`
  Pop $0
!macroend

!macro NSIS_HOOK_PREINSTALL
  ; Harbor: stop the stremio-server sidecar so its .exe isn't locked when we overwrite it during an update.
  ; Wildcard matches both stremio-server.exe and the triple-suffixed stremio-server-<triple>.exe; /T kills children.
  nsExec::Exec 'taskkill /F /T /FI "IMAGENAME eq stremio-server*"'
  Pop $0
  nsExec::Exec 'taskkill /F /T /IM stremio-server.exe'
  Pop $0
  !insertmacro HARBOR_STOP_HELPERS
  Sleep 1000
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro HARBOR_STOP_HELPERS
  Sleep 500
!macroend
