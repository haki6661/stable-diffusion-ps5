// Entry point for the PS5 build of stable-diffusion.cpp.
//
// Placed in front of sd-cli's own main with `-Wl,--wrap=main`. It solves three
// things that work differently on the console:
//
//  1. **Arguments.** elfldr documents no way to pass arguments to a payload, and
//     a title has no command line either. So the program fetches them itself,
//     from `args.txt`, one argument per line — the pattern PS5LM uses with
//     `app-args.txt`. Any real argv entries are appended after them.
//  2. **Output.** There is no terminal; stdout and stderr go nowhere. Both end
//     up in `run.log`, line-buffered, so the progress can be read over FTP while
//     the run is still going.
//  3. **Leaving.** After main returns, the SDK's start code calls Sony's exit(),
//     which runs every static destructor while other threads may still be alive —
//     that is where `[SceLibc] A heap error is detected` comes from. PS5LM leaves
//     its tools through `_Exit` for that reason, and so does this.
//
// A `started` file is written before anything can go wrong, which separates a
// failed start from a failed run.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
// Where args.txt, run.log and started live. Override at build time with
// -DSD_PS5_DIR="\"/data/elsewhere\"".
#ifndef SD_PS5_DIR
#define SD_PS5_DIR "/data/sd"
#endif

std::string path_in_dir(const char* name) {
    return std::string(SD_PS5_DIR) + "/" + name;
}
}  // namespace

// The TLS initialisers for sd::parallel_detail's thread_locals:
//
//     thread_local ParallelExecutor* executor = nullptr;
//     thread_local bool              active   = false;
//
// Both are constant-initialised, so there is nothing to run, and clang emits only
// a weak reference. A payload is happy to leave that dangling. The fSELF converter
// for a native app is not: it stops with "no public SDK stub exports required
// symbol ...". An empty body is the correct answer — PS5LM does the same for
// Mesa's _ZTH23_mesa_glapi_tls_Context.
//
// The names are deliberately written out mangled: extern "C" makes the linker see
// exactly this string.
extern "C" void _ZTHN2sd15parallel_detail8executorE(void) {}
extern "C" void _ZTHN2sd15parallel_detail6activeE(void) {}

extern "C" int __real_main(int argc, char** argv);

extern "C" int __wrap_main(int argc, char** argv) {
    if (FILE* marker = std::fopen(path_in_dir("started").c_str(), "w")) {
        std::fputs("sd-cli started\n", marker);
        std::fclose(marker);
    }

    const std::string log = path_in_dir("run.log");
    if (std::freopen(log.c_str(), "w", stdout) != nullptr) {
        std::setvbuf(stdout, nullptr, _IOLBF, 0);
    }
    if (std::freopen(log.c_str(), "a", stderr) != nullptr) {
        std::setvbuf(stderr, nullptr, _IOLBF, 0);
    }

    std::vector<std::string> args;
    args.push_back(argc > 0 && argv != nullptr && argv[0] != nullptr ? argv[0] : "sd-cli");

    const std::string args_file = path_in_dir("args.txt");
    if (FILE* f = std::fopen(args_file.c_str(), "r")) {
        char line[4096];
        while (std::fgets(line, sizeof line, f) != nullptr) {
            size_t n = std::strlen(line);
            while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
                line[--n] = '\0';
            }
            if (n > 0) {
                args.push_back(line);
            }
        }
        std::fclose(f);
    } else {
        std::fprintf(stderr, "ps5_entry: cannot read %s, using argv only\n", args_file.c_str());
    }

    for (int i = 1; i < argc; ++i) {
        if (argv[i] != nullptr) {
            args.push_back(argv[i]);
        }
    }

    std::fprintf(stderr, "ps5_entry: %zu arguments\n", args.size() - 1);
    for (size_t i = 1; i < args.size(); ++i) {
        std::fprintf(stderr, "ps5_entry:   [%zu] %s\n", i, args[i].c_str());
    }
    std::fflush(stderr);

    std::vector<char*> argv_out;
    argv_out.reserve(args.size() + 1);
    for (std::string& a : args) {
        argv_out.push_back(const_cast<char*>(a.c_str()));
    }
    argv_out.push_back(nullptr);

    const int rc = __real_main(static_cast<int>(argv_out.size()) - 1, argv_out.data());

    std::fprintf(stderr, "ps5_entry: main returned %d\n", rc);
    std::fflush(nullptr);
    _Exit(rc);
}
