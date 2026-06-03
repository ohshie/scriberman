## 1. Bump Package Dependency

- [x] 1.1 In Xcode, update the FluidAudio SPM dependency version from `0.13.6` to `0.14.8` and resolve packages
- [x] 1.2 Confirm `Package.resolved` reflects the new revision for `fluidaudio` (no SPM resolution conflict)

## 2. Compile Verification

- [x] 2.1 Build the project — confirm zero compiler errors across all call sites
- [x] 2.2 Verify `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` in `LiveTranscriptionService` compiles; adapt signature if needed
- [x] 2.3 Verify `OfflineDiarizerModels.load(from: workspace.modelsURL)` in `TranscriptionPassRunner` compiles; adapt signature if needed

## 3. Test Validation

- [x] 3.1 Run full `ScribermanTests` suite — all existing tests must pass
- [x] 3.2 If any test asserts strict ordering of concurrent transcription output, fix the assertion to be order-independent
