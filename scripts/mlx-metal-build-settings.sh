#!/bin/zsh
# Prints the xcodebuild setting a Mac build of Baton needs for MLX's shaders (TBX-10854), or
# nothing. With Xcode's Metal Toolchain component installed, Xcode compiles MLX's .metal sources
# and nothing is needed. Without it, compiling them fails, so the build leaves them out and the
# app target's "Bundle MLX shaders" phase supplies MLX's published metallib instead
# (scripts/fetch-mlx-metallib.sh). Usage: xcodebuild ... $(scripts/mlx-metal-build-settings.sh)
if ! xcrun metal --version >/dev/null 2>&1; then
  print -r -- 'EXCLUDED_SOURCE_FILE_NAMES=*.metal'
fi
