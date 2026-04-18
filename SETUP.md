# Setup — iOS MVP (Gemma + Cactus)

A minimal SwiftUI app that runs Gemma on-device via the [Cactus](https://github.com/cactus-compute/cactus) Swift SDK. Ships with the prebuilt `cactus-ios.xcframework`; you only need to download the model weights locally (too large to check into git).

## Prerequisites

- macOS with **Xcode 15+**
- **python3.12** (`brew install python@3.12`)
- An iPhone simulator or a physical iPhone (iOS 15+)

## Steps

### 1. Clone this repo

```bash
git clone https://github.com/IshanBaliyan/voice-agents-hack.git
cd voice-agents-hack
```

### 2. Install the Cactus CLI (needed only to fetch model weights)

```bash
git clone https://github.com/cactus-compute/cactus
cd cactus && source ./setup && cd ..
```

`source ./setup` creates a Python venv and installs the `cactus` command. Any new terminal session needs `source ./cactus/setup` re-run from this directory before `cactus` is on PATH.

### 3. Download the model weights

```bash
cactus download google/functiongemma-270m-it
```

This pulls the pre-converted 267 MB model from `Cactus-Compute` on HuggingFace into `cactus/weights/functiongemma-270m-it/`.

### 4. Copy weights into the app bundle source

```bash
mkdir -p ios/Voice-AI-Copilot/Voice-AI-Copilot/Models
cp -R cactus/weights/functiongemma-270m-it ios/Voice-AI-Copilot/Voice-AI-Copilot/Models/
```

### 5. Open in Xcode and run

```bash
open ios/Voice-AI-Copilot/Voice-AI-Copilot.xcodeproj
```

Pick an iPhone simulator (or a plugged-in device) from the top scheme bar, then ⌘R. The app will load the model on first launch (a few seconds), then you can type a prompt and stream tokens back from Gemma.

## Swapping to Gemma 4 E2B (for the real hackathon demo)

The 270M model is fine for verifying the pipeline. The hackathon target is `google/gemma-4-E2B-it` (~6.3 GB). That's too large to bundle in the `.ipa` — plan to download it at first launch into `FileManager.default.urls(for: .cachesDirectory, …)` and point `cactusInit` at that path.

```bash
cactus download google/gemma-4-E2B-it
```

## Troubleshooting

- **"no library for this platform was found" at build time** — the target is trying to build for macOS. Remove Mac/Mac Catalyst/Vision from Target → General → Supported Destinations.
- **"Unable to find module dependency: 'cactus'"** — `cactus-ios.xcframework/{ios-arm64,ios-arm64-simulator}/cactus.framework/Modules/module.modulemap` is missing. Copy it from `cactus/apple/module.modulemap` into each slice's `Modules/` directory.
- **"Model weights not found in app bundle"** — step 4 above wasn't run, or the weights didn't get copied into Xcode's build products. Clean build folder (⇧⌘K) and rebuild.
