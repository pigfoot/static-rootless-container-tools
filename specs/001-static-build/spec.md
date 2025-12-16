# Feature Specification: Static Container Tools Build System

**Feature Branch**: `001-static-build`
**Created**: 2025-12-12
**Status**: Draft
**Input**: Build static podman, buildah, and skopeo binaries with automated GitHub Actions release pipeline

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Download Pre-built Static Binary (Priority: P1)

As a user who needs container tools on a minimal Linux environment, I want to download pre-built static binaries from GitHub Releases so that I can run podman/buildah/skopeo without installing dependencies.

**Why this priority**: This is the core value proposition - providing ready-to-use static binaries that work on any Linux distribution.

**Independent Test**: Download a tarball from GitHub Release, extract it, and run `podman --version` on a clean Alpine/Ubuntu/CentOS system without any prior container tool installation.

**Acceptance Scenarios**:

1. **Given** a GitHub Release exists for podman-v5.3.1, **When** I download and extract podman-full-linux-amd64.tar.zst, **Then** I can run `./podman --version` and see "podman version 5.3.1"
2. **Given** I am on a minimal Linux system with no glibc, **When** I run the extracted binary, **Then** it executes without "library not found" errors
3. **Given** I download the podman-full variant, **When** I list the extracted contents, **Then** I see podman plus all runtime components (crun, conmon, fuse-overlayfs, netavark, aardvark-dns, pasta, catatonit)

---

### User Story 2 - Verify Binary Authenticity (Priority: P2)

As a security-conscious user, I want to verify the downloaded binaries using checksums and signatures so that I can trust the binaries have not been tampered with.

**Why this priority**: Security verification is essential for production use but requires working binaries first.

**Independent Test**: Download checksums.txt and signature files, then verify the tarball matches the checksum and the signature is valid.

**Acceptance Scenarios**:

1. **Given** I download a tarball and checksums.txt, **When** I run sha256sum verification, **Then** the checksum matches
2. **Given** I download the cosign signature, **When** I verify using cosign, **Then** the signature validates successfully against the Sigstore transparency log

---

### User Story 3 - Automatic New Version Detection (Priority: P3)

As a project maintainer, I want the system to automatically detect new upstream releases so that users can access updated binaries without manual intervention.

**Why this priority**: Automation reduces maintenance burden but is only valuable after the build system works correctly.

**Independent Test**: When a new podman version is released upstream, within 24 hours a corresponding GitHub Release appears in this repository.

**Acceptance Scenarios**:

1. **Given** containers/podman releases v5.4.0, **When** the daily check runs, **Then** a build is triggered for podman-v5.4.0
2. **Given** containers/buildah releases v1.39.0 but podman has no new release, **When** the daily check runs, **Then** only buildah build is triggered (podman is not rebuilt)
3. **Given** no upstream releases occurred since last check, **When** the daily check runs, **Then** no builds are triggered

---

### User Story 4 - Manual Build Trigger (Priority: P4)

As a project maintainer, I want to manually trigger a build for a specific tool and version so that I can rebuild after fixing issues or build older versions.

**Why this priority**: Manual control is a fallback mechanism when automation fails or for special cases.

**Independent Test**: Use GitHub Actions workflow_dispatch to trigger a build with specific parameters.

**Acceptance Scenarios**:

1. **Given** I have write access to the repository, **When** I trigger workflow_dispatch for podman version 5.3.0, **Then** a build starts for that specific version
2. **Given** a release already exists for podman-v5.3.0, **When** I trigger a rebuild, **Then** the existing release assets are updated (not duplicated)

---

### Edge Cases

- What happens when upstream releases a pre-release/rc version? System MUST skip pre-release versions and only build stable releases.
- What happens when the build fails for one architecture but succeeds for another? System MUST fail the entire release and not publish partial artifacts.
- What happens when GitHub API rate limit is exceeded during version check? System MUST retry with exponential backoff (3 attempts with delays: 1s, 2s, 4s) and fallback to tags API if releases API continues to fail, or fail gracefully with notification if all retries exhausted.
- What happens when cosign signing fails? System MUST fail the release and not publish unsigned artifacts.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST produce statically linked binaries that run without external library dependencies (verified via `ldd` showing "not a dynamic executable")
- **FR-002**: System MUST build binaries for linux/amd64 and linux/arm64 architectures
- **FR-003**: System MUST track and release podman, buildah, and skopeo independently based on their upstream versions
- **FR-004**: System MUST check for new upstream versions daily at a scheduled time
- **FR-005**: System MUST support manual build triggers with configurable tool and version parameters
- **FR-006**: System MUST generate SHA256 checksums for all release artifacts
- **FR-007**: System MUST sign all release artifacts using Sigstore/cosign keyless signing
- **FR-008**: System MUST provide three package variants for podman, buildah, and skopeo:
  - **standalone**: Binary only (for users with existing system runtimes)
  - **default**: Binary + minimum runtime components (crun, conmon) + configs (recommended for most users)
  - **full**: Binary + all companion tools (complete rootless stack)
- **FR-009**: System MUST skip pre-release versions (alpha, beta, rc) and only build stable releases
- **FR-010**: System MUST check GitHub Releases to track which versions have been released to avoid duplicate builds
- **FR-011**: System MUST fail the entire release if any architecture build fails (no partial releases)

### Non-Functional Requirements

- **NFR-001**: Podman-full package SHOULD NOT exceed 100MB total size (current: ~72MB for 8 components)
- **NFR-002**: Individual binary sizes SHOULD remain under 50MB (largest: podman at 44MB)

### Package Variants

**Current Build Status (as of 2025-12-15)**: All components successfully building ✅

**Verified Builds**:
- [Podman v5.7.1](https://github.com/pigfoot/static-rootless-container-tools/actions/runs/20227166202) - 6/6 builds passed
- [Buildah v1.41.7](https://github.com/pigfoot/static-rootless-container-tools/actions/runs/20227166540) - 6/6 builds passed
- [Skopeo v1.21.0](https://github.com/pigfoot/static-rootless-container-tools/actions/runs/20227166967) - 6/6 builds passed

#### Variant 1: standalone (Binary Only)

**Contents**:
- **podman/buildah/skopeo**: Main binary only (44M for podman, ~50M for buildah, ~30M for skopeo)

**Use Case**: Users with existing compatible system runtimes (runc/crun ≥ v1.1.11, latest conmon)

**Compatibility Requirements**:
- ⚠️ **Requires system runc/crun** ≥ v1.1.11 (Ubuntu 22.04 base version 1.1.0 is TOO OLD)
- ⚠️ **Requires latest conmon** (Ubuntu's conmon is typically outdated)
- ❌ **NOT RECOMMENDED** unless you have verified compatible system packages

**Known Issues**:
- Ubuntu 22.04 base: runc 1.1.0 < 1.1.11 required → Will fail
- Most distributions: conmon too old → Will fail with version mismatch errors

#### Variant 2: default (Recommended)

**Contents**:
- **Main binary**: podman/buildah/skopeo
- **Minimum runtime**: crun (2.6M), conmon (2.3M)
- **Default configs**: /etc/containers/* (registries.conf, policy.json, storage.conf)

**Total Size**: ~49M for podman-default

**Use Case**: Recommended for most users - provides core functionality without system dependencies

**Features**:
- ✅ Container execution (via crun)
- ✅ Container monitoring (via conmon)
- ✅ Basic networking (host network only)
- ❌ No custom networks (requires netavark/aardvark-dns from full variant)
- ❌ No rootless overlay mounts (requires fuse-overlayfs from full variant)

#### Variant 3: full (Complete Stack)

**Contents** (8 components):
- **podman/buildah/skopeo**: Main binary (44M/~50M/~30M)
- **conmon**: Container monitor process (2.3M, static) ✅ Fixed with libglib2.0-dev
- **crun**: OCI runtime (2.6M, static) ✅ Fixed with libcap-dev + gperf + libseccomp source build
- **netavark**: Container networking (14M, static) ✅ Fixed with Rust 1.92 + musl target
- **aardvark-dns**: DNS server for container networks (3.5M, static) ✅ Fixed with Rust 1.92 + musl target
- **pasta**: Rootless networking (1.5M + 1.5M AVX2, static) ✅ Fixed with Clang migration
- **fuse-overlayfs**: Rootless overlay filesystem (1.4M, static) ✅ Fixed with libfuse manual install
- **catatonit**: Minimal init process for containers (953K, static)

**Total Size**: ~57M for podman-full

**Use Case**: Complete rootless container stack with all features

**Features**:
- ✅ All features from default variant
- ✅ Custom container networks (netavark + aardvark-dns)
- ✅ Rootless overlay mounts (fuse-overlayfs)
- ✅ Advanced rootless networking (pasta with AVX2 optimization)
- ✅ Proper init process handling (catatonit)

### Package Naming Convention

**Tarball naming**:
- **default variant**: `{tool}-linux-{arch}.tar.zst` (simplified name, e.g., `podman-linux-amd64.tar.zst`)
- **other variants**: `{tool}-{variant}-linux-{arch}.tar.zst` (e.g., `podman-standalone-linux-amd64.tar.zst`, `podman-full-linux-amd64.tar.zst`)

**Rationale**: Default variant is the recommended option, so it gets the simplest filename for ease of use.

### Variant Comparison by Tool

#### Podman Variants

| Variant | Size | Components | Use Case |
|---------|------|------------|----------|
| **standalone** | ~44MB | `podman` | Users with system runc ≥1.1.11 + latest conmon (NOT RECOMMENDED) |
| **default** ⭐ | ~49MB | `podman` + `crun` + `conmon` + configs | Recommended - Core container functionality |
| **full** | ~74MB | default + `netavark` + `aardvark-dns` + `pasta` + `fuse-overlayfs` + `catatonit` | Complete rootless stack with networking |

**Default variant includes**:
- Main binary: podman (44MB)
- Runtime: crun (2.6MB), conmon (2.3MB)
- Configs: /etc/containers/* (registries.conf, policy.json, storage.conf)

**Full variant adds**:
- Networking: netavark (14MB), aardvark-dns (3.5MB), pasta + pasta.avx2 (3MB)
- Rootless FS: fuse-overlayfs (1.4MB)
- Init: catatonit (953KB)

#### Buildah Variants

| Variant | Size | Components | Use Case |
|---------|------|------------|----------|
| **standalone** | ~50MB | `buildah` | Users with system runc/crun + conmon (NOT RECOMMENDED) |
| **default** ⭐ | ~55MB | `buildah` + `crun` + `conmon` + configs | Recommended - Build images with `buildah run` support |
| **full** | ~56MB | default + `fuse-overlayfs` | Rootless image building with overlay mounts |

**Default variant includes**:
- Main binary: buildah (~50MB)
- Runtime: crun (2.6MB), conmon (2.3MB) ← Required for `buildah run`
- Configs: /etc/containers/*

**Full variant adds**:
- Rootless FS: fuse-overlayfs (1.4MB) ← Required for rootless overlay mounts during builds

**Note**: buildah does NOT need netavark/aardvark-dns/pasta (only uses host networking)

#### Skopeo Variants

| Variant | Size | Components | Use Case |
|---------|------|------------|----------|
| **standalone** | ~30MB | `skopeo` | Binary only |
| **default** ⭐ | ~30MB | `skopeo` + configs | Recommended - Image operations with registry configs |
| **full** | ~30MB | Same as default | Alias for default (skopeo needs no runtime components) |

**Default variant includes**:
- Main binary: skopeo (~30MB)
- Configs: /etc/containers/* (registries.conf, policy.json)

**Note**: skopeo does NOT run containers, so default and full variants are identical

### Key Entities

- **Tool**: One of podman, buildah, or skopeo with its version tracking
- **Release**: A GitHub Release containing artifacts for a specific tool version
- **Artifact**: A tarball containing binaries for a specific architecture and variant
- **Checksum**: SHA256 hash file for verification
- **Signature**: Cosign signature for authenticity verification

## Assumptions

- Upstream repositories (containers/podman, containers/buildah, containers/skopeo) follow semantic versioning
- GitHub Actions has sufficient runner time for multi-architecture builds
- Sigstore/cosign keyless signing remains available and free for open source projects
- Critical runtime components (libseccomp, libfuse) are built from source for reproducibility and compatibility (see [MIGRATION-ZIG-TO-CLANG.md](./MIGRATION-ZIG-TO-CLANG.md))

**Note on MIGRATION-ZIG-TO-CLANG.md**: This document should cover: (1) Zig compatibility issues encountered (pasta `__cpu_model` symbol, fuse-overlayfs meson detection failures), (2) Clang migration solution with musl target, (3) Build time impact analysis (+1-2 minutes for container setup), (4) Verification that all 8/8 components build successfully with Clang, (5) Containerization benefits (reproducibility, isolation)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Static binaries execute successfully on at least 3 different Linux distributions (Alpine, Ubuntu, CentOS/Rocky) without installing additional packages
- **SC-002**: New upstream stable releases result in corresponding GitHub Releases within 24 hours
- **SC-003**: All release artifacts pass checksum verification (100% integrity)
- **SC-004**: All release artifacts pass cosign signature verification (100% authenticity)
- **SC-005**: Build-to-release time for a single tool is under 30 minutes **per architecture** (includes compilation, packaging, signing, and upload for one architecture; total pipeline may run architectures in parallel)
- **SC-006**: Users can download and run a tool in under 5 minutes (download, extract, execute)
