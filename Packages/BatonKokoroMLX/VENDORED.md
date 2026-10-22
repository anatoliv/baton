# BatonKokoroMLX: what is vendored here

The built-in "This Mac" voices for document clippings: Kokoro-82M on
MLX Swift, in Baton's own process. Mac only. `ios/project.yml` must never list this package, so
the iPhone app links no MLX.

## KokoroSwift (`Sources/KokoroSwift/`)

- **Origin:** [mlalma/kokoro-ios](https://github.com/mlalma/kokoro-ios), tag `1.0.10`, commit
  `9a1e2614e5898106d00eec7fd21ff2fc89d805a6` (2025-12-08).
- **Licence:** MIT, copyright 2025 Lassi Maksimainen. The licence travels with the code in
  `Sources/KokoroSwift/LICENSE`.
- **Why vendored and why this tag:** an internal task (`spikes/kokoro-mlx/RESULTS.md`) measured 1.0.10
  on mlx-swift 0.29.1 at WER 0.4%, the same as the LAN Kokoro server. The latest tag, 1.0.11 on
  mlx-swift 0.30.2, drops or garbles about a quarter of the words (WER 27%, kokoro-ios issue #37
  reports the same). The port has had no commits since January 2026, so Baton carries it.

### What changed from upstream

1. **Static, not `.dynamic`.** Upstream's product is `type: .dynamic`. Two dynamic libraries
   that each embed MLX made SwiftPM refuse the graph (kokoro-ios issue #26). Here the source is
   a plain target inside this package and the product is static.
2. **Resources moved.** Upstream copies `../../Resources/` (`config.json`). Here it is
   `Sources/KokoroSwift/Resources/config.json`, declared `.copy("Resources")`, so
   `Bundle.module.url(forResource: "config", withExtension: "json", subdirectory: "Resources")`
   finds it unchanged.
3. **No speakable text is an error, not a crash.** `KokoroTTS.prepareInputTensors` threw only for
   too many tokens; with zero tokens (text that is all punctuation) it went on to read
   `voice[tokenCount - 1]` at index -1. It now throws `KokoroTTSError.noSpeakableText`, which the
   engine turns into silence. Marked `Baton:` in `TTSEngine/KokoroTTS.swift`.
4. **Swift 5 language mode** for this target only (`swiftLanguageMode(.v5)`), as upstream
   compiled; Baton's own target is Swift 6.

Nothing else is edited. `Tests/`, `README.md`, `.swiftformat` and upstream's `Package.resolved`
are not carried.

## Dependencies, pinned exactly

| Package | Version | Licence |
|---|---|---|
| [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.29.1 (`072b684a`) | MIT |
| [mlalma/MisakiSwift](https://github.com/mlalma/MisakiSwift) | 1.0.5 (`bb5e3e36`), English G2P, 18 MB of lexicons | Apache-2.0 |
| [mlalma/MLXUtilsLibrary](https://github.com/mlalma/MLXUtilsLibrary) | 0.0.6 (`41f6cfd5`), reads `voices.npz` | MIT |

MisakiSwift's own product is still `.dynamic` upstream. Xcode builds the graph (it makes the
shared MLX targets frameworks where needed), and SwiftPM's native build system does too
(`swift build --build-system native`). An MLX upgrade must re-run the spike's WER check
(`spikes/kokoro-mlx/wer.py` against the LAN whisperx) before it lands.

## The model (downloaded on demand, never in the app or in git)

Into `Application Support/Baton/Models/kokoro-mlx/`, excluded from backup, each file checked
against its sha256 before it is kept (`KokoroModelStore`):

| File | Bytes | sha256 | Source |
|---|---|---|---|
| `kokoro-v1_0.safetensors` | 327,115,152 | `4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8` | Hugging Face `prince-canuma/Kokoro-82M` at `e02c9eada7ce7416798af36b190a8a2dd2ecd566` (the sha256 is also Hugging Face's LFS id for it). Apache-2.0, converted from `hexgrad/Kokoro-82M` |
| `voices.npz` | 14,629,684 | `56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f` | `mlalma/KokoroTestApp` `Resources/voices.npz` at `9dcd3b06468a3c1ecee6d09a33ca687c8e708566` (git blob `8e8efa95`), 28 English voices. Apache-2.0, from Kokoro-82M |

341,744,836 bytes in all, shown in Settings as 342 MB.

## MLX's Metal shaders: two ways to build

MLX's GPU kernels are `.metal` sources compiled into a metallib. Compiling them needs Xcode's
**Metal Toolchain** component, which Xcode 27 does not install by default
(`xcodebuild -showComponent MetalToolchain`; `xcrun metal --version` fails without it).

1. **With the Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`, a one-time,
   machine-wide install): a normal `xcodebuild` compiles MLX's shaders into
   `Baton.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, and
   the app target's "Bundle MLX shaders" phase leaves it as built (its log says so).
2. **Without it** (this Mac until the toolchain was installed on 2026-10-15): the build passes
   `EXCLUDED_SOURCE_FILE_NAMES=*.metal` (printed by `scripts/mlx-metal-build-settings.sh`, which
   `scripts/test.sh` uses), and the "Bundle MLX shaders" phase copies MLX's published metallib
   of the same version into the same place. That file is `mlx/lib/mlx.metallib` from PyPI's
   `mlx-metal` 0.29.1 wheel (`mlx_metal-0.29.1-py3-none-macosx_15_0_arm64.whl`, sha256
   `ebd9ba8e83213f929663b92b8065b451a4276c7002ed83eae0fc8dde721c50c5`), 101,233,987 bytes,
   sha256 in `Metal/mlx.metallib.sha256`. It is too big for git (GitHub refuses files over
   100 MB), so `scripts/fetch-mlx-metallib.sh` fetches it into `Metal/mlx.metallib`
   (gitignored), checking both hashes; the build phase checks it again.

With neither, the app still builds and runs: `KokoroMLXRuntime.metalLibraryURL()` finds no
metallib, the engine is never registered, and Settings says the voices are not available in this
build. (Touching MLX's GPU without a metallib aborts the process, so nothing does.)

**Release (owner decision, 2026-10-15):** the release Mac has the Metal Toolchain installed and
`scripts/publish.sh` stays unchanged, so a release compiles MLX's shaders itself (path 1). The
prebuilt metallib (path 2) is only the fallback for a Mac without the toolchain;
`scripts/mlx-metal-build-settings.sh` prints nothing once `xcrun metal` works, so `scripts/test.sh`
then builds the normal way too.

**The two metallibs differ.** mlx-swift builds MLX in its JIT mode: Xcode compiles 9 `.metal`
sources into a 2,918,284-byte `default.metallib` (sha256 `f900edd4…a048c3dd`) and MLX compiles
the remaining kernels from source at run time, the first time each is used. The PyPI metallib is
MLX's full precompiled library (101,233,987 bytes). Both render correctly: the real-render test
passed on each, with WER 0.4% on the Austen passage both times. The compiled one adds a little
to the first render in a process (shader compilation) and saves about 98 MB.

A Release build of the Baton scheme with the toolchain (`xcodebuild -configuration Release`,
2026-10-15, universal x86_64 and arm64): 147 MB installed, 42 MB zipped, of which
`Cmlx.framework` is 35 MB. MLX runs on Apple silicon only, so on an Intel Mac the app never
touches it and Settings says the voices need Apple silicon.
