# Product roadmap

This roadmap turns the selected Comfy Desktop product ideas into Apple-native,
SGLang-specific feature slices. It is ordered by dependency, not by marketing
priority.

## Foundation — present in the repository

- native navigation and product shell
- Apple Silicon/macOS gate
- runtime manifest and local installation registry
- base-runtime and engine-overlay compatibility identities
- model metadata registry
- sidecar process and log supervision
- readiness probing and SHA-256 support

## Runtime installation

- resumable runtime archive download
- signed release-index verification
- staging, archive traversal protection, and checksum verification
- atomic activation and uninstall-to-Trash
- engine adapters for SGLang and SGLang-Omni
- runtime environment sanitization and bundled FFmpeg resolution
- stable/preview/nightly catalog channels plus local-checkout adoption
- pure-Python engine overlays tied to an immutable base compatibility lock

## Multiple installations and rollback

- create independent named installations
- stable/preview/custom channels
- snapshots of configuration and extension metadata
- immutable runtime switch and automatic startup rollback
- adopt the current local Apple Silicon checkout/runtime

## Model library

- Hugging Face authentication in Keychain
- model catalog and hardware-memory guidance
- resumable downloads with revision pinning
- content integrity and disk-space preflight
- shared model directory across installations
- relocate/import/remove model data safely

## Daily operation

- configure and launch local servers
- visible startup phases and actionable errors
- copy endpoint/API examples
- simple Chat, VLM, ASR, and TTS playgrounds
- menu-bar status and explicit start-at-login option
- diagnostics bundle with secret redaction

## Distribution

- generated Xcode application project and app assets
- hardened runtime and nested code signing
- Developer ID notarization and stapled DMG
- application update feed with rollback-safe update behavior
- release CI on a physical Apple Silicon runner

## Explicit non-goals for the initial product

- Windows or Linux
- Intel macOS
- iPhone or iPad
- Mac App Store sandboxing
- arbitrary Python plugins or mutation of a managed runtime
- pretending arbitrary `sglang` and `sglang-omni` revisions are compatible
