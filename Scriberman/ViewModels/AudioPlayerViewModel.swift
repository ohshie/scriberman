import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlayerViewModel {
    private let player = AVPlayer()
    private var statusObservation: NSKeyValueObservation?
    private var periodicTimeObserver: Any?
    private var playbackEndedObserver: NSObjectProtocol?

    var isReady = false
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isScrubbing = false

    init() {
        addPeriodicTimeObserver()
    }

    deinit {
        MainActor.assumeIsolated {
            tearDownPlaybackEndedObserver()
            removePeriodicTimeObserver()
        }
    }

    func load(url: URL) {
        tearDownPlaybackEndedObserver()

        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                switch item.status {
                case .readyToPlay:
                    let durationSeconds = item.duration.seconds
                    if durationSeconds.isFinite, durationSeconds > 0 {
                        duration = durationSeconds
                    } else {
                        duration = 0
                    }
                    isReady = true
                case .failed:
                    isReady = false
                    duration = 0
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clampedSeconds = max(0, min(seconds, duration > 0 ? duration : seconds))
        let time = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        player.seek(to: time)
        currentTime = clampedSeconds
    }

    func stop() {
        pause()
        player.seek(to: .zero)
        currentTime = 0
        isPlaying = false
    }

    func clear() {
        stop()
        statusObservation = nil
        tearDownPlaybackEndedObserver()
        player.replaceCurrentItem(with: nil)
        isReady = false
        isScrubbing = false
        duration = 0
        currentTime = 0
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, isScrubbing == false else {
                return
            }

            let seconds = time.seconds
            if seconds.isFinite {
                currentTime = max(0, seconds)
            }
        }
    }

    private func removePeriodicTimeObserver() {
        guard let periodicTimeObserver else {
            return
        }

        player.removeTimeObserver(periodicTimeObserver)
        self.periodicTimeObserver = nil
    }

    private func tearDownPlaybackEndedObserver() {
        guard let playbackEndedObserver else {
            return
        }

        NotificationCenter.default.removeObserver(playbackEndedObserver)
        self.playbackEndedObserver = nil
    }
}
