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
- **Speaker memory** — recognized speakers keep their names across meetings.
- **Voice dictation** — system-wide dictation that types into any app.
- **AI summary** — summaries for your transcript via OpenRouter.
- **Calendar suggestions** — suggests recordings from your calendar events.

Transcription runs on Apple silicon with Parakeet Ultra, Silero VAD,
Nemotron 3, pyannote and WeSpeaker — see
[ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) for full credits.

## Installation

Download the latest DMG from
[Releases](https://github.com/ohshie/scriberman/releases), drag
`Scriberman.app` into `/Applications`, then clear the download quarantine
(the app is self-signed, not notarized):

```bash
xattr -cr /Applications/Scriberman.app
```

## Contributing

Contributions are welcome under a contributor license agreement — see
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR.

## License

Scriberman is licensed under the **PolyForm Noncommercial License 1.0.0** —
see [LICENSE](LICENSE). You may use, modify, and share it for any noncommercial
purpose; commercial use is not permitted. Third-party components remain under
their own licenses, listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

Copyright © 2026 ohshie.
