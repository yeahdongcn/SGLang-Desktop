# Architecture

## Ownership boundary

SGLang Desktop is a product and lifecycle manager. It does not become a third
inference engine and does not vendor either engine's Python source tree.

| Component | Owns | Does not own |
|---|---|---|
| `sglang` | text/VLM models, scheduler, engine server, accelerator backends | desktop UI, installation, app updates |
| `sglang-omni` | ASR/TTS/omni pipelines, model implementations, service APIs | DMG, runtime rollback, model library UI |
| `SGLang-Desktop` | runtime/model lifecycle, launch supervision, diagnostics, desktop UX | model forward implementations, scheduling |

## Layers

```text
SwiftUI application
    ↓
Application model and feature coordinators
    ↓
RuntimeLibrary  ModelLibrary  Installer  UpdateService
    ↓                 ↓
Engine adapters   Model providers
    ↓
EngineProcessSupervisor + HealthProbe
    ↓
Immutable base runtime + versioned engine overlay
```

The core library contains domain contracts and platform services without UI.
The application target renders state and coordinates explicit user actions.

## Runtime principles

1. Every base and overlay generation is immutable after installation.
2. Installation occurs in `staging/`, including checksum and signature checks.
3. A verified runtime moves atomically into `runtimes/<id>/<version>/`.
4. Activation changes metadata only; it never rewrites the previous runtime.
5. Failed startup can restore the previously active runtime.
6. Engine state is determined from a validated process identity plus HTTP
   health, not solely from a successful `Process.run()` call. Non-secret
   session identity is persisted so a relaunched app can reconnect to a server
   that outlived its original UI process.
7. Environment variables are constructed explicitly and do not inherit user
   Python, uv, or Homebrew configuration accidentally.
8. The initial distribution ships outside the Mac App Store using Developer ID,
   hardened runtime, and notarization.
9. Pure-Python engine changes are delivered as overlays tied to a base lock;
   native/ABI changes create a new base generation.

## Why native Swift

The initial product only targets Apple Silicon Macs. SwiftUI/AppKit therefore
provides a smaller signed payload, native system integration, and fewer update
and sandbox boundaries than a cross-platform web shell. Runtime workloads stay
inside the managed Python/MLX/PyTorch sidecar, so UI technology has no effect on
model execution performance.

## Compatibility discipline

SGLang and SGLang-Omni dependencies are never resolved on the end-user machine.
Release CI produces a tested base from an explicit lock set and an engine
overlay tied to that base's compatibility identity. Desktop never combines
arbitrary overlays and bases. Local mode may run a contributor-managed checkout
or venv, but labels that profile as non-reproducible and never mutates it.

Health response bodies may differ between engines. Adapters treat a documented
2xx status as readiness and may optionally decode richer engine-specific data.
