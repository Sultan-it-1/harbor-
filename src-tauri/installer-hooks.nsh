; Stops Harbor's own helper programs that are still running from the install folder, so their
; files can be replaced (update) or removed (uninstall). The installer closes the app itself,
; but on Windows its children live on when it is closed that way: the mpv.exe that makes the
; seek-bar thumbnails, a recording's mpv.exe, a download's ffmpeg or yt-dlp. A running one
; locks its .exe ("Error opening file for writing: ...\mpv.exe").
; Only copies inside this install folder are stopped: an mpv or ffmpeg the user has elsewhere
; is left alone. The folder reaches PowerShell through an environment variable, so a quote or
; any other character in the path can't break the command.
!macro HARBOR_STOP_HELPERS
  System::Call 'Kernel32::SetEnvironmentVariable(t "HARBOR_INSTDIR", t "$INSTDIR\")'
  nsExec::Exec `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$$d = $$env:HARBOR_INSTDIR; Get-Process -Name mpv,ffmpeg,ffprobe,yt-dlp -ErrorAction SilentlyContinue | Where-Object { $$_.Path -and $$_.Path.StartsWith($$d, [System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue"`
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
