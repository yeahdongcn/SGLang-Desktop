# Managed runtime contract

A managed runtime is either a self-contained relocatable directory or a
validated composition of a base runtime and an engine overlay. It must not
depend on system Python, Homebrew, or a mutable global package installation.

## Required layout

```text
runtime-root/
├── runtime.json
├── bin/
│   └── engine entrypoint
├── lib/                     Python and native libraries
├── share/                   runtime-owned data
├── THIRD_PARTY_NOTICES.md
└── licenses/
```

For a layered generation, the base owns CPython, locked packages, and native
libraries while the overlay owns engine code and its relative entrypoint. Both
have manifests and hashes. Desktop only composes them when `baseRuntimeID` and
`compatibilityID` match exactly.

## Manifest fields

- `schemaVersion`: currently `1`
- `id`: stable runtime channel identifier
- `displayName`: user-facing name
- `engine`: `sglang` or `sglang-omni`
- `version`: immutable artifact version
- `platform`: must be `macos`
- `architecture`: must be `arm64`
- `minimumMacOSVersion`: deployment floor
- `channel`: `stable`, `preview`, `nightly`, or `local`
- `distribution`: prebuilt artifact, source checkout, or local virtualenv
- `artifactKind`: complete runtime, reusable base, or engine overlay
- `baseRuntimeID` and `compatibilityID`: required for an engine overlay
- `containsNativeCode`: drives signing and promotion policy
- `entrypoint`: safe relative executable path inside the runtime
- `defaultArguments`: arguments controlled by the runtime publisher
- `capabilities`: feature identifiers used by the UI and launch adapter
- `components`: exact engine and runtime component versions or commits
- `downloadURL`: optional source for a remote archive
- `archiveSizeBytes`: optional download size
- `sha256`: required for downloaded runtime archives

## Launch contract

Desktop supplies model, port, and explicit runtime settings to the engine
adapter. The adapter produces an `EngineLaunchConfiguration` containing:

- executable URL
- working directory
- ordered arguments
- sanitized environment
- selected localhost port
- health endpoint

For SGLang-Omni, Desktop will request strict port ownership rather than accept
silent port reassignment. Readiness is based on the configured health URL and a
2xx HTTP status. Response body shape is adapter-specific.

## Publication contract

Runtime release CI must:

1. build on the minimum supported Apple Silicon macOS target
2. install a fully locked dependency set
3. rewrite native library search paths to layer-relative locations
4. run engine import, launch, API, shutdown, and model smoke tests
5. generate third-party notices and licenses
6. sign nested code in the correct order
7. archive the runtime reproducibly
8. publish size and SHA-256 in a signed release manifest

Desktop never runs `pip install`, compiles SGLang, or invokes Homebrew on an end
user machine.
