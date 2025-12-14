# Rootless Static Toolkits

[![Build Podman](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/build-podman.yml/badge.svg)](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/build-podman.yml)
[![Build Buildah](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/build-buildah.yml/badge.svg)](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/build-buildah.yml)
[![Build Skopeo](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/build-skopeo.yml/badge.svg)](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/build-skopeo.yml)
[![Check New Releases](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/check-releases.yml/badge.svg)](https://github.com/pigfoot/rootless-static-toolkits/actions/workflows/check-releases.yml)

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
REPO="pigfoot/rootless-static-toolkits"
ARCH=$([[ $(uname -m) == "aarch64" ]] && echo "arm64" || echo "amd64")

# Download latest podman-full
TOOL="podman"; VARIANT="-full"
TAG=$(curl -s "https://api.github.com/repos/${REPO}/releases" | \
  sed -n 's/.*"tag_name": "\('"${TOOL}"'-v[^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}${VARIANT}-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -

# Download latest buildah
TOOL="buildah"; VARIANT=""
TAG=$(curl -s "https://api.github.com/repos/${REPO}/releases" | \
  sed -n 's/.*"tag_name": "\('"${TOOL}"'-v[^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}${VARIANT}-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -

# Download latest skopeo
TOOL="skopeo"; VARIANT=""
TAG=$(curl -s "https://api.github.com/repos/${REPO}/releases" | \
  sed -n 's/.*"tag_name": "\('"${TOOL}"'-v[^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${TOOL}${VARIANT}-linux-${ARCH}.tar.zst" | \
  zstd -d | tar xvf -
```

### Download Specific Version

Check [Releases](https://github.com/pigfoot/rootless-static-toolkits/releases) for all available versions.

```bash
# Example: Download podman-full v5.7.1 for linux/amd64
curl -fsSL -O https://github.com/pigfoot/rootless-static-toolkits/releases/download/podman-v5.7.1/podman-full-linux-amd64.tar.zst

# Extract
zstd -d podman-full-linux-amd64.tar.zst && tar -xf podman-full-linux-amd64.tar
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
curl -fsSL -O https://github.com/pigfoot/rootless-static-toolkits/releases/download/podman-v5.7.1/checksums.txt

# Verify SHA256 checksum
sha256sum -c checksums.txt --ignore-missing

# Verify cosign signature (requires cosign CLI)
curl -fsSL -O https://github.com/pigfoot/rootless-static-toolkits/releases/download/podman-v5.7.1/podman-full-linux-amd64.tar.zst.bundle
cosign verify-blob \
  --bundle=podman-full-linux-amd64.tar.zst.bundle \
  --certificate-identity-regexp='https://github.com/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  podman-full-linux-amd64.tar.zst
```

## Available Tools

### podman

- **podman-full**: Includes all runtime components (crun, conmon, fuse-overlayfs, netavark, aardvark-dns, pasta, catatonit)
- **podman-minimal**: Binary only

### buildah

Single binary for building OCI images.

### skopeo

Single binary for image operations.

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
# Build podman-full for amd64 (runs inside container)
make build-podman

# Or manually trigger workflow
gh workflow run build-podman.yml \
  -f version=v5.3.1 \
  -f architecture=amd64 \
  -f variant=full
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
/workspace/scripts/build-tool.sh podman amd64 full
/workspace/scripts/package.sh podman v5.3.1 amd64 full
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
