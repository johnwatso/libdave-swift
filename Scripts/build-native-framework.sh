#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=../Native/versions.env
source "${repository_root}/Native/versions.env"

native_work_dir="${DAVE_NATIVE_WORK_DIR:-${repository_root}/.build/native-rebuild}"
source_dir="${native_work_dir}/src/libdave"
build_dir="${native_work_dir}/build"
output_dir="${native_work_dir}/output"
framework_dir="${output_dir}/Dave.xcframework"

mkdir -p "${native_work_dir}/src" "${output_dir}"

if [[ ! -d "${source_dir}/.git" ]]; then
  git clone --filter=blob:none "${LIBDAVE_REPOSITORY}" "${source_dir}"
fi

git -C "${source_dir}" fetch --quiet origin "${LIBDAVE_REVISION}"
# This checkout is owned exclusively by this script. Restore the pinned tree on
# every run so an interrupted prior patch application cannot affect the output.
git -C "${source_dir}" checkout --quiet --detach --force "${LIBDAVE_REVISION}"
git -C "${source_dir}" submodule update --init --recursive

actual_libdave_revision="$(git -C "${source_dir}" rev-parse HEAD)"
actual_vcpkg_revision="$(git -C "${source_dir}/cpp/vcpkg" rev-parse HEAD)"
[[ "${actual_libdave_revision}" == "${LIBDAVE_REVISION}" ]]
[[ "${actual_vcpkg_revision}" == "${VCPKG_REVISION}" ]]

patch_file="${repository_root}/Native/patches/0001-generic-persisted-key-store.patch"
if git -C "${source_dir}" apply --unidiff-zero --check "${patch_file}" 2>/dev/null; then
  git -C "${source_dir}" apply --unidiff-zero "${patch_file}"
elif ! git -C "${source_dir}" apply --unidiff-zero --reverse --check "${patch_file}" 2>/dev/null; then
  echo "Pinned libdave checkout does not match the persisted-key patch" >&2
  exit 1
fi

vcpkg_dir="${source_dir}/cpp/vcpkg"
if [[ ! -x "${vcpkg_dir}/vcpkg" ]]; then
  "${vcpkg_dir}/bootstrap-vcpkg.sh" -disableMetrics
fi
cmake_path="$("${vcpkg_dir}/vcpkg" fetch cmake | tail -n 1)"
ninja_path="$("${vcpkg_dir}/vcpkg" fetch ninja | tail -n 1)"
actual_cmake_version="$(${cmake_path} --version | awk 'NR == 1 { print $3 }')"
[[ "${actual_cmake_version}" == "${CMAKE_VERSION}" ]]
actual_ninja_version="$(${ninja_path} --version)"
[[ "${actual_ninja_version}" == "${NINJA_VERSION}" ]]
actual_xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
actual_xcode_build_version="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
[[ "${actual_xcode_version}" == "${XCODE_VERSION}" ]]
[[ "${actual_xcode_build_version}" == "${XCODE_BUILD_VERSION}" ]]

# The pinned vcpkg ports require pkg-config while packaging OpenSSL. macOS does
# not ship it, so build a pinned pkgconf from the same vcpkg revision rather
# than relying on an unrecorded Homebrew installation.
pkg_tools_root="${native_work_dir}/pkg-tools"
pkgconf_path="${pkg_tools_root}/arm64-osx/tools/pkgconf/pkgconf"
if [[ ! -x "${pkgconf_path}" ]]; then
  "${vcpkg_dir}/vcpkg" install pkgconf:arm64-osx --x-install-root="${pkg_tools_root}"
fi
actual_pkgconf_version="$(${pkgconf_path} --version)"
[[ "${actual_pkgconf_version}" == "${PKGCONF_VERSION}" ]]
tool_bin_dir="${native_work_dir}/tools/bin"
mkdir -p "${tool_bin_dir}"
ln -sf "${pkgconf_path}" "${tool_bin_dir}/pkg-config"

env PATH="${tool_bin_dir}:${PATH}" "${cmake_path}" \
  --fresh \
  -G Ninja \
  -S "${repository_root}/Native" \
  -B "${build_dir}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}" \
  -DCMAKE_MAKE_PROGRAM="${ninja_path}" \
  -DCMAKE_TOOLCHAIN_FILE="${vcpkg_dir}/scripts/buildsystems/vcpkg.cmake" \
  -DDAVE_SOURCE_DIR="${source_dir}" \
  -DVCPKG_INSTALLED_DIR="${build_dir}/vcpkg_installed" \
  -DVCPKG_MANIFEST_DIR="${source_dir}/cpp/vcpkg-alts/openssl_3" \
  -DVCPKG_TARGET_TRIPLET=arm64-osx

"${cmake_path}" --build "${build_dir}" --config Release --parallel

libdave_archive="${build_dir}/libdave-build/libdave.a"
dependency_lib_dir="${build_dir}/vcpkg_installed/arm64-osx/lib"
merged_archive="${output_dir}/libdave_merged.a"

for required_archive in \
  "${libdave_archive}" \
  "${dependency_lib_dir}/libbytes.a" \
  "${dependency_lib_dir}/libtls_syntax.a" \
  "${dependency_lib_dir}/libhpke.a" \
  "${dependency_lib_dir}/libmlspp.a" \
  "${dependency_lib_dir}/libcrypto.a"; do
  [[ -f "${required_archive}" ]] || {
    echo "Missing expected static archive: ${required_archive}" >&2
    exit 1
  }
done

env ZERO_AR_DATE=1 /usr/bin/libtool -static -o "${merged_archive}" \
  "${libdave_archive}" \
  "${dependency_lib_dir}/libbytes.a" \
  "${dependency_lib_dir}/libtls_syntax.a" \
  "${dependency_lib_dir}/libhpke.a" \
  "${dependency_lib_dir}/libmlspp.a" \
  "${dependency_lib_dir}/libcrypto.a"

if [[ -e "${framework_dir}" ]]; then
  /bin/rm -rf "${framework_dir}"
fi
xcodebuild -create-xcframework \
  -library "${merged_archive}" \
  -headers "${source_dir}/cpp/includes" \
  -output "${framework_dir}"

metadata_file="${framework_dir}/BUILD-METADATA.json"
python3 - "${metadata_file}" <<PY
import json
import pathlib
import sys

metadata = {
    "schemaVersion": 1,
    "libdave": {"repository": "${LIBDAVE_REPOSITORY}", "revision": "${LIBDAVE_REVISION}", "tag": "${LIBDAVE_TAG}"},
    "vcpkg": {"revision": "${VCPKG_REVISION}", "builtinBaseline": "${VCPKG_BASELINE}"},
    "mlspp": {"revision": "${MLSPP_REVISION}"},
    "openssl": {"version": "${OPENSSL_VERSION}"},
    "nlohmannJson": {"version": "${NLOHMANN_JSON_VERSION}"},
    "cmake": {"version": "${CMAKE_VERSION}"},
    "ninja": {"version": "${NINJA_VERSION}"},
    "pkgconf": {"version": "${PKGCONF_VERSION}"},
    "target": {"platform": "macOS", "architecture": "arm64", "deploymentTarget": "${MACOS_DEPLOYMENT_TARGET}"},
    "xcode": {"version": "${XCODE_VERSION}", "buildVersion": "${XCODE_BUILD_VERSION}"},
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY

cp "${repository_root}/Native/SBOM.spdx.json" "${framework_dir}/SBOM.spdx.json"
mkdir -p "${framework_dir}/Licenses"
cp "${repository_root}"/ThirdPartyLicenses/*.txt "${framework_dir}/Licenses/"

(
  cd "${framework_dir}"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 \
    | sed 's#  \./#  Frameworks/Dave.xcframework/#' \
    > "${framework_dir}/SHA256SUMS"
)

echo "Framework: ${framework_dir}"
echo "Integration helper: ${build_dir}/integration/dave_external_sender_helper"
