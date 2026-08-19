"""Prove that a built pycolmap wheel downloads its default ONNX models."""

from pathlib import Path

import pycolmap


def resolve(model_spec: str, expected_filename: str) -> Path:
    """Split a COLMAP resource URI and return its expected cache path."""
    parts = model_spec.split(";")
    assert len(parts) == 3, f"unexpected model URI: {model_spec!r}"
    url, filename, sha256 = parts
    assert url.startswith("https://"), f"no default download URL: {url!r}"
    assert filename == expected_filename, f"{filename!r} != {expected_filename!r}"
    assert len(sha256) == 64
    return Path.home() / ".cache" / "colmap" / f"{sha256}-{filename}"


def check(label: str, options, cache_paths: list[Path]) -> None:
    for cache_path in cache_paths:
        assert not cache_path.exists(), (
            f"{label} download test requires an empty cache, "
            f"but {cache_path} exists"
        )
    # Construction resolves the default URIs, downloads and verifies the models,
    # and opens them with ONNX Runtime. No model path is assigned anywhere here.
    extractor = pycolmap.FeatureExtractor.create(options, pycolmap.Device.cpu)
    assert extractor is not None
    for cache_path in cache_paths:
        assert cache_path.is_file(), f"{label} model was not cached at {cache_path}"
        assert cache_path.stat().st_size > 0
    print(f"{label} default-model download passed: {[str(p) for p in cache_paths]}")


aliked_options = pycolmap.FeatureExtractionOptions(
    pycolmap.FeatureExtractorType.ALIKED_N16ROT
)
check(
    "ALIKED",
    aliked_options,
    [resolve(aliked_options.aliked.n16rot_model_path, "aliked-n16rot.onnx")],
)

# LoMa-B pulls two files: the shared DaD detector and the fp32 descriptor. bf16
# is not requested here, so the bf16 descriptor is deliberately not fetched.
loma_options = pycolmap.FeatureExtractionOptions(pycolmap.FeatureExtractorType.LOMA_B)
loma_detector = loma_options.loma.detector_model_path
loma_descriptor = loma_options.loma.descriptor_model_path
check(
    "LoMa-B",
    loma_options,
    [
        resolve(loma_detector, loma_detector.split(";")[1]),
        resolve(loma_descriptor, loma_descriptor.split(";")[1]),
    ],
)
