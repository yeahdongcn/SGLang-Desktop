# Distribution channels

Prebuilt environments are a delivery mechanism, not a restriction on which
SGLang commit can be tested. A runtime can be built from any clean commit; the
question is whether that build is published for end users.

## Four channels

| Channel | Input | What Desktop installs | Intended audience |
|---|---|---|---|
| Stable | tagged SGLang/Omni commit | signed, hash-verified immutable runtime | normal users |
| Preview | selected release-candidate commit | signed runtime retained for compatibility testing | early adopters |
| Nightly | arbitrary CI commit on a schedule or manual dispatch | short-lived opt-in runtime; usually latest plus previous | maintainers and testers |
| Local | user's checkout and/or venv | no downloaded artifact; app supervises the local executable | contributors |

The word “release” here means a Desktop runtime artifact. It does not require
the source project to publish a PyPI or GitHub release for every commit.

## Artifact layers

Managed installations are composed from three independently versioned layers:

```text
Base Runtime                         built infrequently
  CPython + Torch + MLX + FFmpeg + locked native/Python dependencies
        +
Engine Overlay                       built per useful commit
  SGLang, or SGLang + SGLang-Omni code and entrypoint
        +
Model Store                          downloaded independently
  weights + tokenizer + model manifest
```

An overlay records the exact base generation and `compatibilityID` it requires.
Desktop refuses a composition when those identities differ. Pure-Python engine
changes therefore produce only a small overlay. Changing Torch, MLX, Python,
FFmpeg, a compiled extension, or the dependency lock creates a new base
generation.

This is intentionally stricter than installing a wheel into a live environment:
CI resolves dependencies once and Desktop never runs pip or uv for a managed
installation.

## Stable and preview

These channels follow the no-surprises promise:

1. CI checks out exact source commits.
2. It reuses or builds the hash-locked Apple arm64 base required by that commit.
3. It runs import, Metal, API, shutdown, and model smoke tests.
4. It emits an engine overlay, SHA-256, SBOM, and signed catalog entry.
5. Desktop downloads only artifacts compatible with the selected model.

The large base is produced only when its compatibility lock changes. Promotion
normally changes catalog metadata around an already-tested base-plus-overlay
pair; it does not rebuild PyTorch. Model and configuration updates do not force
a runtime build.

## Nightly without a daily distribution burden

Nightly should be a CI validation lane, not a promise to rebuild and mirror a
large public archive every day:

- cache the base runtime and wheelhouse on the arm64 runner;
- test arbitrary commits against the matching base compatibility identity;
- build/upload only the small engine overlay when a commit is useful to testers;
- rebuild the large base only when the dependency/native lock changes;
- retain the latest successful overlay and one known-good predecessor;
- garbage-collect unreferenced archives after a short retention period;
- promote a successful nightly artifact to Preview without rebuilding it.

The initial builder may still emit a self-contained complete archive as a
bootstrap and verification fixture. The catalog and domain model are layered
from the start so nightlies are not forced to use that expensive path.

## Local development mode

Contributors must not wait for CI to test a branch. Desktop will support a
`Local` installation record with:

- a checkout path;
- an existing virtualenv Python or console-script path;
- an explicit engine kind and source commit, when available;
- a warning that dependencies are user-managed;
- no automatic mutation, upgrade, or rollback by Desktop.

The app launches this executable with the same engine adapter and health probe
used for prebuilt runtimes. This keeps the UI and process lifecycle useful
while making the trust and reproducibility difference visible.

An optional “Build local runtime” action can invoke the repository builder for a
clean checkout. That action is for contributors and CI, not normal onboarding.

## Why not one shared environment?

The current Apple implementations have different dependency contracts. The
SGLang-Omni Apple path is tied to SGLang v0.5.16 and Torch 2.11, while current
SGLang MLX development follows a different Torch line. Desktop therefore keeps
separate immutable Core and Omni runtime bundles until their lock sets converge.
