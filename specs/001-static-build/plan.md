# Implementation Plan: Static Container Tools Build System

**Branch**: `001-static-build` | **Date**: 2025-12-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-static-build/spec.md`

## Summary

Build a fully automated release pipeline for static podman, buildah, and skopeo binaries targeting linux/amd64 and linux/arm64. Uses Clang with musl target and mimalloc for optimal static binaries. Each tool is tracked and released independently based on upstream versions, with daily automated checks and manual trigger support.

## Technical Context

**Language/Version**: Bash scripts, YAML (GitHub Actions), Dockerfile (optional fallback)
**Compiler**: Clang 18+ with musl target (for C/C++ cross-compilation and CGO dependencies)
**Libc**: musl (for truly static binaries)
**Allocator**: mimalloc (static linked, replaces musl's slow allocator)
**Primary Dependencies**: Go toolchain, Clang, musl-dev, musl-tools, protobuf-compiler, cosign, curl (for GitHub API)
**Storage**: N/A (version tracking via GitHub Releases)
**Testing**: Shell-based smoke tests (ldd verification, version checks, binary execution)
**Target Platform**: GitHub Actions runners (ubuntu-latest for cross-compile)
**Project Type**: Build infrastructure / CI-CD pipeline
**Performance Goals**: Build-to-release < 30 minutes per tool per architecture
**Constraints**: GitHub Actions runner limits, upstream release frequency
**Scale/Scope**: 3 tools × 2 architectures × 2 variants (podman) = ~10 artifacts per release cycle

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Truly Static Binaries | ✅ PASS | Clang + musl target produces static binaries; verified with `ldd` |
| II. Independent Tool Releases | ✅ PASS | Separate workflows per tool; version tracking per tool |
| III. Reproducible Builds | ✅ PASS | Documented minimum versions; exact build steps in scripts; containerized fallback available |
| IV. Minimal Dependencies | ✅ PASS | Only required runtime components in podman-full; minimal has binary only |
| V. Automated Release Pipeline | ✅ PASS | Daily cron + workflow_dispatch; cosign signing; auto GitHub Release |

## Project Structure

### Documentation (this feature)

```text
specs/001-static-build/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── checklists/          # Validation checklists
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
.github/
└── workflows/
    ├── check-releases.yml       # Daily cron: check upstream versions
    ├── build-podman.yml         # Build + release podman
    ├── build-buildah.yml        # Build + release buildah
    └── build-skopeo.yml         # Build + release skopeo

scripts/
├── check-version.sh             # Compare upstream vs local releases
├── build-tool.sh                # Common build logic (Clang + Go + mimalloc)
├── package.sh                   # Create tarball with bin/lib/etc structure
└── sign-release.sh              # Cosign signing

build/
├── mimalloc/                    # mimalloc source for static compilation
└── patches/                     # Any patches needed for dependencies

Dockerfile.podman               # Fallback: Alpine-based build environment
Dockerfile.buildah              # Fallback: Alpine-based build
Dockerfile.skopeo               # Fallback: Alpine-based build

Makefile                        # Local build/test commands
```

**Structure Decision**: Build infrastructure project with GitHub Actions workflows as primary, scripts for build logic, and Dockerfiles as fallback.

## Runtime Component Build Requirements

### Go Components (podman, buildah, skopeo)
- **Build System**: Go modules
- **Dependencies**: Go 1.21+, Clang, musl-dev
- **CGO**: Enabled with Clang cross-compiler
- **Static Linking**: `-ldflags "-linkmode external -extldflags '-static'"`

### Rust Components (netavark, aardvark-dns)
- **Build System**: Cargo
- **Dependencies**: Rust/Cargo, protobuf-compiler (required for netavark)
- **Static Linking**: Use musl target (`--target x86_64-unknown-linux-musl`)
- **Fallback**: RUSTFLAGS with `+crt-static` (if musl target unavailable)

### C Components with Make (conmon, pasta, catatonit)
- **Build System**: Makefile
- **Dependencies**: Clang, musl-dev, make
- **Special Requirements**:
  - conmon: Requires libglib2.0-dev, disable systemd (`USE_JOURNALD=0`) ✅ Fixed
  - pasta: Source from `git://passt.top/passt` (NOT GitHub) ✅ Fixed
  - catatonit: Direct copy from build directory ✅ Working

**Note**: runc originally planned but removed (not in spec requirements, redundant with crun). See [MIGRATION-ZIG-TO-CLANG.md](./MIGRATION-ZIG-TO-CLANG.md) for details.

### C Components with Autotools (crun)
- **Build System**: autotools (./configure)
- **Dependencies**: Clang, musl-dev, autoconf, automake, libcap-dev
- **Configure Flags**: `--disable-systemd --enable-embedded-yajl`
- **Static Linking**: `LDFLAGS='-static-libgcc -all-static'`

### C Components with Meson (fuse-overlayfs)
- **Build System**: meson + ninja
- **Dependencies**: Clang, musl-dev, meson, ninja
- **Two-Stage Build**: libfuse (meson) → fuse-overlayfs (autotools)
- **Install Path**: Local prefix (avoid permission issues) ⚠️ In Progress
  - Issue: libfuse install_helper.sh tries to access /etc/init.d/ (permission denied)
  - Solution: Skip `ninja install`, manually copy built libfuse files to local prefix

## Build Artifacts

### Release Naming

- Tag format: `{tool}-v{version}` (e.g., `podman-v5.3.1`)
- Release title: `{Tool} {version}` (e.g., `Podman 5.3.1`)

### Artifact Structure

For podman:
```
podman-full-linux-amd64.tar.zst
podman-full-linux-arm64.tar.zst
podman-minimal-linux-amd64.tar.zst
podman-minimal-linux-arm64.tar.zst
checksums.txt
cosign signatures (attached to release)
```

For buildah/skopeo:
```
buildah-linux-amd64.tar.zst
buildah-linux-arm64.tar.zst
checksums.txt
cosign signatures
```

### Tarball Contents (podman-full example)

```
podman-v5.3.1/
├── bin/
│   ├── podman
│   ├── crun
│   ├── conmon
│   ├── fuse-overlayfs
│   ├── netavark
│   ├── aardvark-dns
│   ├── pasta
│   └── catatonit
├── lib/
│   └── podman/
│       └── (helper libraries if any)
└── etc/
    └── containers/
        ├── policy.json
        └── registries.conf
```

## Complexity Tracking

| Technical Choice | Why Needed | Fallback Plan | Status |
|------------------|------------|---------------|--------|
| Clang + musl target | GCC compatibility, build system support | Dockerfile.* with Alpine/musl | **ACTIVE** - Verified working |
| mimalloc static link | musl allocator is slow | Accept musl allocator for CLI tools | **ACTIVE** |
| Cross-compile arm64 | Avoid ARM runner cost/complexity | Use ubuntu-24.04-arm native runner | **ACTIVE** |

**Historical Note**: Zig cross-compiler was initially considered but abandoned due to ecosystem compatibility issues. See [MIGRATION-ZIG-TO-CLANG.md](./MIGRATION-ZIG-TO-CLANG.md) for details.
