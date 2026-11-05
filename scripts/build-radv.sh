#!/usr/bin/env bash
# Builds the PS5 Vulkan driver (RADV) that a native app needs to use the GPU.
# Follows PS5LM's docs/BUILDING.md; the sources and pins come from there and from
# PS5_Vulkan's own tools/build-radv.sh.
#
# Takes about five minutes on four cores once the clones are warm. The first run
# clones PS5_Mesa, which is large and takes considerably longer.
#
# Produces, under $SD_PS5_ROOT/vk/.deps/src/PS5_Vulkan/:
#   .deps/native/radv-release/lib/libvulkan_radeon.ps5.a   the driver
#   .deps/native/ps5-payload-sdk/                          the SDK it builds itself
#   runtime/libc.prx                                       the clean libc for titles
#   build/host/ps5-native-tool                             ELF -> fSELF
set -euo pipefail

# PS5_Vulkan looks for the **unversioned** tool names (clang, clang++, llvm-ar,
# llvm-ranlib) the way Arch has them; Debian ships only clang-19. Without this
# the zlib step already fails with "clang, an archive tool, and ranlib are
# required to build zlib".
export PATH=${LLVM_BIN:-/usr/lib/llvm-19/bin}:$PATH
export LLVM_CONFIG=${LLVM_CONFIG:-/usr/bin/llvm-config-19}

root=${RADV_ROOT:-${SD_PS5_ROOT:-/work}/vk}
src="$root/.deps/src"
ps5lm="$root/ps5lm"
mesa_revision=${PS5_MESA_REVISION:-1ba9874f478657ccf6da72ce55f0260164cc0bd0}
# The revision PS5_Vulkan's own tools/setup-native-dependencies.sh pins
# (`sdk_revision` there). A mismatch makes the setup step exit.
sdk_revision=${PS5_PAYLOAD_SDK_REVISION:-b83202be73e930050e00de0f1b4d9ec46c0391bf}

mkdir -p "$src"

# PS5LM only for patches/mesa and as the template for packing a title.
[ -d "$ps5lm/.git" ] || git clone -q --depth 1 https://github.com/cobanov/PS5LM "$ps5lm"

step() { printf '\n=== %s (%s) ===\n' "$1" "$(date +%H:%M:%S)"; }

step "Fetching PS5_Vulkan"
[ -d "$src/PS5_Vulkan/.git" ] ||
    git clone -q https://github.com/mihawk-99/PS5_Vulkan "$src/PS5_Vulkan"

step "Checking the host tools"
# setup-native-dependencies.sh looks for exactly three of these and otherwise only
# says "clang, an archive tool, and ranlib are required to build zlib", without
# saying which is missing. Look here, while it is still cheap.
for c in clang clang++ llvm-ar llvm-ranlib git wget unzip sha256sum tar make meson ninja glslc; do
    printf '  %-14s %s\n' "$c" "$(command -v "$c" || echo 'MISSING')"
done
for c in clang llvm-ar llvm-ranlib git wget unzip sha256sum tar make; do
    command -v "$c" >/dev/null || { echo "  stopping: $c is missing" >&2; exit 2; }
done

step "Fetching PS5_PayloadSDK (pinned at $sdk_revision)"
# PS5_Vulkan builds its SDK out of this fork and expects it as a sibling
# directory. Without it the setup ends with "the payload SDK fork at ... does not
# have <revision>" and exit 2.
if [ ! -d "$src/PS5_PayloadSDK/.git" ]; then
    git clone -q https://github.com/mihawk-99/PS5_PayloadSDK "$src/PS5_PayloadSDK"
fi
git -C "$src/PS5_PayloadSDK" cat-file -e "$sdk_revision^{commit}" 2>/dev/null ||
    git -C "$src/PS5_PayloadSDK" fetch -q --all
git -C "$src/PS5_PayloadSDK" cat-file -e "$sdk_revision^{commit}" 2>/dev/null || {
    echo "  stopping: $sdk_revision is not in this fork" >&2
    exit 2
}
echo "  $sdk_revision present"

step "Fetching PS5_Mesa (pinned at $mesa_revision)"
[ -d "$src/PS5_Mesa/.git" ] ||
    git clone -q https://github.com/mihawk-99/PS5_Mesa "$src/PS5_Mesa"
git -C "$src/PS5_Mesa" cat-file -e "$mesa_revision^{commit}" 2>/dev/null ||
    git -C "$src/PS5_Mesa" fetch -q --all
git -C "$src/PS5_Mesa" checkout -q "$mesa_revision"

step "Applying PS5LM's Mesa patches"
git -C "$src/PS5_Mesa" config user.email build@localhost
git -C "$src/PS5_Mesa" config user.name "sd-ps5 build"
for p in "$ps5lm"/patches/mesa/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$src/PS5_Mesa" apply --reverse --check "$p" 2>/dev/null; then
        echo "  already applied: $(basename "$p")"
        continue
    fi
    git -C "$src/PS5_Mesa" am -q "$p" || {
        git -C "$src/PS5_Mesa" am --abort 2>/dev/null || true
        echo "  FAILED on $(basename "$p")" >&2
        exit 1
    }
    echo "  applied: $(basename "$p")"
done

step "PS5_Vulkan's own dependencies (SDK, zlib; checksummed)"
(cd "$src/PS5_Vulkan" && bash tools/setup-native-dependencies.sh)

step "Building RADV (the long part)"
(cd "$src/PS5_Vulkan" &&
    PS5_MESA_REVISION="$mesa_revision" bash tools/build-radv.sh release)

step "libc.prx and the host tool"
# PS5LM's BUILDING.md notes that PS5_Vulkan's own demo title may fail to link at
# HEAD. That does not matter here: libc.prx and the host tool are what we need.
(cd "$src/PS5_Vulkan" && make app) ||
    echo "  'make app' reported an error - the demo title is allowed to fail"

step "What came out"
for f in "$src/PS5_Vulkan/.deps/native/radv-release/lib/libvulkan_radeon.ps5.a" \
         "$src/PS5_Vulkan/runtime/libc.prx" \
         "$src/PS5_Vulkan/build/host/ps5-native-tool" \
         "$src/PS5_Vulkan/.deps/native/ps5-payload-sdk/bin/prospero-lld"; do
    if [ -e "$f" ]; then
        printf '  OK   %10s  %s\n' "$(stat -c %s "$f")" "$f"
    else
        printf '  MISSING        %s\n' "$f"
    fi
done
