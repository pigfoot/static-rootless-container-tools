#!/usr/bin/env bash
# Build container tools with clang + musl/glibc
# Usage: ./scripts/build-tool.sh <tool> [arch] [variant] [libc]
# Example: ./scripts/build-tool.sh podman amd64 full static
#          ./scripts/build-tool.sh podman amd64 default glibc
#          ./scripts/build-tool.sh podman amd64 standalone static
#          ./scripts/build-tool.sh buildah arm64 default glibc
#          ./scripts/build-tool.sh skopeo amd64 default static

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
TOOL="${1:-}"
ARCH="${2:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"
VARIANT="${3:-}"
LIBC="${4:-static}"

if [[ -z "$TOOL" ]]; then
  echo "Error: Tool name required" >&2
  echo "Usage: $0 <podman|buildah|skopeo> [amd64|arm64] [standalone|default|full] [static|glibc]" >&2
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

# Validate libc
case "$LIBC" in
  static|glibc)
    ;;
  *)
    echo "Error: Unsupported libc: $LIBC" >&2
    echo "Supported: static (musl), glibc (dynamic glibc)" >&2
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
echo "Libc variant: $LIBC"
[[ -n "$VARIANT" ]] && echo "Package variant: $VARIANT"
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

# Setup build directories with libc variant suffix
if [[ "$LIBC" == "glibc" ]]; then
  BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH-glibc"
else
  BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH"
fi
INSTALL_DIR="$BUILD_DIR/install"
SRC_DIR="$BUILD_DIR/src"

mkdir -p "$BUILD_DIR" "$INSTALL_DIR/bin" "$SRC_DIR"

# Initialize LDFLAGS (will be extended during build)
LDFLAGS="${LDFLAGS:-}"

# Set upstream repository
UPSTREAM_REPO="containers/$TOOL"

# Get version (from env or fetch latest)
if [[ -z "${VERSION:-}" || "${VERSION}" == "latest" ]]; then
  echo "Fetching latest $TOOL version from GitHub API..."
  # Use GitHub API with authentication if available to avoid rate limiting
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    VERSION=$(curl -sk -H "Authorization: Bearer ${GITHUB_TOKEN}" \
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
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      VERSION=$(curl -sk -H "Authorization: Bearer ${GITHUB_TOKEN}" \
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

# Save detected/specified version for downstream usage (package.sh, workflows)
mkdir -p "$PROJECT_ROOT/build"
echo "$VERSION" > "$PROJECT_ROOT/build/.detected-version"
echo "Saved version to build/.detected-version: $VERSION"

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
# Note: For glibc builds, we can reuse the same mimalloc as static builds since
# mimalloc itself is always statically linked. The LIBC parameter only affects
# whether mimalloc's *own* dependencies use -static flag during its build.
MIMALLOC_INSTALL="$PROJECT_ROOT/build/mimalloc/build-$ARCH/install"
if [[ -f "$MIMALLOC_INSTALL/lib/libmimalloc.a" ]]; then
  MIMALLOC_DIR="$MIMALLOC_INSTALL"
  MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib"
elif [[ -f "$MIMALLOC_INSTALL/lib64/libmimalloc.a" ]]; then
  MIMALLOC_DIR="$MIMALLOC_INSTALL"
  MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib64"
else
  echo "Building mimalloc for $ARCH with libc=$LIBC..."
  "$SCRIPT_DIR/build-mimalloc.sh" "$ARCH" "$LIBC"
  # Re-check after building
  if [[ -f "$MIMALLOC_INSTALL/lib64/libmimalloc.a" ]]; then
    MIMALLOC_DIR="$MIMALLOC_INSTALL"
    MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib64"
  else
    MIMALLOC_DIR="$MIMALLOC_INSTALL"
    MIMALLOC_LIB_DIR="$MIMALLOC_DIR/lib"
  fi
fi

# Setup compiler environment based on libc variant
export CC="clang"
export CXX="clang++"
export AR="ar"
export RANLIB="ranlib"

# Setup CGO for Go build
export CGO_ENABLED=1
export GOOS=linux
export GOARCH="$GOARCH"

if [[ "$LIBC" == "static" ]]; then
  # Static build with musl libc
  echo "Configuring for static musl build..."

  # Point clang to use musl instead of glibc (architecture-aware)
  # CRITICAL: Prevents SIGFPE errors during podman build (glibc NSS incompatibility)
  if [[ "$ARCH" == "amd64" ]]; then
      MUSL_ARCH="x86_64-linux-musl"
  elif [[ "$ARCH" == "arm64" ]]; then
      MUSL_ARCH="aarch64-linux-musl"
  fi

  # Combine musl and mimalloc flags
  # -w disables warnings to avoid musl header issues
  export CGO_CFLAGS="-I/usr/include/${MUSL_ARCH} -I$MIMALLOC_DIR/include -w"
  export CGO_LDFLAGS="-L/usr/lib/${MUSL_ARCH} -static"
  # NOTE: mimalloc linking moved to -extldflags to avoid duplication

else
  # Dynamic glibc build
  echo "Configuring for glibc dynamic build..."

  # Use default system glibc (no special target needed for clang)
  export CGO_CFLAGS="-I$MIMALLOC_DIR/include -w"
  export CGO_LDFLAGS=""
  # NOTE: mimalloc and other libs linked via -extldflags
fi

# Build libseccomp from source (required for podman and buildah)
# Reason: podman and buildah use github.com/seccomp/libseccomp-golang bindings
# MUST build before main tool to ensure CGO finds libseccomp during compilation
if [[ "$TOOL" == "podman" || "$TOOL" == "buildah" ]]; then
  echo "========================================"
  echo "Building libseccomp (dependency for $TOOL)"
  echo "========================================"

  # Get latest libseccomp version from GitHub API (consistent with other components)
  echo "Fetching latest libseccomp version from GitHub API..."
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    LIBSECCOMP_VERSION=$(curl -sk -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "https://api.github.com/repos/seccomp/libseccomp/releases" \
      | sed -En '/\"tag_name\"/ s#.*\"([^\"]+)\".*#\1#p' \
      | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      | head -1)
  else
    LIBSECCOMP_VERSION=$(curl -sk "https://api.github.com/repos/seccomp/libseccomp/releases" \
      | sed -En '/\"tag_name\"/ s#.*\"([^\"]+)\".*#\1#p' \
      | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      | head -1)
  fi

  if [[ -z "$LIBSECCOMP_VERSION" ]]; then
    echo "Error: Could not fetch libseccomp version from GitHub API" >&2
    exit 1
  fi

  echo "Using libseccomp version: $LIBSECCOMP_VERSION"

  LIBSECCOMP_SRC="$SRC_DIR/libseccomp"
  LIBSECCOMP_INSTALL="$BUILD_DIR/libseccomp-install"

  if [[ ! -d "$LIBSECCOMP_SRC" ]]; then
    echo "Cloning libseccomp $LIBSECCOMP_VERSION..."
    git clone --depth 1 --branch "$LIBSECCOMP_VERSION" \
      https://github.com/seccomp/libseccomp "$LIBSECCOMP_SRC" || {
      echo "⚠ Warning: Failed to clone libseccomp, $TOOL build may fail..."
    }
  else
    echo "Updating existing libseccomp source..."
    cd "$LIBSECCOMP_SRC"
    git fetch --tags
    git checkout "$LIBSECCOMP_VERSION"
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
      # Export CGO flags so Go can find libseccomp during podman/buildah build
      export CGO_CFLAGS="$CGO_CFLAGS -I$LIBSECCOMP_INSTALL/include"
      export CGO_LDFLAGS="$CGO_LDFLAGS -L$LIBSECCOMP_INSTALL/lib"
      echo "  PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
      echo "  CPPFLAGS=$CPPFLAGS"
      echo "  LDFLAGS=$LDFLAGS"
      echo "  CGO_CFLAGS=$CGO_CFLAGS"
      echo "  CGO_LDFLAGS=$CGO_LDFLAGS"
    else
      echo "⚠ Warning: libseccomp.a not found, $TOOL build may fail"
    fi

    # Return to tool source directory
    cd "$SRC_DIR/$TOOL"
  fi
fi

# Build tags for static linking
# seccomp: Enable seccomp support (requires libseccomp, built above)
BUILD_TAGS="containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper seccomp"

echo "========================================"
echo "Building $TOOL binary..."
echo "========================================"

# Configure extldflags based on libc variant
if [[ "$LIBC" == "static" ]]; then
  # Static build: fully static binary with musl
  # Use --whole-archive to force mimalloc's malloc to override musl malloc
  EXTLDFLAGS="-static -L${MIMALLOC_LIB_DIR} -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread"
else
  # Glibc dynamic build: only glibc is dynamic, rest is static
  # Static link libstdc++ and libgcc, dynamic link only glibc
  # Use -Wl,-Bstatic/-Bdynamic to control linking per-library
  EXTLDFLAGS="-static-libgcc -static-libstdc++ -L${MIMALLOC_LIB_DIR} -Wl,-Bstatic -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread -Wl,-Bdynamic"
fi

echo "Linking with mimalloc from: $MIMALLOC_LIB_DIR"
echo "EXTLDFLAGS: $EXTLDFLAGS"

go build \
  -tags "$BUILD_TAGS" \
  -ldflags "-linkmode external -extldflags \"${EXTLDFLAGS}\" -s -w" \
  -o "$INSTALL_DIR/bin/$TOOL" \
  ./cmd/$TOOL

# Verify binary linking
echo "Verifying binary linking..."
LDD_OUTPUT=$(ldd "$INSTALL_DIR/bin/$TOOL" 2>&1 || true)

if [[ "$LIBC" == "static" ]]; then
  # Static build should have no dynamic dependencies
  if echo "$LDD_OUTPUT" | grep -q "not a dynamic executable"; then
    echo "✓ Binary is truly static (musl)"
  else
    echo "⚠ Warning: Binary has unexpected dynamic dependencies:"
    echo "$LDD_OUTPUT"
  fi
else
  # Glibc build should only have glibc dependencies
  echo "Binary dynamic dependencies:"
  echo "$LDD_OUTPUT"

  # Check that only glibc is dynamically linked
  if echo "$LDD_OUTPUT" | grep -qE "libc\.so|ld-linux"; then
    echo "✓ Binary links to glibc dynamically"

    # Verify no other libraries (except linux-vdso.so.1 which is kernel-provided)
    NON_GLIBC_DEPS=$(echo "$LDD_OUTPUT" | grep -v "linux-vdso" | grep -v "libc\.so" | grep -v "ld-linux" | grep "=>" || true)
    if [[ -z "$NON_GLIBC_DEPS" ]]; then
      echo "✓ Only glibc is dynamically linked (as expected)"
    else
      echo "⚠ Warning: Unexpected dynamic dependencies found:"
      echo "$NON_GLIBC_DEPS"
    fi
  else
    echo "⚠ Warning: Expected glibc dependencies not found"
  fi
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

  if (ldd "$INSTALL_DIR/lib/podman/rootlessport" 2>&1 || true) | grep -q "not a dynamic executable"; then
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

  if (ldd "$INSTALL_DIR/libexec/podman/quadlet" 2>&1 || true) | grep -q "not a dynamic executable"; then
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

  # Build glib if conmon is needed (only conmon requires glib)
  if [[ " ${COMPONENTS_TO_BUILD[*]} " =~ " conmon " ]] && [[ ! -f "/usr/local/lib/pkgconfig/glib-2.0.pc" ]]; then
    echo "----------------------------------------"
    echo "Building: glib (dependency for conmon)"
    echo "----------------------------------------"

    # Get latest stable glib tag from GitLab API
    echo "  Detecting latest stable glib version..."
    GLIB_TAG=$(curl -fsSL "https://gitlab.gnome.org/api/v4/projects/GNOME%2Fglib/repository/tags" 2>/dev/null | \
      grep -oP '"name":"\K[0-9]+\.[0-9]*[02468]\.[0-9]+' | head -1)

    if [[ -z "$GLIB_TAG" ]]; then
      echo "  Warning: Could not detect latest version, using fallback: 2.86.3"
      GLIB_TAG="2.86.3"
    fi

    echo "  Using glib version: $GLIB_TAG"

    GLIB_SRC="$SRC_DIR/glib"
    if [[ ! -d "$GLIB_SRC" ]]; then
      echo "  Cloning glib..."
      git clone --depth 1 --branch "$GLIB_TAG" https://gitlab.gnome.org/GNOME/glib.git "$GLIB_SRC" 2>&1 | tail -3 || {
        echo "  Warning: Failed to clone tag $GLIB_TAG, trying latest stable branch..."
        rm -rf "$GLIB_SRC"
        GLIB_MINOR=$(echo "$GLIB_TAG" | grep -oP '^[0-9]+\.[0-9]+')
        git clone --depth 1 --branch "glib-${GLIB_MINOR//./-}" https://gitlab.gnome.org/GNOME/glib.git "$GLIB_SRC" 2>&1 | tail -3 || {
          echo "⚠ Warning: Failed to clone glib, conmon build may fail"
        }
      }
    fi

    if [[ -d "$GLIB_SRC" ]]; then
      cd "$GLIB_SRC"
      rm -rf build 2>/dev/null || true

      # Ensure meson can find system dependencies via pkg-config
      export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

      echo "  Configuring glib (minimal build, no introspection/docs)..."
      /root/.local/bin/uv tool run meson setup build \
        --prefix=/usr/local \
        --buildtype=release \
        --default-library=static \
        -Dintrospection=disabled \
        -Ddocumentation=false \
        -Dselinux=disabled \
        -Dlibmount=disabled \
        -Dtests=false \
        -Dglib_debug=disabled \
        -Dglib_assert=false \
        -Dglib_checks=false || {
        echo "⚠ Warning: meson configure failed for glib"
      }

      echo "  Building glib..."
      /root/.local/bin/uv tool run ninja -C build || {
        echo "⚠ Warning: ninja build failed for glib"
      }

      echo "  Installing glib to /usr/local..."
      /root/.local/bin/uv tool run ninja -C build install || {
        echo "⚠ Warning: ninja install failed for glib"
      }

      # Ensure pkg-config can find glib
      export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

      if pkg-config --exists glib-2.0 2>/dev/null; then
        echo "  ✓ glib built successfully: $(pkg-config --modversion glib-2.0)"
      else
        echo "⚠ Warning: glib pkg-config not found, conmon may fail"
      fi

      # Return to original directory
      cd "$SRC_DIR/$TOOL"
    fi
  fi

  # Note: libseccomp may already be built if TOOL is podman/buildah
  # If not (e.g., TOOL=skopeo but building crun), build it now for crun
  # Only build if crun is in the components list AND libseccomp not yet built
  if [[ " ${COMPONENTS_TO_BUILD[*]} " =~ " crun " ]] && [[ ! -f "$BUILD_DIR/libseccomp-install/lib/libseccomp.a" ]]; then
    echo "----------------------------------------"
    echo "Building: libseccomp (dependency for crun)"
    echo "----------------------------------------"

    # Get libseccomp version (reuse if already set by podman/buildah build above)
    if [[ -z "${LIBSECCOMP_VERSION:-}" ]]; then
      echo "Fetching latest libseccomp version from GitHub API..."
      if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        LIBSECCOMP_VERSION=$(curl -sk -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          "https://api.github.com/repos/seccomp/libseccomp/releases" \
          | sed -En '/\"tag_name\"/ s#.*\"([^\"]+)\".*#\1#p' \
          | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
          | head -1)
      else
        LIBSECCOMP_VERSION=$(curl -sk "https://api.github.com/repos/seccomp/libseccomp/releases" \
          | sed -En '/\"tag_name\"/ s#.*\"([^\"]+)\".*#\1#p' \
          | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
          | head -1)
      fi

      if [[ -z "$LIBSECCOMP_VERSION" ]]; then
        echo "Error: Could not fetch libseccomp version from GitHub API" >&2
        exit 1
      fi
    fi

    echo "Using libseccomp version: $LIBSECCOMP_VERSION"

    LIBSECCOMP_SRC="$SRC_DIR/libseccomp"
    LIBSECCOMP_INSTALL="$BUILD_DIR/libseccomp-install"

  if [[ ! -d "$LIBSECCOMP_SRC" ]]; then
    echo "Cloning libseccomp $LIBSECCOMP_VERSION..."
    git clone --depth 1 --branch "$LIBSECCOMP_VERSION" \
      https://github.com/seccomp/libseccomp "$LIBSECCOMP_SRC" || {
      echo "⚠ Warning: Failed to clone libseccomp, crun may fail..."
    }
  else
    echo "Updating existing libseccomp source..."
    cd "$LIBSECCOMP_SRC"
    git fetch --tags
    git checkout "$LIBSECCOMP_VERSION"
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
      if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        COMP_VERSION=$(curl -sk -H "Authorization: Bearer ${GITHUB_TOKEN}" \
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
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
          COMP_VERSION=$(curl -sk -H "Authorization: Bearer ${GITHUB_TOKEN}" \
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

        # Configure flags based on libc variant
        if [[ "$LIBC" == "static" ]]; then
          # Static build with musl
          CONMON_CFLAGS="-std=c99 -Os -Wall -Wextra -static -I$MIMALLOC_DIR/include"
          CONMON_LDFLAGS="-s -w -static -L$MIMALLOC_LIB_DIR -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread"
          CONMON_LIBS=""  # Not needed for static build, pkg-config handles it
          CONMON_PKG_CONFIG='pkg-config --static'
        else
          # Dynamic glibc build - libs must go in LIBS (after obj files), not LDFLAGS (before obj files)
          # Also add libseccomp flags manually (Makefile's seccomp detection uses pkg-config)
          CONMON_CFLAGS="-std=c99 -Os -Wall -Wextra -I$MIMALLOC_DIR/include -I$LIBSECCOMP_INSTALL/include -D USE_SECCOMP=1 $(pkg-config --cflags glib-2.0)"
          GLIB_STATIC_LIBS=$(pkg-config --static --libs glib-2.0)
          CONMON_LDFLAGS="-s -w -static-libgcc -static-libstdc++ -L$MIMALLOC_LIB_DIR -L$LIBSECCOMP_INSTALL/lib -Wl,-Bstatic -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread"
          CONMON_LIBS="-Wl,-Bstatic $GLIB_STATIC_LIBS -lseccomp -ldl -Wl,-Bdynamic"
          CONMON_PKG_CONFIG='/bin/false'  # Disable pkg-config (and systemd detection) since we already added libs
        fi

        make git-vars bin/conmon \
          PKG_CONFIG="$CONMON_PKG_CONFIG" \
          CFLAGS="$CONMON_CFLAGS" \
          LDFLAGS="$CONMON_LDFLAGS" \
          LIBS="$CONMON_LIBS" || {
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
        # netavark: Rust build (musl static or glibc dynamic based on LIBC)
        echo "Building netavark (Rust)..."
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

        # Configure target based on libc variant and architecture
        if [[ "$LIBC" == "static" ]]; then
          # Static musl build
          case "$ARCH" in
            amd64)
              RUST_TARGET_NAME="x86_64-unknown-linux-musl"
              ;;
            arm64)
              RUST_TARGET_NAME="aarch64-unknown-linux-musl"
              ;;
          esac

          # Try to install musl target
          RUST_TARGET=""
          BUILD_PATH="target/release"

          if command -v rustup &> /dev/null; then
            if rustup target list | grep -q "$RUST_TARGET_NAME (installed)"; then
              RUST_TARGET="--target $RUST_TARGET_NAME"
              BUILD_PATH="target/$RUST_TARGET_NAME/release"
              echo "  Using musl target for static linking"
            else
              echo "  musl target not installed, trying to add..."
              rustup target add "$RUST_TARGET_NAME" 2>/dev/null && {
                RUST_TARGET="--target $RUST_TARGET_NAME"
                BUILD_PATH="target/$RUST_TARGET_NAME/release"
                echo "  ✓ Added musl target"
              }
            fi
          fi

          if [[ -z "$RUST_TARGET" ]]; then
            export RUSTFLAGS='-C target-feature=+crt-static -C link-arg=-s'
            echo "  Using RUSTFLAGS for static linking"
          else
            export RUSTFLAGS='-C link-arg=-s'
          fi
        else
          # Dynamic glibc build - use default gnu target
          # Note: Will dynamically link to glibc AND libgcc_s.so.1 (system libraries)
          # libgcc_s.so.1 is unavoidable for Rust + glibc (provides unwinding support)
          RUST_TARGET=""
          BUILD_PATH="target/release"
          export RUSTFLAGS='-C link-arg=-s'
          echo "  Using default gnu target for glibc dynamic linking (includes libgcc_s.so.1)"
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
        # aardvark-dns: Rust build (musl static or glibc dynamic based on LIBC)
        echo "Building aardvark-dns (Rust)..."
        if ! command -v cargo &> /dev/null; then
          echo "⚠ Warning: cargo not found, skipping $component"
          continue
        fi

        # Configure target based on libc variant and architecture
        if [[ "$LIBC" == "static" ]]; then
          # Static musl build
          case "$ARCH" in
            amd64)
              RUST_TARGET_NAME="x86_64-unknown-linux-musl"
              ;;
            arm64)
              RUST_TARGET_NAME="aarch64-unknown-linux-musl"
              ;;
          esac

          # Try to install musl target
          RUST_TARGET=""
          BUILD_PATH="target/release"

          if command -v rustup &> /dev/null; then
            if rustup target list | grep -q "$RUST_TARGET_NAME (installed)"; then
              RUST_TARGET="--target $RUST_TARGET_NAME"
              BUILD_PATH="target/$RUST_TARGET_NAME/release"
              echo "  Using musl target for static linking"
            else
              echo "  musl target not installed, trying to add..."
              rustup target add "$RUST_TARGET_NAME" 2>/dev/null && {
                RUST_TARGET="--target $RUST_TARGET_NAME"
                BUILD_PATH="target/$RUST_TARGET_NAME/release"
                echo "  ✓ Added musl target"
              }
            fi
          fi

          if [[ -z "$RUST_TARGET" ]]; then
            export RUSTFLAGS='-C target-feature=+crt-static -C link-arg=-s'
            echo "  Using RUSTFLAGS for static linking"
          else
            export RUSTFLAGS='-C link-arg=-s'
          fi
        else
          # Dynamic glibc build - use default gnu target
          # Note: Will dynamically link to glibc AND libgcc_s.so.1 (system libraries)
          # libgcc_s.so.1 is unavoidable for Rust + glibc (provides unwinding support)
          RUST_TARGET=""
          BUILD_PATH="target/release"
          export RUSTFLAGS='-C link-arg=-s'
          echo "  Using default gnu target for glibc dynamic linking (includes libgcc_s.so.1)"
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

        # Configure LDFLAGS based on libc variant
        if [[ "$LIBC" == "static" ]]; then
          # Static build with musl
          FUSE_LDFLAGS="-L$LIBFUSE_INSTALL/lib64 -L$LIBFUSE_INSTALL/lib -s -w -static"
          FUSE_LIBS="-ldl"
        else
          # Dynamic glibc build
          FUSE_LDFLAGS="-L$LIBFUSE_INSTALL/lib64 -L$LIBFUSE_INSTALL/lib -s -w -static-libgcc"
          FUSE_LIBS="-ldl"
        fi

        sh autogen.sh || {
          echo "⚠ Warning: autogen.sh failed for fuse-overlayfs"
          continue
        }

        LIBS="$FUSE_LIBS" LDFLAGS="$FUSE_LDFLAGS" ./configure --prefix=/usr || {
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

        # Ensure Python is available for configure script (installed via uv)
        export PATH="/root/.local/bin:$PATH"

        ./autogen.sh || {
          echo "⚠ Warning: autogen.sh failed for crun"
          continue
        }

        # Configure with mimalloc (same for both variants)
        # Use uv run python to ensure Python is found by configure
        PYTHON="/root/.local/bin/uv run python" ./configure --disable-systemd --enable-embedded-yajl \
          CFLAGS="-I$MIMALLOC_DIR/include" \
          LDFLAGS="$LDFLAGS -L$MIMALLOC_LIB_DIR -Wl,--whole-archive -l:libmimalloc.a -Wl,--no-whole-archive -lpthread" || {
          echo "⚠ Warning: configure failed for crun"
          continue
        }

        make clean 2>/dev/null || true

        # Configure make flags based on libc variant
        # Preserve LDFLAGS from environment (contains -L for libseccomp and mimalloc)
        if [[ "$LIBC" == "static" ]]; then
          # Static build with musl
          make LDFLAGS="$LDFLAGS -static-libgcc -all-static" EXTRA_LDFLAGS='-s -w' -j$(nproc) || {
            echo "⚠ Warning: make failed for crun"
            continue
          }
        else
          # Dynamic glibc build - use .a file paths to bypass libtool flag filtering
          # libtool rewrites -l flags but cannot modify file paths (proven solution)
          echo "  Finding static libraries for selective linking..."

          # Find libcap.a (system library)
          LIBCAP_A=$(find /usr/lib* -name "libcap.a" 2>/dev/null | head -1)
          if [[ -z "$LIBCAP_A" ]]; then
            echo "⚠ Warning: libcap.a not found, crun may have dynamic libcap"
          else
            echo "  Found libcap.a: $LIBCAP_A"
          fi

          # libseccomp.a (custom built)
          LIBSECCOMP_A="$LIBSECCOMP_INSTALL/lib/libseccomp.a"
          if [[ ! -f "$LIBSECCOMP_A" ]]; then
            echo "⚠ Warning: libseccomp.a not found at $LIBSECCOMP_A"
          else
            echo "  Found libseccomp.a: $LIBSECCOMP_A"
          fi

          # Override FOUND_LIBS with .a paths (libtool cannot filter file paths)
          # Keep -lm dynamic (glibc math library)
          CRUN_STATIC_LIBS="$LIBCAP_A $LIBSECCOMP_A"

          make FOUND_LIBS="$CRUN_STATIC_LIBS -lm" LDFLAGS="$LDFLAGS -static-libgcc -static-libstdc++" EXTRA_LDFLAGS='-s -w' -j$(nproc) || {
            echo "⚠ Warning: make failed for crun"
            continue
          }
        fi
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

        # Configure LDFLAGS based on libc variant
        if [[ "$LIBC" == "static" ]]; then
          # Static build with musl
          CATATONIT_LDFLAGS="-static"
        else
          # Dynamic glibc build
          CATATONIT_LDFLAGS="-static-libgcc"
        fi

        ./configure LDFLAGS="$CATATONIT_LDFLAGS" --prefix=/ --bindir=/bin || {
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
        # pasta: custom Makefile - supports both static and dynamic builds
        echo "Building pasta..."
        make clean 2>/dev/null || true

        # Build based on libc variant
        if [[ "$LIBC" == "static" ]]; then
          # Static build - produces both pasta and pasta.avx2 (if AVX2 available)
          echo "  Using 'make static' for musl static build"
          make static 2>/dev/null || make -j$(nproc) 2>/dev/null || {
            echo "⚠ Warning: Build failed for pasta, skipping..."
            continue
          }
        else
          # Dynamic glibc build - use default make target
          echo "  Using default 'make' for glibc dynamic build"
          make -j$(nproc) 2>/dev/null || {
            echo "⚠ Warning: Build failed for pasta, skipping..."
            continue
          }
        fi

        # Copy pasta binary
        if [[ -f "pasta" ]]; then
          cp pasta "$INSTALL_DIR/bin/" && echo "✓ Built pasta"
        fi
        # Copy pasta.avx2 if it was built (typically only with static builds)
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
