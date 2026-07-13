"""Prove that a built pycolmap wheel downloads ALIKED's default model."""

from pathlib import Path

import pycolmap


options = pycolmap.FeatureExtractionOptions(
    pycolmap.FeatureExtractorType.ALIKED_N16ROT
)
model_spec = options.aliked.n16rot_model_path
parts = model_spec.split(";")
assert len(parts) == 3, f"unexpected ALIKED model URI: {model_spec!r}"
url, filename, sha256 = parts
assert url.startswith("https://"), f"ALIKED has no default download URL: {url!r}"
assert filename == "aliked-n16rot.onnx"
assert len(sha256) == 64

cache_path = Path.home() / ".cache" / "colmap" / f"{sha256}-{filename}"
assert not cache_path.exists(), (
    f"ALIKED download test requires an empty cache, but {cache_path} exists"
)

# Construction resolves the default URI, downloads and verifies the model, and
# opens it with ONNX Runtime. No model path is assigned anywhere in this test.
extractor = pycolmap.FeatureExtractor.create(options, pycolmap.Device.cpu)
assert extractor is not None
assert cache_path.is_file(), f"ALIKED model was not cached at {cache_path}"
assert cache_path.stat().st_size > 0
print(f"ALIKED default-model download passed: {cache_path}")
