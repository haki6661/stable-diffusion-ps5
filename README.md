# stable-diffusion.cpp on the PlayStation 5

Image generation on a jailbroken PS5, on the **GPU**, through
[PS5_Vulkan](https://github.com/mihawk-99/PS5_Vulkan)'s RADV.

**SD 1.5 at 512×512, 20 steps: 15.85 s. SDXL at 1024×1024: 71.36 s.**

The same image on the console's CPU takes 1103 s, so the GPU is **70× faster**.

![CPU on the left, GPU on the right](images/cpu-vs-gpu.png)

*Left: CPU, 1103.4 s. Right: GPU, 15.85 s. Same prompt, same seed.*

---

## What this is

[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) builds for the PS5
**without a single change to the project's core** — the build flags from
[PS5LM](https://github.com/cobanov/PS5LM) are enough. That is the main finding here: the
porting work PS5LM did for llama.cpp carries a second ggml program.

Two patches are needed, and both are about the console rather than about the project.
They are in [`patches/`](patches/).

This repository holds the build scripts, the patches, the entry point, and the numbers.
It does **not** vendor stable-diffusion.cpp, PS5LM or PS5_Vulkan; the scripts fetch them.

## Results

Measured on a PS5 Slim (CFI-1216A), firmware 9.60.

| | CPU (payload) | GPU (native app) |
|---|---|---|
| SD 1.5 Q4_0, 512×512, 20 steps | 1103.4 s | **15.85 s** |
| SDXL Q4_0, 1024×1024, 20 steps | ~2 h (extrapolated) | **71.36 s** |
| Weights | 1496 MB in RAM | 1496 MB in VRAM |

The GPU result is **bit-exact reproducible**: three further runs took 15.85 s each and
produced files with the same SHA-256.

For scale, a Steam Deck (also RDNA2, also RADV) needs **52.44 s** for the same 512×512
image. The PS5's GPU is the stronger part.

![SDXL](images/sdxl.png)

*SDXL, 1024×1024, 71.36 s on the console.*

## Read this before you build: turn flash attention off

**With `--diffusion-fa` the console produces coloured noise instead of an image.**
Without it the result is correct, and leaving it off costs 0.66 s out of 16.

This is a driver bug, not a stable-diffusion.cpp bug. Three measurements pin it down:

| | device / driver | flash attention |
|---|---|---|
| sd.cpp on PS5 | RADV, PS5_Vulkan port | **wrong** |
| sd.cpp on Steam Deck | RADV, stock Mesa 26.2 | correct |
| llama.cpp (PS5LM) on PS5 | RADV, PS5_Vulkan port | correct |

So it is neither "sd.cpp's shaders are broken" nor "flash attention is broken on the PS5
port" — it is the specific shader variants sd.cpp uses and llama.cpp does not:
non-causal attention over image planes rather than causal over tokens, different head
sizes, no GQA.

![All four correct](images/steam-deck-comparison.png)

*Left to right: PS5 CPU, PS5 GPU without flash attention, Steam Deck **with** flash
attention, Steam Deck without. Same prompt, same seed, same binary on both devices.*

A second, independent symptom points the same way. On the PS5 every run logs:

```
conv2d direct auto: Vulkan0 -> off (probe output check failed)
conv3d direct auto: Vulkan0 -> off (probe output check failed)
```

sd.cpp runs a probe, compares the result against the expected one, and switches the
direct convolution path off because it computes **wrong** values. On the Steam Deck the
same probe passes and picks by speed (`im2col 0.508 ms, direct 0.551 ms`). sd.cpp falls
back cleanly, so the image is still correct — but it is a real driver finding.

## Why a native app and not a payload

A payload cannot reach the GPU at all, and this is structural rather than untested:
`elfldr` starts every payload with budget 0 (`sys_budget_set(0)`), so direct memory is
empty and `sceKernelAllocateDirectMemory` returns `0x80020023` — that is
`0x80020000 + EAGAIN`. RADV allocates its device memory exactly there, so
`vkCreateDevice` cannot succeed. etaHEN's jailbreak request changes rights, not budget.

A payload build is still useful as a first step, and the CPU numbers above come from one.
It is limited to about 4–5 GiB and 5 of the 16 logical CPUs.

## Building

You need an x86-64 Linux host (a container is fine), and the scripts fetch everything
else. The whole chain is four steps:

```sh
scripts/setup-container.sh   # Debian trixie + clang 19 + the pinned PS5 payload SDK
scripts/build-radv.sh        # PS5_Vulkan, PS5_Mesa and the RADV driver (~5 min on 4 cores)
scripts/build-vulkan.sh      # stable-diffusion.cpp with the Vulkan backend
scripts/build-title.sh       # link it into a native app and sign it as an fSELF
```

Paths and the console's address come from environment variables; the defaults are in
each script's header.

The result is a title folder — `eboot.bin`, `sce_module/libc.prx`,
`sce_sys/param.json` — that ShadowMountPlus registers when you copy it to
`/data/homebrew/<TITLE_ID>` over FTP.

### Running it

`elfldr` passes no arguments to a payload, and a title has no command line either. So the
program reads its own arguments from a file, one per line, and writes its output to a log
next to it — the same pattern PS5LM uses with `app-args.txt`. See
[`src/ps5_entry.cpp`](src/ps5_entry.cpp), which is placed in front of `main` with
`-Wl,--wrap=main`.

```
/data/sd/args.txt    one argument per line, so prompts need no quoting
/data/sd/run.log     stdout and stderr, line-buffered, readable over FTP while it runs
/data/sd/started     written before anything else, so you can tell a failed start
                     from a failed run
```

## Things that cost us a try

Collected here so the next person does not have to find them again.

**The title must be signed, not just linked.** `ps5-native-tool link` produces an
ordinary ELF. The console only loads an fSELF, and refuses anything else with
`launch_sony_error_0x80020008` — `0x80020000 + 8`, so `ENOEXEC`. The second step is:

```sh
ps5-native-tool self --sign --in eboot.elf --out eboot.bin --magic 0x1D3D154F
```

An fSELF starts with `4F 15 3D 1D`, not with `\177ELF`. `self --inspect` reads the
finished file back and is worth running in the build.

**There is no Vulkan loader on the console.** The public `vk*` entry points are normally
the loader's; RADV as an ICD only exports its internal ones. PS5LM bridges this with one
forwarder from `vkGetInstanceProcAddr` to `vk_icdGetInstanceProcAddr`, which is enough
for llama.cpp because its ggml resolves everything else through the dispatcher. The ggml
fork stable-diffusion.cpp uses calls three more commands directly, so they are undefined
at link time. They exist in the archive under Mesa's internal names with identical
signatures, so aliases do it:

```
--defsym=vkGetInstanceProcAddr=vk_icdGetInstanceProcAddr
--defsym=vkGetDeviceProcAddr=vk_common_GetDeviceProcAddr
--defsym=vkCmdCopyBuffer=vk_common_CmdCopyBuffer
--defsym=vkGetPhysicalDeviceFeatures2=vk_common_GetPhysicalDeviceFeatures2
```

**The fSELF converter insists every symbol resolves.** It stopped at
`_ZTHN2sd15parallel_detail8executorE`, one of two weak TLS initialisers that a payload is
happy to leave dangling. Both belong to constant-initialised `thread_local`s, so there is
nothing to run and an empty body is correct — the same thing PS5LM does for Mesa's
`_ZTH23_mesa_glapi_tls_Context`.

**PS5_Vulkan needs its own SDK fork** as a sibling directory, pinned, next to
`PS5_Vulkan` — `PS5LM`'s build notes mention it in half a sentence. Without it the
dependency step exits with 2. It also looks for the unversioned tool names (`clang`,
`llvm-ar`, `llvm-ranlib`), which Debian does not provide; put `/usr/lib/llvm-19/bin` on
`PATH`.

**Do not let the thread count default.** stable-diffusion.cpp falls back to
`hardware_concurrency() / 2` on this platform, and the console reports 16 logical CPUs
while a payload may use 5. Eight busy threads on five shared CPUs is what shut PS5LM's
console down twice. `patches/0001` derives the count from the affinity mask instead.

## Credits

This stands almost entirely on other people's work.

- **[cobanov/PS5LM](https://github.com/cobanov/PS5LM)** (GPL-3.0-or-later) — llama.cpp on
  the PS5. Its `docs/PORTING.md`, `docs/CONSOLE.md` and `scripts/build-app.sh` are the
  recipe this repository follows; the title build reuses its toolchain wrapper and C++
  runtime. Nearly every console fact quoted above was measured by that project first.
- **[mihawk-99/PS5_Vulkan](https://github.com/mihawk-99/PS5_Vulkan)** (GPL-3.0-or-later)
  — RADV for the PS5, without which none of this exists.
- **[leejet/stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)** (MIT)
  — the thing that does the actual work, and which needed no changes.
- **[ps5-payload-dev/sdk](https://github.com/ps5-payload-dev/sdk)** — the toolchain.

Licensed GPL-3.0-or-later, following PS5LM, from whose build recipe these scripts derive.
