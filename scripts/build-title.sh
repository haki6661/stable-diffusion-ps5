#!/usr/bin/env bash
# Links stable-diffusion.cpp into a native PS5 app (a title) with RADV, so the
# GPU can do the work. A payload cannot: elfldr gives it budget 0, so there is no
# direct memory and RADV gets no device memory.
#
# Needs build-radv.sh and build-vulkan.sh to have run.
# Produces $TITLE_OUT/$TITLE_ID/ with eboot.bin and sce_sys/param.json.
#
# The recipe follows PS5LM's scripts/build-app.sh, minus the user interface:
# no ps5-opengl, no dashboard, no downloads — just sd-cli.
set -euo pipefail

export PATH=${LLVM_BIN:-/usr/lib/llvm-19/bin}:$PATH

root=${SD_PS5_ROOT:-/work}
vk=${PS5_VULKAN_ROOT:-$root/vk/.deps/src/PS5_Vulkan}
ps5lm=${PS5LM_ROOT:-$root/vk/ps5lm}
src=${SD_SRC:-$root/src/stable-diffusion.cpp}
libs_dir=${SD_OUT:-$root/build/sd-vulkan}
entry=${PS5_ENTRY:-$root/src-ps5/ps5_entry.cpp}
headers=${VK_HEADERS:-$root/build/vk-headers}
out=${TITLE_OUT:-$root/build/title}
title_id=${TITLE_ID:-PPSA99574}
title_name=${TITLE_NAME:-sd.cpp}
icon=${TITLE_ICON:-$root/src-ps5/icon0.png}

export PS5_VULKAN_ROOT="$vk"
sdk="$vk/.deps/native/ps5-payload-sdk"
export PS5_PAYLOAD_SDK="$sdk"
archive="$vk/.deps/native/radv-release/lib/libvulkan_radeon.ps5.a"
tool="$vk/build/host/ps5-native-tool"

obj="$out/obj"
mkdir -p "$obj" "$out/stubs"

cxx() { "$ps5lm/ps5/app/ps5cxx" -O2 -ffunction-sections -fdata-sections "$@"; }
cc() { "$ps5lm/ps5/app/ps5cc" -O2 -ffunction-sections -fdata-sections "$@"; }

inc=(-I "$src/examples" -I "$src/src" -I "$src/src/core" -I "$src/include"
     -I "$src/thirdparty" -I "$src/ggml/include" -I "$headers/include")
xflags=(-std=c++17 -fexceptions -fcxx-exceptions -frtti -DGGML_MAX_NAME=160 -DGGML_USE_CPU)

step() { printf '\n=== %s (%s) ===\n' "$1" "$(date +%H:%M:%S)"; }

step "Compiling sd-cli's own sources"
# CMake does not build these (SD_BUILD_EXAMPLES is off), because a title is not
# linked by CMake. This is the same list the payload link line uses.
for s in examples/cli/main.cpp examples/cli/image_metadata.cpp \
         examples/common/common.cpp examples/common/generation_metadata.cpp \
         examples/common/log.cpp examples/common/media_io.cpp \
         examples/common/media_metadata.cpp; do
    base=${s#examples/}
    base=${base%.cpp}
    o="$obj/$(echo "$base" | tr '/' '_').o"
    echo "  $s -> $(basename "$o")"
    cxx "${xflags[@]}" "${inc[@]}" -c "$src/$s" -o "$o"
done
cc -std=c11 -I "$src/thirdparty" -c "$src/thirdparty/zip.c" -o "$obj/zip.o"

step "Entry point and runtime"
cxx "${xflags[@]}" -c "$entry" -o "$obj/ps5_entry.o"
# PS5_Vulkan's title start code and PS5LM's C++ runtime for a title.
cxx -std=c++20 -fno-exceptions -fno-rtti -c "$vk/tooling/native/app_crt.cpp" -o "$obj/app_crt.o"
cxx -std=c++20 -fexceptions -fcxx-exceptions -c "$ps5lm/ps5/app/cpp_runtime.cpp" -o "$obj/cpp_runtime.o"
# compat_app.c replaces libc functions a title lacks (getaddrinfo, accept4, HOME,
# localeconv). Into an archive so --exclude-libs keeps them local: a stub module
# defines some of the same names and lld would otherwise export ours over them.
cc -c "$ps5lm/ps5/app/compat_app.c" -o "$obj/compat_app.o"
rm -f "$obj/libcompat.a"
"$sdk/bin/llvm-ar" rcs "$obj/libcompat.a" "$obj/compat_app.o"

step "AGC stubs from the driver's imports"
# The AGC functions come from system modules; these stubs only name the imports
# RADV actually makes.
agc_imports=$("$sdk/bin/llvm-nm" -u "$archive" 2>/dev/null | awk '{print $NF}' | grep -E '^sceAgc' | sort -u)
echo "  $(echo "$agc_imports" | wc -l) AGC symbols"
for lib in libSceAgc libSceAgcDriver; do
    stub_c="$out/stubs/$lib.c"
    : > "$stub_c"
    for name in $agc_imports; do
        case $lib:$name in
            libSceAgcDriver:sceAgcDriver*) echo "void $name(void) {}" >> "$stub_c" ;;
            libSceAgc:sceAgcDriver*) ;;
            libSceAgc:*) echo "void $name(void) {}" >> "$stub_c" ;;
        esac
    done
    cc -fPIC -c "$stub_c" -o "$obj/${lib}_stub.o"
    "$sdk/bin/prospero-lld" --shared -soname "$lib.prx" -o "$out/stubs/$lib.so" "$obj/${lib}_stub.o"
done

step "Linking"
# shellcheck source=/dev/null
source "$vk/tools/radv-link.sh"
PS5_CLANG=clang radv_link_recipe "$vk" "$sdk" "$archive" || exit 2
# The platform's getaddrinfo always fails; compat_app.c has a numeric one.
flags=()
for f in "${radv_link_flags[@]}"; do
    case $f in --defsym=getaddrinfo=*|--defsym=freeaddrinfo=*) ;; *) flags+=("$f") ;; esac
done
radv_link_flags=("${flags[@]}" --wrap=main)

# There is **no Vulkan loader** on the console. The public vk* names are normally
# the loader's; RADV as an ICD only brings its internal ones. PS5LM solves this
# with a forwarder in ps5/app/main.cpp, but needs only vkGetInstanceProcAddr,
# because llama.cpp's ggml resolves everything else through the dispatcher. The
# ggml fork sd.cpp uses calls three more commands directly, so they are missing at
# link time. The signatures are identical, so aliases suffice — the same mechanism
# radv-link.sh already uses for the libc functions.
radv_link_flags+=(--defsym=vkGetInstanceProcAddr=vk_icdGetInstanceProcAddr)
radv_link_flags+=(--defsym=vkGetDeviceProcAddr=vk_common_GetDeviceProcAddr)
radv_link_flags+=(--defsym=vkCmdCopyBuffer=vk_common_CmdCopyBuffer)
radv_link_flags+=(--defsym=vkGetPhysicalDeviceFeatures2=vk_common_GetPhysicalDeviceFeatures2)

mapfile -t libs < <(find "$libs_dir" -name '*.a' | sort)
echo "  libraries: ${#libs[@]}"
"$sdk/bin/prospero-lld" "${radv_linker_script[@]}" --eh-frame-hdr "${radv_link_flags[@]}" \
    --version-script "$vk/tooling/native/app-symbols.map" --exclude-libs=ALL \
    -e _start -o "$out/llvm-pie.elf" \
    "$obj/app_crt.o" "$obj/cpp_runtime.o" "$obj/ps5_entry.o" \
    "$obj/cli_main.o" "$obj/cli_image_metadata.o" \
    "$obj/common_common.o" "$obj/common_generation_metadata.o" "$obj/common_log.o" \
    "$obj/common_media_io.o" "$obj/common_media_metadata.o" "$obj/zip.o" \
    --start-group "${libs[@]}" "$obj/libcompat.a" --end-group \
    "$out/stubs/libSceAgc.so" "$out/stubs/libSceAgcDriver.so" \
    "${radv_link_inputs[@]}" \
    --as-needed "$sdk"/target/lib/*.so

step "fSELF and title folder"
"$tool" link --in "$out/llvm-pie.elf" --out "$out/eboot.elf" \
    --stub-dir "$sdk/target/lib" --stub "$out/stubs/libSceAgc.so" \
    --stub "$out/stubs/libSceAgcDriver.so" --module-sdk 0x02000009 \
    --companion-sdk 0x08050001 --file-name eboot.elf

title="$out/$title_id"
mkdir -p "$title/sce_sys" "$title/sce_module"

# **The decisive second step.** `link` produces an ordinary ELF; the console only
# loads an fSELF. Without this signing it refuses the title with
# launch_sony_error_0x80020008 — that is 0x80020000 + errno, so errno 8, ENOEXEC:
# wrong file format. An fSELF starts with the magic 0x1D3D154F (`4F 15 3D 1D`),
# not with `\177ELF`.
"$tool" self --sign --in "$out/eboot.elf" --out "$title/eboot.bin" --magic 0x1D3D154F
# The tool reads the finished file back; if that fails it is not loadable, and
# noticing it here beats noticing it on the console.
"$tool" self --inspect --file "$title/eboot.bin" > /dev/null

cp "$vk/runtime/libc.prx" "$title/sce_module/libc.prx"
sed -e "s/PPSA99575/$title_id/g" -e "s/99575/${title_id#PPSA}/g" \
    -e "s/PS5LMVULKAN00001/SDCPPVULKAN00001/" -e "s/\"PS5LM\"/\"$title_name\"/" \
    "$ps5lm/ps5/app/sce_sys/param.json" > "$title/sce_sys/param.json"
if [ -f "$icon" ]; then
    cp "$icon" "$title/sce_sys/icon0.png"
else
    echo "  WARNING: $icon missing, the title gets no icon" >&2
fi

step "Done"
find "$title" -type f -printf '  %10s  %P\n' | sort -k2
echo
echo "Copy this folder to /data/homebrew/$title_id on the console (FTP, port 2121)."
echo "ShadowMountPlus picks it up and puts it on the home screen."
