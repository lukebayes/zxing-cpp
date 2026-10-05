#!/usr/bin/env bash
# Build zxing_reader.{js,wasm} from the committed source tree (HEAD).
#
# This is the build eightamps/bom used to run itself (script/build-zxing-wasm.sh,
# eightamps/bom#3355): Emscripten in a pinned emsdk container, reader only,
# targets web and worker. The stb_image.h header is vendored in
# wrappers/wasm/third_party/stb, so nothing is fetched at build time.
#
# The source goes into the container with `podman cp`, not a bind mount. On the
# CI runner podman talks to the host daemon over a socket, and the host cannot
# see the job's workspace path. The same script works on a workstation.
#
# Usage: eightamps/build-wasm.sh [OUT_DIR]     (default: eightamps/dist)
# Env:   RELEASE_TAG  recorded in VERSION (default: unreleased)
#        PODMAN       podman command; CI sets "podman --remote"
set -euo pipefail

# Pinned by digest. Update the tag and digest together, and EMSDK_VERSION.
EMSDK_IMAGE=docker.io/emscripten/emsdk:4.0.10@sha256:90b757eb11fa9a0e3ce4d2d9f76d932a56018e4accc37b5a28b2783751e60eb7
EMSDK_VERSION=4.0.10
STB_REPO_URL=https://github.com/nothings/stb
STB_COMMIT=2c980bb59875b0d32144a71867fbdebb2f77cd20
STB_DIR=wrappers/wasm/third_party/stb
ENVIRONMENT=web,worker
CXX_FLAGS='-O3'
SOURCE_URL=https://git.eightamps.com/eightamps/zxing-cpp

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-$root/eightamps/dist}
release_tag=${RELEASE_TAG:-unreleased}
read -ra podman <<<"${PODMAN:-podman}"

if [[ ! $EMSDK_IMAGE =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "error: EMSDK_IMAGE must be pinned by digest: $EMSDK_IMAGE" >&2
  exit 1
fi

commit=$(git -C "$root" rev-parse HEAD)
upstream=$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-ea*' 2>/dev/null || echo unknown)

# -ffile-prefix-map keeps the container's mount paths out of the output.
container_script="set -euo pipefail
  mkdir -p /build
  cd /build
  emcmake cmake /src/wrappers/wasm \\
    -DCMAKE_BUILD_TYPE=Release \\
    -DCMAKE_CXX_FLAGS='$CXX_FLAGS -ffile-prefix-map=/src=.' \\
    -DZXING_READERS=ON -DZXING_WRITERS=OFF \\
    -DZXING_EMSCRIPTEN_ENVIRONMENT=$ENVIRONMENT \\
    -DSTB_IMAGE_INCLUDE_DIR=/src/$STB_DIR
  cmake --build . --target zxing_reader -j\$(nproc)"

cid=$("${podman[@]}" create "$EMSDK_IMAGE" bash -c "$container_script")
trap '"${podman[@]}" rm -f "$cid" >/dev/null 2>&1 || true' EXIT

# git archive ships exactly the committed files, so the build is of $commit.
git -C "$root" archive --format=tar --prefix=src/ HEAD | "${podman[@]}" cp - "$cid:/"

"${podman[@]}" start --attach "$cid"

rm -rf "$out"
mkdir -p "$out"
"${podman[@]}" cp "$cid:/build/zxing_reader.js" "$out/"
"${podman[@]}" cp "$cid:/build/zxing_reader.wasm" "$out/"

cat > "$out/VERSION" <<VERSION
release:  $release_tag
source:   $SOURCE_URL
upstream: $upstream
commit:   $commit
stb:      $STB_REPO_URL @ $STB_COMMIT (vendored in $STB_DIR)
emsdk:    $EMSDK_IMAGE (emcc $EMSDK_VERSION)
target:   wrappers/wasm, zxing_reader
flags:    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS='$CXX_FLAGS -ffile-prefix-map=/src=.' -DZXING_READERS=ON -DZXING_WRITERS=OFF -DZXING_EMSCRIPTEN_ENVIRONMENT=$ENVIRONMENT
          (C++20 comes from wrappers/wasm/CMakeLists.txt)
build:    eightamps/build-wasm.sh
VERSION

(cd "$out" && sha256sum zxing_reader.js zxing_reader.wasm VERSION > SHA256SUMS)

echo "wrote $out"
cat "$out/SHA256SUMS"
