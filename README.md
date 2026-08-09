# Scriberman

Private, on-device meeting transcription for macOS. Scriberman records your
microphone and system audio, transcribes speech locally with speaker
diarization, and keeps everything on your Mac — no audio ever leaves your
machine for transcription.

## Features

- **Recording** — capture microphone and app/system audio (with optional
  screen video) into per-session files.
- **Live transcription** — on-device speech-to-text with real-time speaker
  turn attribution while you record.
- **Offline transcription & retranscription** — re-run improved transcription
  over any session's audio, with global speaker diarization and word-level
  speaker alignment.
- **Speaker memory** — recognized speakers keep their names across meetings.
- **Voice dictation** — system-wide dictation that types into any app.
- **AI transformations** — optional post-processing of transcripts (summaries,
  cleanups) through OpenAI-compatible providers you configure; only the
  transcript text you explicitly transform is sent.
- **Transcript tools** — search, playback-synced navigation, cleanup rules,
  export.

Transcription runs on Apple silicon via [FluidAudio](https://github.com/FluidInference/FluidAudio)
(NVIDIA Parakeet ASR, Silero VAD, pyannote/WeSpeaker diarization) — see
[ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) for full credits.

## Installation

Download the latest DMG from
[Releases](https://github.com/ohshie/scriberman/releases), drag
`Scriberman.app` into `/Applications`, then clear the download quarantine
(the app is self-signed, not notarized):

```bash
xattr -cr /Applications/Scriberman.app
```

## Support

Scriberman is free software, developed in spare time. If it's useful to you,
donations are welcome — see the repository sidebar.

## Contributing

Contributions are welcome under a contributor license agreement — see
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR.

## License

Scriberman is licensed under the **PolyForm Noncommercial License 1.0.0** —
see [LICENSE](LICENSE). You may use, modify, and share it for any noncommercial
purpose; commercial use is not permitted. Third-party components remain under
their own licenses, listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

Copyright © 2026 ohshie.
