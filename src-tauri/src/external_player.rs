//! "Open in another player": finds the media players installed on this computer and starts one
//! with the stream Harbor is playing, at the same position when the player can do that.
//!
//! A player is always started directly with a list of arguments, never through a shell, so an
//! address with spaces, quotes, `&`, `%` or `^` reaches the player exactly as it is.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::stream_proxy::ProxyState;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
enum Player {
    Vlc,
    Mpv,
    PotPlayer,
    MpcHc,
}

/// The players we look for, in the order the menu lists them. PotPlayer and MPC-HC only
/// exist for Windows.
#[cfg(windows)]
const PLAYERS: &[Player] = &[Player::Vlc, Player::Mpv, Player::PotPlayer, Player::MpcHc];
#[cfg(not(windows))]
const PLAYERS: &[Player] = &[Player::Vlc, Player::Mpv];

impl Player {
    fn id(self) -> &'static str {
        match self {
            Player::Vlc => "vlc",
            Player::Mpv => "mpv",
            Player::PotPlayer => "potplayer",
            Player::MpcHc => "mpc-hc",
        }
    }

    fn name(self) -> &'static str {
        match self {
            Player::Vlc => "VLC",
            Player::Mpv => "mpv",
            Player::PotPlayer => "PotPlayer",
            Player::MpcHc => "MPC-HC",
        }
    }

    fn from_id(id: &str) -> Option<Self> {
        PLAYERS.iter().copied().find(|p| p.id() == id)
    }

    /// Whether the player has a command-line option for sending this request header.
    fn sends_header(self, name: &str) -> bool {
        match self {
            Player::Mpv => true,
            // VLC and PotPlayer only have options for these two.
            Player::Vlc | Player::PotPlayer => {
                name.eq_ignore_ascii_case("user-agent") || name.eq_ignore_ascii_case("referer")
            }
            Player::MpcHc => false,
        }
    }
}

/// The program names a player has when it is found through the PATH.
#[cfg(windows)]
fn program_names(p: Player) -> &'static [&'static str] {
    match p {
        Player::Vlc => &["vlc.exe"],
        Player::Mpv => &["mpv.exe"],
        Player::PotPlayer => &["PotPlayerMini64.exe", "PotPlayerMini.exe"],
        Player::MpcHc => &["mpc-hc64.exe", "mpc-hc.exe"],
    }
}

#[cfg(not(windows))]
fn program_names(p: Player) -> &'static [&'static str] {
    match p {
        Player::Vlc => &["vlc"],
        Player::Mpv => &["mpv"],
        Player::PotPlayer | Player::MpcHc => &[],
    }
}

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// Where the installers put each player on Windows. Checked before the PATH because the
/// installers of VLC, PotPlayer and MPC-HC don't add themselves to it.
#[cfg(windows)]
fn install_locations(p: Player) -> Vec<PathBuf> {
    // Both Program Files folders: from the environment, and at their usual place in case the
    // variables are missing.
    let mut program_dirs: Vec<PathBuf> = Vec::new();
    let usual = [PathBuf::from(r"C:\Program Files"), PathBuf::from(r"C:\Program Files (x86)")];
    let from_env = ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"]
        .iter()
        .filter_map(|v| env_dir(v));
    for d in from_env.chain(usual) {
        if !program_dirs.iter().any(|x| x.as_os_str().eq_ignore_ascii_case(d.as_os_str())) {
            program_dirs.push(d);
        }
    }
    let local = env_dir("LOCALAPPDATA");
    let home = env_dir("USERPROFILE");
    let program_data = env_dir("ProgramData");

    let mut out = Vec::new();
    match p {
        Player::Vlc => {
            for d in &program_dirs {
                out.push(d.join(r"VideoLAN\VLC\vlc.exe"));
            }
        }
        Player::Mpv => {
            // mpv has no installer: people unpack it somewhere or use a package manager.
            for d in &program_dirs {
                out.push(d.join(r"mpv\mpv.exe"));
            }
            if let Some(l) = &local {
                out.push(l.join(r"Programs\mpv\mpv.exe"));
                out.push(l.join(r"Microsoft\WinGet\Links\mpv.exe"));
            }
            if let Some(h) = &home {
                out.push(h.join(r"scoop\apps\mpv\current\mpv.exe"));
            }
            if let Some(pd) = &program_data {
                out.push(pd.join(r"scoop\apps\mpv\current\mpv.exe"));
                out.push(pd.join(r"chocolatey\bin\mpv.exe"));
            }
        }
        Player::PotPlayer => {
            for d in &program_dirs {
                for sub in [r"DAUM\PotPlayer", "PotPlayer", r"Kakao\PotPlayer"] {
                    for exe in ["PotPlayerMini64.exe", "PotPlayerMini.exe"] {
                        out.push(d.join(sub).join(exe));
                    }
                }
            }
        }
        Player::MpcHc => {
            // Its own installer, and the copy that comes with the K-Lite Codec Pack.
            for d in &program_dirs {
                for sub in ["MPC-HC", r"K-Lite Codec Pack\MPC-HC64", r"K-Lite Codec Pack\MPC-HC"] {
                    for exe in ["mpc-hc64.exe", "mpc-hc.exe"] {
                        out.push(d.join(sub).join(exe));
                    }
                }
            }
        }
    }
    out
}

/// Where VLC and mpv usually are on macOS. An app started from the Dock has a short PATH, so
/// the Homebrew and MacPorts folders are listed here too.
#[cfg(target_os = "macos")]
fn install_locations(p: Player) -> Vec<PathBuf> {
    let mut apps = vec![PathBuf::from("/Applications")];
    if let Some(h) = env_dir("HOME") {
        apps.push(h.join("Applications"));
    }
    let mut out = Vec::new();
    match p {
        Player::Vlc => {
            for a in &apps {
                out.push(a.join("VLC.app/Contents/MacOS/VLC"));
            }
        }
        Player::Mpv => {
            for a in &apps {
                out.push(a.join("mpv.app/Contents/MacOS/mpv"));
            }
            for d in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
                out.push(Path::new(d).join("mpv"));
            }
        }
        Player::PotPlayer | Player::MpcHc => {}
    }
    out
}

/// Where VLC and mpv usually are on Linux, including the launchers Snap and Flatpak create.
/// An app started from the desktop menu can have a short PATH, so these are listed too.
#[cfg(all(unix, not(target_os = "macos")))]
fn install_locations(p: Player) -> Vec<PathBuf> {
    let (bin, flatpak) = match p {
        Player::Vlc => ("vlc", "org.videolan.VLC"),
        Player::Mpv => ("mpv", "io.mpv.Mpv"),
        Player::PotPlayer | Player::MpcHc => return Vec::new(),
    };
    let mut out: Vec<PathBuf> = ["/usr/bin", "/usr/local/bin", "/snap/bin"]
        .iter()
        .map(|d| Path::new(d).join(bin))
        .collect();
    out.push(Path::new("/var/lib/flatpak/exports/bin").join(flatpak));
    if let Some(h) = env_dir("HOME") {
        out.push(h.join(".local/share/flatpak/exports/bin").join(flatpak));
    }
    out
}

fn usable(path: &Path) -> bool {
    match std::fs::metadata(path) {
        Ok(m) if m.is_file() => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                m.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                true
            }
        }
        _ => false,
    }
}

fn find(p: Player) -> Option<PathBuf> {
    if let Some(found) = install_locations(p).into_iter().find(|c| usable(c)) {
        return Some(found);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        // A relative entry would mean "the current folder", which could run anything.
        .filter(|dir| dir.is_absolute())
        .flat_map(|dir| program_names(p).iter().map(move |n| dir.join(n)))
        .find(|c| usable(c))
}

#[derive(Serialize)]
pub struct ExternalPlayer {
    id: &'static str,
    name: &'static str,
    path: String,
}

/// The supported players that are installed, in menu order. The system's default app is not
/// in the list: the page always offers it.
#[tauri::command]
pub async fn external_players_list() -> Result<Vec<ExternalPlayer>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        PLAYERS
            .iter()
            .filter_map(|&p| {
                find(p).map(|path| ExternalPlayer {
                    id: p.id(),
                    name: p.name(),
                    path: path.to_string_lossy().into_owned(),
                })
            })
            .collect()
    })
    .await
    .map_err(|e| e.to_string())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenArgs {
    /// A player id from the list, or "system" for the system's default app.
    pub player: String,
    pub url: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub start_sec: Option<f64>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
}

enum Target {
    File(PathBuf),
    Url(String),
}

/// Network addresses a player may get. Anything else (javascript:, magnet:, ...) is refused.
const URL_SCHEMES: &[&str] = &["http", "https", "rtmp", "rtmps", "rtsp", "rtp", "udp", "mms", "mmsh", "srt"];

fn parse_target(input: &str) -> Result<Target, String> {
    let s = input.trim();
    if s.is_empty() {
        return Err("nothing is playing".into());
    }
    let file = |p: PathBuf| {
        // Rebuilt from its parts, so "C:/a/b.mkv" becomes "C:\a\b.mkv" on Windows: not every
        // player there takes forward slashes.
        let p: PathBuf = p.components().collect();
        if p.exists() {
            Ok(Target::File(p))
        } else {
            Err(format!("the file is not there any more: {}", p.display()))
        }
    };
    if s.get(..7).is_some_and(|head| head.eq_ignore_ascii_case("file://")) {
        let path = url::Url::parse(s)
            .ok()
            .and_then(|u| u.to_file_path().ok())
            .ok_or_else(|| "not a file address".to_string())?;
        return file(path);
    }
    // A local file the player view got as a plain path ("C:\..." or "\\server\share\..." on
    // Windows, "/..." elsewhere). Checked before parsing as a URL: "C:\x" parses as scheme "c".
    let as_path = Path::new(s);
    if as_path.is_absolute() {
        return file(as_path.to_path_buf());
    }
    let parsed = url::Url::parse(s).map_err(|_| "not a stream address".to_string())?;
    if !URL_SCHEMES.contains(&parsed.scheme()) {
        return Err(format!("can't open {} addresses", parsed.scheme()));
    }
    Ok(Target::Url(s.to_string()))
}

/// A title for the player's window, without characters that don't belong in one.
fn clean_title(title: Option<String>) -> Option<String> {
    let t: String = title?.chars().filter(|c| !c.is_control()).take(200).collect();
    let t = t.trim();
    (!t.is_empty()).then(|| t.to_string())
}

/// Request headers worth passing on. Ones a player sets itself for each request (Range,
/// Host, ...) are dropped, as are names or values that would not make a valid header.
fn clean_headers(headers: impl IntoIterator<Item = (String, String)>) -> Vec<(String, String)> {
    const PER_REQUEST: &[&str] = &["host", "range", "connection", "content-length", "transfer-encoding"];
    let mut out: Vec<(String, String)> = Vec::new();
    for (k, v) in headers {
        let k = k.trim().to_string();
        let v = v.trim().to_string();
        let name_ok = !k.is_empty() && k.bytes().all(|b| b.is_ascii_graphic() && b != b':');
        if !name_ok || v.is_empty() || v.chars().any(|c| c.is_control()) {
            continue;
        }
        if PER_REQUEST.iter().any(|h| k.eq_ignore_ascii_case(h)) {
            continue;
        }
        // A later value for the same header wins, whatever its letter case.
        out.retain(|(ek, _)| !ek.eq_ignore_ascii_case(&k));
        out.push((k, v));
    }
    out
}

/// The address the player opens and the headers it is given.
///
/// A stream behind Harbor's local proxy is opened at its source when the player can send the
/// headers the proxy adds, so it keeps playing after Harbor closes. When the player can't send
/// them, it goes through the proxy, which adds them for it (that needs Harbor running).
async fn pick_address(
    url: String,
    page_headers: HashMap<String, String>,
    sends: impl Fn(&str) -> bool,
    proxy: &ProxyState,
) -> (String, Vec<(String, String)>) {
    let (source, proxy_headers, proxied) = match proxy.upstream_of(&url).await {
        Some((up, h)) => (up, h, true),
        None => (url.clone(), HashMap::new(), false),
    };
    let headers = clean_headers(proxy_headers.into_iter().chain(page_headers));
    if headers.iter().all(|(k, _)| sends(k)) {
        return (source, headers);
    }
    if proxied {
        return (url, Vec::new());
    }
    match proxy.local_address(&source, headers.iter().cloned().collect()).await {
        Some(local) => (local, Vec::new()),
        // No proxy: the player gets what it can send and may still manage without the rest.
        None => (source, headers.into_iter().filter(|(k, _)| sends(k)).collect()),
    }
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

/// "1:02:03" style time for PotPlayer's /seek option.
fn hms(sec: f64) -> String {
    let s = sec.max(0.0).floor() as u64;
    format!("{:02}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
}

fn player_args(
    p: Player,
    media: OsString,
    title: Option<&str>,
    start: Option<f64>,
    headers: &[(String, String)],
) -> Vec<OsString> {
    let mut a: Vec<OsString> = Vec::new();
    match p {
        Player::Vlc => {
            // VLC reads options for one item after its address, each starting with ":".
            a.push(media);
            if let Some(s) = start {
                a.push(format!(":start-time={}", s.floor() as u64).into());
            }
            if let Some(t) = title {
                a.push(format!(":meta-title={t}").into());
            }
            if let Some(ua) = header(headers, "user-agent") {
                a.push(format!(":http-user-agent={ua}").into());
            }
            if let Some(r) = header(headers, "referer") {
                a.push(format!(":http-referrer={r}").into());
            }
        }
        Player::Mpv => {
            // Open the window at once, so something shows while a network stream connects.
            a.push("--force-window=immediate".into());
            if let Some(s) = start {
                a.push(format!("--start={s:.3}").into());
            }
            if let Some(t) = title {
                a.push(format!("--force-media-title={t}").into());
            }
            for (k, v) in headers {
                if k.eq_ignore_ascii_case("user-agent") {
                    a.push(format!("--user-agent={v}").into());
                } else if k.eq_ignore_ascii_case("referer") {
                    a.push(format!("--referrer={v}").into());
                } else {
                    // "-append" adds one header as it is: a comma in the value is not taken
                    // as the start of another header.
                    a.push(format!("--http-header-fields-append={k}: {v}").into());
                }
            }
            // Everything after "--" is the file or address, even if it starts with "-".
            a.push("--".into());
            a.push(media);
        }
        Player::PotPlayer => {
            a.push(media);
            if let Some(s) = start {
                a.push(format!("/seek={}", hms(s)).into());
            }
            if let Some(ua) = header(headers, "user-agent") {
                a.push(format!("/user_agent={ua}").into());
            }
            if let Some(r) = header(headers, "referer") {
                a.push(format!("/referer={r}").into());
            }
        }
        Player::MpcHc => {
            a.push(media);
            a.push("/play".into());
            if let Some(s) = start {
                // MPC-HC takes the start position in milliseconds.
                a.push("/start".into());
                a.push(format!("{}", (s * 1000.0).floor() as u64).into());
            }
        }
    }
    a
}

fn launch(exe: &Path, args: Vec<OsString>) -> Result<(), String> {
    let mut cmd = Command::new(exe);
    cmd.args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // Started from its own folder, as a shortcut would start it.
    if let Some(dir) = exe.parent() {
        cmd.current_dir(dir);
    }
    #[cfg(windows)]
    {
        // Only matters for a console launcher such as a Scoop shim: no black window pops up.
        // The player's own window is not affected.
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(unix)]
    {
        // Its own process group, so a Ctrl+C in a terminal that runs Harbor doesn't close it.
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("could not start {}: {e}", exe.display()))?;
    // Collect its exit status when it closes, so it doesn't stay behind as a zombie process.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[tauri::command]
pub async fn external_player_open(
    args: OpenArgs,
    proxy: tauri::State<'_, ProxyState>,
) -> Result<(), String> {
    let target = parse_target(&args.url)?;
    let title = clean_title(args.title);
    let start = args.start_sec.filter(|s| s.is_finite() && *s >= 1.0);

    if args.player == "system" {
        // The system's default app can't be given a position or headers.
        return match target {
            Target::File(p) => tauri_plugin_opener::open_path(&p, None::<&str>).map_err(|e| e.to_string()),
            Target::Url(u) => {
                let (u, _) = pick_address(u, args.headers, |_| false, &proxy).await;
                tauri_plugin_opener::open_url(&u, None::<&str>).map_err(|e| e.to_string())
            }
        };
    }

    // Looked up again here rather than taken from the page, so only a known player's program
    // can be started.
    let player = Player::from_id(&args.player).ok_or_else(|| format!("unknown player: {}", args.player))?;
    let exe = tauri::async_runtime::spawn_blocking(move || find(player))
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("{} is not installed", player.name()))?;

    let (media, headers) = match target {
        // A local file plays from its path; headers mean nothing there.
        Target::File(p) => (p.into_os_string(), Vec::new()),
        Target::Url(u) => {
            let (u, h) = pick_address(u, args.headers, |name| player.sends_header(name), &proxy).await;
            (OsString::from(u), h)
        }
    };
    launch(&exe, player_args(player, media, title.as_deref(), start, &headers))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_are_cleaned() {
        let h = clean_headers(vec![
            ("User-Agent".to_string(), "UA 1".to_string()),
            ("user-agent".to_string(), "UA 2".to_string()),
            ("Range".to_string(), "bytes=0-".to_string()),
            ("Bad Name".to_string(), "x".to_string()),
            ("X-Evil".to_string(), "a\r\nInjected: 1".to_string()),
            ("Referer".to_string(), "https://example.com/a,b".to_string()),
        ]);
        assert_eq!(
            h,
            vec![
                ("user-agent".to_string(), "UA 2".to_string()),
                ("Referer".to_string(), "https://example.com/a,b".to_string()),
            ]
        );
    }

    #[test]
    fn targets() {
        assert!(matches!(parse_target("https://x.test/a b?c=1&d=%20"), Ok(Target::Url(_))));
        assert!(parse_target("javascript:alert(1)").is_err());
        assert!(parse_target("magnet:?xt=urn:btih:abc").is_err());
        assert!(parse_target("   ").is_err());
        #[cfg(unix)]
        assert!(matches!(parse_target("file:///"), Ok(Target::File(_))));
    }

    #[test]
    fn mpv_args_keep_the_address_last() {
        let a = player_args(
            Player::Mpv,
            OsString::from("-weird"),
            Some("A, B"),
            Some(61.5),
            &[("Cookie".to_string(), "a=1, b=2".to_string())],
        );
        let a: Vec<String> = a.into_iter().map(|s| s.into_string().unwrap()).collect();
        assert_eq!(
            a,
            vec![
                "--force-window=immediate",
                "--start=61.500",
                "--force-media-title=A, B",
                "--http-header-fields-append=Cookie: a=1, b=2",
                "--",
                "-weird",
            ]
        );
        assert_eq!(hms(3723.9), "01:02:03");
    }
}
