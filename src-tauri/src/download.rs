use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use futures_util::StreamExt;
use serde::Serialize;
use tauri::ipc::Channel;
use tauri::State;
use tokio::io::AsyncWriteExt;

pub struct DownloadState {
    tasks: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

impl DownloadState {
    pub fn new() -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DownloadEvent {
    Started { total: Option<u64>, resumed: u64 },
    Progress { received: u64, total: Option<u64> },
    Done { received: u64 },
    Error { message: String },
    Canceled { received: u64 },
}

enum DownloadEnd {
    Canceled(u64),
    Failed(String),
}

const EMIT_INTERVAL_MS: u128 = 250;
const EMIT_BYTES: u64 = 4 * 1024 * 1024;

fn total_from_content_range(value: &str) -> Option<u64> {
    value.rsplit('/').next().and_then(|s| s.trim().parse::<u64>().ok())
}

#[tauri::command]
pub async fn download_start(
    state: State<'_, DownloadState>,
    id: String,
    url: String,
    dest: String,
    on_event: Channel<DownloadEvent>,
) -> Result<(), String> {
    let cancel = Arc::new(AtomicBool::new(false));
    state.tasks.lock().unwrap().insert(id.clone(), cancel.clone());

    let outcome = run_download(&url, &dest, &cancel, &on_event).await;
    state.tasks.lock().unwrap().remove(&id);

    match outcome {
        Ok(()) => Ok(()),
        Err(DownloadEnd::Canceled(received)) => {
            let _ = on_event.send(DownloadEvent::Canceled { received });
            Ok(())
        }
        Err(DownloadEnd::Failed(message)) => {
            let _ = on_event.send(DownloadEvent::Error {
                message: message.clone(),
            });
            Err(message)
        }
    }
}

#[tauri::command]
pub fn download_cancel(state: State<'_, DownloadState>, id: String) {
    if let Some(flag) = state.tasks.lock().unwrap().get(&id) {
        flag.store(true, Ordering::Relaxed);
    }
}

async fn run_download(
    url: &str,
    dest: &str,
    cancel: &Arc<AtomicBool>,
    on_event: &Channel<DownloadEvent>,
) -> Result<(), DownloadEnd> {
    let part = format!("{}.part", dest);

    let start_byte = match tokio::fs::metadata(&part).await {
        Ok(meta) => meta.len(),
        Err(_) => 0,
    };

    let client = reqwest::Client::builder()
        .user_agent("Harbor")
        .build()
        .map_err(|e| DownloadEnd::Failed(format!("client: {}", e)))?;
    let mut req = client.get(url);
    if start_byte > 0 {
        req = req.header(reqwest::header::RANGE, format!("bytes={}-", start_byte));
    }
    let resp = req
        .send()
        .await
        .map_err(|e| DownloadEnd::Failed(format!("request: {}", e)))?;
    let status = resp.status();

    if status == reqwest::StatusCode::RANGE_NOT_SATISFIABLE && start_byte > 0 {
        let _ = tokio::fs::rename(&part, dest).await;
        let _ = on_event.send(DownloadEvent::Done { received: start_byte });
        return Ok(());
    }
    if !status.is_success() {
        return Err(DownloadEnd::Failed(format!("HTTP {}", status.as_u16())));
    }

    let resuming = start_byte > 0 && status == reqwest::StatusCode::PARTIAL_CONTENT;
    let total = if resuming {
        resp.headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|h| h.to_str().ok())
            .and_then(total_from_content_range)
    } else {
        resp.content_length()
    };

    let mut received = if resuming { start_byte } else { 0 };
    let file = if resuming {
        tokio::fs::OpenOptions::new().append(true).open(&part).await
    } else {
        tokio::fs::File::create(&part).await
    }
    .map_err(|e| DownloadEnd::Failed(format!("open: {}", e)))?;
    let mut writer = tokio::io::BufWriter::with_capacity(1 << 20, file);

    let _ = on_event.send(DownloadEvent::Started {
        total,
        resumed: received,
    });

    let mut stream = resp.bytes_stream();
    let mut last = Instant::now();
    let mut since: u64 = 0;
    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::Relaxed) {
            let _ = writer.flush().await;
            return Err(DownloadEnd::Canceled(received));
        }
        let bytes = chunk.map_err(|e| DownloadEnd::Failed(format!("stream: {}", e)))?;
        writer
            .write_all(&bytes)
            .await
            .map_err(|e| DownloadEnd::Failed(format!("write: {}", e)))?;
        received += bytes.len() as u64;
        since += bytes.len() as u64;
        if last.elapsed().as_millis() >= EMIT_INTERVAL_MS || since >= EMIT_BYTES {
            let _ = on_event.send(DownloadEvent::Progress { received, total });
            last = Instant::now();
            since = 0;
        }
    }

    writer
        .flush()
        .await
        .map_err(|e| DownloadEnd::Failed(format!("flush: {}", e)))?;
    drop(writer);
    tokio::fs::rename(&part, dest)
        .await
        .map_err(|e| DownloadEnd::Failed(format!("rename: {}", e)))?;

    let _ = on_event.send(DownloadEvent::Progress { received, total });
    let _ = on_event.send(DownloadEvent::Done { received });
    Ok(())
}
