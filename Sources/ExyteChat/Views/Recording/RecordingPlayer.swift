//
//  RecordingPlayer.swift
//
//
//  Created by Alexandra Afonasova on 21.06.2022.
//

@preconcurrency import Combine
@preconcurrency import AVFoundation

final actor RecordingPlayer: ObservableObject {

    @MainActor @Published var playing = false
    @MainActor @Published var duration: Double = 0.0
    @MainActor @Published var secondsLeft: Double = 0.0
    @MainActor @Published var progress: Double = 0.0

    @MainActor let didPlayTillEnd = PassthroughSubject<Void, Never>()

    private var recording: Recording? {
        didSet {
            internalPlaying = false
            Task { @MainActor in
                self.progress = 0
                if let r = await self.recording {
                    self.duration = r.duration
                    self.secondsLeft = r.duration
                } else {
                    self.duration = 0
                    self.secondsLeft = 0
                }
            }
        }
    }

    private var internalPlaying = false {
        didSet {
            Task { @MainActor in
                self.playing = await internalPlaying
            }
        }
    }

    private let audioSession = AVAudioSession.sharedInstance()
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    init() {
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audioSession.overrideOutputAudioPort(.speaker)
    }

    func play(_ recording: Recording) {
        setupPlayer(for: recording)
        play()
    }

    func pause() {
        player?.pause()
        internalPlaying = false
    }

    func togglePlay(_ recording: Recording) {
        if self.recording?.url != recording.url {
            setupPlayer(for: recording)
        }
        internalPlaying ? pause() : play()
    }

    func seek(with recording: Recording, to progress: Double) {
        let goalTime = recording.duration * progress
        if self.recording == nil {
            setupPlayer(for: recording)
        }
        player?.currentTime = goalTime
        if !internalPlaying {
            play()
        }
    }

    func seek(to progress: Double) {
        if let recording {
            let goalTime = recording.duration * progress
            player?.currentTime = goalTime
            if !internalPlaying { play() }
        }
    }

    func reset() {
        if internalPlaying { pause() }
        recording = nil
    }

    private func play() {
        try? audioSession.setActive(true)
        player?.play()
        startProgressTimer()
        internalPlaying = true
        NotificationCenter.default.post(name: .chatAudioIsPlaying, object: self)
    }

    private func setupPlayer(for recording: Recording) {
        guard let url = recording.url else { return }
        self.recording = recording

        NotificationCenter.default.removeObserver(self)
        invalidateProgressTimer()
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()

        NotificationCenter.default.addObserver(forName: .chatAudioIsPlaying, object: nil, queue: nil) { notification in
            if let sender = notification.object as? RecordingPlayer {
                Task { [weak self] in
                    if await sender.recording?.url == self?.recording?.url {
                        return
                    }
                    await self?.pause()
                }
            }
        }
    }

    private func setPlayingState(_ isPlaying: Bool) {
        self.internalPlaying = isPlaying
    }

    @MainActor
    private func updateProgressFromPlayer() {
        guard let player else { return }
        duration = player.duration
        progress = duration > 0 ? player.currentTime / duration : 0
        secondsLeft = max(duration - player.currentTime, 0).rounded()
    }

    private func startProgressTimer() {
        invalidateProgressTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    await MainActor.run {
                        self.updateProgressFromPlayer()
                    }
                    if let player = await self.player, !player.isPlaying {
                        await self.setPlayingState(false)
                        await self.invalidateProgressTimer()
                        await MainActor.run {
                            self.didPlayTillEnd.send()
                        }
                    }
                }
            }
            if let timer = self.progressTimer {
                RunLoop.current.add(timer, forMode: .common)
            }
        }
    }

    private func invalidateProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
