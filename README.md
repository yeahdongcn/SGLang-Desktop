# SGLang Desktop

SGLang Desktop is a native macOS application for installing, running, and
managing local SGLang runtimes and models on Apple Silicon.

The project is intentionally independent from `sglang` and `sglang-omni`.
Those repositories own inference, scheduling, model implementations, and the
server APIs. This repository owns the desktop product lifecycle: runtime
installation, updates, rollback, model storage, process supervision,
diagnostics, signing, and distribution.

## Scope

The initial target is deliberately narrow:

- Apple Silicon (`arm64`) Macs only
- macOS 14 or newer
- native SwiftUI/AppKit application
- managed SGLang and SGLang-Omni sidecar runtimes
- PyTorch MPS and MLX execution supplied by those runtimes
- Developer ID signed and notarized distribution outside the Mac App Store

Cross-platform UI frameworks, Intel Macs, iOS/iPadOS, and arbitrary user-managed
Python environments are not part of the initial architecture.

## Product direction

The product model follows the strongest ideas from Comfy Desktop while using a
native, Apple-only implementation:

- multiple independent installations
- isolated, relocatable runtime payloads
- one-click, versioned updates
- snapshots and rollback
- adoption of a compatible existing installation
- shared model storage and model downloads
- built-in application updates
- health checks, structured diagnostics, and engine logs

The application itself, engine runtimes, and model weights are separate assets:

```text
SGLang Desktop.app
    └── native UI and runtime manager

~/Library/Application Support/SGLang Desktop/
    ├── runtimes/       versioned, immutable engine payloads
    ├── staging/        verified installation staging
    ├── models/         shared model weights
    ├── state/          installation and model metadata
    └── logs/           application and engine logs
```

Users should never need to install Homebrew, Python, uv, PyTorch, MLX, SGLang,
or FFmpeg themselves. Runtime artifacts will carry a manifest, cryptographic
checksum, and every native executable or library required to run.

## Current foundation

This initial repository includes:

- a native SwiftUI application shell with Dashboard, Installations, Models,
  Logs, and Settings
- Apple Silicon/macOS compatibility detection
- actionable Mac/runtime/model/port diagnostics
- per-model Advanced launch settings with effective-command preview
- OpenAI API handoff to local clients such as AnythingLLM
- a versioned runtime manifest schema
- persistent runtime and model registries
- safe managed-runtime adoption plus arbitrary local `sglang`/`sgl-omni` CLI adoption
- streaming SHA-256 verification
- staged archive validation and atomic runtime installation
- compatible base-runtime and engine-overlay composition
- sidecar process supervision with durable, restart-safe stdout/stderr logs
- persistent engine sessions with safe reconnect after an app relaunch
- HTTP readiness probing
- Swift Testing coverage for the core storage and validation contracts

The runtime downloader, transactional installer, snapshot implementation,
engine-specific launch adapters, model downloader, and packaged `.app` release
pipeline remain intentionally visible roadmap work. The UI does not pretend
that these flows are complete yet.

## Build and test

Requirements:

- Apple Silicon Mac
- Xcode 16 or newer with the macOS SDK
- Swift 6

Build and launch the development executable:

```bash
swift build
swift run SGLangDesktop
```

Run the core test suite:

```bash
swift test
```

Swift Package Manager is the source of truth for the current foundation. An
Xcode application project, app icon/assets, hardened-runtime entitlements,
codesigning, notarization, DMG creation, and update feed will be added with the
release pipeline rather than committed as opaque generated files now.

## Runtime manifest

A managed runtime is a relocatable directory containing `runtime.json` and the
entrypoint named by that manifest. See
[`docs/runtime-contract.md`](docs/runtime-contract.md) and
[`docs/examples/sglang-omni-runtime.json`](docs/examples/sglang-omni-runtime.json).

During development, the Installations screen can adopt a local runtime by
selecting its `runtime.json`. Adoption validates the manifest and executable;
it does not mutate or copy the selected directory yet.

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for ownership boundaries and
[`docs/product-roadmap.md`](docs/product-roadmap.md) for the feature slices.
The distinction between release artifacts, nightlies, and local development is
described in [`docs/distribution-channels.md`](docs/distribution-channels.md).

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

This project studies Comfy Desktop as a product and architecture reference. It
does not copy Comfy Desktop source code or assets.
