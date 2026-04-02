import Testing
@testable import Scriberman

@MainActor
@Suite
struct AudioPlayerViewModelTests {
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
}
