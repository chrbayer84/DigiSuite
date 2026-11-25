# DigiSuite iOS Radio Modem App — Implementation Plan

## Purpose

Repurpose the current iOS application project as a radio modem app. The existing DigiSuite code is a skeleton only: its ON4KST chat, push notifications, and backend integration are not product requirements. The project currently targets iOS 17 and uses Swift 5 with a UIKit entry point hosting SwiftUI views.

The first modem is Robot 36 SSTV. The architecture must support future picture and text modems, including FT8 and RTTY, without tying audio capture, the waterfall, transmit output, history, or navigation to SSTV.

## Product shape

### Main tabs

- **Receive** — Choose a mode and view its live output alongside the shared audio waterfall.
- **Transmit** — Prepare a mode-specific payload and send its encoded audio through the selected iOS output route.
- **History** — Browse locally saved decoded text/chat and received pictures.
- **Settings** — Configure audio routes, mode defaults, and local storage preferences.

“Chat history” means locally decoded text messages, not the existing ON4KST online chat.

### Adaptive receive layout

- Stack decoded output and waterfall panes on iPhone.
- Place the panes side by side on iPad or wider screens.
- Use a mode-provided output view: progressive image display for SSTV, decoded-message rows for text modes, or a future mode-specific view.
- Keep shared receive status, mode selection, and start/stop/clear actions outside the mode-specific view.

## Architecture

Organize the app into distinct layers. Modems expose typed interfaces to the rest of the app; mode-specific synchronization and decoding remain inside the modem.

### App and navigation

Own application startup, root navigation, tabs, and dependency construction. Replace the current chat-oriented root UI and disconnect obsolete DigiSuite runtime logic. Retain only project infrastructure that fits the new app.

### Mode registry and domain types

Define mode descriptors and capabilities, including:

- Stable mode identifier and display name
- Receive and transmit support
- Expected audio input characteristics
- Decoded output kind, such as text or image
- Mode-specific configuration and payload types

Define shared types for audio chunks, decoder status, decoded events, received text, received pictures, and transmit requests.

### Audio services

- Configure `AVAudioSession` and `AVAudioEngine` for microphone capture.
- Handle microphone permission, route changes, interruptions, and input format changes.
- Provide sample buffering and sample-rate conversion.
- Provide output playback for generated transmit audio.
- Keep real-time audio callbacks lightweight; hand samples to processing outside the callback.
- Put radio PTT behind a separate interface so output playback and radio keying can evolve independently.

### Shared DSP

Provide reusable signal-processing utilities where applicable:

- Audio ring buffers and chunking
- Sample-rate conversion
- Spectrum analysis for the waterfall
- Shared filtering or frequency translation where useful

Do not force all modes into the same demodulation algorithm. Each modem owns its protocol-specific synchronization, symbol/line recovery, and decoding.

### Receive modem interface

Each receive modem should:

- Accept sequential audio chunks and configuration.
- Reset on mode changes, input restarts, route changes, or explicit clear.
- Emit typed events for status, decoded output, progress, and completion.
- Expose metadata needed by shared UI and persistence without exposing implementation details.

Implement `Robot36Decoder` first. Future examples:

- **FT8** — Own time-slot alignment, synchronization, and message decoding.
- **RTTY** — Own tone/baud configuration, symbol timing, framing, and text decoding.

### Transmit modem interface

Each transmit modem accepts a mode-specific payload and produces audio for a shared output service. Include progress and completion/failure reporting.

Initial examples:

- **Robot 36 SSTV** — Image payload to Robot 36 audio.
- **FT8** — Structured message payload to scheduled audio.
- **RTTY** — Text payload to configured FSK audio.

Initial transmit scope is audio generation/playback through the selected iOS output route. Actual PTT behavior is undecided and must remain behind an adapter/interface.

### Waterfall

Implement a shared waterfall driven by audio spectrum rows:

- Use Accelerate/vDSP for windowed FFT processing.
- Map spectrum levels through a palette, following the GridTracker2 reference’s frequency-horizontal, time-vertical presentation and scrolling concepts.
- Keep newest rows visible and support resize/layout changes without coupling waterfall state to a modem decoder.
- Initially emphasize the SSTV audio band and its characteristic sync/picture tones. Future mode descriptors can provide useful frequency-range or marker metadata.

### Decoded output views

Select the live output renderer by decoded output kind:

- **Picture** — Progressive image, mode, progress, and completion state.
- **Text** — Decoded-message/chat timeline with timestamp, mode, and available signal metadata.
- Future output kinds add renderers without changing audio capture or navigation.

### Persistence and history

- Persist decoded text/chat and picture metadata locally.
- Store received picture data as files and reference those files from persistent records.
- Provide mode/date filtering and a detail view.
- Keep persistence behind a repository interface so UI and modems do not depend on a specific database implementation.
- Initial scope is on-device storage without account or cloud synchronization.

## Robot 36 implementation

Implement receive and transmit from the published Robot 36 specification, guided by the local GridTracker2 implementation. Before any algorithm work, follow the required research workflow in `AGENTS.md`.

### Receive

- Detect VIS code 8 and report mode acquisition.
- Estimate signal frequency offset and track it during reception.
- Recover line timing from sync pulses.
- Decode 240 lines at the Robot 36 line period.
- Recover luminance and alternating chroma channels, using separator tones to determine chroma order.
- Emit image updates progressively and report completion or interrupted reception.
- Keep signal processing and image conversion outside the SwiftUI rendering path.

### Transmit

- Accept an image payload and prepare it at Robot 36 dimensions.
- Encode VIS and line data into phase-continuous audio with appropriate timing and ramps.
- Send audio through the shared output service and report progress.
- Do not implement radio PTT until its scope and control method are decided.

## UI behavior

### Receive tab

- Mode selector and input/audio status
- Start, stop, and clear actions
- Adaptive output and waterfall panes
- Live decoder state, such as listening, synchronizing, receiving, complete, or error

### Transmit tab

- Mode-specific payload composer
- Preview where applicable
- Output-route/status information
- Send, stop, and progress controls
- Make receive/transmit audio-route conflicts explicit in state and behavior

### History tab

- Local decoded-text/chat and received-picture history
- Search/filter by mode and date
- Detail view for a selected message or picture

### Settings tab

- Input and output route preferences
- Mode-specific configuration
- History/storage preferences

## Project migration

- Replace the current root screen and active DigiSuite application logic with the new radio-app shell.
- Add a microphone usage description to `DigiSuite/Info.plist`.
- Disconnect/remove obsolete chat, push-notification, and backend logic when it is no longer referenced by the new app.
- Keep the deployment target at iOS 17 unless implementation findings require a change.
- The Xcode project currently uses explicit source-file references. Add new Swift files to the correct groups and the application target in `DigiSuite.xcodeproj/project.pbxproj`.
- Product display name: DigiSuite. Bundle identifier: `com.github.chrbayer84.DigiSuite`. Preserve signing team and distribution identity; a matching provisioning profile is required for signed distribution builds.

## Suggested implementation phases

1. **Project replacement**
   - Establish the new app entry and tab navigation.
   - Replace the old app runtime path without carrying forward chat/backend behavior.
   - Add microphone permission messaging and an adaptive receive layout.

2. **Audio capture and waterfall**
   - Implement audio session setup, capture, route/interruption handling, buffering, and resampling.
   - Implement spectrum analysis and a scrolling waterfall independently of any modem.

3. **Robot 36 receive**
   - Define the receive modem interface and typed decoder events.
   - Implement Robot 36 VIS detection, timing recovery, line decoding, color reconstruction, and progressive updates.
   - Connect decoder events to the live image pane.

4. **History**
   - Add local persistence for received pictures and decoded-text records.
   - Implement history browsing and detail views.

5. **Transmit foundation and Robot 36 TX**
   - Define transmit payload/audio interfaces and output playback service.
   - Implement the Robot 36 image composer and encoder.
   - Keep PTT behind its adapter until its scope is decided.

6. **Prepare future modem additions**
   - Document how to register a modem, add its decoder/encoder, and provide its output view.
   - Confirm FT8 and RTTY can add their own synchronization and protocol logic without changes to shared audio/UI contracts.

## Verification

- Build the app for its supported iOS target.
- Verify microphone permission, audio route changes, interruptions, and capture start/stop.
- Test waterfall spectrum placement, level-to-color mapping, scrolling, and resizing.
- Use deterministic Robot 36 audio fixtures to verify VIS detection, 320×240 output, line timing, chroma ordering, and progressive rendering.
- Test interrupted/noisy reception as well as clean synthetic signals.
- Verify Robot 36 transmit audio by decoding it through the receive path or a suitable reference fixture.
- Verify history persistence across app restarts and display of saved pictures and decoded text.

## Local reference projects

### GridTracker2

- `gridtracker2/src/renderer/lib/mmd/sstvWorker.js` — SSTV receive processing, including Robot 36.
- `gridtracker2/src/renderer/lib/mmd/mmdSstv.js` — SSTV mode registration and event-to-view integration.
- `gridtracker2/src/renderer/lib/mmd/sstvEncoder.js` — SSTV tone generation and audio rendering.
- `gridtracker2/src/renderer/lib/mmd/mmdSstvTx.js` — SSTV transmit workflow and output handling.
- `gridtracker2/src/renderer/lib/mmd/mmDecoder.js` — Waterfall palette, row coloring, and scrolling.
- `gridtracker2/src/renderer/lib/mmd/mmdFallView.js` — Waterfall level styles and palette options.
- `gridtracker2/tools/test_signals/sstv.js` — Generated Robot 36 test-signal specification and fixture generator.
- `gridtracker2/docs/Multi-Mode-Decoder/Decoder-Modes.md` — SSTV receive/transmit behavior reference.

GridTracker2’s SSTV worker documents its implementation as based on published mode specifications. GridTracker2 is BSD-3-Clause licensed; preserve applicable copyright, conditions, and disclaimer if code is adapted.

### WSJT-X (`ws-3.3.0`)

The local WSJT-X tree is `ws-3.3.0/src/ws/`. Search its decoder, modulator, audio, plotter, and palette code for future modem/DSP/waterfall work. `src/ws/widgets/plotter.cpp` contains general waterfall drawing and scrolling references. No SSTV modem implementation was found in the inspected source. Check the relevant source-file and repository license before adapting code.

## Decisions to confirm when relevant

- **Transmit/PTT:** Initial transmit is encoded audio playback; radio PTT mechanism is unspecified.
- **Audio routes:** Prefer active iOS-selected input/output routes initially; ask before committing to an in-app route picker or limiting supported device types.
- **Background reception:** Foreground-only initially; ask before implementing background decoding.
- **History sync:** Local on-device history initially; no account/cloud sync is specified.
- **Product identity:** DigiSuite display name and `com.github.chrbayer84.DigiSuite` bundle ID are selected; signing team and distribution identity remain unchanged.
