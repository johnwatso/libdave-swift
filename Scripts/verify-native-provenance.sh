#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/.." && pwd)"
framework_dir="${DAVE_FRAMEWORK_ROOT:-${repository_root}/Frameworks/Dave.xcframework}"
metadata_file="${framework_dir}/BUILD-METADATA.json"
checksum_file="${framework_dir}/SHA256SUMS"

[[ -f "${metadata_file}" ]] || {
  echo "Missing ${metadata_file}" >&2
  exit 1
}

python3 - "${framework_dir}" "${checksum_file}" <<'PY'
import hashlib
import pathlib
import sys

framework = pathlib.Path(sys.argv[1])
checksum_file = pathlib.Path(sys.argv[2])
prefix = "Frameworks/Dave.xcframework/"
for line in checksum_file.read_text().splitlines():
    expected, recorded_path = line.split("  ", 1)
    if not recorded_path.startswith(prefix):
        raise SystemExit(f"unexpected checksum path: {recorded_path}")
    artifact = framework / recorded_path.removeprefix(prefix)
    actual = hashlib.sha256(artifact.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"checksum mismatch: {artifact}")
    print(f"{recorded_path}: OK")
PY

python3 - "${repository_root}/Native/versions.env" "${metadata_file}" <<'PY'
import json
import pathlib
import sys

versions = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line and not line.startswith("#"):
        key, value = line.split("=", 1)
        versions[key] = value

metadata = json.loads(pathlib.Path(sys.argv[2]).read_text())
checks = {
    "LIBDAVE_REPOSITORY": metadata["libdave"]["repository"],
    "LIBDAVE_REVISION": metadata["libdave"]["revision"],
    "LIBDAVE_TAG": metadata["libdave"]["tag"],
    "VCPKG_REVISION": metadata["vcpkg"]["revision"],
    "VCPKG_BASELINE": metadata["vcpkg"]["builtinBaseline"],
    "MLSPP_REVISION": metadata["mlspp"]["revision"],
    "OPENSSL_VERSION": metadata["openssl"]["version"],
    "NLOHMANN_JSON_VERSION": metadata["nlohmannJson"]["version"],
    "CMAKE_VERSION": metadata["cmake"]["version"],
    "NINJA_VERSION": metadata["ninja"]["version"],
    "PKGCONF_VERSION": metadata["pkgconf"]["version"],
    "XCODE_VERSION": metadata["xcode"]["version"],
    "XCODE_BUILD_VERSION": metadata["xcode"]["buildVersion"],
    "MACOS_DEPLOYMENT_TARGET": metadata["target"]["deploymentTarget"],
}
for key, actual in checks.items():
    expected = versions[key]
    if actual != expected:
        raise SystemExit(f"{key}: metadata has {actual!r}, expected {expected!r}")
PY

archive="${framework_dir}/macos-arm64/libdave_merged.a"
[[ "$(lipo "${archive}" -archs)" == "arm64" ]]
strings "${archive}" | grep -F "OpenSSL 3.0.7 1 Nov 2022" >/dev/null

echo "Native framework provenance and integrity verified"
