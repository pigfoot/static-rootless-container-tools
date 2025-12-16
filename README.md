# Rootless Static Toolkits

[![Build Podman](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/build-podman.yml/badge.svg)](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/build-podman.yml)
[![Build Buildah](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/build-buildah.yml/badge.svg)](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/build-buildah.yml)
[![Build Skopeo](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/build-skopeo.yml/badge.svg)](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/build-skopeo.yml)
[![Check New Releases](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/check-releases.yml/badge.svg)](https://github.com/pigfoot/static-rootless-container-tools/actions/workflows/check-releases.yml)

Build truly static binaries for **podman**, **buildah**, and **skopeo** targeting `linux/amd64` and `linux/arm64`.

## Features

- **Truly Static Binaries**: Built with musl libc + mimalloc in containerized Ubuntu:rolling, runs on any Linux distribution
- **Cross-Architecture**: Supports amd64 and arm64 via Clang cross-compilation with musl target
- **Independent Releases**: Each tool released separately when upstream updates
- **Automated Pipeline**: Daily upstream version checks (2 AM UTC) with GitHub Actions
- **Verified Downloads**: SHA256 checksums + Sigstore/cosign keyless OIDC signatures

## Quick Start

### Download Latest Version (Auto-detect)

```bash
# Set repository and architecture
REPO="pigfoot/static-rootless-container-tools"
ARCH=$([[ $(uname -m) == "aarch64" ]] && echo "arm64" || echo "amd64")

# Download latest podman (default variant - recommended)
TOOL="podman"
TAG=$(curl -s "https://api.github.com/repos/${REPO}/releases" | \
  sed -n 's/.*"tag_name": "\('"${TOOL}"'-v[^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -

# Or download podman-full for complete rootless stack
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}-full-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -

# Download latest buildah (default variant - recommended)
TOOL="buildah"
TAG=$(curl -s "https://api.github.com/repos/${REPO}/releases" | \
  sed -n 's/.*"tag_name": "\('"${TOOL}"'-v[^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -

# Download latest skopeo (default variant - recommended)
TOOL="skopeo"
TAG=$(curl -s "https://api.github.com/repos/${REPO}/releases" | \
  sed -n 's/.*"tag_name": "\('"${TOOL}"'-v[^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -
```

### Download Specific Version

Check [Releases](https://github.com/pigfoot/static-rootless-container-tools/releases) for all available versions.

```bash
# Example: Download podman default variant v5.7.1 for linux/amd64 (recommended)
curl -fsSL -O https://github.com/pigfoot/static-rootless-container-tools/releases/download/podman-v5.7.1/podman-linux-amd64.tar.zst

# Extract
zstd -d podman-linux-amd64.tar.zst && tar -xf podman-linux-amd64.tar
cd podman-v5.7.1

# Install system-wide
sudo cp -r usr/* /usr/
sudo cp -r etc/* /etc/

# Or use from current directory
export PATH=$PWD/usr/local/bin:$PATH
podman --version
```

### Verify Authenticity

All releases include SHA256 checksums and cosign signatures (keyless OIDC).

```bash
# Download checksums file
curl -fsSL -O https://github.com/pigfoot/static-rootless-container-tools/releases/download/podman-v5.7.1/checksums.txt

# Verify SHA256 checksum
sha256sum -c checksums.txt --ignore-missing

# Verify cosign signature (requires cosign CLI)
curl -fsSL -O https://github.com/pigfoot/static-rootless-container-tools/releases/download/podman-v5.7.1/podman-linux-amd64.tar.zst.bundle
cosign verify-blob \
  --bundle=podman-linux-amd64.tar.zst.bundle \
  --certificate-identity-regexp='https://github.com/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  podman-linux-amd64.tar.zst
```

## Package Variants

All tools provide three package variants to suit different use cases:

### Podman Variants

| Variant | Size | Components | Use Case |
|---------|------|------------|----------|
| **podman-linux-{arch}.tar.zst** ⭐ | ~49MB | podman + crun + conmon + configs | **RECOMMENDED** - Core container functionality, works everywhere |
| **podman-standalone-linux-{arch}.tar.zst** ⚠️ | ~44MB | podman only | NOT RECOMMENDED - requires system runc ≥1.1.11 + latest conmon |
| **podman-full-linux-{arch}.tar.zst** | ~74MB | Default + all networking tools | Complete rootless stack with custom networks |

**Default variant includes**: podman (44MB), crun (2.6MB), conmon (2.3MB), configs

**Full variant adds**: netavark (14MB), aardvark-dns (3.5MB), pasta + pasta.avx2 (3MB), fuse-overlayfs (1.4MB), catatonit (953KB)

### Buildah Variants

| Variant | Size | Components | Use Case |
|---------|------|------------|----------|
| **buildah-linux-{arch}.tar.zst** ⭐ | ~55MB | buildah + crun + conmon + configs | **RECOMMENDED** - Build images with `buildah run` support |
| **buildah-standalone-linux-{arch}.tar.zst** ⚠️ | ~50MB | buildah only | NOT RECOMMENDED - requires system runc/crun + conmon |
| **buildah-full-linux-{arch}.tar.zst** | ~56MB | Default + fuse-overlayfs | Rootless image building with overlay mounts |

**Default variant includes**: buildah (~50MB), crun (2.6MB), conmon (2.3MB), configs

**Full variant adds**: fuse-overlayfs (1.4MB) for rootless overlay mounts

### Skopeo Variants

| Variant | Size | Components | Use Case |
|---------|------|------------|----------|
| **skopeo-linux-{arch}.tar.zst** ⭐ | ~30MB | skopeo + configs | **RECOMMENDED** - Image operations with registry configs |
| **skopeo-standalone-linux-{arch}.tar.zst** | ~30MB | skopeo only | Binary only |
| **skopeo-full-linux-{arch}.tar.zst** | ~30MB | Same as default | Alias (skopeo needs no runtime components) |

**Note**: All skopeo variants are essentially the same since skopeo doesn't run containers.

### ⚠️ Compatibility Warnings

- **standalone variants** require compatible system packages:
  - runc or crun ≥ v1.1.11
  - Latest conmon version
  - Most Ubuntu versions have **outdated** runc/conmon that will fail
- **default and full variants** include all required runtimes - work on **any** Linux distribution

## Building from Source

### Prerequisites

- podman or docker (for containerized builds)
- cosign (optional, for signing)
- gh CLI (optional, for automated releases)

All builds run inside Ubuntu:rolling containers with:
- Clang + musl-dev + musl-tools
- Go 1.21+
- Rust (for netavark/aardvark-dns)
- protobuf-compiler

### Containerized Build

```bash
# Build podman default variant for amd64 (runs inside container)
make build-podman

# Or manually trigger workflow with specific variant
gh workflow run build-podman.yml \
  -f version=v5.3.1 \
  -f architecture=amd64 \
  -f variant=default    # or standalone, or full

# Build all variants for both architectures
gh workflow run build-podman.yml \
  -f version=v5.3.1 \
  -f architecture=both \
  -f variant=all
```

### Manual Build

```bash
# Setup build environment (inside container)
podman run --rm -it \
  -v ./scripts:/workspace/scripts:ro,z \
  -v ./build:/workspace/build:rw,z \
  docker.io/ubuntu:rolling bash

# Inside container:
/workspace/scripts/container/setup-build-env.sh

# Build default variant (recommended)
/workspace/scripts/build-tool.sh podman amd64 default
/workspace/scripts/package.sh podman v5.3.1 amd64 default

# Or build full variant
/workspace/scripts/build-tool.sh podman amd64 full
/workspace/scripts/package.sh podman v5.3.1 amd64 full

# Or build standalone variant (not recommended)
/workspace/scripts/build-tool.sh podman amd64 standalone
/workspace/scripts/package.sh podman v5.3.1 amd64 standalone
```

### Local Signing

```bash
# Sign all tarballs in release directory
./scripts/sign-release.sh ./release/
```

## Architecture

### Build Strategy

1. **Containerized**: Ubuntu:rolling with Clang + musl-dev for reproducible builds
2. **Cross-Compilation**: Clang with `--target=<arch>-linux-musl` for amd64/arm64
3. **Allocator**: mimalloc (statically linked, 7-10x faster than musl default)
4. **Dependencies**: All dependencies built from source (libseccomp, libfuse, etc.)

### Release Pipeline

```
Daily Cron (check-releases.yml)
  ├─> Check upstream podman release
  ├─> Check upstream buildah release
  └─> Check upstream skopeo release
       └─> Trigger build-<tool>.yml if new version found
            ├─> Build for amd64
            ├─> Build for arm64
            ├─> Generate checksums
            ├─> Sign with cosign
            └─> Create GitHub Release
```

### Directory Structure

```
.github/workflows/     # CI/CD workflows
scripts/               # Build and utility scripts
build/                 # Build dependencies
  ├── mimalloc/        # Cloned mimalloc source
  ├── patches/         # Patches for dependencies
  └── etc/             # Default config files
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development workflow.

## License

This build infrastructure is provided as-is. The built tools (podman, buildah, skopeo) retain their original licenses:

- podman: Apache-2.0
- buildah: Apache-2.0
- skopeo: Apache-2.0

## References

- Inspired by [mgoltzsche/podman-static](https://github.com/mgoltzsche/podman-static)
- [Project Constitution](.specify/memory/constitution.md)
- [Feature Specification](specs/001-static-build/spec.md)
