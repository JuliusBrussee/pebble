#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Shaders/Vulkan"
OUTPUT="${1:-$ROOT/.build/vulkan-shaders}"
mkdir -p "$OUTPUT"

for shader in "$SOURCE"/*.vert "$SOURCE"/*.frag; do
    [ -f "$shader" ] || continue
    name="$(basename "$shader")"
    glslc --target-env=vulkan1.2 -O "$shader" -o "$OUTPUT/$name.spv"
    spirv-val --target-env vulkan1.2 "$OUTPUT/$name.spv"
done

echo "$OUTPUT"
