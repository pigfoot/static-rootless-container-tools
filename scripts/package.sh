#!/usr/bin/env bash
# Package built binaries into release tarball
# Usage: ./scripts/package.sh <tool> <arch> <libc> [variant] [version]
# Example: ./scripts/package.sh podman amd64 static full v5.3.1
#          ./scripts/package.sh buildah arm64 glibc default v1.35.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
TOOL="${1:-}"
ARCH="${2:-amd64}"
LIBC="${3:-static}"
VARIANT="${4:-default}"
VERSION="${5:-}"

if [[ -z "$TOOL" ]]; then
  echo "Error: Missing required arguments" >&2
  echo "Usage: $0 <tool> <arch> <libc> [variant] [version]" >&2
  echo "Example: $0 podman amd64 static full v5.3.1" >&2
  echo "         $0 buildah arm64 glibc default v1.35.0" >&2
  echo "         $0 skopeo amd64 static standalone v1.14.0" >&2
  exit 1
fi

# Normalize version (ensure it starts with 'v')
if [[ ! "$VERSION" =~ ^v ]]; then
  VERSION="v$VERSION"
fi

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

# Determine tarball name according to constitution naming convention:
# {tool}-{version}-linux-{arch}-{libc}[-{package}].tar.zst
# Default package variant omits package suffix
if [[ "$VARIANT" == "default" ]]; then
  if [[ -n "$VERSION" ]]; then
    TARBALL_NAME="${TOOL}-${VERSION}-linux-${ARCH}-${LIBC}"
  else
    TARBALL_NAME="${TOOL}-linux-${ARCH}-${LIBC}"
  fi
else
  if [[ -n "$VERSION" ]]; then
    TARBALL_NAME="${TOOL}-${VERSION}-linux-${ARCH}-${LIBC}-${VARIANT}"
  else
    TARBALL_NAME="${TOOL}-linux-${ARCH}-${LIBC}-${VARIANT}"
  fi
fi

PACKAGE_DIR="${TOOL}-${VERSION}"
# Use libc-specific build directory
if [[ "$LIBC" == "glibc" ]]; then
  BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH-glibc"
else
  BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH"
fi
INSTALL_DIR="$BUILD_DIR/install"
STAGING_DIR="$BUILD_DIR/staging"
CONFIG_DIR="$PROJECT_ROOT/etc/containers"

echo "========================================"
echo "Packaging: $TOOL ${VERSION:-latest}"
echo "Architecture: $ARCH"
echo "Libc variant: $LIBC"
echo "Package variant: $VARIANT"
echo "Output: ${TARBALL_NAME}.tar.zst"
echo "========================================"

# Download config files from upstream if not present
echo "Checking container config files..."
mkdir -p "$CONFIG_DIR"

download_config_file() {
  local url="$1"
  local output="$2"

  if [[ ! -f "$output" ]]; then
    echo "Downloading $(basename "$output") from upstream..."
    curl -fsSL "$url" -o "$output"
  else
    echo "✓ $(basename "$output") already exists"
  fi
}

# Download from containers organization repos (main branch for latest stable defaults)
download_config_file \
  "https://raw.githubusercontent.com/containers/common/main/pkg/config/containers.conf" \
  "$CONFIG_DIR/containers.conf"

download_config_file \
  "https://raw.githubusercontent.com/containers/common/main/pkg/seccomp/seccomp.json" \
  "$CONFIG_DIR/seccomp.json"

download_config_file \
  "https://raw.githubusercontent.com/containers/storage/main/storage.conf" \
  "$CONFIG_DIR/storage.conf"

download_config_file \
  "https://raw.githubusercontent.com/containers/image/main/default-policy.json" \
  "$CONFIG_DIR/policy.json"

download_config_file \
  "https://raw.githubusercontent.com/containers/image/main/registries.conf" \
  "$CONFIG_DIR/registries.conf"

echo "✓ All config files ready"
echo ""

# Download systemd files from podman source (for systemd integration)
if [[ "$TOOL" == "podman" ]]; then
  echo "Getting systemd integration files from source..."
  # Use the already-cloned source directory from build-tool.sh
  PODMAN_SRC_DIR="$BUILD_DIR/src/podman"

  if [[ ! -d "$PODMAN_SRC_DIR" ]]; then
    echo "Error: Podman source not found at $PODMAN_SRC_DIR"
    exit 1
  fi

  if [[ -d "$PODMAN_SRC_DIR/contrib/systemd" ]]; then
    # Copy systemd service/socket files
    SYSTEMD_SYSTEM_DIR="$CONFIG_DIR/systemd/system"
    SYSTEMD_USER_DIR="$CONFIG_DIR/systemd/user"

    mkdir -p "$SYSTEMD_SYSTEM_DIR"
    mkdir -p "$SYSTEMD_USER_DIR"

    # System-wide service files
    if [[ -d "$PODMAN_SRC_DIR/contrib/systemd/system" ]]; then
      cp "$PODMAN_SRC_DIR/contrib/systemd/system/"*.service "$SYSTEMD_SYSTEM_DIR/" 2>/dev/null || true
      cp "$PODMAN_SRC_DIR/contrib/systemd/system/"*.socket "$SYSTEMD_SYSTEM_DIR/" 2>/dev/null || true
      echo "✓ Copied system-wide systemd files"
    fi

    # User service files
    if [[ -d "$PODMAN_SRC_DIR/contrib/systemd/user" ]]; then
      cp "$PODMAN_SRC_DIR/contrib/systemd/user/"*.service "$SYSTEMD_USER_DIR/" 2>/dev/null || true
      cp "$PODMAN_SRC_DIR/contrib/systemd/user/"*.socket "$SYSTEMD_USER_DIR/" 2>/dev/null || true
      echo "✓ Copied user systemd files"
    fi
  fi
fi

echo ""

# Check if build exists
if [[ ! -d "$INSTALL_DIR/bin" ]]; then
  echo "Error: Build directory not found: $INSTALL_DIR/bin" >&2
  echo "Please run build-tool.sh first" >&2
  exit 1
fi

# Create staging directory
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/$PACKAGE_DIR"

# Organize binaries based on variant
echo "Organizing binaries..."

if [[ "$VARIANT" == "standalone" ]]; then
  # standalone variant: binary at root level only (no subdirectories, no README)
  echo "  → $TOOL (root level)"
  cp "$INSTALL_DIR/bin/$TOOL" "$STAGING_DIR/$PACKAGE_DIR/"
else
  # default/full variants: FHS-compliant structure
  # usr/local/bin/ = user-facing tools
  # usr/local/lib/podman/ = runtime helpers
  mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/bin"
  mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/podman"

  # Define which binaries go where
  BIN_TOOLS="podman crun fuse-overlayfs pasta pasta.avx2 buildah skopeo"
  LIB_HELPERS="conmon netavark aardvark-dns catatonit"

  # Copy user-facing tools to bin/
  for binary in $BIN_TOOLS; do
    if [[ -f "$INSTALL_DIR/bin/$binary" ]]; then
      echo "  → usr/local/bin/$binary"
      cp "$INSTALL_DIR/bin/$binary" "$STAGING_DIR/$PACKAGE_DIR/usr/local/bin/"
    fi
  done

  # Copy runtime helpers to lib/podman/
  for binary in $LIB_HELPERS; do
    if [[ -f "$INSTALL_DIR/bin/$binary" ]]; then
      echo "  → usr/local/lib/podman/$binary"
      cp "$INSTALL_DIR/bin/$binary" "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/podman/"
    fi
  done
fi

# Also check lib/podman/ and libexec/podman/ source directories (only for default/full variants)
if [[ "$VARIANT" != "standalone" ]]; then
  if [[ -d "$INSTALL_DIR/lib/podman" ]]; then
    for binary in "$INSTALL_DIR/lib/podman"/*; do
      if [[ -f "$binary" ]]; then
        binary_name=$(basename "$binary")
        echo "  → usr/local/lib/podman/$binary_name"
        cp "$binary" "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/podman/"
      fi
    done
  fi

  # Also check libexec/podman/ source directory (for quadlet)
  if [[ -d "$INSTALL_DIR/libexec/podman" ]]; then
    mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/libexec/podman"
    for binary in "$INSTALL_DIR/libexec/podman"/*; do
      if [[ -f "$binary" ]]; then
        binary_name=$(basename "$binary")
        echo "  → usr/local/libexec/podman/$binary_name"
        cp "$binary" "$STAGING_DIR/$PACKAGE_DIR/usr/local/libexec/podman/"
      fi
    done
  fi
fi

# Validate required components based on tool and variant
echo ""
echo "Validating required components for $TOOL-$VARIANT..."

REQUIRED_COMPONENTS=()

# Define required components based on tool and variant
if [[ "$TOOL" == "podman" ]]; then
  if [[ "$VARIANT" == "standalone" ]]; then
    REQUIRED_COMPONENTS=("podman")
  elif [[ "$VARIANT" == "default" ]]; then
    REQUIRED_COMPONENTS=(
      "usr/local/bin/podman"
      "usr/local/bin/crun"
      "usr/local/lib/podman/conmon"
    )
  elif [[ "$VARIANT" == "full" ]]; then
    REQUIRED_COMPONENTS=(
      "usr/local/bin/podman"
      "usr/local/bin/crun"
      "usr/local/bin/fuse-overlayfs"
      "usr/local/bin/pasta"
      "usr/local/lib/podman/conmon"
      "usr/local/lib/podman/netavark"
      "usr/local/lib/podman/aardvark-dns"
      "usr/local/lib/podman/catatonit"
    )
  fi
elif [[ "$TOOL" == "buildah" ]]; then
  if [[ "$VARIANT" == "standalone" ]]; then
    REQUIRED_COMPONENTS=("buildah")
  elif [[ "$VARIANT" == "default" ]]; then
    REQUIRED_COMPONENTS=(
      "usr/local/bin/buildah"
      "usr/local/bin/crun"
      "usr/local/lib/podman/conmon"
    )
  elif [[ "$VARIANT" == "full" ]]; then
    REQUIRED_COMPONENTS=(
      "usr/local/bin/buildah"
      "usr/local/bin/crun"
      "usr/local/bin/fuse-overlayfs"
      "usr/local/lib/podman/conmon"
    )
  fi
elif [[ "$TOOL" == "skopeo" ]]; then
  if [[ "$VARIANT" == "standalone" ]]; then
    REQUIRED_COMPONENTS=("skopeo")
  else
    # skopeo doesn't need runtime components (doesn't run containers)
    REQUIRED_COMPONENTS=("usr/local/bin/skopeo")
  fi
fi

MISSING_COMPONENTS=()
for component in "${REQUIRED_COMPONENTS[@]}"; do
  if [[ ! -f "$STAGING_DIR/$PACKAGE_DIR/$component" ]]; then
    MISSING_COMPONENTS+=("$component")
  fi
done

if [[ ${#MISSING_COMPONENTS[@]} -gt 0 ]]; then
  echo ""
  echo "❌ ERROR: Missing required components for $TOOL-$VARIANT:"
  for missing in "${MISSING_COMPONENTS[@]}"; do
    echo "  - $missing"
  done
  echo ""
  echo "These components are required by spec.md and MUST be present."
  echo "Build failures should be fixed, not silently ignored."
  exit 1
fi

echo "✅ All required components present (${#REQUIRED_COMPONENTS[@]}/${#REQUIRED_COMPONENTS[@]})"
echo ""

# Copy etc/ directory with default configs (skip for standalone variant)
if [[ "$VARIANT" != "standalone" ]]; then
  echo "Copying configuration files to etc/containers/..."
  mkdir -p "$STAGING_DIR/$PACKAGE_DIR/etc/containers"
  cp "$PROJECT_ROOT/etc/containers/policy.json" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"
  cp "$PROJECT_ROOT/etc/containers/registries.conf" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"
  cp "$PROJECT_ROOT/etc/containers/containers.conf" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"
  cp "$PROJECT_ROOT/etc/containers/storage.conf" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"
  cp "$PROJECT_ROOT/etc/containers/seccomp.json" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"
fi

# Copy systemd files (for podman only, skip for standalone variant)
if [[ "$TOOL" == "podman" && "$VARIANT" != "standalone" ]]; then
  # Copy systemd service/socket files
  if [[ -d "$CONFIG_DIR/systemd" ]]; then
    echo "Copying systemd integration files..."
    mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/system"
    mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/user"

    if [[ -d "$CONFIG_DIR/systemd/system" ]]; then
      cp "$CONFIG_DIR/systemd/system/"* "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/system/" 2>/dev/null || true
    fi

    if [[ -d "$CONFIG_DIR/systemd/user" ]]; then
      cp "$CONFIG_DIR/systemd/user/"* "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/user/" 2>/dev/null || true
    fi
  fi

  # Create systemd generator symlinks (for quadlet)
  if [[ -f "$STAGING_DIR/$PACKAGE_DIR/usr/local/libexec/podman/quadlet" ]]; then
    echo "Creating systemd generator symlinks..."
    mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/system-generators"
    mkdir -p "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/user-generators"

    # Create relative symlinks to quadlet
    cd "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/system-generators"
    ln -s ../../../libexec/podman/quadlet podman-system-generator

    cd "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/systemd/user-generators"
    ln -s ../../../libexec/podman/quadlet podman-user-generator

    cd "$PROJECT_ROOT"
    echo "✓ Created systemd generators"
  fi
fi

# Create README for the package (skip for standalone variant)
if [[ "$VARIANT" != "standalone" ]]; then
cat > "$STAGING_DIR/$PACKAGE_DIR/README.txt" <<EOF
$TOOL $VERSION - Static Binary Release
======================================

Architecture: linux/$ARCH
Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Build System: Zig cross-compiler + musl + mimalloc

Installation
------------

1. Extract this archive:
   tar -xf ${TARBALL_NAME}.tar.zst

2. Install to system (recommended):
   cd $PACKAGE_DIR
   sudo cp -r usr/* /usr/
   sudo cp -r etc/* /etc/

   OR add to PATH (user install):
   export PATH=\$PWD/$PACKAGE_DIR/usr/local/bin:\$PATH

3. Verify installation:
   $TOOL --version

Configuration
-------------

Default configuration files are in etc/containers/:
- policy.json: Image signature verification policy
- registries.conf: Container registry configuration

You can copy these to:
- System-wide: /etc/containers/
- User-specific: ~/.config/containers/

Verification
------------

This tarball should have accompanying files:
- checksums.txt: SHA256 checksums
- ${TARBALL_NAME}.tar.zst.sig: Cosign signature

Verify checksum:
  sha256sum -c checksums.txt --ignore-missing

Verify signature:
  cosign verify-blob \\
    --signature ${TARBALL_NAME}.tar.zst.sig \\
    --certificate-identity-regexp 'https://github.com/.*' \\
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \\
    ${TARBALL_NAME}.tar.zst

Binary Information
------------------

All binaries are statically linked with:
- musl libc (no glibc dependencies)
- mimalloc allocator (high performance)

Verify with: ldd usr/local/bin/$TOOL
Expected output: "not a dynamic executable"

Contents
--------

EOF

# List all binaries organized by location
if [[ -d "$STAGING_DIR/$PACKAGE_DIR/usr/local/bin" ]] && [[ -n "$(ls -A "$STAGING_DIR/$PACKAGE_DIR/usr/local/bin" 2>/dev/null)" ]]; then
  echo "usr/local/bin/ (user-facing tools):" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
  ls -1 "$STAGING_DIR/$PACKAGE_DIR/usr/local/bin/" | sed 's/^/  /' >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
  echo "" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
fi

if [[ -d "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/podman" ]] && [[ -n "$(ls -A "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/podman" 2>/dev/null)" ]]; then
  echo "usr/local/lib/podman/ (runtime helpers):" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
  ls -1 "$STAGING_DIR/$PACKAGE_DIR/usr/local/lib/podman/" | sed 's/^/  /' >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
  echo "" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
fi

if [[ -d "$STAGING_DIR/$PACKAGE_DIR/usr/local/libexec/podman" ]] && [[ -n "$(ls -A "$STAGING_DIR/$PACKAGE_DIR/usr/local/libexec/podman" 2>/dev/null)" ]]; then
  echo "usr/local/libexec/podman/ (systemd integration):" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
  ls -1 "$STAGING_DIR/$PACKAGE_DIR/usr/local/libexec/podman/" | sed 's/^/  /' >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
  echo "" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
fi

echo "etc/containers/ (configuration):" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
ls -1 "$STAGING_DIR/$PACKAGE_DIR/etc/containers/" | sed 's/^/  /' >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
fi  # End of README creation (skip for standalone variant)

# Create tarball with zstd compression
echo "Creating tarball..."
cd "$STAGING_DIR"

# Create tarball in build directory (for container volume mount)
OUTPUT_TARBALL="$PROJECT_ROOT/build/${TARBALL_NAME}.tar.zst"
mkdir -p "$PROJECT_ROOT/build"
tar -cf - "$PACKAGE_DIR" | zstd -19 -T0 -f -o "$OUTPUT_TARBALL"

# Show results
echo "========================================"
echo "Package created successfully!"
echo "========================================"
echo "Tarball: $OUTPUT_TARBALL"
ls -lh "$OUTPUT_TARBALL"
echo ""

# Calculate SHA256
echo "Calculating SHA256 checksum..."
SHA256=$(sha256sum "$OUTPUT_TARBALL" | awk '{print $1}')
echo "$SHA256  $(basename "$OUTPUT_TARBALL")" | tee -a "$PROJECT_ROOT/checksums.txt"

echo ""
echo "✓ Packaging complete"
echo "  Tarball: $OUTPUT_TARBALL"
echo "  SHA256: $SHA256"
