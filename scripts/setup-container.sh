#!/usr/bin/env bash
# Sets up the build container: Debian trixie with clang 19 and the
# checksum-verified PS5 payload SDK, plus the sources.
#
#   WORK=/srv/sd-ps5 bash setup-container.sh
#
# Everything lands in $WORK on the host and is /work inside the container.
# Put $WORK on fast local storage; a network filesystem costs real time here.
set -euo pipefail

WORK=${WORK:-/srv/sd-ps5}
NAME=${NAME:-sdps5-build}
IMAGE=${IMAGE:-debian:trixie-slim}
JOBS=${JOBS:-4}
SDK_VERSION=v0.43
SDK_SHA256=a9cc9929f21b2b2c5d5b309f3bab4997067c45281c0622cf4838b1aecba66fcb

mkdir -p "$WORK"

if ! docker inspect "$NAME" >/dev/null 2>&1; then
    docker run -d --name "$NAME" --cpus "$JOBS" -v "$WORK:/work" -w /work \
        "$IMAGE" sleep infinity
fi

# The first group is enough for the CPU payload. The rest is what building Mesa
# and RADV needs; it is the package list from PS5LM's CI workflow.
docker exec "$NAME" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v clang-19 >/dev/null; then
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential git ca-certificates curl wget unzip rsync cmake ninja-build \
        clang-19 lld-19 libclang-rt-19-dev llvm-19-dev libclang-19-dev libclang-cpp19-dev \
        libllvmspirvlib-19-dev libclc-19-dev spirv-tools spirv-headers glslang-tools \
        meson pkgconf flex bison python3 python3-mako python3-yaml python3-packaging \
        python3-setuptools zlib1g-dev libzstd-dev libffi-dev libedit-dev libxml2-dev \
        libvulkan-dev glslc xxd
fi
'

# The SDK is a release zip; the checksum is the one PS5LM pins in its
# scripts/setup-sdk.sh. If it does not match, nothing is unpacked.
docker exec "$NAME" bash -c "
set -euo pipefail
mkdir -p /work/sdk-dl
cd /work/sdk-dl
if [ ! -f ps5-payload-sdk.zip ]; then
    curl -fsSL -o ps5-payload-sdk.zip \
        https://github.com/ps5-payload-dev/sdk/releases/download/$SDK_VERSION/ps5-payload-sdk.zip
fi
echo '$SDK_SHA256  ps5-payload-sdk.zip' | sha256sum -c -
if [ ! -x /work/sdk/ps5-payload-sdk/bin/prospero-clang ]; then
    rm -rf /work/sdk && mkdir -p /work/sdk
    unzip -q ps5-payload-sdk.zip -d /work/sdk
fi
"

# Sources. Only the ggml submodule: libwebp, libwebm and cutlass stay empty, which
# turns WebP and WebM output off by itself (see thirdparty/CMakeLists.txt). PNG is
# all we need and stb_image_write is header-only.
docker exec "$NAME" bash -c '
set -euo pipefail
mkdir -p /work/src
cd /work/src
[ -d stable-diffusion.cpp ] || git clone -q https://github.com/leejet/stable-diffusion.cpp.git
cd stable-diffusion.cpp
git submodule update --init --depth 1 ggml
echo "sd.cpp  $(git rev-parse HEAD)"
echo "ggml    $(git -C ggml rev-parse HEAD)"
'

# The patches and the entry point belong where the build scripts look for them.
mkdir -p "$WORK/patches" "$WORK/src-ps5"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cp "$here"/patches/*.patch "$WORK/patches/" 2>/dev/null || true
cp "$here"/src/ps5_entry.cpp "$WORK/src-ps5/" 2>/dev/null || true
cp "$here"/scripts/*.sh "$WORK/" 2>/dev/null || true
[ -f "$here/icon0.png" ] && cp "$here/icon0.png" "$WORK/src-ps5/"

echo
echo "Ready. Next:"
echo "  docker exec $NAME bash /work/build-radv.sh      # the driver"
echo "  docker exec $NAME bash /work/build-vulkan.sh    # sd.cpp with Vulkan"
echo "  docker exec $NAME bash /work/build-title.sh     # the native app"
echo "or, for the CPU payload only:"
echo "  docker exec $NAME bash /work/build.sh"
