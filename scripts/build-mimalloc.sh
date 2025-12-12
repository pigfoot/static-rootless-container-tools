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

# Map architecture to Zig target triple
case "$ARCH" in
  amd64)
    ZIG_TARGET="x86_64-linux-musl"
    ;;
  arm64)
    ZIG_TARGET="aarch64-linux-musl"
    ;;
  *)
    echo "Error: Unsupported architecture: $ARCH" >&2
    echo "Usage: $0 <amd64|arm64>" >&2
    exit 1
    ;;
esac

echo "Building mimalloc for $ARCH ($ZIG_TARGET)..."

# Check dependencies
if ! command -v zig &> /dev/null; then
  echo "Error: zig not found. Please install Zig 0.11+" >&2
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

# Configure with CMake using Zig as compiler
# Note: CMake needs compiler path and flags separately
ZIG_PATH=$(which zig)

cmake -B "$BUILD_DIR" \
  -G "Ninja" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$ZIG_PATH" \
  -DCMAKE_C_COMPILER_ARG1="cc" \
  -DCMAKE_C_FLAGS="-target $ZIG_TARGET" \
  -DCMAKE_CXX_COMPILER="$ZIG_PATH" \
  -DCMAKE_CXX_COMPILER_ARG1="c++" \
  -DCMAKE_CXX_FLAGS="-target $ZIG_TARGET" \
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
