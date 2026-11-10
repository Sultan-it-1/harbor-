import Foundation
import Network
import UIKit
import UserNotifications

/**
 * In-app downloads for offline watching (Android: Downloads.kt + HttpTransfer.kt), on a background
 * URLSession: iOS keeps them going while the app is away and wakes the app when they finish.
 *
 *  - files go to the app's own storage (Application Support/Harbor/Downloads/<id>/), kept out of
 *    the iCloud backup, removed with the app
 *  - two at a time, the rest queued; pause / resume keep what was downloaded (resume data), waits
 *    for the network (or Wi-Fi), retries with back-off; pause / resume / retry from the page
 *  - picks up again after the app was closed (state in downloads.json)
 *  - addon subtitles are saved next to the video (as UTF-8) and deleted with it
 *  - the page's calls and status are the same as Android's (its codes, its JSON)
 *
 * Everything runs on the main thread (the session's delegate queue too).
 */
final class Downloads: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    static let sessionId = "app.harbor.downloads"

    /// Used for downloads that don't bring their own (the web view's user agent).
    var userAgent = "HarborIOS"
    /// iOS's "the session's events are delivered" call, kept until they are.
    var backgroundCompletion: (() -> Void)?
    /// Told when something the page shows changed.
    var onChange: (() -> Void)?

    private struct Task: Codable {
        let id: String
        var url: String
        var headers: [String: String]
        let ua: String
        let file: String
        let title: String
        var state: String
        let at: Double
        var total: Int64 = -1
        var received: Int64 = 0
        var reason: String?
        var code: String?
        var http: Int = 0
        var attempts: Int = 0
        var retryAt: Double = 0
        var waitingFor: String?
    }

    private struct SavedSub: Codable {
        let name: String
        let url: String
        let lang: String?
        let label: String?
    }

    private var tasks: [String: Task] = [:]
    private var live: [String: URLSessionDownloadTask] = [:]
    /// Tasks being stopped on purpose (pause, Wi-Fi only, delete): their cancel isn't a failure.
    private var stopping: [String: String] = [:]
    private var resumeOffset: [String: Int64] = [:]
    private var wake: Timer?
    private var lastPersist = Date.distantPast
    private let monitor = NWPathMonitor()
    private var online = true
    private var metered = false
    private var keepAlive: UIBackgroundTaskIdentifier = .invalid
    private let subsQueue = DispatchQueue(label: "harbor.downloads.subs")

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Downloads.sessionId)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Start up

    /// Loads the downloads and carries on with the unfinished ones (call once, at launch).
    func start() {
        restore()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.online = path.status == .satisfied
                self.metered = path.isExpensive
                self.pump()
            }
        }
        monitor.start(queue: DispatchQueue(label: "harbor.downloads.net"))
        // Transfers iOS kept going while the app was away: reattach them.
        session.getAllTasks { all in
            DispatchQueue.main.async {
                for t in all {
                    guard let d = t as? URLSessionDownloadTask, let id = d.taskDescription else { continue }
                    if self.tasks[id] != nil, d.state == .running || d.state == .suspended {
                        self.live[id] = d
                        self.tasks[id]?.state = Self.RUNNING
                    } else {
                        d.cancel()
                    }
                }
                for (id, t) in self.tasks where t.state == Self.RUNNING && self.live[id] == nil {
                    self.tasks[id]?.state = Self.QUEUED
                }
                self.pump()
            }
        }
    }

    /// Opening the app: carry on with anything that stalled while it was away.
    func kick() { pump() }

    // MARK: - Folders

    private static let idRx = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")

    static func validId(_ id: String) -> Bool {
        idRx.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil && !id.contains("..")
    }

    private func root() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Harbor/Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    /// Only plain ids get a folder ("", "." or ".." would point at the downloads folder itself).
    private func dirFor(_ id: String) -> URL? {
        Downloads.validId(id) ? root().appendingPathComponent(id, isDirectory: true) : nil
    }

    private func resumeFile(_ id: String) -> URL? { dirFor(id)?.appendingPathComponent(".resume") }

    private var stateFile: URL { root().deletingLastPathComponent().appendingPathComponent("downloads.json") }

    // MARK: - The page's calls (the same as Android's)

    /// {id, url, headers, fileName, title, description, subtitles:[{url,lang,label}]} -> {ok, error?}
    func startDownload(_ json: String) -> String {
        guard let j = parseObject(json), let id = j.str("id"), let url = j.str("url") else { return jsonText(["ok": false, "error": "bad request"]) }
        guard Downloads.validId(id) else { return jsonText(["ok": false, "error": "invalid id"]) }
        if let old = tasks[id], [Self.RUNNING, Self.QUEUED, Self.WAITING].contains(old.state) {
            return jsonText(["ok": true, "already": true])
        }
        guard let dir = dirFor(id) else { return jsonText(["ok": false, "error": "storage unavailable"]) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ua = userAgent
        var headers: [String: String] = [:]
        for (k, v) in j.obj("headers") ?? [:] {
            guard let s = v as? String else { continue }
            if k.lowercased() == "user-agent" { ua = s } else { headers[k] = s }
        }
        let title = [j.str("title"), j.str("description")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let t = Task(
            id: id, url: url, headers: headers, ua: ua,
            file: Downloads.safeFileName(j.str("fileName") ?? "video.mp4"),
            title: title.isEmpty ? "Harbor" : title,
            state: Self.QUEUED, at: Date().timeIntervalSince1970
        )
        tasks[id] = t
        persist(force: true)
        let subs = j.objs("subtitles")
        if !subs.isEmpty { saveSubtitles(id, subs, ua: ua) }
        askToNotify()
        pump()
        return jsonText(["ok": true])
    }

    func pause(_ id: String) -> Bool {
        guard var t = tasks[id], ![Self.DONE, Self.ERROR, Self.PAUSED].contains(t.state) else { return false }
        t.state = Self.PAUSED
        tasks[id] = t
        stop(id, why: "pause")
        persist(force: true)
        pump()
        return true
    }

    /// Resume a paused download, or try a failed one again (from where it got to).
    func resume(_ id: String) -> Bool {
        guard var t = tasks[id], t.state != Self.DONE, t.state != Self.RUNNING else { return false }
        if t.url.isEmpty {
            t.state = Self.ERROR
            t.reason = "The download link is gone. Delete it and download it again."
            tasks[id] = t
            persist(force: true)
            return false
        }
        t.state = Self.QUEUED
        t.attempts = 0
        t.retryAt = 0
        t.waitingFor = nil
        t.reason = nil
        tasks[id] = t
        persist(force: true)
        pump()
        return true
    }

    /// A fresh link for a download whose link expired. (The new link starts the file over:
    /// what was downloaded from the old one can't be carried across.)
    func relink(_ id: String, url: String, headersJson: String?) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://"), var t = tasks[id] else { return false }
        guard t.state != Self.DONE, t.state != Self.RUNNING, live[id] == nil else { return false }
        t.url = url
        if let hj = headersJson, let o = parseObject(hj) {
            var h: [String: String] = [:]
            for (k, v) in o where k.lowercased() != "user-agent" { h[k] = v as? String ?? "" }
            t.headers = h
        }
        t.state = Self.QUEUED
        t.attempts = 0
        t.retryAt = 0
        t.waitingFor = nil
        t.reason = nil
        t.code = nil
        t.http = 0
        tasks[id] = t
        if let r = resumeFile(id) { try? FileManager.default.removeItem(at: r) }
        persist(force: true)
        pump()
        return true
    }

    /// Download only on Wi-Fi (or any network that isn't metered). On by default.
    var wifiOnly: Bool {
        get { UserDefaults.standard.object(forKey: "harbor.dl.wifiOnly") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "harbor.dl.wifiOnly")
            // Turned on while on mobile data: the running ones stop too (and carry on over Wi-Fi).
            if newValue && metered {
                for (id, t) in tasks where t.state == Self.RUNNING {
                    tasks[id]?.state = Self.WAITING
                    tasks[id]?.waitingFor = Self.WAIT_WIFI
                    stop(id, why: "wifi")
                }
            } else if !newValue {
                // Off: the ones waiting for Wi-Fi start again over the mobile network.
                for (id, t) in tasks where t.state == Self.WAITING && t.waitingFor == Self.WAIT_WIFI {
                    tasks[id]?.state = Self.QUEUED
                }
            }
            persist(force: true)
            pump()
        }
    }

    /// Cancel and/or delete for good: the video, its subtitles and the folder.
    func delete(_ id: String) -> Bool {
        tasks[id] = nil
        stop(id, why: "delete")
        if let dir = dirFor(id) { try? FileManager.default.removeItem(at: dir) }
        persist(force: true)
        pump()
        return true
    }

    /// Background work in the page (season queue, subtitle searches): a little more time when the
    /// app goes to the background (iOS gives a few minutes at most).
    func setKeepAlive(_ on: Bool) {
        if on {
            guard keepAlive == .invalid else { return }
            keepAlive = UIApplication.shared.beginBackgroundTask(withName: "harbor.page") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.keepAlive)
                self.keepAlive = .invalid
            }
        } else if keepAlive != .invalid {
            UIApplication.shared.endBackgroundTask(keepAlive)
            keepAlive = .invalid
        }
    }

    /// {<id>: {status, received, total, reason, code, title, http, sec, subs}} for every download.
    func statusObject() -> JObj {
        var out: JObj = [:]
        let now = Date().timeIntervalSince1970
        for t in tasks.values {
            var received = t.received
            if let task = live[t.id] { received = Swift.max(received, task.countOfBytesReceived + (resumeOffset[t.id] ?? 0)) }
            let sec = t.state == Self.WAITING && t.waitingFor == Self.WAIT_RETRY ? Swift.max(1, Int(ceil(t.retryAt - now))) : 0
            out[t.id] = [
                "subs": savedSubs(t.id).count,
                "status": t.state == Self.QUEUED ? "pending" : t.state == Self.RUNNING ? "downloading" : t.state,
                "received": received,
                "total": t.total > 0 ? t.total as Any : NSNull(),
                "reason": note(t, now),
                "code": code(t),
                "title": t.title,
                "http": t.http,
                "sec": sec,
            ] as JObj
        }
        return out
    }

    /// Local files for offline playback: {video: "file://…", subtitles: [{url, src, lang, label}]}.
    func files(_ id: String) -> JObj {
        guard let dir = dirFor(id) else { return [:] }
        var out: JObj = [:]
        if let t = tasks[id], t.state == Self.DONE {
            let video = dir.appendingPathComponent(t.file)
            if FileManager.default.fileExists(atPath: video.path) { out["video"] = video.absoluteString }
        }
        out["subtitles"] = savedSubtitleFiles(id).map { s -> JObj in
            var o: JObj = ["url": s.file.absoluteString, "src": s.src]
            if let l = s.lang { o["lang"] = l }
            if let l = s.label { o["label"] = l }
            return o
        }
        return out
    }

    /// Every download's files, for the page's offline playback.
    func allFiles() -> JObj {
        var out: JObj = [:]
        for id in tasks.keys { out[id] = files(id) }
        return out
    }

    /// Free space and how much the downloads use.
    func storage() -> JObj {
        let r = root()
        let free = (try? r.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? -1
        var used: Int64 = 0
        if let e = FileManager.default.enumerator(at: r, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                used += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return ["free": free, "used": used]
    }

    /// Anything queued, running or waiting.
    var hasPendingWork: Bool { tasks.values.contains { [Self.QUEUED, Self.RUNNING, Self.WAITING].contains($0.state) } }

    // MARK: - Engine

    /// Starts what can start (two at a time) and schedules the next retry.
    private func pump() {
        let now = Date().timeIntervalSince1970
        let net = network()
        var running = tasks.values.filter { $0.state == Self.RUNNING }.count
        for id in tasks.values.sorted(by: { $0.at < $1.at }).map(\.id) {
            guard var t = tasks[id] else { continue }
            if t.state == Self.WAITING {
                let ready = t.waitingFor == Self.WAIT_NETWORK || t.waitingFor == Self.WAIT_WIFI ? net == .ok : now >= t.retryAt
                if ready { t.state = Self.QUEUED }
            }
            if t.state == Self.QUEUED {
                if net != .ok {
                    t.state = Self.WAITING
                    t.waitingFor = net == .metered ? Self.WAIT_WIFI : Self.WAIT_NETWORK
                } else if running < Self.maxParallel && live[id] == nil {
                    tasks[id] = t
                    launch(id)
                    running += 1
                    continue
                }
            }
            tasks[id] = t
        }
        scheduleWake(now)
        changed()
    }

    private func scheduleWake(_ now: Double) {
        wake?.invalidate()
        wake = nil
        let waiting = tasks.values.filter { $0.state == Self.WAITING }
        guard !waiting.isEmpty else { return }
        // Retries at their time; network waits are checked again now and then.
        let next = waiting.map { $0.waitingFor == Self.WAIT_RETRY ? $0.retryAt : now + 30 }.min() ?? now + 30
        wake = Timer.scheduledTimer(withTimeInterval: Swift.max(0.3, next - now), repeats: false) { [weak self] _ in self?.pump() }
    }

    private enum Net { case ok, none, metered }

    private func network() -> Net {
        if !online { return .none }
        if wifiOnly && metered { return .metered }
        return .ok
    }

    private func launch(_ id: String) {
        guard var t = tasks[id], let url = URL(string: t.url) else {
            tasks[id]?.state = Self.ERROR
            tasks[id]?.reason = "The download link is broken"
            tasks[id]?.code = "failed"
            return
        }
        t.state = Self.RUNNING
        t.waitingFor = nil
        t.reason = nil
        t.code = nil
        t.http = 0
        tasks[id] = t
        let task: URLSessionDownloadTask
        if let rf = resumeFile(id), let data = try? Data(contentsOf: rf) {
            try? FileManager.default.removeItem(at: rf)
            task = session.downloadTask(withResumeData: data)
        } else {
            var r = URLRequest(url: url)
            r.setValue(t.ua, forHTTPHeaderField: "User-Agent")
            r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (k, v) in t.headers where !["user-agent", "range", "accept-encoding"].contains(k.lowercased()) {
                r.setValue(v, forHTTPHeaderField: k)
            }
            r.allowsCellularAccess = !wifiOnly
            task = session.downloadTask(with: r)
            resumeOffset[id] = 0
        }
        task.taskDescription = id
        live[id] = task
        task.resume()
        persist(force: true)
    }

    /// Stops a running transfer on purpose, keeping what it got when it can.
    private func stop(_ id: String, why: String) {
        guard let task = live[id] else { return }
        stopping[id] = why
        if why == "delete" {
            task.cancel()
        } else {
            task.cancel(byProducingResumeData: { [weak self] data in
                DispatchQueue.main.async {
                    guard let self, let data, let rf = self.resumeFile(id), self.tasks[id] != nil else { return }
                    try? data.write(to: rf)
                }
            })
        }
    }

    // MARK: - The session's news

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, tasks[id] != nil else { return }
        tasks[id]?.received = Swift.max(totalBytesWritten, resumeOffset[id] ?? 0)
        if totalBytesExpectedToWrite > 0 { tasks[id]?.total = totalBytesExpectedToWrite }
        if Date().timeIntervalSince(lastPersist) > 30 { persist(force: true) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        resumeOffset[id] = fileOffset
        if expectedTotalBytes > 0 { tasks[id]?.total = expectedTotalBytes }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, var t = tasks[id], let dir = dirFor(id) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if !(200..<300).contains(status) {
            // The server's answer is an error page, not the file.
            finishHttp(id, status)
            return
        }
        if let why = Downloads.notMediaType(http?.value(forHTTPHeaderField: "Content-Type")) ?? Downloads.notMediaBytes(location) {
            t.state = Self.ERROR
            t.reason = "This link isn't a video file (\(why))"
            t.code = "not_media"
            tasks[id] = t
            notifyFinished(t, ok: false)
            return
        }
        let dest = dir.appendingPathComponent(t.file)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? t.received
            t.state = Self.DONE
            t.received = size
            t.total = size
            t.reason = nil
            t.code = nil
            tasks[id] = t
            notifyFinished(t, ok: true)
        } catch {
            t.state = Self.ERROR
            t.reason = "Couldn't save the file"
            t.code = "save_failed"
            tasks[id] = t
            notifyFinished(t, ok: false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        live[id] = nil
        let why = stopping.removeValue(forKey: id)
        defer {
            persist(force: true)
            pump()
        }
        guard var t = tasks[id] else { return } // deleted
        guard let error = error as NSError? else { return } // finished (see didFinishDownloadingTo)
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let rf = resumeFile(id) {
            try? data.write(to: rf)
        }
        if why != nil { return } // paused or waiting for Wi-Fi on purpose
        if t.state != Self.RUNNING { return }
        let madeProgress = (error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data) != nil
        if madeProgress { t.attempts = 0 }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) || error.code == NSURLErrorCannotWriteToFile {
            t.state = Self.ERROR
            t.reason = "Not enough storage on the phone"
            t.code = "no_space"
            tasks[id] = t
            notifyFinished(t, ok: false)
            return
        }
        let net = network()
        if net != .ok {
            // Offline (or only mobile data with Wi-Fi only on): wait; that isn't a failed attempt.
            t.state = Self.WAITING
            t.waitingFor = net == .metered ? Self.WAIT_WIFI : Self.WAIT_NETWORK
        } else {
            t.attempts += 1
            if t.attempts > Self.maxAttempts {
                t.state = Self.ERROR
                t.reason = "Keeps failing (\(error.localizedDescription)). Tap retry."
                t.code = "keeps_failing"
                notifyFinished(t, ok: false)
            } else {
                t.state = Self.WAITING
                t.waitingFor = Self.WAIT_RETRY
                t.retryAt = Date().timeIntervalSince1970 + Self.backoff[Swift.min(t.attempts - 1, Self.backoff.count - 1)]
            }
        }
        tasks[id] = t
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }

    /// The server answered with an error status instead of the file.
    private func finishHttp(_ id: String, _ code: Int) {
        guard var t = tasks[id] else { return }
        t.attempts += 1
        if code == 408 || code == 429 || code >= 500 {
            if t.attempts > Self.maxAttempts {
                t.state = Self.ERROR
                t.reason = "Keeps failing (HTTP \(code)). Tap retry."
                t.code = "keeps_failing"
                notifyFinished(t, ok: false)
            } else {
                t.state = Self.WAITING
                t.waitingFor = Self.WAIT_RETRY
                t.retryAt = Date().timeIntervalSince1970 + Self.backoff[Swift.min(t.attempts - 1, Self.backoff.count - 1)]
            }
        } else if (code == 401 || code == 403) && t.attempts <= 2 {
            // Sometimes just a hiccup on the server's side; try twice before giving up.
            t.state = Self.WAITING
            t.waitingFor = Self.WAIT_RETRY
            t.retryAt = Date().timeIntervalSince1970 + 5 * Double(t.attempts)
        } else {
            t.state = Self.ERROR
            t.http = code
            switch code {
            case 404, 410:
                t.code = "expired"
                t.reason = "The link has expired (HTTP \(code)). Tap retry for a fresh link."
            case 401, 403:
                t.code = "refused"
                t.reason = "The server refused the download (HTTP \(code)). The link may have expired."
            default:
                t.code = "http_error"
                t.reason = "The server refused the download (HTTP \(code))"
            }
            notifyFinished(t, ok: false)
        }
        tasks[id] = t
    }

    // MARK: - What the page shows

    private func code(_ t: Task) -> String {
        switch t.state {
        case Self.QUEUED: return "queued"
        case Self.WAITING:
            switch t.waitingFor {
            case Self.WAIT_NETWORK: return "waiting_network"
            case Self.WAIT_WIFI: return "waiting_wifi"
            default: return "retry_in"
            }
        case Self.PAUSED: return "paused"
        case Self.ERROR: return t.code ?? "failed"
        default: return ""
        }
    }

    private func note(_ t: Task, _ now: Double) -> String {
        switch t.state {
        case Self.QUEUED: return "Queued"
        case Self.WAITING:
            switch t.waitingFor {
            case Self.WAIT_NETWORK: return "Waiting for internet"
            case Self.WAIT_WIFI: return "Waiting for Wi-Fi"
            default: return "Retrying in \(Swift.max(1, Int(ceil(t.retryAt - now))))s"
            }
        case Self.PAUSED: return "Paused"
        case Self.ERROR: return t.reason ?? "Download failed"
        default: return ""
        }
    }

    private func changed() { onChange?() }

    // MARK: - Saved state

    private func persist(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPersist) > 30 else { return }
        lastPersist = Date()
        if let data = try? JSONEncoder().encode(Array(tasks.values)) { try? data.write(to: stateFile, options: .atomic) }
        changed()
    }

    private func restore() {
        guard let data = try? Data(contentsOf: stateFile), let list = try? JSONDecoder().decode([Task].self, from: data) else { return }
        for var t in list {
            // It was downloading when the app went away: carry on (or reattach, see start()).
            if t.state == Self.WAITING { t.state = Self.QUEUED }
            if t.state == Self.DONE, let dir = dirFor(t.id) {
                let f = dir.appendingPathComponent(t.file)
                if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    t.received = Int64(size)
                    t.total = Int64(size)
                } else {
                    t.state = Self.ERROR
                    t.reason = "The file is gone. Delete it and download it again."
                    t.code = "failed"
                }
            }
            tasks[t.id] = t
        }
    }

    // MARK: - Notifications

    private func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyFinished(_ t: Task, ok: Bool) {
        guard UIApplication.shared.applicationState != .active else { return }
        let ar = (Locale.preferredLanguages.first ?? "").hasPrefix("ar")
        let c = UNMutableNotificationContent()
        c.title = ok ? (ar ? "اكتمل التنزيل" : "Download finished") : (ar ? "تعذّر التنزيل" : "Download failed")
        c.body = t.title
        c.sound = .default
        let r = UNNotificationRequest(identifier: "dl-" + t.id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }

    // MARK: - Subtitles saved with a download

    /// Adds addon subtitles to a download (found after it started).
    func addSubtitles(_ id: String, json: String) -> Bool {
        guard let dir = dirFor(id), FileManager.default.fileExists(atPath: dir.path) else { return false }
        guard let data = json.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [JObj] else { return false }
        saveSubtitles(id, list, ua: tasks[id]?.ua ?? userAgent)
        return true
    }

    /// The player's "save" on a subtitle: adds it to the download; done(true) once it's there.
    func saveSubtitle(_ id: String, url: String, lang: String?, label: String?, done: @escaping (Bool) -> Void) {
        guard let dir = dirFor(id), FileManager.default.fileExists(atPath: dir.path) else { return done(false) }
        var one: JObj = ["url": url]
        if let lang { one["lang"] = lang }
        if let label { one["label"] = label }
        saveSubtitles(id, [one], ua: tasks[id]?.ua ?? userAgent) { [weak self] in
            done(self?.savedSubs(id).contains { $0.url == url } == true)
        }
    }

    private func subsList(_ dir: URL) -> URL { dir.appendingPathComponent("subs.json") }

    private func savedSubs(_ id: String) -> [SavedSub] {
        guard let dir = dirFor(id), let data = try? Data(contentsOf: subsList(dir)) else { return [] }
        return (try? JSONDecoder().decode([SavedSub].self, from: data)) ?? []
    }

    /// The saved subtitles that are still on disk: the file and the URL it came from.
    func savedSubtitleFiles(_ id: String) -> [(file: URL, src: String, lang: String?, label: String?)] {
        guard let dir = dirFor(id) else { return [] }
        return savedSubs(id).compactMap { s in
            let f = dir.appendingPathComponent("subs").appendingPathComponent(s.name)
            return FileManager.default.fileExists(atPath: f.path) ? (f, s.url, s.lang, s.label) : nil
        }
    }

    /// Downloads each subtitle as UTF-8 into <dir>/subs and lists it in subs.json, one at a time.
    private func saveSubtitles(_ id: String, _ subs: [JObj], ua: String, then: (() -> Void)? = nil) {
        guard let dir = dirFor(id) else { return }
        subsQueue.async {
            let subsDir = dir.appendingPathComponent("subs", isDirectory: true)
            try? FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
            var list = (try? JSONDecoder().decode([SavedSub].self, from: Data(contentsOf: self.subsList(dir)))) ?? []
            for s in subs {
                guard let src = s.str("url"), !src.isEmpty, !list.contains(where: { $0.url == src }), let u = URL(string: src) else { continue }
                var r = URLRequest(url: u, timeoutInterval: 30)
                r.setValue(ua, forHTTPHeaderField: "User-Agent")
                let sem = DispatchSemaphore(value: 0)
                var got: Data?
                URLSession.shared.dataTask(with: r) { data, response, _ in
                    if let h = response as? HTTPURLResponse, (200..<300).contains(h.statusCode) { got = data }
                    sem.signal()
                }.resume()
                _ = sem.wait(timeout: .now() + 40)
                let lang = s.str("lang")
                let name = "sub\(Int(Date().timeIntervalSince1970 * 1000))\(list.count)"
                guard let data = got, let file = SubtitleFile.save(data, lang: lang, in: subsDir, name: name) else { continue }
                guard FileManager.default.fileExists(atPath: dir.path) else { return } // deleted meanwhile
                list.append(SavedSub(name: file.lastPathComponent, url: src, lang: lang, label: s.str("label")))
                if let out = try? JSONEncoder().encode(list) { try? out.write(to: self.subsList(dir), options: .atomic) }
            }
            DispatchQueue.main.async {
                self.changed()
                then?()
            }
        }
    }

    // MARK: - Rules shared with Android

    private static let QUEUED = "queued"
    private static let RUNNING = "running"
    private static let WAITING = "waiting"
    private static let PAUSED = "paused"
    private static let DONE = "done"
    private static let ERROR = "error"
    private static let WAIT_NETWORK = "network"
    private static let WAIT_WIFI = "wifi"
    private static let WAIT_RETRY = "retry"
    private static let maxParallel = 2
    private static let maxAttempts = 12
    private static let backoff: [Double] = [3, 10, 30, 60, 120, 300]

    /// Safe on any filesystem, any script kept; long names lose the middle, not the extension.
    static func safeFileName(_ name: String) -> String {
        var clean = String(name.unicodeScalars.map { c -> Character in
            let ok = CharacterSet.letters.contains(c) || CharacterSet.decimalDigits.contains(c) || "._ ()[]-".unicodeScalars.contains(c)
            return ok ? Character(c) : "_"
        }).trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty { clean = "video.mp4" }
        var ext = ""
        var stem = clean
        if let dot = clean.lastIndex(of: "."), dot > clean.startIndex, clean.distance(from: dot, to: clean.endIndex) <= 6 {
            ext = String(clean[dot...])
            stem = String(clean[..<dot])
        }
        let keep = String(stem.prefix(80 - ext.count))
        return (keep.isEmpty ? "video" : keep) + ext
    }

    /// Why a Content-Type can't be a video file, or nil when it can.
    static func notMediaType(_ contentType: String?) -> String? {
        guard let t = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if t == "text/html" || t == "application/xhtml+xml" { return "the server sent a web page" }
        if t == "application/json" || t.hasSuffix("+json") { return "the server sent an error message" }
        if t.contains("mpegurl") { return "the link is a streaming playlist (HLS), not a file" }
        if t == "application/dash+xml" { return "the link is a streaming playlist (DASH), not a file" }
        return nil
    }

    /// Why the file's first bytes can't be a video (HTML, JSON, a playlist), or nil.
    static func notMediaBytes(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let b = h.readData(ofLength: 128)
        var i = 0
        let skip: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09, 0xEF, 0xBB, 0xBF]
        while i < b.count && i < 64 && skip.contains(b[b.startIndex + i]) { i += 1 }
        let head = String(decoding: b.dropFirst(i).prefix(64), as: UTF8.self).lowercased()
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<head") || head.hasPrefix("<body") { return "the server sent a web page" }
        if head.hasPrefix("#extm3u") { return "the link is a streaming playlist (HLS), not a file" }
        if head.hasPrefix("<?xml") && head.contains("mpd") { return "the link is a streaming playlist (DASH), not a file" }
        if head.hasPrefix("{\"") || head.hasPrefix("{ \"") || head.hasPrefix("[{") { return "the server sent an error message" }
        return nil
    }
}
