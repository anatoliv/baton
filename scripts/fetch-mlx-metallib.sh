#!/bin/zsh
# Puts MLX's prebuilt Metal shaders where the Mac app's "Bundle MLX shaders" build phase finds them
# (TBX-10854). Only needed on a Mac without Xcode's Metal Toolchain component; with it, Xcode
# compiles MLX's shaders itself and the build phase leaves them alone.
#
# The file is mlx/lib/mlx.metallib from PyPI's mlx-metal 0.29.1 wheel (MIT, ml-explore), the same
# MLX version that mlx-swift 0.29.1 builds. Both the wheel and the metallib are checked by sha256.
#
#   scripts/fetch-mlx-metallib.sh                 download the wheel from PyPI, extract, check
#   MLX_METALLIB=<path> scripts/fetch-mlx-metallib.sh   copy a metallib you already have, check
set -euo pipefail
ROOT="${0:A:h:h}"
DEST="$ROOT/Packages/BatonKokoroMLX/Metal/mlx.metallib"
WANT="$(cat "$ROOT/Packages/BatonKokoroMLX/Metal/mlx.metallib.sha256")"
WHEEL_URL="https://files.pythonhosted.org/packages/64/7f/294c8cac159661d732e5c01f841e07edfd2ea90651d39faca6579b3cdbf4/mlx_metal-0.29.1-py3-none-macosx_15_0_arm64.whl"
WHEEL_SHA="ebd9ba8e83213f929663b92b8065b451a4276c7002ed83eae0fc8dde721c50c5"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [[ -f "$DEST" && "$(sha "$DEST")" == "$WANT" ]]; then
  echo "MLX metallib already in place: $DEST"; exit 0
fi

if [[ -n "${MLX_METALLIB:-}" ]]; then
  [[ "$(sha "$MLX_METALLIB")" == "$WANT" ]] || { echo "refused: $MLX_METALLIB is not mlx-metal 0.29.1's mlx.metallib" >&2; exit 1; }
  cp "$MLX_METALLIB" "$DEST.tmp" && mv "$DEST.tmp" "$DEST"
  echo "copied: $DEST"; exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/dl" "$WORK/x"
curl -fL --retry 2 -o "$WORK/dl/mlx_metal.whl" "$WHEEL_URL"
[[ "$(sha "$WORK/dl/mlx_metal.whl")" == "$WHEEL_SHA" ]] || { echo "refused: the wheel's sha256 is wrong" >&2; exit 1; }
unzip -q -j "$WORK/dl/mlx_metal.whl" 'mlx/lib/mlx.metallib' -d "$WORK/x"
[[ "$(sha "$WORK/x/mlx.metallib")" == "$WANT" ]] || { echo "refused: the metallib's sha256 is wrong" >&2; exit 1; }
mv "$WORK/x/mlx.metallib" "$DEST"
echo "fetched: $DEST"
