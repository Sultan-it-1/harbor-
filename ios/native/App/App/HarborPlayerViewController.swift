import AVFoundation
import MediaPlayer
import MobileVLCKit
import UIKit

/// The iPhone app's video player (VLC: MKV, HEVC, Dolby / DTS audio, ASS / SRT subtitles), full
/// screen over the page. It reports to the page like the Android player does (state every second,
/// ended, error, closed) and takes the same commands (play, pause, seek, rate, addSubs, meta…).
final class HarborPlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private var source: PlayerSource
    private let send: (String) -> Void
    private var player: VLCMediaPlayer
    private let text: PlayerText

    // Views
    private let videoView = UIView()
    private let controls = UIView()
    private let topShade = GradientView(top: true)
    private let bottomShade = GradientView(top: false)
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let audioButton = UIButton(type: .system)
    private let subsButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let sourcesButton = UIButton(type: .system)
    /// What a swipe is changing (the time, the brightness, the volume).
    private let hud = PaddedLabel()
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()
    private let nextButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let toast = PaddedLabel()
    private let errorBox = UIStackView()
    private let errorLabel = UILabel()

    // State
    private var tick: Timer?
    private var hideWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var scrubbing = false
    private var userPaused = false
    private var sentEnded = false
    private var sentError = false
    private var hasNext = false
    private var fill = false
    private var lastState: VLCMediaPlayerState = .opening
    private var wasPlaying = false
    private var knownSubTracks = Set<Int32>()
    /// External subtitles we loaded: our URL -> VLC's track id.
    private var externalTrack: [String: Int32] = [:]
    private var pendingExternal: String?
    /// A subtitle file being downloaded (not handed to VLC yet).
    private var downloadingExternal: String?
    private var userPickedSub = false
    private var lastKnownMs: Int32 = 0
    /// The subtitle look (VLC's text options) and the delay (milliseconds, + = later).
    private var style: SubStyle
    private var subDelayMs = 0
    /// The sources list: the open menu waiting for them, and the one being switched to.
    private var streamsWaiter: (([UIMenuElement]) -> Void)?
    private var pickingStream: String?
    /// A swipe: 1 the time, 2 the brightness, 3 the volume.
    private var panMode = 0
    private var panStartMs = 0
    private var panTargetMs = 0
    private var panStartValue: Float = 0
    private var hudWork: DispatchWorkItem?
    /// The phone's volume, set through the system's own (hidden) volume slider.
    private lazy var volumeSlider: UISlider? = {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        v.alpha = 0.01
        view.addSubview(v)
        return v.subviews.compactMap { $0 as? UISlider }.first
    }()

    /// Test builds (the simulator check): VLC's own log and the subtitle steps in the console.
    static var verbose = false

    private func log(_ message: @autoclosure () -> String) {
        if Self.verbose { NSLog("[harbor player] %@", message()) }
    }
    /// Text sizes offered (1 = normal).
    private static let scales: [Double] = [0.75, 0.875, 1, 1.25, 1.5]

    init(source: PlayerSource, send: @escaping (String) -> Void) {
        self.source = source
        self.send = send
        text = PlayerText(lang: source.uiLang)
        let look = SubStyle.load() ?? SubStyle.fromHarbor(source.subStyle)
        style = look
        player = HarborPlayerViewController.makePlayer(look)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func makePlayer(_ look: SubStyle) -> VLCMediaPlayer {
        let made = VLCMediaPlayer(options: look.vlcOptions)
        if verbose {
            made.libraryInstance.debugLogging = true
            made.libraryInstance.debugLoggingLevel = 3
        }
        return made
    }

    // MARK: - Lifecycle

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.semanticContentAttribute = .forceLeftToRight
        buildViews()
        start(at: source.startMs)
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        showControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFill()
    }

    /// A new source while on screen (next episode, another stream).
    func load(_ next: PlayerSource) {
        source = next
        pickingStream = nil
        sentEnded = false
        sentError = false
        userPickedSub = false
        wasPlaying = false
        externalTrack = [:]
        knownSubTracks = []
        pendingExternal = nil
        downloadingExternal = nil
        errorBox.isHidden = true
        titleLabel.text = next.title
        player.stop()
        start(at: next.startMs)
        showControls()
    }

    private func start(at ms: Int) {
        let media = VLCMedia(url: source.url)
        media.addOption(":network-caching=\(source.isLive ? 3000 : 1500)")
        media.addOption(":http-reconnect")
        if ms > 0 { media.addOption(":start-time=\(Double(ms) / 1000)") }
        for (name, value) in source.headers {
            switch name.lowercased() {
            case "user-agent": media.addOption(":http-user-agent=\(value)")
            case "referer", "referrer": media.addOption(":http-referrer=\(value)")
            default: break // VLC can't send other headers
            }
        }
        if !source.prefAudioLangs.isEmpty { media.addOption(":audio-language=\(source.prefAudioLangs.joined(separator: ","))") }
        if !source.prefSubLangs.isEmpty { media.addOption(":sub-language=\(source.prefSubLangs.joined(separator: ","))") }
        player.drawable = videoView
        player.media = media
        player.play()
        player.currentVideoSubTitleDelay = subDelayMs * 1000
        userPaused = false
    }

    /// The player's own close button: stop, tell the page where it got to, leave.
    @objc private func closeTapped() {
        let pos = currentMs()
        let dur = durationMs()
        finish()
        sendEvent(["type": "closed", "positionMs": pos, "durationMs": dur])
        dismiss(animated: true)
    }

    /// The page closed playback itself: leave without reporting back.
    func closeQuietly() {
        finish()
        if presentingViewController != nil { dismiss(animated: true) }
    }

    private func finish() {
        tick?.invalidate()
        tick = nil
        player.stop()
        player.drawable = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Commands from the page

    func handle(_ cmd: [String: Any]) {
        switch cmd["cmd"] as? String {
        case "play":
            userPaused = false
            player.play()
        case "pause":
            userPaused = true
            player.pause()
        case "seek":
            if let ms = (cmd["ms"] as? NSNumber)?.intValue { seek(to: ms) }
        case "rate":
            if let r = (cmd["rate"] as? NSNumber)?.floatValue { player.rate = r }
        case "addSubs":
            let subs = PlayerSource.subs(cmd["subs"])
            let known = Set(source.subtitles.map(\.url))
            source.subtitles += subs.filter { !known.contains($0.url) }
            autoPickSubtitle()
        case "meta":
            if let t = cmd["title"] as? String, !t.isEmpty { titleLabel.text = t }
            let line = [cmd["subtitle"] as? String, (cmd["showQuality"] as? Bool == true) ? cmd["quality"] as? String : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            subtitleLabel.text = line
            subtitleLabel.isHidden = line.isEmpty
            hasNext = (cmd["hasNext"] as? Bool) ?? false
            nextButton.isHidden = !hasNext
        case "subSearch":
            let n = (cmd["count"] as? NSNumber)?.intValue ?? 0
            if (cmd["manual"] as? Bool) == true || n == 0 { showToast(n > 0 ? text.foundSubs(n) : text.noSubs) }
        case "streamFailed":
            pickingStream = nil
            showToast((cmd["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.cantPlay)
        case "streams":
            if let done = streamsWaiter {
                streamsWaiter = nil
                done(streamsMenu(cmd))
            }
        case "volume":
            if let v = (cmd["volume"] as? NSNumber)?.doubleValue { player.audio?.volume = Int32(Swift.min(Swift.max(v, 0), 1) * 100) }
        default:
            break
        }
    }

    // MARK: - State to the page

    private func currentMs() -> Int { Int(max(player.time.intValue, 0)) }
    private func durationMs() -> Int { Int(max(player.media?.length.intValue ?? 0, 0)) }

    private func update() {
        let state = player.state
        let pos = currentMs()
        let dur = durationMs()
        if pos > 0 { lastKnownMs = Int32(pos) }
        let buffering = state == .opening || state == .buffering && !player.isPlaying
        let ended = state == .ended
        spinner.isHidden = !(buffering && !userPaused)
        if buffering && !userPaused { spinner.startAnimating() } else { spinner.stopAnimating() }
        playButton.setImage(symbol(player.isPlaying ? "pause.fill" : "play.fill", 34), for: .normal)
        if !scrubbing {
            slider.maximumValue = Float(max(dur, 1))
            slider.value = Float(pos)
            timeLabel.text = format(pos)
            durationLabel.text = dur > 0 ? format(dur) : (source.isLive ? "LIVE" : "--:--")
        }
        slider.isEnabled = dur > 0 && player.isSeekable
        trackSubtitleSlaves()

        sendEvent([
            "type": "state",
            "positionMs": pos,
            "durationMs": dur,
            "bufferedMs": pos,
            "playing": player.isPlaying,
            "playWhenReady": !userPaused,
            "buffering": buffering,
            "ended": ended,
            "ready": player.isPlaying || state == .paused,
            "rate": player.rate,
            "width": Int(player.videoSize.width),
            "height": Int(player.videoSize.height),
        ])
        if ended && !sentEnded {
            sentEnded = true
            sendEvent(["type": "ended"])
            showControls(autoHide: false)
        }
        if state == .error && !sentError {
            sentError = true
            sendEvent(["type": "error", "code": "source", "message": text.cantPlay, "fatal": true])
            spinner.stopAnimating()
            errorBox.isHidden = false
            showControls(autoHide: false)
        }
        if state != lastState {
            log("state \(state.rawValue) playing=\(player.isPlaying) subs=\(player.videoSubTitlesIndexes ?? []) current=\(player.currentVideoSubTitleIndex)")
        }
        // VLC keeps saying "buffering" while a network stream plays: the picture moving is what counts.
        if player.isPlaying && !wasPlaying { autoPickSubtitle() }
        wasPlaying = player.isPlaying
        lastState = state
    }

    private func sendEvent(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        send(json)
    }

    // MARK: - Controls

    @objc private func togglePlay() {
        if player.isPlaying {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            if player.state == .ended || player.state == .stopped { start(at: 0) } else { player.play() }
        }
        showControls()
    }

    @objc private func skipBack() { seek(by: -10_000) }
    @objc private func skipForward() { seek(by: 10_000) }

    private func seek(by delta: Int) {
        seek(to: max(0, currentMs() + delta))
        showControls()
    }

    private func seek(to ms: Int) {
        let dur = durationMs()
        let target = dur > 0 ? min(ms, max(0, dur - 1000)) : ms
        player.time = VLCTime(int: Int32(target))
    }

    @objc private func sliderDown() {
        scrubbing = true
        hideWork?.cancel()
    }

    @objc private func sliderMoved() {
        timeLabel.text = format(Int(slider.value))
    }

    @objc private func sliderUp() {
        seek(to: Int(slider.value))
        scrubbing = false
        showControls()
    }

    @objc private func nextTapped() {
        sendEvent(["type": "next"])
    }

    @objc private func retryTapped() {
        sentError = false
        errorBox.isHidden = true
        player.stop()
        start(at: Int(lastKnownMs))
    }

    @objc private func viewTapped(_ g: UITapGestureRecognizer) {
        if controls.alpha > 0.5 { hideControls() } else { showControls() }
    }

    @objc private func viewDoubleTapped(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x
        if x < view.bounds.width * 0.4 {
            seek(by: -10_000)
            showToast("−10")
        } else if x > view.bounds.width * 0.6 {
            seek(by: 10_000)
            showToast("+10")
        } else {
            fill.toggle()
            applyFill()
        }
    }

    private func showControls(autoHide: Bool = true) {
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        hideWork?.cancel()
        guard autoHide else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.player.isPlaying, !self.scrubbing else { return }
            self.hideControls()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideControls() {
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 }
    }

    private func showToast(_ message: String) {
        toast.text = message
        toast.isHidden = false
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast.isHidden = true }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Fit (whole picture) or fill (the screen, edges cut), by scaling the picture's view.
    private func applyFill() {
        let size = player.videoSize
        guard fill, size.width > 0, size.height > 0, view.bounds.height > 0 else {
            videoView.transform = .identity
            return
        }
        let videoAspect = size.width / size.height
        let screenAspect = view.bounds.width / view.bounds.height
        let scale = max(videoAspect / screenAspect, screenAspect / videoAspect)
        videoView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    // MARK: - Subtitles

    /// Notes which VLC track a subtitle file we added became (it appears a moment after adding).
    private func trackSubtitleSlaves() {
        let ids = Set((player.videoSubTitlesIndexes as? [NSNumber] ?? []).map { $0.int32Value })
        let fresh = ids.subtracting(knownSubTracks).subtracting([-1])
        if let url = pendingExternal, let id = fresh.first {
            externalTrack[url] = id
            pendingExternal = nil
        }
        knownSubTracks = ids
    }

    /// The best subtitle in the preferred languages, once, unless the viewer already chose.
    private func autoPickSubtitle() {
        log("autoPick: picked=\(userPickedSub) current=\(player.currentVideoSubTitleIndex) pending=\(pendingExternal ?? "-") downloading=\(downloadingExternal ?? "-") subs=\(source.subtitles.count) prefs=\(source.prefSubLangs)")
        guard !userPickedSub, player.currentVideoSubTitleIndex == -1, pendingExternal == nil, downloadingExternal == nil else { return }
        for lang in source.prefSubLangs {
            if let sub = source.subtitles.first(where: { ($0.lang ?? "").lowercased() == lang.lowercased() }) {
                loadExternal(sub, announce: false)
                return
            }
        }
    }

    /// Downloads the subtitle file (any encoding: Arabic Windows-1256 files show correctly), saves
    /// it as UTF-8 and hands it to VLC.
    private func loadExternal(_ sub: PlayerSource.Subtitle, announce: Bool) {
        if let id = externalTrack[sub.url] {
            player.currentVideoSubTitleIndex = id
            return
        }
        guard let url = URL(string: sub.url) else { return }
        downloadingExternal = sub.url
        if announce { showToast(text.loadingSub) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let ua = source.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        log("subtitle: downloading \(sub.url)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadingExternal = nil
                self.log("subtitle: got \(data?.count ?? -1) bytes, status \((response as? HTTPURLResponse)?.statusCode ?? -1), error \(error?.localizedDescription ?? "none")")
                guard let data, let file = SubtitleFile.save(data, lang: sub.lang) else {
                    if announce { self.showToast(self.text.subFailed) }
                    return
                }
                self.knownSubTracks = Set((self.player.videoSubTitlesIndexes as? [NSNumber] ?? []).map { $0.int32Value })
                self.pendingExternal = sub.url
                let added = self.player.addPlaybackSlave(file, type: .subtitle, enforce: true)
                self.log("subtitle: saved \(file.path), addPlaybackSlave -> \(added), tracks \(self.player.videoSubTitlesIndexes ?? []) names \(self.player.videoSubTitlesNames ?? [])")
            }
        }.resume()
    }

    private func subtitleMenu() -> [UIMenuElement] {
        let current = player.currentVideoSubTitleIndex
        var items: [UIMenuElement] = []
        items.append(UIAction(title: text.off, state: current == -1 ? .on : .off) { [weak self] _ in
            self?.userPickedSub = true
            self?.player.currentVideoSubTitleIndex = -1
        })
        // Inside the video file.
        let externalIds = Set(externalTrack.values)
        let ids = (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map { $0.int32Value }
        let names = player.videoSubTitlesNames as? [String] ?? []
        var embedded: [UIMenuElement] = []
        for (i, id) in ids.enumerated() where id != -1 && !externalIds.contains(id) {
            let name = i < names.count ? names[i] : "\(text.track) \(i)"
            embedded.append(UIAction(title: name, state: id == current ? .on : .off) { [weak self] _ in
                self?.userPickedSub = true
                self?.player.currentVideoSubTitleIndex = id
            })
        }
        if !embedded.isEmpty { items.append(UIMenu(title: text.embedded, options: .displayInline, children: embedded)) }
        // Saved with the download: files on the phone, so they work offline too.
        let saved = source.downloadId.map { Downloads.shared.savedSubtitleFiles($0) } ?? []
        let savedUrls = Set(saved.map { $0.file.absoluteString } + saved.map { $0.src })
        if !saved.isEmpty {
            let list: [UIMenuElement] = saved.map { f in
                let sub = PlayerSource.Subtitle(url: f.file.absoluteString, lang: f.lang, label: f.label)
                let on = externalTrack[sub.url].map { $0 == current } ?? false
                return UIAction(title: f.label ?? text.language(f.lang ?? "und"), state: on ? .on : .off) { [weak self] _ in
                    self?.userPickedSub = true
                    self?.loadExternal(sub, announce: true)
                }
            }
            items.append(UIMenu(title: text.savedOnDevice, options: .displayInline, children: list))
        }
        // From the addons, by language (preferred ones first).
        var byLang: [String: [PlayerSource.Subtitle]] = [:]
        for s in source.subtitles where !savedUrls.contains(s.url) { byLang[(s.lang ?? "und").lowercased(), default: []].append(s) }
        let order = byLang.keys.sorted { a, b in
            let ia = source.prefSubLangs.firstIndex(of: a) ?? Int.max
            let ib = source.prefSubLangs.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : text.language(a) < text.language(b)
        }
        var groups: [UIMenuElement] = []
        for lang in order {
            let subs = byLang[lang] ?? []
            let children: [UIMenuElement] = subs.enumerated().map { (n, s) -> UIMenuElement in
                let on = externalTrack[s.url].map { $0 == current } ?? false
                return UIAction(title: s.label ?? "\(text.language(lang)) \(n + 1)", state: on ? .on : .off) { [weak self] _ in
                    self?.userPickedSub = true
                    self?.loadExternal(s, announce: true)
                }
            }
            groups.append(UIMenu(title: "\(text.language(lang)) (\(subs.count))", children: children))
        }
        if !groups.isEmpty { items.append(UIMenu(title: text.fromAddons, options: .displayInline, children: groups)) }
        // A downloaded title: an addon subtitle can be saved with the video (for offline).
        if let id = source.downloadId {
            let online = source.subtitles.filter { !savedUrls.contains($0.url) && !$0.url.hasPrefix("file:") }
            if !online.isEmpty {
                let list: [UIMenuElement] = online.map { s in
                    UIAction(title: s.label ?? text.language(s.lang ?? "und"), image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                        Downloads.shared.saveSubtitle(id, url: s.url, lang: s.lang, label: s.label) { ok in
                            guard let self else { return }
                            self.showToast(ok ? self.text.subSaved : self.text.subSaveFailed)
                        }
                    }
                }
                items.append(UIMenu(title: text.saveWithDownload, image: UIImage(systemName: "square.and.arrow.down"), children: list))
            }
        }
        items.append(UIAction(title: text.searchSubs, image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.sendEvent(["type": "subSearch"])
            self?.showToast(self?.text.searching ?? "")
        })
        return items
    }

    private func audioMenu() -> [UIMenuElement] {
        let ids = (player.audioTrackIndexes as? [NSNumber] ?? []).map { $0.int32Value }
        let names = player.audioTrackNames as? [String] ?? []
        let current = player.currentAudioTrackIndex
        let items: [UIMenuElement] = ids.enumerated().compactMap { (i, id) -> UIMenuElement? in
            guard id != -1 else { return nil }
            let name = i < names.count ? names[i] : "\(text.track) \(i)"
            return UIAction(title: name, state: id == current ? .on : .off) { [weak self] _ in
                self?.player.currentAudioTrackIndex = id
            }
        }
        return items.isEmpty ? [UIAction(title: text.noTracks, attributes: .disabled) { _ in }] : items
    }

    private func moreMenu() -> [UIMenuElement] {
        let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
        let speed = UIMenu(title: text.speed, image: UIImage(systemName: "speedometer"), children: rates.map { r in
            UIAction(title: r == 1 ? text.normal : "\(r)×", state: abs(player.rate - r) < 0.01 ? .on : .off) { [weak self] _ in
                self?.player.rate = r
            }
        })
        let fillAction = UIAction(title: fill ? text.fit : text.fill, image: UIImage(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
            self?.fill.toggle()
            self?.applyFill()
        }
        return [fillAction, speed, styleMenu(), delayMenu()]
    }

    /// The subtitle look: size, colour, background, bold, position.
    private func styleMenu() -> UIMenu {
        let s = style
        func pick(_ change: @escaping (inout SubStyle) -> Void) -> (UIAction) -> Void {
            { [weak self] _ in
                guard let self else { return }
                var next = self.style
                change(&next)
                self.applyStyle(next)
            }
        }
        let size = UIMenu(title: text.subSize, image: UIImage(systemName: "textformat.size"), children: Self.scales.enumerated().map { i, sc in
            UIAction(title: text.sizeNames[i], state: abs(s.scale - sc) < 0.06 ? .on : .off, handler: pick { $0.scale = sc })
        })
        let colour = UIMenu(title: text.colour, image: UIImage(systemName: "paintpalette"), children: text.colourNames.map { hex, name in
            UIAction(title: name, state: s.color.uppercased() == hex ? .on : .off, handler: pick { $0.color = hex })
        })
        let background = UIMenu(title: text.backgroundTitle, image: UIImage(systemName: "rectangle.fill"), children: text.backgroundNames.map { id, name in
            UIAction(title: name, state: s.background == id ? .on : .off, handler: pick { $0.background = id })
        })
        let bold = UIAction(title: text.bold, image: UIImage(systemName: "bold"), state: s.bold ? .on : .off, handler: pick { $0.bold.toggle() })
        let position = UIMenu(title: text.position, image: UIImage(systemName: "arrow.up.and.down"), children: text.positionNames.map { at, name in
            UIAction(title: name, state: abs(s.bottom - at) < 0.04 ? .on : .off, handler: pick { $0.bottom = at })
        })
        return UIMenu(title: text.subStyle, image: UIImage(systemName: "captions.bubble"), children: [size, colour, background, bold, position])
    }

    /// The subtitles earlier or later (half a second a step); applies at once.
    private func delayMenu() -> UIMenu {
        let steps = [-1000, -500, 500, 1000]
        var items: [UIMenuElement] = steps.map { d in
            UIAction(title: text.seconds(d)) { [weak self] _ in self?.setDelay((self?.subDelayMs ?? 0) + d) }
        }
        items.append(UIAction(title: text.resetDelay, state: subDelayMs == 0 ? .on : .off) { [weak self] _ in self?.setDelay(0) })
        return UIMenu(title: "\(text.delay): \(text.seconds(subDelayMs))", image: UIImage(systemName: "clock.arrow.2.circlepath"), children: items)
    }

    private func setDelay(_ ms: Int) {
        subDelayMs = Swift.max(-30_000, Swift.min(30_000, ms))
        player.currentVideoSubTitleDelay = subDelayMs * 1000
        showToast("\(text.delay): \(text.seconds(subDelayMs))")
    }

    // MARK: - Sources

    /// Every source for this title (the page sends them); a tap switches to it.
    private func sourcesElement() -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else {
                done([])
                return
            }
            self.streamsWaiter?([])
            self.streamsWaiter = done
            self.sendEvent(["type": "requestStreams"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let waiting = self.streamsWaiter else { return }
                self.streamsWaiter = nil
                waiting([UIAction(title: self.text.noSources, attributes: .disabled) { _ in }])
            }
        }
    }

    private func streamsMenu(_ data: [String: Any]) -> [UIMenuElement] {
        let items = (data["items"] as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            let m = (data["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.noSources
            return [UIAction(title: m, attributes: .disabled) { _ in }]
        }
        func action(_ it: [String: Any]) -> UIAction {
            let key = it["key"] as? String ?? ""
            let current = it["current"] as? Bool ?? false
            let cached = it["cached"] as? Bool ?? false
            let name = (cached ? "⚡ " : "") + (it["name"] as? String ?? "")
            let a = UIAction(title: name, state: current ? .on : .off) { [weak self] _ in
                guard let self, !current, self.pickingStream == nil else { return }
                self.pickingStream = key
                self.showToast(self.text.switching)
                self.sendEvent(["type": "pickStream", "key": key])
            }
            let sub = [it["desc"] as? String, it["badges"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !sub.isEmpty { a.subtitle = sub }
            return a
        }
        var qualities: [String] = []
        for it in items {
            if let q = it["quality"] as? String, !q.isEmpty, !qualities.contains(q) { qualities.append(q) }
        }
        guard qualities.count > 1 else { return items.map(action) }
        // Several qualities: one list each.
        return qualities.map { q in
            UIMenu(title: q, children: items.filter { ($0["quality"] as? String) == q }.map(action))
        }
    }

    /// VLC takes the subtitle look when the player is made: a new player, at the same point.
    private func applyStyle(_ next: SubStyle) {
        guard next != style else { return }
        style = next
        next.save()
        let at = currentMs()
        let pickedUrl = externalTrack.first(where: { $0.value == player.currentVideoSubTitleIndex })?.key
        player.stop()
        player.drawable = nil
        player = Self.makePlayer(next)
        externalTrack = [:]
        knownSubTracks = []
        pendingExternal = nil
        downloadingExternal = nil
        start(at: at)
        if let url = pickedUrl {
            let sub = source.subtitles.first(where: { $0.url == url }) ?? PlayerSource.Subtitle(url: url, lang: nil, label: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.loadExternal(sub, announce: false) }
        }
    }

    // MARK: - Swipes

    /// Buttons and the time bar keep their own touches.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g is UIPanGestureRecognizer, touch.view is UIControl { return false }
        return true
    }

    /// Sideways: the time (two minutes across the screen); up and down: the brightness on the
    /// left half, the volume on the right.
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        let w = Swift.max(view.bounds.width, 1)
        let h = Swift.max(view.bounds.height, 1)
        switch g.state {
        case .began:
            let v = g.velocity(in: view)
            if abs(v.x) > abs(v.y) {
                guard durationMs() > 0, player.isSeekable else {
                    panMode = 0
                    return
                }
                panMode = 1
                panStartMs = currentMs()
                panTargetMs = panStartMs
            } else {
                panMode = g.location(in: view).x < w / 2 ? 2 : 3
                panStartValue = panMode == 2 ? Float(UIScreen.main.brightness) : (volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
            }
        case .changed:
            switch panMode {
            case 1:
                let delta = Int(t.x / w * 120_000)
                panTargetMs = Swift.min(Swift.max(0, panStartMs + delta), Swift.max(0, durationMs() - 1000))
                let shown = (panTargetMs - panStartMs) / 1000
                showHud("\(shown >= 0 ? "+" : "−")\(abs(shown))s  ·  \(format(panTargetMs))")
            case 2:
                let v = Swift.min(Swift.max(panStartValue - Float(t.y / (h * 0.8)), 0), 1)
                UIScreen.main.brightness = CGFloat(v)
                showHud("\(text.brightness) \(Int(v * 100))%")
            case 3:
                let v = Swift.min(Swift.max(panStartValue - Float(t.y / (h * 0.8)), 0), 1)
                volumeSlider?.value = v
                showHud("\(text.volume) \(Int(v * 100))%")
            default:
                break
            }
        case .ended:
            if panMode == 1 { seek(to: panTargetMs) }
            panMode = 0
            hideHud()
        default:
            panMode = 0
            hideHud()
        }
    }

    private func showHud(_ s: String) {
        hud.text = s
        hud.isHidden = false
        hudWork?.cancel()
    }

    private func hideHud() {
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud.isHidden = true }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Layout

    private func buildViews() {
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        view.addSubview(videoView)
        pin(videoView, to: view)

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(viewDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        controls.backgroundColor = .clear
        view.addSubview(controls)
        pin(controls, to: view)
        controls.addSubview(topShade)
        controls.addSubview(bottomShade)
        [topShade, bottomShade].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        style(closeButton, "xmark", 20)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.text = source.title
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        subtitleLabel.isHidden = true
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 2

        style(audioButton, "waveform", 20)
        style(subsButton, "captions.bubble", 20)
        style(moreButton, "ellipsis.circle", 20)
        style(sourcesButton, "rectangle.stack", 20)
        sourcesButton.menu = UIMenu(title: text.sources, children: [sourcesElement()])
        sourcesButton.showsMenuAsPrimaryAction = true
        sourcesButton.accessibilityLabel = text.sources
        audioButton.menu = UIMenu(title: text.audio, children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.audioMenu() ?? []) }])
        subsButton.menu = UIMenu(title: text.subtitles, children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.subtitleMenu() ?? []) }])
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreMenu() ?? []) }])
        [audioButton, subsButton, moreButton].forEach { $0.showsMenuAsPrimaryAction = true }

        let top = UIStackView(arrangedSubviews: [closeButton, titles, UIView(), sourcesButton, audioButton, subsButton, moreButton])
        top.alignment = .center
        top.spacing = 14
        top.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(top)

        style(backButton, "gobackward.10", 30)
        style(playButton, "pause.fill", 34)
        style(forwardButton, "goforward.10", 30)
        backButton.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        let middle = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        middle.spacing = 56
        middle.alignment = .center
        middle.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(middle)

        [timeLabel, durationLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            $0.textColor = .white
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        timeLabel.text = "0:00"
        durationLabel.text = "--:--"
        slider.minimumTrackTintColor = UIColor(red: 0.83, green: 0.63, blue: 0.39, alpha: 1)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(thumb(), for: .normal)
        slider.addTarget(self, action: #selector(sliderDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        var nextConfig = UIButton.Configuration.filled()
        nextConfig.title = text.nextEpisode
        nextConfig.image = UIImage(systemName: "forward.end.fill")
        nextConfig.imagePadding = 6
        nextConfig.baseBackgroundColor = UIColor.white.withAlphaComponent(0.92)
        nextConfig.baseForegroundColor = .black
        nextConfig.cornerStyle = .capsule
        nextButton.configuration = nextConfig
        nextButton.isHidden = true
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        let bottom = UIStackView(arrangedSubviews: [timeLabel, slider, durationLabel, nextButton])
        bottom.alignment = .center
        bottom.spacing = 12
        bottom.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(bottom)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = false
        view.addSubview(spinner)

        hud.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hud.layer.cornerRadius = 14
        hud.clipsToBounds = true
        hud.textAlignment = .center
        hud.isHidden = true
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
        ])

        toast.font = .systemFont(ofSize: 14, weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        toast.numberOfLines = 2
        toast.textAlignment = .center
        toast.isHidden = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)

        errorLabel.text = text.cantPlay
        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        let retry = UIButton(type: .system)
        var retryConfig = UIButton.Configuration.filled()
        retryConfig.title = text.retry
        retryConfig.baseBackgroundColor = .white
        retryConfig.baseForegroundColor = .black
        retryConfig.cornerStyle = .capsule
        retry.configuration = retryConfig
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        errorBox.addArrangedSubview(errorLabel)
        errorBox.addArrangedSubview(retry)
        errorBox.axis = .vertical
        errorBox.alignment = .center
        errorBox.spacing = 14
        errorBox.isHidden = true
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorBox)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topShade.topAnchor.constraint(equalTo: controls.topAnchor),
            topShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            topShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            topShade.heightAnchor.constraint(equalToConstant: 120),
            bottomShade.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            bottomShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            bottomShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            bottomShade.heightAnchor.constraint(equalToConstant: 130),

            top.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

            middle.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            middle.centerYAnchor.constraint(equalTo: controls.centerYAnchor),

            bottom.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.topAnchor.constraint(equalTo: g.topAnchor, constant: 64),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),

            errorBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorBox.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorBox.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
        ])
    }

    private func pin(_ v: UIView, to parent: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    private func symbol(_ name: String, _ size: CGFloat) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    private func style(_ b: UIButton, _ name: String, _ size: CGFloat) {
        b.setImage(symbol(name, size), for: .normal)
        b.tintColor = .white
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func thumb() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 14, height: 14)).fill()
        }
    }

    private func format(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// A shade behind the controls so white text reads over a bright picture.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(top: Bool) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let g = layer as! CAGradientLayer
        let dark = UIColor.black.withAlphaComponent(0.65).cgColor
        g.colors = top ? [dark, UIColor.clear.cgColor] : [UIColor.clear.cgColor, dark]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height + 16)
    }
}

/// Subtitle files saved for VLC: always UTF-8 (Arabic files are often Windows-1256).
enum SubtitleFile {
    /// For the player: a temporary file.
    static func save(_ data: Data, lang: String?) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        return save(data, lang: lang, in: dir, name: UUID().uuidString)
    }

    /// A gzipped subtitle (OpenSubtitles' .gz) unpacked; anything else as it is.
    static func unpack(_ data: Data) -> Data {
        let b = [UInt8](data.prefix(10))
        guard b.count >= 10, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return data }
        let flags = b[3]
        var i = 10
        let bytes = [UInt8](data)
        if flags & 0x04 != 0, bytes.count > i + 2 { i += 2 + Int(bytes[i]) + Int(bytes[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < bytes.count - 8 else { return data }
        let deflated = Data(bytes[i..<(bytes.count - 8)])
        return (try? (deflated as NSData).decompressed(using: .zlib) as Data) ?? data
    }

    /// Saved as UTF-8 in [dir] as [name] plus the format's extension (sniffed: SRT, VTT, ASS).
    static func save(_ raw: Data, lang: String?, in dir: URL, name: String) -> URL? {
        let data = unpack(raw)
        guard !data.isEmpty else { return nil }
        var text = String(data: data, encoding: .utf8)
        if text == nil {
            func cf(_ e: CFStringEncodings) -> String.Encoding {
                String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
            }
            let encoding: String.Encoding
            switch (lang ?? "").lowercased() {
            case "ar", "fa", "ur", "ps", "ku": encoding = cf(.windowsArabic)
            case "he": encoding = cf(.windowsHebrew)
            case "ru", "uk", "bg", "sr", "mk": encoding = .windowsCP1251
            case "el": encoding = .windowsCP1253
            case "tr", "az": encoding = .windowsCP1254
            case "pl", "cs", "sk", "hu", "ro", "hr", "sl", "bs": encoding = .windowsCP1250
            default: encoding = .windowsCP1252
            }
            text = String(data: data, encoding: encoding) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard var body = text else { return nil }
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let head = body.prefix(200)
        let ext = head.hasPrefix("WEBVTT") ? "vtt" : head.contains("[Script Info]") ? "ass" : "srt"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).\(ext)")
        do {
            try body.data(using: .utf8)?.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}

/// The player's words, in the app's language (English or Arabic).
struct PlayerText {
    let ar: Bool
    let locale: Locale

    init(lang: String) {
        ar = lang.lowercased().hasPrefix("ar")
        locale = Locale(identifier: ar ? "ar" : "en")
    }

    var audio: String { ar ? "الصوت" : "Audio" }
    var subtitles: String { ar ? "الترجمة" : "Subtitles" }
    var off: String { ar ? "بدون ترجمة" : "Off" }
    var embedded: String { ar ? "داخل الملف" : "In the file" }
    var fromAddons: String { ar ? "من الإضافات" : "From addons" }
    var searchSubs: String { ar ? "ابحث عن ترجمات" : "Search for subtitles" }
    var searching: String { ar ? "جارٍ البحث عن ترجمات…" : "Searching for subtitles…" }
    var noSubs: String { ar ? "لم يتم العثور على ترجمات" : "No subtitles found" }
    func foundSubs(_ n: Int) -> String { ar ? "تم العثور على \(n) ترجمة" : "Found \(n) subtitles" }
    var loadingSub: String { ar ? "جارٍ تحميل الترجمة…" : "Loading subtitle…" }
    var subFailed: String { ar ? "تعذّر تحميل هذه الترجمة" : "Couldn't load this subtitle" }
    var track: String { ar ? "مسار" : "Track" }
    var noTracks: String { ar ? "لا توجد مسارات" : "No tracks" }
    var speed: String { ar ? "السرعة" : "Speed" }
    var normal: String { ar ? "عادية" : "Normal" }
    var subSize: String { ar ? "حجم الترجمة" : "Subtitle size" }
    var sizeNames: [String] { ar ? ["أصغر", "صغير", "عادي", "كبير", "أكبر"] : ["Smaller", "Small", "Normal", "Large", "Larger"] }
    var fill: String { ar ? "ملء الشاشة" : "Fill screen" }
    var fit: String { ar ? "عرض الصورة كاملة" : "Fit to screen" }
    var nextEpisode: String { ar ? "الحلقة التالية" : "Next episode" }
    var cantPlay: String { ar ? "تعذّر تشغيل هذا المصدر." : "Couldn't play this source." }
    var retry: String { ar ? "إعادة المحاولة" : "Retry" }

    func language(_ code: String) -> String {
        if code == "und" { return ar ? "غير محددة" : "Unknown" }
        return locale.localizedString(forLanguageCode: code) ?? code
    }
}
