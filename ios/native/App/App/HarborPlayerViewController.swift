import MobileVLCKit
import UIKit

/// The iPhone app's video player (VLC: MKV, HEVC, Dolby / DTS audio, ASS / SRT subtitles), full
/// screen over the page. It reports to the page like the Android player does (state every second,
/// ended, error, closed) and takes the same commands (play, pause, seek, rate, addSubs, meta…).
final class HarborPlayerViewController: UIViewController {
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
    private var knownSubTracks = Set<Int32>()
    /// External subtitles we loaded: our URL -> VLC's track id.
    private var externalTrack: [String: Int32] = [:]
    private var pendingExternal: String?
    /// A subtitle file being downloaded (not handed to VLC yet).
    private var downloadingExternal: String?
    private var userPickedSub = false
    private var lastKnownMs: Int32 = 0

    private static let sizeKey = "harbor.ios.subSize"
    /// Test builds (the simulator check): VLC's own log and the subtitle steps in the console.
    static var verbose = false

    private func log(_ message: @autoclosure () -> String) {
        if Self.verbose { NSLog("[harbor player] %@", message()) }
    }
    private static let sizes: [Int] = [20, 18, 16, 12, 6] // VLC's relative sizes: smaller number = bigger text

    init(source: PlayerSource, send: @escaping (String) -> Void) {
        self.source = source
        self.send = send
        text = PlayerText(lang: source.uiLang)
        player = HarborPlayerViewController.makePlayer()
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func makePlayer() -> VLCMediaPlayer {
        let size = UserDefaults.standard.object(forKey: sizeKey) as? Int ?? 16
        let made = VLCMediaPlayer(options: [
            "--freetype-rel-fontsize=\(size)",
            "--freetype-outline-thickness=4",
            "--freetype-background-opacity=0",
        ])
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
        sentEnded = false
        sentError = false
        userPickedSub = false
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
            if let m = cmd["message"] as? String, !m.isEmpty { showToast(m) }
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
            if state == .playing { autoPickSubtitle() }
        }
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
        // From the addons, by language (preferred ones first).
        var byLang: [String: [PlayerSource.Subtitle]] = [:]
        for s in source.subtitles { byLang[(s.lang ?? "und").lowercased(), default: []].append(s) }
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
        let currentSize = UserDefaults.standard.object(forKey: Self.sizeKey) as? Int ?? 16
        let size = UIMenu(title: text.subSize, image: UIImage(systemName: "textformat.size"), children: Self.sizes.enumerated().map { i, s in
            UIAction(title: text.sizeNames[i], state: s == currentSize ? .on : .off) { [weak self] _ in
                self?.setSubtitleSize(s)
            }
        })
        let fillAction = UIAction(title: fill ? text.fit : text.fill, image: UIImage(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
            self?.fill.toggle()
            self?.applyFill()
        }
        return [fillAction, speed, size]
    }

    /// VLC sets the text size when the player is made: a new player, at the same point.
    private func setSubtitleSize(_ size: Int) {
        UserDefaults.standard.set(size, forKey: Self.sizeKey)
        let at = currentMs()
        let pickedUrl = externalTrack.first(where: { $0.value == player.currentVideoSubTitleIndex })?.key
        player.stop()
        player.drawable = nil
        player = Self.makePlayer()
        externalTrack = [:]
        knownSubTracks = []
        pendingExternal = nil
        downloadingExternal = nil
        start(at: at)
        if let url = pickedUrl, let sub = source.subtitles.first(where: { $0.url == url }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.loadExternal(sub, announce: false) }
        }
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
        audioButton.menu = UIMenu(title: text.audio, children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.audioMenu() ?? []) }])
        subsButton.menu = UIMenu(title: text.subtitles, children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.subtitleMenu() ?? []) }])
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreMenu() ?? []) }])
        [audioButton, subsButton, moreButton].forEach { $0.showsMenuAsPrimaryAction = true }

        let top = UIStackView(arrangedSubviews: [closeButton, titles, UIView(), audioButton, subsButton, moreButton])
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
    static func save(_ data: Data, lang: String?) -> URL? {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
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
