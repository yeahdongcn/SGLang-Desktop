#!/usr/bin/env python3
"""Machine-readable health check for a packaged SGLang-Omni runtime."""

from __future__ import annotations

import importlib.metadata
import json
import platform
import sys
from pathlib import Path


def main() -> int:
    results: dict[str, object] = {
        "ok": True,
        "platform": {
            "system": platform.system(),
            "machine": platform.machine(),
            "macos": platform.mac_ver()[0],
            "python": platform.python_version(),
        },
        "components": {},
        "checks": {},
    }

    checks = results["checks"]
    assert isinstance(checks, dict)
    components = results["components"]
    assert isinstance(components, dict)

    checks["apple_silicon"] = (
        platform.system() == "Darwin" and platform.machine() == "arm64"
    )

    for distribution in (
        "torch",
        "torchvision",
        "torchaudio",
        "torchcodec",
        "mlx",
        "mlx-lm",
        "sglang",
        "sglang-omni",
    ):
        try:
            components[distribution] = importlib.metadata.version(distribution)
        except importlib.metadata.PackageNotFoundError:
            components[distribution] = None
            checks[f"distribution:{distribution}"] = False

    try:
        import torch

        checks["torch_mps_built"] = bool(torch.backends.mps.is_built())
        checks["torch_mps_available"] = bool(torch.backends.mps.is_available())
    except Exception as error:  # noqa: BLE001 - doctor must report every failure
        checks["torch_import"] = False
        checks["torch_error"] = repr(error)

    try:
        import mlx.core as mx

        checks["mlx_metal_available"] = bool(mx.metal.is_available())
    except Exception as error:  # noqa: BLE001 - doctor must report every failure
        checks["mlx_import"] = False
        checks["mlx_error"] = repr(error)

    try:
        from torchcodec.decoders import AudioDecoder  # noqa: F401

        checks["torchcodec_ffmpeg"] = True
    except Exception as error:  # noqa: BLE001 - doctor must report every failure
        checks["torchcodec_ffmpeg"] = False
        checks["torchcodec_error"] = repr(error)

    runtime_root = Path(__file__).resolve().parent.parent
    checks["runtime_root"] = str(runtime_root)
    checks["relocatable_entrypoint"] = (runtime_root / "bin" / "sgl-omni").is_file()

    boolean_checks = [value for value in checks.values() if isinstance(value, bool)]
    results["ok"] = bool(boolean_checks) and all(boolean_checks)
    print(json.dumps(results, indent=2, sort_keys=True))
    return 0 if results["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
