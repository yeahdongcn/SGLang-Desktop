# Apple Silicon runtime builder

SGLang Desktop never resolves or installs Python packages on an end-user Mac.
The release pipeline builds a relocatable runtime archive ahead of time and the
Desktop app only downloads, verifies, extracts, and launches it.

The layout intentionally improves on the pattern validated in Comfy Desktop:

```text
sglang-omni-<version>-macos-arm64/
├── runtime.json
├── bin/
│   ├── sgl-omni
│   └── runtime-doctor
├── python/                 pinned python-build-standalone CPython
├── packages/               preinstalled PyTorch, MLX, SGLang, and Omni
├── ffmpeg/                 relocatable FFmpeg 7 shared libraries
├── metadata/
│   ├── packages.txt
│   └── build-provenance.json
└── licenses/
```

Unlike a conventional virtual environment, the entrypoint contains no build
machine path. It locates CPython and packages relative to its own directory.
The package layer is supplied through a sanitized `PYTHONPATH`; user site
packages are disabled. This removes the `pyvenv.cfg` and console-script
shebang relocation problem entirely.

## Build

The builder currently consumes committed local checkouts so it can package the
Apple Silicon work before those commits are available as wheels:

```bash
SGLANG_SOURCE_DIR="$HOME/.cache/sglang-omni/sglang-v0.5.16" \
SGLANG_OMNI_SOURCE_DIR="../sglang-omni" \
./scripts/build-omni-runtime.sh
```

Both checkouts must be clean. The build records their exact commits, downloads
a pinned CPython archive with a pinned SHA-256, builds a minimal relocatable
FFmpeg 7, installs the engine projects non-editably, and runs import/CLI/Metal
checks before creating the archive.

The final mandatory release step is a second extraction to a different path:

```bash
./scripts/verify-runtime-relocation.sh \
  artifacts/runtimes/sglang-omni-*-macos-arm64.tar.gz
```

Release promotion will additionally consume a hash-locked wheelhouse and emit
an SBOM and complete third-party notices. The current builder emits an exact
installed-package inventory and provenance, but must not be treated as a
reproducible public release until that lock-and-license gate is implemented.

The builder is not restricted to source tags. `SGLANG_SOURCE_DIR` and
`SGLANG_OMNI_SOURCE_DIR` may point at any clean commit, and
`SGLANG_RUNTIME_CHANNEL=nightly` labels the resulting artifact accordingly.
Nightly builds are an opt-in testing channel; local contributors can instead
register an existing virtualenv without building an archive at all. See
[`../docs/distribution-channels.md`](../docs/distribution-channels.md).

For pure-Python engine changes, use `scripts/build-engine-overlay.sh` with a
published base generation and compatibility ID. It builds wheels with
without resolving runtime dependencies, so a nightly overlay cannot silently alter Torch, MLX, FFmpeg, or
any other native dependency. The Desktop materializer will eventually unpack
those wheels into a copy-on-write overlay and launch the base interpreter with
the overlay packages first on `PYTHONPATH`.
