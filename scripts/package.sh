#!/usr/bin/env bash
# Package built binaries into release tarball
# Usage: ./scripts/package.sh <tool> <version> <arch> [variant]
# Example: ./scripts/package.sh podman v5.3.1 amd64 full
#          ./scripts/package.sh buildah v1.35.0 arm64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
TOOL="${1:-}"
VERSION="${2:-}"
ARCH="${3:-}"
VARIANT="${4:-}"

if [[ -z "$TOOL" || -z "$VERSION" || -z "$ARCH" ]]; then
  echo "Error: Missing required arguments" >&2
  echo "Usage: $0 <tool> <version> <arch> [variant]" >&2
  echo "Example: $0 podman v5.3.1 amd64 full" >&2
  exit 1
fi

# Normalize version (ensure it starts with 'v')
if [[ ! "$VERSION" =~ ^v ]]; then
  VERSION="v$VERSION"
fi

# Determine tarball name
if [[ -n "$VARIANT" ]]; then
  TARBALL_NAME="${TOOL}-${VARIANT}-linux-${ARCH}"
else
  TARBALL_NAME="${TOOL}-linux-${ARCH}"
fi

PACKAGE_DIR="${TOOL}-${VERSION}"
BUILD_DIR="$PROJECT_ROOT/build/$TOOL-$ARCH"
INSTALL_DIR="$BUILD_DIR/install"
STAGING_DIR="$BUILD_DIR/staging"

echo "========================================"
echo "Packaging: $TOOL $VERSION"
echo "Architecture: $ARCH"
[[ -n "$VARIANT" ]] && echo "Variant: $VARIANT"
echo "Output: ${TARBALL_NAME}.tar.zst"
echo "========================================"

# Check if build exists
if [[ ! -d "$INSTALL_DIR/bin" ]]; then
  echo "Error: Build directory not found: $INSTALL_DIR/bin" >&2
  echo "Please run build-tool.sh first" >&2
  exit 1
fi

# Create staging directory
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/$PACKAGE_DIR"

# Copy bin/ directory
echo "Copying binaries..."
cp -r "$INSTALL_DIR/bin" "$STAGING_DIR/$PACKAGE_DIR/"

# Create lib/ directory (for future use)
mkdir -p "$STAGING_DIR/$PACKAGE_DIR/lib/$TOOL"

# Copy etc/ directory with default configs
echo "Copying configuration files..."
mkdir -p "$STAGING_DIR/$PACKAGE_DIR/etc/containers"
cp "$PROJECT_ROOT/etc/containers/policy.json" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"
cp "$PROJECT_ROOT/etc/containers/registries.conf" "$STAGING_DIR/$PACKAGE_DIR/etc/containers/"

# Create README for the package
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

2. Add to PATH or copy to system location:
   export PATH=\$PWD/$PACKAGE_DIR/bin:\$PATH

   OR

   sudo cp -r $PACKAGE_DIR/bin/* /usr/local/bin/
   sudo cp -r $PACKAGE_DIR/etc/* /etc/

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

Verify with: ldd bin/$TOOL
Expected output: "not a dynamic executable"

Contents
--------

EOF

# List all binaries
echo "bin/" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
ls -1 "$STAGING_DIR/$PACKAGE_DIR/bin/" | sed 's/^/  /' >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"

echo "" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
echo "etc/containers/" >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"
ls -1 "$STAGING_DIR/$PACKAGE_DIR/etc/containers/" | sed 's/^/  /' >> "$STAGING_DIR/$PACKAGE_DIR/README.txt"

# Create tarball with zstd compression
echo "Creating tarball..."
cd "$STAGING_DIR"

OUTPUT_TARBALL="$PROJECT_ROOT/${TARBALL_NAME}.tar.zst"
tar -cf - "$PACKAGE_DIR" | zstd -19 -T0 -o "$OUTPUT_TARBALL"

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
