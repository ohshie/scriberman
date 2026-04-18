## 1. Protocol and Infrastructure

- [x] 1.1 Define `MicCaptureControlling` protocol with `startCapture`, `stopCapture`, and `retargetDevice` methods
- [x] 1.2 Create `AVAudioEngineMicCaptureController: MicCaptureControlling` that owns `AVAudioEngine`, tap installation, and `AVAudioConverter` (48 kHz/mono/Float32 target format)
- [x] 1.3 Inject `AudioDeviceHardwareProviding` into `RecordingService.init` (default: `CoreAudioDeviceHardware()`), update all call sites

## 2. RecordingService State and Lifecycle Helpers

- [x] 2.1 Add actor-state properties: `desiredMicDeviceUID: String?`, `micFileURL: URL?`, `micTargetFormat: AVAudioFormat`, `isRecoveringMicCapture: Bool`
- [x] 2.2 Extract `startMicCapture(deviceUID: String?, micFileURL: URL, liveContinuation: ...)` helper — sets up controller, prepares `micStreamer`, stores `micFileURL`
- [x] 2.3 Extract `stopMicCapture()` helper — calls `micCaptureController.stopCapture()`, does NOT close `micStreamer` (only full stop closes it)
- [x] 2.4 Add `teardownEngineForRecovery()` — stops controller, removes tap, preserves `micStreamer` open
- [x] 2.5 Add `recoverMicCapture() async -> Bool` — calls `teardownEngineForRecovery()`, resolves `desiredMicDeviceUID` → `AudioDeviceID`, restarts via controller; returns success/failure
- [x] 2.6 Refactor `startRecording` to use new helpers; resolve `micDeviceID` → `desiredMicDeviceUID` via `hardware.deviceUID` at start

## 3. Config Change Handler

- [x] 3.1 Rewrite `handleAudioEngineConfigurationChange()`: guard on `isRecordingValue`, guard on `!isRecoveringMicCapture`, attempt `recoverMicCapture()`
- [x] 3.2 On recovery success: leave `isRecordingValue = true`, do not set `pendingError`
- [x] 3.3 On recovery failure: close `micStreamer`, call `cleanupRecordingState()`, set `isRecordingValue = false`, set `pendingError = .captureInterrupted`

## 4. CoreAudio Hardware Listeners

- [x] 4.1 Add `registerMicHardwareListeners()` in `RecordingService` — registers `AudioObjectPropertyListenerBlock` for `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultInputDevice` (same pattern as `AudioDeviceService`)
- [x] 4.2 Call `registerMicHardwareListeners()` at the end of `startRecording`; deregister in `stopRecording` and cleanup paths
- [x] 4.3 Implement `handleHardwareChange() async` — if `desiredMicDeviceUID` resolves to a device that differs from current capture target, call `recoverMicCapture()`

## 5. Manual Mid-Recording Retarget

- [x] 5.1 Add `retargetMic(desiredDeviceUID: String?) async` to `RecordingService` — guard on `isRecordingValue`, update `desiredMicDeviceUID`, call `recoverMicCapture()`
- [x] 5.2 Add `retargetMic(desiredDeviceUID:)` to `RecordingServiceProtocol`
- [x] 5.3 Wire `retargetMic` call from the ViewModel/coordinator when `AudioDeviceService.selectedDevice` changes during an active recording

## 6. Unit Tests (ScribermanTests)

- [ ] 6.1 Create `MockMicCaptureController: MicCaptureControlling` with controllable `startCapture` success/failure and a `stopCapture` call counter
- [ ] 6.2 Test: config change while recording with mock controller returning success → `isRecordingValue` remains true, `pendingError` nil
- [ ] 6.3 Test: config change while recording with mock controller throwing → `isRecordingValue` false, `pendingError == .captureInterrupted`
- [ ] 6.4 Test: config change while `audioEngine == nil` (recorder fallback) → handler is no-op, `pendingError` nil
- [ ] 6.5 Test: re-entrant config change during recovery is ignored (second call while `isRecoveringMicCapture == true`)
- [ ] 6.6 Test: `micStartHostTime` not overwritten on recovery — set to 1000, trigger recovery, call `captureMicStartHostTimeIfNeeded(2000)`, expect 1000
- [ ] 6.7 Test: UID resolution — mock hardware with two devices; `desiredMicDeviceUID` matches device B → recovery calls `startCapture` with device B's ID
- [ ] 6.8 Test: UID not found during recovery → `startCapture` called with `nil` (system default), `pendingError` not set
- [ ] 6.9 Test: `retargetMic` while not recording is a no-op
- [ ] 6.10 Test: `retargetMic` while recording updates `desiredMicDeviceUID` and triggers recovery via mock controller
