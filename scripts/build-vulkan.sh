#!/usr/bin/env bash
# Compiles stable-diffusion.cpp with the Vulkan backend against the PS5 RADV that
# build-radv.sh produced.
#
# The result is **static libraries**, not a finished program: a native app is not
# linked by CMake but by hand, with libc.prx and the title start code. That is
# build-title.sh. This script gets the compiling out of the way and shows whether
# sd.cpp and ggml-vulkan go through for the console at all.
#
# Toolchain, wrappers and flags come from PS5LM's scripts/build-app.sh and
# ps5/app/toolchain.cmake.
set -euo pipefail

export PATH=${LLVM_BIN:-/usr/lib/llvm-19/bin}:$PATH

root=${SD_PS5_ROOT:-/work}
vk=${PS5_VULKAN_ROOT:-$root/vk/.deps/src/PS5_Vulkan}
ps5lm=${PS5LM_ROOT:-$root/vk/ps5lm}
src=${SD_SRC:-$root/src/stable-diffusion.cpp}
out=${SD_OUT:-$root/build/sd-vulkan}
headers=${VK_HEADERS:-$root/build/vk-headers}
patches=${PATCHES:-$root/patches}

export PS5_VULKAN_ROOT="$vk"
export PS5_PAYLOAD_SDK="$vk/.deps/native/ps5-payload-sdk"
archive="$vk/.deps/native/radv-release/lib/libvulkan_radeon.ps5.a"

for f in "$archive" "$PS5_PAYLOAD_SDK/bin/prospero-lld" \
         "$ps5lm/ps5/app/toolchain.cmake" "$vk/tooling/prospero-clang18"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

# The Vulkan and SPIR-V headers are copied out of /usr/include so the cross build
# never sees them next to the host libc's headers. PS5LM's build-app.sh does the
# same.
if [ ! -f "$headers/include/vulkan/vulkan.h" ]; then
    mkdir -p "$headers/include" "$headers/cmake"
    cp -r /usr/include/vulkan /usr/include/vk_video "$headers/include/"
    [ -d /usr/include/spirv ] && cp -r /usr/include/spirv "$headers/include/"
    cat > "$headers/cmake/SPIRV-HeadersConfig.cmake" <<EOF
add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)
set_target_properties(SPIRV-Headers::SPIRV-Headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "$headers/include")
set(SPIRV-Headers_FOUND TRUE)
EOF
fi

# The PS5 changes to sd.cpp, the same ones the payload build applies.
if [ -d "$patches" ]; then
    for p in "$patches"/*.patch; do
        [ -e "$p" ] || continue
        git -C "$src" apply --reverse --check "$p" 2>/dev/null && continue
        git -C "$src" apply "$p" && echo "applied: $(basename "$p")"
    done
fi

flags="-I$headers/include"
# sd.cpp and llama.cpp both throw, catch and use dynamic_cast; the PS5 target
# turns exceptions and RTTI off by default.
cxxflags="$flags -fexceptions -fcxx-exceptions -frtti"

if [ ! -f "$out/CMakeCache.txt" ]; then
    # Note PS5LM's toolchain.cmake sets CMAKE_TRY_COMPILE_TARGET_TYPE to
    # STATIC_LIBRARY, which is why the compiler check does not fail for want of a
    # link target the way it would in a payload build.
    cmake -S "$src" -B "$out" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$ps5lm/ps5/app/toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$flags" \
        -DCMAKE_CXX_FLAGS="$cxxflags" \
        -DMATH_LIBRARY=SceLibcInternal \
        -DBUILD_SHARED_LIBS=OFF \
        -DSD_BUILD_SHARED_LIBS=OFF \
        -DSD_BUILD_EXAMPLES=OFF \
        -DSD_WEBP=OFF \
        -DSD_WEBM=OFF \
        -DSD_VULKAN=ON \
        -DVulkan_INCLUDE_DIR="$headers/include" \
        -DVulkan_LIBRARY="$archive" \
        -DVulkan_GLSLC_EXECUTABLE="$(command -v glslc)" \
        -DSPIRV-Headers_DIR="$headers/cmake" \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=OFF \
        -DGGML_CPU_ALL_VARIANTS=OFF \
        -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
        -DGGML_AVX512=OFF \
        -DGGML_OPENMP=OFF \
        -DGGML_CCACHE=OFF
fi

cmake --build "$out" --target stable-diffusion -j "${BUILD_JOBS:-4}"

echo
echo "=== Archives ==="
find "$out" -name '*.a' -printf '  %10s  %p\n' | sort -k2
