# Repository Agent Instructions

## Product direction

The iOS application in `DigiSuite/` is a radio modem app. Treat existing DigiSuite code as a project skeleton only. Its ON4KST chat, push notifications, and backend integration are not product requirements unless the user explicitly brings them back into scope.

Use `IOS_MODEM_IMPLEMENTATION_PLAN.md` as the implementation roadmap. The first modem is Robot 36 SSTV. Keep the app architecture extensible for additional receive/transmit modems, including text modes such as FT8 and RTTY, and for shared waterfall, transmit, and local history features.

## Required algorithm research workflow

Before implementing or changing a modem, decoder, encoder, DSP, synchronization, audio-processing, or waterfall algorithm:

1. Search the local reference trees for the closest existing implementation and its tests, fixtures, and documentation:
   - `gridtracker2/` — especially `src/renderer/lib/mmd/`, `src/wasm/`, `plugins/mmd/`, `tools/test_signals/`, and `docs/Multi-Mode-Decoder/`.
   - `ws-3.3.0/src/ws/` — the local WSJT-X source tree, including decoder, modulator, audio, plotter, and palette code.
2. Read the relevant implementation end to end far enough to understand its algorithm, assumptions, sample rate, timing, state, and failure handling. Do not rely on a filename or a superficial search match alone.
3. Port the closest applicable behavior to Swift/iOS and the app's module boundaries. Preserve the reference algorithm's important signal-processing behavior while adapting memory management, threading, real-time audio constraints, and UI integration to iOS.
4. Verify the port with relevant local fixtures/tests where practical. Add or adapt deterministic tests for the Swift implementation rather than relying only on visual inspection.

If the requested behavior materially differs from the available decoders, DSP algorithms, or waterfall techniques, do not silently invent or substitute an algorithm. Report what the local references implement, explain the mismatch and practical choices, and ask the user which direction to take before making that algorithmic change. If no close local reference exists, report that finding and ask before designing a new core algorithm.

This workflow applies to algorithmic changes; ordinary UI, navigation, persistence, and project-configuration work can proceed using established app conventions without an unrelated reference-code search.

## Reference code and attribution

- Treat `gridtracker2/` and `ws-3.3.0/` as references, not as locations to modify for this iOS application unless the user explicitly requests changes there.
- Prefer an independently structured Swift port over copying whole files or implementation-specific scaffolding.
- Preserve applicable license and copyright notices when adapting or translating code. Check the source file and its repository license before carrying code into the app. GridTracker2 is BSD-3-Clause; the WSJT-X tree has its own licensing requirements.
- Distinguish a port of source code from an implementation guided by a published protocol specification; document the basis and attribution accurately.

## Repository and project practices

- Keep changes focused and consistent with the surrounding Swift and Xcode project structure.
- The Xcode project currently uses explicit source-file references. When adding Swift files, ensure they are included in the application target and organized consistently in `DigiSuite.xcodeproj/project.pbxproj`.
- Do not overwrite or remove existing user work, including untracked files or reference repositories.
- Do not commit, amend, push, or create a pull request unless explicitly asked.
- Run the most relevant build or tests available for each implementation change and report any environment limitations.

## Product defaults and open decisions

Use these initial assumptions only for reversible scaffolding. Ask the user before making a consequential choice that is not settled by their request:

- Initial transmit support generates and plays modem audio through an iOS output route; actual radio PTT integration is not yet specified.
- Initial history is stored locally on-device without account or cloud synchronization.
- Initial reception is foreground-only unless the user requests background operation.
- Prefer the active iOS input/output route initially; ask before committing to an in-app route picker or a narrower device-support policy.
- Product display name: DigiSuite. Bundle identifier: `com.github.chrbayer84.DigiSuite`.
- The signing team and distribution identity remain user-owned. Ask before changing them or making other signing changes.
