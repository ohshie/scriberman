import Testing
@testable import Scriberman

@MainActor
@Suite
struct AudioPlayerViewModelTests {
    @MainActor
    private final class MockPlaybackController: TranscriptPlaybackControlling {
        var actions: [String] = []
        var soughtTime: Double?

        func seek(to seconds: Double) {
            soughtTime = seconds
            actions.append("seek")
        }

        func play() {
            actions.append("play")
        }
    }

    @Test
    func initialState() {
        let viewModel = AudioPlayerViewModel()

        #expect(viewModel.isReady == false)
        #expect(viewModel.isPlaying == false)
        #expect(viewModel.currentTime == 0)
        #expect(viewModel.duration == 0)
        #expect(viewModel.isScrubbing == false)
    }

    @Test
    func stopResetsPlaybackPosition() {
        let viewModel = AudioPlayerViewModel()

        viewModel.seek(to: 12)
        viewModel.play()
        viewModel.stop()

        #expect(viewModel.currentTime == 0)
        #expect(viewModel.isPlaying == false)
    }

    @Test
    func clearResetsAllState() {
        let viewModel = AudioPlayerViewModel()

        viewModel.isReady = true
        viewModel.isScrubbing = true
        viewModel.seek(to: 9)
        viewModel.play()

        viewModel.clear()

        #expect(viewModel.isReady == false)
        #expect(viewModel.isPlaying == false)
        #expect(viewModel.currentTime == 0)
        #expect(viewModel.duration == 0)
        #expect(viewModel.isScrubbing == false)
    }

    @Test
    func pauseStopsPlayback() {
        let viewModel = AudioPlayerViewModel()

        viewModel.isPlaying = true
        viewModel.pause()

        #expect(viewModel.isPlaying == false)
    }

    @Test
    func tappingBlockSeeksThenStartsPlayback() {
        let player = MockPlaybackController()
        let block = TranscriptBlock(
            speaker: TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111"),
            audioSource: .mic,
            startTime: 12.34,
            endTime: 14,
            text: "Hello"
        )

        TranscriptStudyView.seekAndPlay(block: block, player: player)

        #expect(player.soughtTime == Double(block.startTime))
        #expect(player.actions == ["seek", "play"])
    }
}
