# Acknowledgements

Scriberman is built on the following open-source software. Each project remains
under its own license; the notices below are reproduced as those licenses require.
Full license texts are available at the linked repositories and, for dependencies
embedded in the application bundle, alongside this file in source distributions.

## Frameworks and libraries

### FluidAudio
On-device ASR, VAD, and speaker diarization.
Copyright FluidInference. Licensed under the Apache License 2.0.
<https://github.com/FluidInference/FluidAudio>
Bundles third-party components: fastcluster (© 2011 Daniel Müllner, BSD-style)
and VBx (Brno University of Technology, Apache License 2.0).

### Sparkle
Software update framework for macOS.
Copyright (c) 2006–2013 Andy Matuschak, (c) 2009–2013 Elgato Systems GmbH,
and other Sparkle contributors. Licensed under the MIT license (with portions
under other permissive licenses; see the project's LICENSE file).
<https://github.com/sparkle-project/Sparkle>

### OpenAI (MacPaw)
OpenAI-compatible API client.
Copyright (c) 2023 MacPaw Inc. Licensed under the MIT license.
<https://github.com/MacPaw/OpenAI>

### swift-markdown-ui
Markdown rendering for SwiftUI.
Copyright (c) 2020 Guillermo Gonzalez. Licensed under the MIT license.
<https://github.com/gonzalezreal/swift-markdown-ui>

### NetworkImage
Remote image loading for SwiftUI.
Copyright (c) 2020 Guille Gonzalez. Licensed under the MIT license.
<https://github.com/gonzalezreal/NetworkImage>

### swift-openapi-runtime / swift-http-types
Copyright Apple Inc. and the project authors. Licensed under the Apache License 2.0.
<https://github.com/apple/swift-openapi-runtime>
<https://github.com/apple/swift-http-types>

### cmark-gfm (swift-cmark)
CommonMark parsing.
Copyright (c) 2014 John MacFarlane and contributors. Licensed under
BSD-2-Clause and MIT (per-file; see the project's COPYING file).
<https://github.com/swiftlang/swift-cmark>

## Machine-learning models

Scriberman downloads the following models at runtime from the
[FluidInference](https://huggingface.co/FluidInference) Hugging Face
organization. They are not distributed inside the application bundle.

- **NVIDIA Parakeet TDT 0.6B v3** (speech recognition) — CC-BY-4.0.
  Original model by NVIDIA; CoreML conversion by FluidInference.
- **Speaker diarization models** (pyannote segmentation, WeSpeaker embeddings) —
  CC-BY-4.0. CoreML conversion by FluidInference.
- **Silero VAD** (voice activity detection) — MIT. © Silero Team.
- **LS-EEND** (streaming turn diarization) — MIT. CoreML conversion by FluidInference.

## MIT License (applies to the MIT-licensed components above)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
