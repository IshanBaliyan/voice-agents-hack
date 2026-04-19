# Setup — iOS MVP (Gemma 4 E4B + Cactus)

A SwiftUI app that runs **Gemma 4 E4B** fully on-device via the [Cactus](https://github.com/cactus-compute/cactus) Swift SDK. Text input, voice input (raw PCM fed straight into Gemma's audio encoder — no intermediate STT), optional camera capture for multimodal queries, and streaming TTS output on the response.

Ships with the prebuilt `cactus-ios.xcframework`; you only need to download the ~8 GB model weights locally (too large for git).

## Prerequisites

- macOS with **Xcode 16+**
- **python3.12** (`brew install python@3.12`)
- A physical iPhone with **8 GB RAM or more** (iPhone 15 Pro / 16 / 16 Pro / 17). The model's working set is ~4.5 GB — 6 GB phones will OOM even with the increased-memory-limit entitlement.
- ~12 GB free disk on Mac, ~8 GB on the phone
- Apple Developer team configured in Xcode for signing

## Steps

### 1. Clone this repo

```bash
git clone https://github.com/IshanBaliyan/voice-agents-hack.git
cd voice-agents-hack
```

### 2. Install the Cactus CLI (only needed to fetch model weights)

```bash
git clone https://github.com/cactus-compute/cactus
cd cactus && source ./setup && cd ..
```

`source ./setup` creates a Python venv and installs the `cactus` command. Any new terminal session needs `source ./cactus/setup` re-run from this directory before `cactus` is on PATH.

### 3. Download the model weights

```bash
cactus download google/gemma-4-E4B-it --reconvert
```

Pulls the pre-quantized E4B bundle (~8 GB, int4-apple) into `cactus/weights/gemma-4-e4b-it/`. This includes `audio_encoder.mlpackage` and `vision_encoder.mlpackage` for the Neural Engine path.

### 4. Copy weights into the app bundle source

```bash
mkdir -p ios/Voice-AI-Copilot/Voice-AI-Copilot/Models
cp -R cactus/weights/gemma-4-e4b-it ios/Voice-AI-Copilot/Voice-AI-Copilot/Models/
```

The `Models/` folder is gitignored; each contributor needs to do this locally.

### 5. Open in Xcode and run on a physical iPhone

```bash
open ios/Voice-AI-Copilot/Voice-AI-Copilot.xcodeproj
```

Plug in your iPhone, select it in the scheme bar, ⌘R. First install copies ~8 GB over USB so expect a slow first deploy; subsequent builds are incremental. First model load on-device takes ~10–20 s.

You'll be prompted for **microphone** and **camera** permissions the first time you use those features. Both are declared in the target's Info (managed through `INFOPLIST_KEY_*` build settings in the pbxproj).

## Why the memory entitlement matters

E4B's working set (~4.5 GB) exceeds the default iOS per-app memory budget (~3 GB on 6 GB phones, ~4 GB on 8 GB phones). Without the entitlement, iOS Jetsam denies the allocation up front and the model crashes instantly with `std::bad_alloc` at completion time (process memory never climbs past ~500 MB).

The fix is already checked in: `Voice-AI-Copilot/Voice-AI-Copilot.entitlements` declares

- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`

and both Debug and Release configs set `CODE_SIGN_ENTITLEMENTS` to that file. If you clone and rebuild, this should "just work" — nothing extra to do.

## Running on the Simulator

The Simulator works for the text pipeline but is ~10× slower than on-device because there's no Neural Engine. Voice input may have audio-session quirks on Simulator — the real validation target is a physical device.

## Troubleshooting

- **`std::bad_alloc` / "Completion failed" instantly, app sits at ~500 MB RAM** — the entitlement isn't being applied. Confirm `CODE_SIGN_ENTITLEMENTS = Voice-AI-Copilot/Voice-AI-Copilot.entitlements` is set in both Debug and Release (`grep CODE_SIGN_ENTITLEMENTS ios/Voice-AI-Copilot/Voice-AI-Copilot.xcodeproj/project.pbxproj` should show two hits). Clean build folder (⇧⌘K) and rebuild. On a 6 GB phone this can't be fixed — upgrade to an 8 GB device or switch the model path in `CactusEngine.swift` to `gemma-4-e2b-it`.
- **"Model weights not found in app bundle"** — step 4 above wasn't run, or Xcode didn't copy the `Models/` folder into the `.app`. The `CactusEngine` load-phase logs enumerate every candidate path that was checked; filter Console for `CactusEngine` to see them.
- **`EXC_BAD_ACCESS` while recording** — `AVCaptureSession` is racing the audio session. `CameraCapture.configureIfNeeded()` sets `automaticallyConfiguresApplicationAudioSession = false`; if you've modified camera setup, make sure that line is still there.
- **TTS silent after a recording** — `AudioRecorder.stop()` deliberately does *not* call `setActive(false)` on the audio session because `AVSpeechSynthesizer` needs it active to play. Don't add a deactivate call.
- **"no library for this platform was found" at build time** — target is trying to build for macOS. Remove Mac/Mac Catalyst/Vision from Target → General → Supported Destinations.
- **"Unable to find module dependency: 'cactus'"** — `cactus-ios.xcframework/{ios-arm64,ios-arm64-simulator}/cactus.framework/Modules/module.modulemap` is missing. Copy it from `cactus/apple/module.modulemap` into each slice's `Modules/` directory.

## Diagnostics

`CactusEngine.swift` emits stage-by-stage `os.Logger` events under subsystem `voice-ai-copilot`, category `CactusEngine`. In Xcode's Console (or Console.app with the device attached), filter for `CactusEngine` to see:

- `load.stage1.resolve` — which weights path was found
- `load.stage2.inventory` — file counts, total GB, mlpackage/mlmodelc list
- `load.stage3.memory` / `load.stage4.init` — available memory + `cactus_init` timing + Δfootprint
- `complete.stage3.pre` / `complete.stage4.done` — generation timing including `ttft` (time-to-first-token) and total tokens
- On failure, whether it died in `PREFILL` or `GENERATION` plus the raw `cactusGetLastError` string
