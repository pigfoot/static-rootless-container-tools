#!/usr/bin/env bash
# Build static container tools with Zig cross-compiler
# Usage: ./scripts/build-tool.sh <tool> [arch] [variant]
# Example: ./scripts/build-tool.sh podman amd64 full
#          ./scripts/build-tool.sh buildah arm64
#          ./scripts/build-tool.sh skopeo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
TOOL="${1:-}"
ARCH="${2:-amd64}"
VARIANT="${3:-}"

if [[ -z "$TOOL" ]]; then
  echo "Error: Tool name required" >&2
  echo "Usage: $0 <podman|buildah|skopeo> [amd64|arm64] [full|minimal]" >&2
  exit 1
fi

# Validate tool
case "$TOOL" in
  podman|buildah|skopeo)
    ;;
  *)
    echo "Error: Unsupported tool: $TOOL" >&2
    echo "Supported: podman, buildah, skopeo" >&2
    exit 1
    ;;
esac

# Validate architecture
case "$ARCH" in
  amd64|arm64)
    ;;
  *)
    echo "Error: Unsupported architecture: $ARCH" >&2
    echo "Supported: amd64, arm64" >&2
    exit 1
    ;;
esac

# Set variant for podman (default: full)
if [[ "$TOOL" == "podman" && -z "$VARIANT" ]]; then
  VARIANT="full"
fi

# Map architecture to Zig/Go targets
case "$ARCH" in
  amd64)
    ZIG_TARGET="x86_64-linux-musl"
    GOARCH="amd64"
    ;;
  arm64)
    ZIG_TARGET="aarch64-linux-musl"
    GOARCH="arm64"
    ;;
esac

echo "========================================"
echo "Building: $TOOL"
echo "Architecture: $ARCH ($ZIG_TARGET)"
[[ -n "$VARIANT" ]] && echo "Variant: $VARIANT"
echo "========================================"

# Check dependencies
if ! command -v zig &> /dev/null; then
  echo "Error: zig not found. Please install Zig 0.11+" >&2
  exit 1
fi

if ! command -v go &> /dev/null; then
  echo "Error: go not found. Please install Go 1.21+" >&2
  exit 1
fi

if ! command -v gh &> /dev/null; then
  echo "Error: gh not found. Please install GitHub CLI" >&2
  exit 1
fi

# Setup build directories
BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH"
INSTALL_DIR="$BUILD_DIR/install"
SRC_DIR="$BUILD_DIR/src"

mkdir -p "$BUILD_DIR" "$INSTALL_DIR/bin" "$SRC_DIR"

# Set upstream repository
UPSTREAM_REPO="containers/$TOOL"

# Get version (from env or fetch latest)
if [[ -z "${VERSION:-}" ]]; then
  echo "Fetching latest $TOOL version..."
  VERSION=$(gh release list --repo "$UPSTREAM_REPO" --limit 1 --exclude-drafts --exclude-pre-releases | head -1 | awk '{print $1}')

  if [[ -z "$VERSION" ]]; then
    echo "Error: Could not fetch latest version for $TOOL" >&2
    exit 1
  fi
  echo "Latest version: $VERSION"
else
  echo "Using specified version: $VERSION"
fi

# Clone/update source with retry
RETRY_COUNT=3
RETRY_DELAY=5

if [[ -d "$SRC_DIR/$TOOL" ]]; then
  echo "Updating existing source..."
  cd "$SRC_DIR/$TOOL"

  for attempt in $(seq 1 $RETRY_COUNT); do
    if git fetch --tags; then
      break
    else
      if [[ $attempt -lt $RETRY_COUNT ]]; then
        echo "Warning: git fetch failed (attempt $attempt/$RETRY_COUNT), retrying in ${RETRY_DELAY}s..." >&2
        sleep $RETRY_DELAY
      else
        echo "Error: git fetch failed after $RETRY_COUNT attempts" >&2
        exit 1
      fi
    fi
  done

  git checkout "$VERSION"
else
  echo "Cloning source..."

  for attempt in $(seq 1 $RETRY_COUNT); do
    if git clone --depth 1 --branch "$VERSION" "https://github.com/$UPSTREAM_REPO.git" "$SRC_DIR/$TOOL"; then
      break
    else
      if [[ $attempt -lt $RETRY_COUNT ]]; then
        echo "Warning: git clone failed (attempt $attempt/$RETRY_COUNT), retrying in ${RETRY_DELAY}s..." >&2
        sleep $RETRY_DELAY
        rm -rf "$SRC_DIR/$TOOL"  # Clean up partial clone
      else
        echo "Error: git clone failed after $RETRY_COUNT attempts" >&2
        exit 1
      fi
    fi
  done

  cd "$SRC_DIR/$TOOL"
fi

# Build mimalloc for this architecture if not already built
MIMALLOC_INSTALL="$PROJECT_ROOT/build/mimalloc/build-$ARCH/install"
if [[ -f "$MIMALLOC_INSTALL/lib/libmimalloc.a" ]]; then
  MIMALLOC_DIR="$MIMALLOC_INSTALL"
  MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib"
elif [[ -f "$MIMALLOC_INSTALL/lib64/libmimalloc.a" ]]; then
  MIMALLOC_DIR="$MIMALLOC_INSTALL"
  MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib64"
else
  echo "Building mimalloc for $ARCH..."
  "$SCRIPT_DIR/build-mimalloc.sh" "$ARCH"
  # Re-check after building
  if [[ -f "$MIMALLOC_INSTALL/lib64/libmimalloc.a" ]]; then
    MIMALLOC_DIR="$MIMALLOC_INSTALL"
    MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib64"
  else
    MIMALLOC_DIR="$MIMALLOC_INSTALL"
    MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib"
  fi
fi

# Setup Zig cross-compilation environment
export CC="zig cc -target $ZIG_TARGET"
export CXX="zig c++ -target $ZIG_TARGET"
export AR="zig ar"
export RANLIB="zig ranlib"

# Setup CGO for Go build
export CGO_ENABLED=1
export GOOS=linux
export GOARCH="$GOARCH"
export CGO_CFLAGS="-I$MIMALLOC_DIR/include"
export CGO_LDFLAGS="-L$MIMALLOC_LIB_DIR -lmimalloc -static"

# Build tags for static linking
BUILD_TAGS="containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper"

echo "Building $TOOL binary..."
go build \
  -tags "$BUILD_TAGS" \
  -ldflags "-linkmode external -extldflags '-static' -s -w" \
  -o "$INSTALL_DIR/bin/$TOOL" \
  ./cmd/$TOOL

# Verify binary is static
echo "Verifying static binary..."
if ldd "$INSTALL_DIR/bin/$TOOL" 2>&1 | grep -q "not a dynamic executable"; then
  echo "✓ Binary is truly static"
else
  echo "⚠ Warning: Binary may have dynamic dependencies:"
  ldd "$INSTALL_DIR/bin/$TOOL" || true
fi

# For podman-full, build runtime components
if [[ "$TOOL" == "podman" && "$VARIANT" == "full" ]]; then
  echo "========================================"
  echo "Building runtime components for podman-full..."
  echo "========================================"

  # Array of runtime components with their repos
  declare -A COMPONENTS=(
    [crun]="containers/crun"
    [conmon]="containers/conmon"
    [fuse-overlayfs]="containers/fuse-overlayfs"
    [netavark]="containers/netavark"
    [aardvark-dns]="containers/aardvark-dns"
    [pasta]="passt-dev/passt"
    [catatonit]="openSUSE/catatonit"
  )

  for component in "${!COMPONENTS[@]}"; do
    echo "----------------------------------------"
    echo "Building: $component"
    echo "----------------------------------------"

    COMP_REPO="${COMPONENTS[$component]}"
    COMP_VERSION=$(gh release list --repo "$COMP_REPO" --limit 1 --exclude-drafts --exclude-pre-releases | head -1 | awk '{print $1}')

    if [[ -z "$COMP_VERSION" ]]; then
      echo "⚠ Warning: Could not fetch version for $component, skipping..."
      continue
    fi

    echo "Version: $COMP_VERSION"

    COMP_SRC="$SRC_DIR/$component"
    if [[ -d "$COMP_SRC" ]]; then
      cd "$COMP_SRC"
      git fetch --tags
      git checkout "$COMP_VERSION" 2>/dev/null || git checkout "v$COMP_VERSION" 2>/dev/null || echo "Using existing checkout"
    else
      git clone --depth 1 --branch "$COMP_VERSION" "https://github.com/$COMP_REPO.git" "$COMP_SRC" 2>/dev/null || \
      git clone --depth 1 --branch "v$COMP_VERSION" "https://github.com/$COMP_REPO.git" "$COMP_SRC" || {
        echo "⚠ Warning: Failed to clone $component, skipping..."
        continue
      }
      cd "$COMP_SRC"
    fi

    # Build based on language/build system
    case "$component" in
      netavark|aardvark-dns)
        # Rust components
        if ! command -v cargo &> /dev/null; then
          echo "⚠ Warning: cargo not found, skipping $component"
          continue
        fi
        cargo build --release --target "$ZIG_TARGET" 2>/dev/null || {
          echo "⚠ Warning: Failed to build $component, skipping..."
          continue
        }
        cp "target/$ZIG_TARGET/release/$component" "$INSTALL_DIR/bin/" 2>/dev/null || echo "⚠ Could not copy binary"
        ;;

      crun|conmon|fuse-overlayfs|catatonit)
        # C components with autotools/make
        if [[ -f "./autogen.sh" ]]; then
          ./autogen.sh || true
        fi
        if [[ -f "./configure" ]]; then
          ./configure --host="$ZIG_TARGET" --prefix="$INSTALL_DIR" --enable-static --disable-shared 2>/dev/null || {
            echo "⚠ Warning: Configure failed for $component, skipping..."
            continue
          }
        fi
        make clean 2>/dev/null || true
        make -j$(nproc) 2>/dev/null || {
          echo "⚠ Warning: Build failed for $component, skipping..."
          continue
        }
        make install 2>/dev/null || cp "$component" "$INSTALL_DIR/bin/" 2>/dev/null || echo "⚠ Could not install $component"
        ;;

      pasta)
        # pasta has custom Makefile
        make clean 2>/dev/null || true
        make -j$(nproc) 2>/dev/null || {
          echo "⚠ Warning: Build failed for pasta, skipping..."
          continue
        }
        cp pasta "$INSTALL_DIR/bin/" 2>/dev/null || echo "⚠ Could not copy pasta binary"
        ;;
    esac

    if [[ -f "$INSTALL_DIR/bin/$component" ]]; then
      echo "✓ $component built successfully"
    else
      echo "⚠ $component binary not found (may have failed)"
    fi
  done
fi

# Show final binary sizes
echo "========================================"
echo "Build complete!"
echo "========================================"
echo "Binaries in: $INSTALL_DIR/bin/"
ls -lh "$INSTALL_DIR/bin/"

echo ""
echo "Version: $VERSION"
echo "Output directory: $INSTALL_DIR"
