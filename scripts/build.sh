#!/usr/bin/env bash
# Builds stable-diffusion.cpp as a PS5 payload (CPU only, runs under elfldr).
#
# This is the simpler of the two targets and a good first step: it needs no
# driver, no title and no signing. It is also **much** slower, because a payload
# cannot reach the GPU at all — 18 minutes for an image the native app does in
# 16 seconds. See the README for why.
#
#   docker exec sdps5-build bash /work/build.sh            # sd-cli
#   docker exec sdps5-build bash /work/build.sh sd-cli     # a single target
#
# The recipe follows PS5LM's scripts/build-llama.sh; the reasons for the
# individual switches are in its docs/PORTING.md.
set -euo pipefail

root=${SD_PS5_ROOT:-/work}
export PS5_PAYLOAD_SDK=${PS5_PAYLOAD_SDK:-$root/sdk/ps5-payload-sdk}
export LLVM_CONFIG=${LLVM_CONFIG:-/usr/bin/llvm-config-19}
export PATH=${LLVM_BIN:-/usr/lib/llvm-19/bin}:$PATH

src=${SD_SRC:-$root/src/stable-diffusion.cpp}
out=${PAYLOAD_OUT:-$root/build/sd-ps5}
compat=$root/build/ps5compat
patches=${PATCHES:-$root/patches}
entry=${PS5_ENTRY:-$root/src-ps5/ps5_entry.cpp}
targets=("${@:-sd-cli}")

mkdir -p "$compat"

if [ -d "$patches" ]; then
    for p in "$patches"/*.patch; do
        [ -e "$p" ] || continue
        git -C "$src" apply --reverse --check "$p" 2>/dev/null && continue
        git -C "$src" apply "$p" && echo "build: applied $(basename "$p")"
    done
fi

# accept4 is declared by the SDK's header but not exported by libkernel. Only the
# server example (cpp-httplib) needs it; harmless for sd-cli. Same approach as
# PS5LM's ps5/compat/compat.c.
cat > "$compat/compat.c" <<'EOF'
#include <fcntl.h>
#include <sys/socket.h>

int accept4(int s, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    int fd = accept(s, addr, addrlen);
    if (fd < 0) {
        return fd;
    }
    if (flags & SOCK_CLOEXEC) {
        int old = fcntl(fd, F_GETFD, 0);
        if (old >= 0) {
            fcntl(fd, F_SETFD, old | FD_CLOEXEC);
        }
    }
    if (flags & SOCK_NONBLOCK) {
        int old = fcntl(fd, F_GETFL, 0);
        if (old >= 0) {
            fcntl(fd, F_SETFL, old | O_NONBLOCK);
        }
    }
    return fd;
}
EOF

"$PS5_PAYLOAD_SDK/bin/prospero-clang" -O2 -Wall -Wextra -c \
    "$compat/compat.c" -o "$compat/compat.o"

# The entry point: arguments from args.txt, output to run.log, leaving through
# _Exit. Reasoning in src/ps5_entry.cpp. It goes into the archive; --wrap=main
# below pulls it in.
"$PS5_PAYLOAD_SDK/bin/prospero-clang++" -O2 -Wall -Wextra -std=c++17 \
    -fexceptions -fcxx-exceptions -frtti -c "$entry" -o "$compat/ps5_entry.o"

rm -f "$compat/libps5compat.a"
"$PS5_PAYLOAD_SDK/bin/prospero-ar" rcs "$compat/libps5compat.a" \
    "$compat/compat.o" "$compat/ps5_entry.o"

# The PS5 target turns exceptions and RTTI off by default; sd.cpp and ggml need both.
cxxflags="-fexceptions -fcxx-exceptions -frtti"

if [ ! -f "$out/CMakeCache.txt" ]; then
    # The PS5's CPU is a Zen 2: AVX2, FMA, F16C, BMI2, no AVX-512. No OpenMP in
    # the SDK, so ggml's own thread pool. Everything static: a payload is one ELF.
    # There is no libm, the maths lives in Sony's libc, hence
    # MATH_LIBRARY=SceLibcInternal.
    #
    # --wrap=main goes only on the C++ link line, not into
    # CMAKE_EXE_LINKER_FLAGS: CMake's compiler probe would otherwise fail with
    # "undefined symbol: __wrap_main" before anything is built.
    "$PS5_PAYLOAD_SDK/bin/prospero-cmake" -S "$src" -B "$out" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="$cxxflags" \
        -DMATH_LIBRARY=SceLibcInternal \
        -DCMAKE_C_STANDARD_LIBRARIES="$compat/libps5compat.a" \
        -DCMAKE_CXX_STANDARD_LIBRARIES="-Wl,--wrap=main $compat/libps5compat.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DSD_BUILD_SHARED_LIBS=OFF \
        -DSD_BUILD_EXAMPLES=ON \
        -DSD_WEBP=OFF \
        -DSD_WEBM=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=OFF \
        -DGGML_CPU_ALL_VARIANTS=OFF \
        -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
        -DGGML_AVX512=OFF \
        -DGGML_OPENMP=OFF \
        -DGGML_CCACHE=OFF
fi

cmake --build "$out" --target "${targets[@]}" -j "${BUILD_JOBS:-4}"

echo
echo "Result: $out/bin/sd-cli"
"${LLVM_BIN:-/usr/lib/llvm-19/bin}/llvm-readelf" -d "$out/bin/sd-cli" | grep -i NEEDED
echo
echo "Copy it and a model to /data/sd on the console, chmod 755 it, then start it"
echo "through elfldr's HTTP interface:"
echo '  curl -m 25 "http://<console>:9021/?uri=file:/data/sd/sd-cli"'
echo "That call runs into a timeout, which is correct: elfldr holds the connection"
echo "while the payload runs."
