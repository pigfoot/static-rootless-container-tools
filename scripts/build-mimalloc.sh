#!/usr/bin/env bash
# Build mimalloc as static library for musl targets
# Usage: ./scripts/build-mimalloc.sh <target-arch>
# Example: ./scripts/build-mimalloc.sh amd64
#          ./scripts/build-mimalloc.sh arm64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIMALLOC_DIR="$PROJECT_ROOT/build/mimalloc"

# Parse arguments
ARCH="${1:-amd64}"

echo "Building mimalloc for $ARCH (native build)..."

# Check dependencies
if ! command -v clang &> /dev/null; then
  echo "Error: clang not found. Please install Clang with musl support" >&2
  exit 1
fi

if ! command -v cmake &> /dev/null; then
  echo "Error: cmake not found. Please install CMake" >&2
  exit 1
fi

if ! command -v ninja &> /dev/null; then
  echo "Error: ninja not found. Please install Ninja build system" >&2
  exit 1
fi

# Clone mimalloc if not exists
if [[ ! -f "$MIMALLOC_DIR/CMakeLists.txt" ]]; then
  echo "Cloning mimalloc..."
  mkdir -p "$(dirname "$MIMALLOC_DIR")"
  git clone --depth 1 --branch v2.1.7 https://github.com/microsoft/mimalloc.git "$MIMALLOC_DIR"
fi

# Create build directory
BUILD_DIR="$MIMALLOC_DIR/build-$ARCH"
mkdir -p "$BUILD_DIR"

cd "$MIMALLOC_DIR"

# Configure with CMake using Clang as compiler
CLANG_PATH=$(which clang)

cmake -B "$BUILD_DIR" \
  -G "Ninja" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CLANG_PATH" \
  -DCMAKE_C_FLAGS="-static" \
  -DCMAKE_CXX_COMPILER="$(which clang++)" \
  -DCMAKE_CXX_FLAGS="-static" \
  -DMI_BUILD_SHARED=OFF \
  -DMI_BUILD_STATIC=ON \
  -DMI_BUILD_OBJECT=OFF \
  -DMI_BUILD_TESTS=OFF \
  -DMI_INSTALL_TOPLEVEL=ON \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install"

# Build with Ninja
ninja -C "$BUILD_DIR"

# Install to build directory
cmake --install "$BUILD_DIR"

# Verify static library was built (check both lib/ and lib64/)
if [[ -f "$BUILD_DIR/install/lib/libmimalloc.a" ]]; then
  STATIC_LIB="$BUILD_DIR/install/lib/libmimalloc.a"
elif [[ -f "$BUILD_DIR/install/lib64/libmimalloc.a" ]]; then
  STATIC_LIB="$BUILD_DIR/install/lib64/libmimalloc.a"
else
  echo "Error: Static library not found in $BUILD_DIR/install/lib/ or lib64/" >&2
  exit 1
fi

# Show library info
ls -lh "$STATIC_LIB"
file "$STATIC_LIB"

echo "✓ mimalloc built successfully for $ARCH"
echo "  Library: $STATIC_LIB"
echo "  Headers: $BUILD_DIR/install/include/"
