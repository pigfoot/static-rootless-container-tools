#!/usr/bin/env bash
# Build static container tools with clang + musl
# Usage: ./scripts/build-tool.sh <tool> [arch] [variant]
# Example: ./scripts/build-tool.sh podman amd64 full
#          ./scripts/build-tool.sh podman amd64 default
#          ./scripts/build-tool.sh podman amd64 standalone
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
  echo "Usage: $0 <podman|buildah|skopeo> [amd64|arm64] [standalone|default|full]" >&2
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

# Set variant (default: "default" for all tools)
if [[ -z "$VARIANT" ]]; then
  VARIANT="default"
fi

# Validate variant
case "$VARIANT" in
  standalone|default|full)
    ;;
  *)
    echo "Error: Unsupported variant: $VARIANT" >&2
    echo "Supported: standalone (binary only), default (+ crun/conmon), full (all components)" >&2
    exit 1
    ;;
esac

# Map architecture to Go arch
case "$ARCH" in
  amd64)
    GOARCH="amd64"
    ;;
  arm64)
    GOARCH="arm64"
    ;;
esac

echo "========================================"
echo "Building: $TOOL"
echo "Architecture: $ARCH (native build)"
[[ -n "$VARIANT" ]] && echo "Variant: $VARIANT"
echo "========================================"

# Check dependencies
if ! command -v clang &> /dev/null; then
  echo "Error: clang not found. Please install clang and musl-dev" >&2
  echo "  Ubuntu/Debian: apt-get install clang musl-dev musl-tools" >&2
  echo "  Gentoo: emerge sys-devel/clang dev-libs/musl" >&2
  exit 1
fi

if ! command -v go &> /dev/null; then
  echo "Error: go not found. Please install Go 1.21+" >&2
  exit 1
fi

if ! command -v curl &> /dev/null; then
  echo "Error: curl not found. Please install curl" >&2
  exit 1
fi

# Optional dependencies (warnings only)
# Check for dependencies needed by default and full variants
if [[ "$VARIANT" != "standalone" ]]; then
  # Check for autoconf/automake (needed for libseccomp source build for crun)
  if [[ "$TOOL" == "podman" || "$TOOL" == "buildah" ]]; then
    if ! command -v autoconf &> /dev/null || ! command -v automake &> /dev/null; then
      echo "Warning: autoconf/automake not found. libseccomp source build may fail (crun will fail)." >&2
      echo "  Install with: apt-get install autoconf automake libtool (Debian/Ubuntu)" >&2
      echo "               emerge sys-devel/autoconf sys-devel/automake (Gentoo)" >&2
    fi
  fi
fi

# Check for dependencies only needed by full variant
if [[ "$VARIANT" == "full" ]]; then
  if [[ "$TOOL" == "podman" ]]; then
    # Check for protoc (needed for Rust components like netavark)
    if ! command -v protoc &> /dev/null; then
      echo "Warning: protoc not found. Rust components (netavark) may fail to build." >&2
      echo "  Install with: apt-get install protobuf-compiler (Debian/Ubuntu)" >&2
      echo "               emerge dev-libs/protobuf (Gentoo)" >&2
    fi

    # Check for Rust/Cargo (needed for netavark, aardvark-dns)
    if ! command -v cargo &> /dev/null; then
      echo "Warning: cargo not found. Rust components will be skipped." >&2
      echo "  Install Rust from: https://rustup.rs/" >&2
    fi
  fi
fi

# Setup build directories
BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH"
INSTALL_DIR="$BUILD_DIR/install"
SRC_DIR="$BUILD_DIR/src"

mkdir -p "$BUILD_DIR" "$INSTALL_DIR/bin" "$SRC_DIR"

# Initialize LDFLAGS (will be extended during build)
LDFLAGS="${LDFLAGS:-}"

# Set upstream repository
UPSTREAM_REPO="containers/$TOOL"

# Get version (from env or fetch latest)
if [[ -z "${VERSION:-}" ]]; then
  echo "Fetching latest $TOOL version from GitHub API..."
  # Use GitHub API with authentication if available to avoid rate limiting
  if [[ -n "$GITHUB_TOKEN" ]]; then
    VERSION=$(curl -sk -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/${UPSTREAM_REPO}/releases" \
      | sed -En '/"tag_name"/ s#.*"([^"]+)".*#\1#p' \
      | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      | head -1)
  else
    VERSION=$(curl -sk "https://api.github.com/repos/${UPSTREAM_REPO}/releases" \
      | sed -En '/"tag_name"/ s#.*"([^"]+)".*#\1#p' \
      | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      | head -1)
  fi

  if [[ -z "$VERSION" ]]; then
    echo "⚠ Warning: Could not fetch version from releases, trying tags..."
    # Fallback: try tags endpoint
    if [[ -n "$GITHUB_TOKEN" ]]; then
      VERSION=$(curl -sk -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/${UPSTREAM_REPO}/tags" \
        | sed -En '/"name"/ s#.*"([^"]+)".*#\1#p' \
        | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | head -1)
    else
      VERSION=$(curl -sk "https://api.github.com/repos/${UPSTREAM_REPO}/tags" \
        | sed -En '/"name"/ s#.*"([^"]+)".*#\1#p' \
        | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | head -1)
    fi
  fi

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

# Setup clang + musl native build environment
export CC="clang"
export CXX="clang++"
export AR="ar"
export RANLIB="ranlib"

# Setup CGO for Go build
export CGO_ENABLED=1
export GOOS=linux
export GOARCH="$GOARCH"
export CGO_CFLAGS="-I$MIMALLOC_DIR/include"
# NOTE: mimalloc linking moved to -extldflags to avoid duplication
export CGO_LDFLAGS=""

# Build tags for static linking
BUILD_TAGS="containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper"

echo "Building $TOOL binary..."
# Use --whole-archive in extldflags to force mimalloc's malloc to override musl malloc
# This ensures mimalloc is only linked once (not repeated for each CGO package)
# Build extldflags with expanded variables
EXTLDFLAGS="-static -L${MIMALLOC_LIB_DIR} -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread"

echo "Linking with mimalloc from: $MIMALLOC_LIB_DIR"
echo "EXTLDFLAGS: $EXTLDFLAGS"

go build \
  -tags "$BUILD_TAGS" \
  -ldflags "-linkmode external -extldflags \"${EXTLDFLAGS}\" -s -w" \
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

# Note: Verify mimalloc usage at runtime with:
# MIMALLOC_VERBOSE=1 ./$TOOL --version
# If mimalloc is active, it will show initialization messages and configuration

# For podman, extract helper binaries
if [[ "$TOOL" == "podman" ]]; then
  echo "========================================"
  echo "Extracting podman helper binaries..."
  echo "========================================"

  # Build rootlessport (critical for port forwarding)
  echo "Building rootlessport..."
  CGO_ENABLED=0 make bin/rootlessport \
    BUILDFLAGS=" -mod=vendor -ldflags=\"-s -w -extldflags '-static'\""

  mkdir -p "$INSTALL_DIR/lib/podman"
  mv bin/rootlessport "$INSTALL_DIR/lib/podman/"

  if ldd "$INSTALL_DIR/lib/podman/rootlessport" 2>&1 | grep -q "not a dynamic executable"; then
    echo "✓ rootlessport is static"
  else
    echo "⚠ Warning: rootlessport may have dynamic dependencies"
  fi

  # Build quadlet (systemd generator for .container files)
  echo "Building quadlet..."
  # Custom linker flag to set podman binary directory
  export LDFLAGS_QUADLET="-X github.com/containers/podman/v5/pkg/systemd/quadlet._binDir=/usr/local/bin"

  CGO_ENABLED=0 make bin/quadlet \
    LDFLAGS_PODMAN="-s -w -extldflags '-static' ${LDFLAGS_QUADLET}" \
    BUILDTAGS="$BUILD_TAGS"

  mkdir -p "$INSTALL_DIR/libexec/podman"
  mv bin/quadlet "$INSTALL_DIR/libexec/podman/"

  if ldd "$INSTALL_DIR/libexec/podman/quadlet" 2>&1 | grep -q "not a dynamic executable"; then
    echo "✓ quadlet is static"
  else
    echo "⚠ Warning: quadlet may have dynamic dependencies"
  fi
fi

# Build runtime components based on variant
# default: crun + conmon (+ fuse-overlayfs for buildah)
# full: all components
if [[ "$VARIANT" != "standalone" ]]; then
  echo "========================================"
  echo "Building runtime components for $TOOL-$VARIANT..."
  echo "========================================"

  # Determine which components to build based on tool and variant
  # This MUST be before libseccomp build check
  COMPONENTS_TO_BUILD=()

  if [[ "$TOOL" == "podman" ]]; then
    if [[ "$VARIANT" == "default" ]]; then
      COMPONENTS_TO_BUILD=(crun conmon)
    elif [[ "$VARIANT" == "full" ]]; then
      COMPONENTS_TO_BUILD=(crun conmon fuse-overlayfs netavark aardvark-dns pasta catatonit)
    fi
  elif [[ "$TOOL" == "buildah" ]]; then
    if [[ "$VARIANT" == "default" ]]; then
      COMPONENTS_TO_BUILD=(crun conmon)
    elif [[ "$VARIANT" == "full" ]]; then
      COMPONENTS_TO_BUILD=(crun conmon fuse-overlayfs)
    fi
  elif [[ "$TOOL" == "skopeo" ]]; then
    # skopeo doesn't need runtime components (doesn't run containers)
    COMPONENTS_TO_BUILD=()
  fi

  echo "Components to build: ${COMPONENTS_TO_BUILD[*]:-none}"
  echo ""

  # Build libseccomp from source (required for crun)
  # Reason: Ensures compatibility with Ubuntu 24.04 and musl libc static linking
  # Only build if crun is in the components list
  if [[ " ${COMPONENTS_TO_BUILD[*]} " =~ " crun " ]]; then
    echo "----------------------------------------"
    echo "Building: libseccomp (dependency for crun)"
    echo "----------------------------------------"

    LIBSECCOMP_VERSION="v2.5.5"
    LIBSECCOMP_SRC="$SRC_DIR/libseccomp"
    LIBSECCOMP_INSTALL="$BUILD_DIR/libseccomp-install"

  if [[ ! -d "$LIBSECCOMP_SRC" ]]; then
    echo "Fetching libseccomp $LIBSECCOMP_VERSION..."
    git clone --depth 1 --branch "$LIBSECCOMP_VERSION" \
      https://github.com/seccomp/libseccomp "$LIBSECCOMP_SRC" || {
      echo "⚠ Warning: Failed to clone libseccomp, crun may fail..."
    }
  fi

  if [[ -d "$LIBSECCOMP_SRC" ]]; then
    cd "$LIBSECCOMP_SRC"

    # Clean previous build
    make distclean 2>/dev/null || true

    # Generate configure script
    if [[ ! -f configure ]]; then
      ./autogen.sh || {
        echo "⚠ Warning: autogen.sh failed for libseccomp"
      }
    fi

    # Configure for static build
    ./configure \
      --prefix="$LIBSECCOMP_INSTALL" \
      --enable-static \
      --disable-shared \
      CC="clang" \
      CFLAGS="-O2 -fPIC" || {
      echo "⚠ Warning: configure failed for libseccomp"
    }

    # Build and install
    make -j$(nproc) || {
      echo "⚠ Warning: make failed for libseccomp"
    }

    make install || {
      echo "⚠ Warning: make install failed for libseccomp"
    }

    if [[ -f "$LIBSECCOMP_INSTALL/lib/libseccomp.a" ]]; then
      echo "✓ libseccomp built successfully"
      # Export PKG_CONFIG_PATH so pkg-config can find it
      export PKG_CONFIG_PATH="$LIBSECCOMP_INSTALL/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      # Export CPPFLAGS and LDFLAGS so configure scripts can find headers and libs directly
      export CPPFLAGS="-I$LIBSECCOMP_INSTALL/include${CPPFLAGS:+ $CPPFLAGS}"
      export LDFLAGS="-L$LIBSECCOMP_INSTALL/lib${LDFLAGS:+ $LDFLAGS}"
      # Export CGO flags for compatibility (reserved for future use)
      export CGO_CFLAGS="$CGO_CFLAGS -I$LIBSECCOMP_INSTALL/include"
      export CGO_LDFLAGS="$CGO_LDFLAGS -L$LIBSECCOMP_INSTALL/lib"
      echo "  PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
      echo "  CPPFLAGS=$CPPFLAGS"
      echo "  LDFLAGS=$LDFLAGS"
      echo "  CGO_CFLAGS=$CGO_CFLAGS"
      echo "  CGO_LDFLAGS=$CGO_LDFLAGS"
    else
      echo "⚠ Warning: libseccomp.a not found, crun may fail"
    fi
  fi
  fi  # End of libseccomp build (only if crun needed)

  # Array of runtime components with their repos
  # Note: runc removed - not in original spec, crun is the default OCI runtime
  declare -A COMPONENTS=(
    [crun]="containers/crun"
    [conmon]="containers/conmon"
    [fuse-overlayfs]="containers/fuse-overlayfs"
    [netavark]="containers/netavark"
    [aardvark-dns]="containers/aardvark-dns"
    [pasta]="passt-dev/passt"
    [catatonit]="openSUSE/catatonit"
  )

  # COMPONENTS_TO_BUILD is already defined above (before libseccomp build)
  # Build each component in the list
  for component in "${COMPONENTS_TO_BUILD[@]}"; do
    echo "----------------------------------------"
    echo "Building: $component"
    echo "----------------------------------------"

    COMP_REPO="${COMPONENTS[$component]}"

    # Special handling for pasta (not on GitHub)
    if [[ "$component" == "pasta" ]]; then
      # pasta uses git://passt.top/passt
      # Get latest tag from git repo directly
      COMP_VERSION=$(git ls-remote --tags git://passt.top/passt 2>/dev/null | grep -v '\^{}' | tail -1 | awk '{print $2}' | sed 's#refs/tags/##')
      if [[ -z "$COMP_VERSION" ]]; then
        echo "⚠ Warning: Could not fetch pasta version, using hardcoded version"
        COMP_VERSION="2025_12_10.d04c480"
      fi
    else
      # GitHub repos: use API to get latest stable release tag
      # Use authentication if available to avoid rate limiting
      echo "Fetching version from GitHub API..."
      if [[ -n "$GITHUB_TOKEN" ]]; then
        COMP_VERSION=$(curl -sk -H "Authorization: Bearer $GITHUB_TOKEN" \
          "https://api.github.com/repos/${COMP_REPO}/releases" \
          | sed -En '/"tag_name"/ s#.*"([^"]+)".*#\1#p' \
          | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
          | head -1)
      else
        COMP_VERSION=$(curl -sk "https://api.github.com/repos/${COMP_REPO}/releases" \
          | sed -En '/"tag_name"/ s#.*"([^"]+)".*#\1#p' \
          | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
          | head -1)
      fi

      if [[ -z "$COMP_VERSION" ]]; then
        echo "⚠ Warning: Could not fetch version for $component from releases, trying tags..."
        # Fallback: try tags endpoint
        if [[ -n "$GITHUB_TOKEN" ]]; then
          COMP_VERSION=$(curl -sk -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/repos/${COMP_REPO}/tags" \
            | sed -En '/"name"/ s#.*"([^"]+)".*#\1#p' \
            | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
            | head -1)
        else
          COMP_VERSION=$(curl -sk "https://api.github.com/repos/${COMP_REPO}/tags" \
            | sed -En '/"name"/ s#.*"([^"]+)".*#\1#p' \
            | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
            | head -1)
        fi
      fi

      if [[ -z "$COMP_VERSION" ]]; then
        echo "⚠ Warning: Could not fetch version for $component, skipping..."
        continue
      fi
    fi

    echo "Version: $COMP_VERSION"

    COMP_SRC="$SRC_DIR/$component"
    if [[ -d "$COMP_SRC" ]]; then
      cd "$COMP_SRC"
      git fetch --tags
      git checkout "$COMP_VERSION" 2>/dev/null || git checkout "v$COMP_VERSION" 2>/dev/null || echo "Using existing checkout"
    else
      # Special handling for pasta (not on GitHub)
      if [[ "$component" == "pasta" ]]; then
        CLONE_URL="git://passt.top/passt"
      else
        CLONE_URL="https://github.com/$COMP_REPO.git"
      fi

      git clone --depth 1 --branch "$COMP_VERSION" "$CLONE_URL" "$COMP_SRC" 2>/dev/null || \
      git clone --depth 1 --branch "v$COMP_VERSION" "$CLONE_URL" "$COMP_SRC" || {
        echo "⚠ Warning: Failed to clone $component, skipping..."
        continue
      }
      cd "$COMP_SRC"
    fi

    # Build based on language/build system (following mgoltzsche/podman-static patterns)
    case "$component" in
      conmon)
        # conmon: Use direct make, NOT autotools configure
        # Makefile auto-enables systemd if not using -static flag
        echo "Building conmon (plain Makefile with mimalloc)..."
        make clean 2>/dev/null || true
        make git-vars bin/conmon \
          PKG_CONFIG='pkg-config --static' \
          CFLAGS="-std=c99 -Os -Wall -Wextra -static -I$MIMALLOC_DIR/include" \
          LDFLAGS="-s -w -static -L$MIMALLOC_LIB_DIR -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread" || {
            echo "⚠ Warning: Failed to build $component, skipping..."
            continue
          }
        # Copy from build directory
        if [[ -f "bin/conmon" ]]; then
          cp bin/conmon "$INSTALL_DIR/bin/" && echo "✓ Built conmon"
        else
          echo "⚠ Warning: Could not find conmon binary"
          continue
        fi
        ;;

      netavark)
        # netavark: Rust native build with musl target for true static linking
        echo "Building netavark (Rust, static)..."
        if ! command -v cargo &> /dev/null; then
          echo "⚠ Warning: cargo not found, skipping $component"
          continue
        fi

        # Check for protoc (required by netavark's build.rs)
        if ! command -v protoc &> /dev/null; then
          echo "⚠ Warning: protoc not found, netavark build will fail"
          echo "  Install with: apt-get install protobuf-compiler (Debian/Ubuntu)"
          echo "               emerge dev-libs/protobuf (Gentoo)"
          echo "  Skipping $component..."
          continue
        fi

        # Determine musl target based on architecture
        case "$ARCH" in
          amd64)
            MUSL_TARGET="x86_64-unknown-linux-musl"
            ;;
          arm64)
            MUSL_TARGET="aarch64-unknown-linux-musl"
            ;;
        esac

        # Try musl target first (preferred), fallback to static feature
        RUST_TARGET=""
        BUILD_PATH="target/release"

        if command -v rustup &> /dev/null; then
          # Check if musl target is available
          if rustup target list | grep -q "$MUSL_TARGET (installed)"; then
            RUST_TARGET="--target $MUSL_TARGET"
            BUILD_PATH="target/$MUSL_TARGET/release"
            echo "  Using musl target for static linking"
          else
            echo "  musl target not installed, trying to add..."
            rustup target add "$MUSL_TARGET" 2>/dev/null && {
              RUST_TARGET="--target $MUSL_TARGET"
              BUILD_PATH="target/$MUSL_TARGET/release"
              echo "  ✓ Added musl target"
            }
          fi
        fi

        # If no musl target, use static feature flag
        if [[ -z "$RUST_TARGET" ]]; then
          export RUSTFLAGS='-C target-feature=+crt-static -C link-arg=-s'
          echo "  Using RUSTFLAGS for static linking"
        else
          export RUSTFLAGS='-C link-arg=-s'
        fi

        cargo build --release $RUST_TARGET || {
          echo "⚠ Warning: Failed to build $component, skipping..."
          continue
        }

        if [[ -f "$BUILD_PATH/netavark" ]]; then
          cp "$BUILD_PATH/netavark" "$INSTALL_DIR/bin/" && echo "✓ Built netavark"
        else
          echo "⚠ Warning: Could not find netavark binary at $BUILD_PATH"
          continue
        fi
        ;;

      aardvark-dns)
        # aardvark-dns: Rust native build with musl target for true static linking
        echo "Building aardvark-dns (Rust, static)..."
        if ! command -v cargo &> /dev/null; then
          echo "⚠ Warning: cargo not found, skipping $component"
          continue
        fi

        # Determine musl target based on architecture
        case "$ARCH" in
          amd64)
            MUSL_TARGET="x86_64-unknown-linux-musl"
            ;;
          arm64)
            MUSL_TARGET="aarch64-unknown-linux-musl"
            ;;
        esac

        # Try musl target first (preferred), fallback to static feature
        RUST_TARGET=""
        BUILD_PATH="target/release"

        if command -v rustup &> /dev/null; then
          # Check if musl target is available
          if rustup target list | grep -q "$MUSL_TARGET (installed)"; then
            RUST_TARGET="--target $MUSL_TARGET"
            BUILD_PATH="target/$MUSL_TARGET/release"
            echo "  Using musl target for static linking"
          else
            echo "  musl target not installed, trying to add..."
            rustup target add "$MUSL_TARGET" 2>/dev/null && {
              RUST_TARGET="--target $MUSL_TARGET"
              BUILD_PATH="target/$MUSL_TARGET/release"
              echo "  ✓ Added musl target"
            }
          fi
        fi

        # If no musl target, use static feature flag
        if [[ -z "$RUST_TARGET" ]]; then
          export RUSTFLAGS='-C target-feature=+crt-static -C link-arg=-s'
          echo "  Using RUSTFLAGS for static linking"
        else
          export RUSTFLAGS='-C link-arg=-s'
        fi

        cargo build --release $RUST_TARGET || {
          echo "⚠ Warning: Failed to build $component, skipping..."
          continue
        }

        if [[ -f "$BUILD_PATH/aardvark-dns" ]]; then
          cp "$BUILD_PATH/aardvark-dns" "$INSTALL_DIR/bin/" && echo "✓ Built aardvark-dns"
        else
          echo "⚠ Warning: Could not find aardvark-dns binary at $BUILD_PATH"
          continue
        fi
        ;;

      fuse-overlayfs)
        # fuse-overlayfs: TWO-STAGE BUILD - requires libfuse first
        echo "Building fuse-overlayfs (two-stage: libfuse → fuse-overlayfs)..."

        # Stage 1: Build libfuse dependency
        echo "  Stage 1/2: Building libfuse..."
        LIBFUSE_VERSION="fuse-3.17.4"
        LIBFUSE_SRC="$SRC_DIR/libfuse"
        LIBFUSE_INSTALL="$LIBFUSE_SRC/install"

        if [[ ! -d "$LIBFUSE_SRC" ]]; then
          git clone --depth 1 --branch "$LIBFUSE_VERSION" \
            https://github.com/libfuse/libfuse "$LIBFUSE_SRC" || {
            echo "⚠ Warning: Failed to clone libfuse, skipping fuse-overlayfs..."
            continue
          }
        fi

        cd "$LIBFUSE_SRC"
        if ! command -v meson &> /dev/null || ! command -v ninja &> /dev/null; then
          echo "⚠ Warning: meson or ninja not found, skipping fuse-overlayfs..."
          continue
        fi

        rm -rf build install 2>/dev/null || true
        mkdir -p build
        cd build

        # Install to local directory to avoid permission issues
        LDFLAGS="-lpthread -s -w -static" meson \
          --prefix "$LIBFUSE_INSTALL" \
          -D default_library=static \
          -D examples=false \
          .. || {
          echo "⚠ Warning: meson configure failed for libfuse"
          cat meson-logs/meson-log.txt 2>/dev/null || true
          continue
        }

        ninja || {
          echo "⚠ Warning: ninja build failed for libfuse"
          continue
        }

        # Manual install (skip ninja install to avoid permission issues)
        # The install_helper.sh script tries to access /etc/init.d/ which fails in containers
        echo "  Installing libfuse manually (skip install_helper.sh)..."
        mkdir -p "$LIBFUSE_INSTALL"/{lib,include/fuse3,lib/pkgconfig}

        # Copy static library
        if [[ -f lib/libfuse3.a ]]; then
          cp lib/libfuse3.a "$LIBFUSE_INSTALL/lib/" && echo "    ✓ Copied libfuse3.a"
        else
          echo "⚠ Warning: libfuse3.a not found"
          continue
        fi

        # Copy header files
        cp ../include/*.h "$LIBFUSE_INSTALL/include/fuse3/" 2>/dev/null && echo "    ✓ Copied headers"

        # Copy generated config header (CRITICAL for fuse-overlayfs compilation)
        if [[ -f libfuse_config.h ]]; then
          cp libfuse_config.h "$LIBFUSE_INSTALL/include/fuse3/" && echo "    ✓ Copied libfuse_config.h"
        else
          echo "⚠ Warning: libfuse_config.h not found (fuse-overlayfs will fail)"
        fi

        # Copy pkg-config file
        if [[ -f meson-private/fuse3.pc ]]; then
          cp meson-private/fuse3.pc "$LIBFUSE_INSTALL/lib/pkgconfig/" && echo "    ✓ Copied fuse3.pc"
        else
          echo "⚠ Warning: fuse3.pc not found"
        fi

        echo "  ✓ libfuse built and installed to $LIBFUSE_INSTALL (manual install)"

        # Stage 2: Build fuse-overlayfs
        echo "  Stage 2/2: Building fuse-overlayfs..."
        cd "$COMP_SRC"

        # Set PKG_CONFIG_PATH so configure can find libfuse
        export PKG_CONFIG_PATH="$LIBFUSE_INSTALL/lib/pkgconfig:$LIBFUSE_INSTALL/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

        # Set CPPFLAGS and LDFLAGS to help find headers/libs
        export CPPFLAGS="-I$LIBFUSE_INSTALL/include${CPPFLAGS:+ $CPPFLAGS}"
        FUSE_LDFLAGS="-L$LIBFUSE_INSTALL/lib64 -L$LIBFUSE_INSTALL/lib -s -w -static"

        sh autogen.sh || {
          echo "⚠ Warning: autogen.sh failed for fuse-overlayfs"
          continue
        }

        LIBS="-ldl" LDFLAGS="$FUSE_LDFLAGS" ./configure --prefix=/usr || {
          echo "⚠ Warning: configure failed for fuse-overlayfs"
          continue
        }

        make clean 2>/dev/null || true
        make -j$(nproc) || {
          echo "⚠ Warning: make failed for fuse-overlayfs"
          continue
        }

        # Install to INSTALL_DIR using DESTDIR
        make install DESTDIR="$INSTALL_DIR" || {
          echo "⚠ Warning: make install failed for fuse-overlayfs"
          # Try to copy manually if install fails
          if [[ -f "fuse-overlayfs" ]]; then
            cp fuse-overlayfs "$INSTALL_DIR/bin/" && echo "  ✓ Copied fuse-overlayfs manually"
          fi
          continue
        }

        # Move binaries from usr/bin to bin/
        if [[ -f "$INSTALL_DIR/usr/bin/fuse-overlayfs" ]]; then
          mv "$INSTALL_DIR/usr/bin/fuse-overlayfs" "$INSTALL_DIR/bin/" && echo "  ✓ Built fuse-overlayfs"
        fi
        if [[ -f "$INSTALL_DIR/usr/bin/fusermount3" ]]; then
          mv "$INSTALL_DIR/usr/bin/fusermount3" "$INSTALL_DIR/bin/" && echo "  ✓ Built fusermount3"
        fi

        # Clean up empty directories
        rm -rf "$INSTALL_DIR/usr" 2>/dev/null || true
        ;;

      crun)
        # crun: autotools with specific flags to disable systemd
        echo "Building crun (autotools, --disable-systemd, with mimalloc)..."
        ./autogen.sh || {
          echo "⚠ Warning: autogen.sh failed for crun"
          continue
        }
        # Add mimalloc to configure
        ./configure --disable-systemd --enable-embedded-yajl \
          CFLAGS="-I$MIMALLOC_DIR/include" \
          LDFLAGS="$LDFLAGS -L$MIMALLOC_LIB_DIR -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread" || {
          echo "⚠ Warning: configure failed for crun"
          continue
        }
        make clean 2>/dev/null || true
        # Preserve LDFLAGS from environment (contains -L for libseccomp and mimalloc)
        make LDFLAGS="$LDFLAGS -static-libgcc -all-static" EXTRA_LDFLAGS='-s -w' -j$(nproc) || {
          echo "⚠ Warning: make failed for crun"
          continue
        }
        make install || {
          echo "⚠ Warning: make install failed for crun"
          continue
        }
        # crun installs to /usr/local/bin/crun
        if [[ -f "/usr/local/bin/crun" ]]; then
          cp /usr/local/bin/crun "$INSTALL_DIR/bin/" && echo "✓ Built crun"
        elif [[ -f "crun" ]]; then
          cp crun "$INSTALL_DIR/bin/" && echo "✓ Built crun"
        else
          echo "⚠ Warning: Could not find crun binary"
          continue
        fi
        ;;

      catatonit)
        # catatonit: autotools but NO make install (copy directly)
        echo "Building catatonit (autotools, no install)..."
        ./autogen.sh || {
          echo "⚠ Warning: autogen.sh failed for catatonit"
          continue
        }
        ./configure LDFLAGS="-static" --prefix=/ --bindir=/bin || {
          echo "⚠ Warning: configure failed for catatonit"
          continue
        }
        make clean 2>/dev/null || true
        make -j$(nproc) || {
          echo "⚠ Warning: make failed for catatonit"
          continue
        }
        # Binary is ./catatonit in build directory, don't use make install
        if [[ -f "./catatonit" ]]; then
          cp ./catatonit "$INSTALL_DIR/bin/" && echo "✓ Built catatonit"
        else
          echo "⚠ Warning: Could not find catatonit binary"
          continue
        fi
        ;;

      pasta)
        # pasta: custom Makefile (already correct!)
        # make static produces both pasta and pasta.avx2 (if AVX2 available)
        echo "Building pasta (make static)..."
        make clean 2>/dev/null || true
        make static 2>/dev/null || make -j$(nproc) 2>/dev/null || {
          echo "⚠ Warning: Build failed for pasta, skipping..."
          continue
        }
        # Copy pasta binary
        if [[ -f "pasta" ]]; then
          cp pasta "$INSTALL_DIR/bin/" && echo "✓ Built pasta"
        fi
        # Copy pasta.avx2 if it was built
        if [[ -f "pasta.avx2" ]]; then
          cp pasta.avx2 "$INSTALL_DIR/bin/" && echo "✓ Built pasta.avx2 (AVX2 optimized)"
        fi
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
