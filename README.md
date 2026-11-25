# DigiSuite

## iOS Radio Modem App

This iOS app is being built from the DigiSuite project skeleton. The old ON4KST chat, notification, and backend features are out of scope. The first modem is Robot 36 SSTV; the app architecture is intended to support additional picture and text modes such as FT8 and RTTY.

## Current implementation

- **Receive:** microphone capture, 12 kHz conversion, Robot 36 VIS detection and picture reconstruction, and a live audio waterfall.
- **Transmit:** Robot 36 image selection, audio encoding, and playback through the active iOS output route. Radio PTT is not implemented.
- **History:** on-device persistence for received pictures and a model for future decoded text.
- **Settings:** current input route and initial modem/storage information.

FT8 and RTTY are architectural placeholders; their decoders and transmitters are not implemented yet. Initial reception is foreground-only. Audio route selection follows the active iOS route.

## Project layout

- `DigiSuite/Models/RadioModemModels.swift` — shared mode, audio, event, picture, and history types.
- `DigiSuite/Services/RadioAudioService.swift` — microphone capture, sample-rate conversion, and audio playback.
- `DigiSuite/Services/RadioReceivePipeline.swift` — serialized receive/DSP boundary.
- `DigiSuite/Services/Robot36Decoder.swift` — Robot 36 receive implementation.
- `DigiSuite/Services/Robot36Encoder.swift` — Robot 36 audio encoder.
- `DigiSuite/Services/SpectrumAnalyzer.swift` — shared waterfall spectrum and palette mapping.
- `DigiSuite/Services/RadioHistoryStore.swift` — local picture/text history storage.
- `DigiSuite/Views/RadioModemRootView.swift` — Receive, Transmit, History, and Settings tabs.
- `IOS_MODEM_IMPLEMENTATION_PLAN.md` — implementation roadmap and reference notes.
- `AGENTS.md` — repository workflow, including required local algorithm research.

## Build and test

Open `DigiSuite.xcodeproj` in Xcode, select the shared `DigiSuite` scheme and an iOS Simulator or device, then build and run. The scheme includes deterministic modem tests; run them with **Product → Test**.

The app requires iOS 17 or later. Microphone access is requested when receiving starts. A headset or audio interface can be selected through iOS before reception.

## Signal-processing references

The local `gridtracker2/` and `ws-3.3.0/` trees are read-only references for modem, DSP, audio, and waterfall work. See `AGENTS.md` for the research, porting, attribution, and verification requirements.

## Privacy

Audio capture, decoding, transmit audio generation, selected images, and history are processed or stored on-device. See [`PRIVACY.md`](PRIVACY.md) for details.

## License

GPL v3. Check reference-project licenses before adapting their implementation into this app.
