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
- What happens when GitHub API rate limit is exceeded during version check? System MUST retry with exponential backoff or fail gracefully with notification.
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
- **FR-008**: System MUST provide two podman variants: "full" (with runtime components) and "minimal" (binary only)
- **FR-009**: System MUST skip pre-release versions (alpha, beta, rc) and only build stable releases
- **FR-010**: System MUST check GitHub Releases to track which versions have been released to avoid duplicate builds
- **FR-011**: System MUST fail the entire release if any architecture build fails (no partial releases)

### Non-Functional Requirements

- **NFR-001**: Podman-full package SHOULD NOT exceed 100MB total size (current: ~72MB for 8 components)
- **NFR-002**: Individual binary sizes SHOULD remain under 50MB (largest: podman at 44MB)

### Podman Full Package Components

**Current Build Status (as of 2025-12-14)**: 8/8 components successfully building (100%) ✅

**✅ All Components Building Successfully**:
- **podman**: Main container management tool (44M, static)
- **conmon**: Container monitor process (2.0M, static) ✅ Fixed with libglib2.0-dev
- **crun**: OCI runtime (3.6M, static) ✅ Fixed with libcap-dev + libseccomp source build
- **netavark**: Container networking (14M, static) ✅ Fixed with Rust musl target
- **aardvark-dns**: DNS server for container networks (3.5M, static) ✅ Fixed with Rust musl target
- **pasta**: Rootless networking (1.3M + 1.3M AVX2, static) ✅ Fixed with Clang migration
- **fuse-overlayfs**: Rootless overlay filesystem (1.3M, static) ✅ Fixed with libfuse manual install
- **catatonit**: Minimal init process for containers (847K, static)

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

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Static binaries execute successfully on at least 3 different Linux distributions (Alpine, Ubuntu, CentOS/Rocky) without installing additional packages
- **SC-002**: New upstream stable releases result in corresponding GitHub Releases within 24 hours
- **SC-003**: All release artifacts pass checksum verification (100% integrity)
- **SC-004**: All release artifacts pass cosign signature verification (100% authenticity)
- **SC-005**: Build-to-release time for a single tool is under 30 minutes **per architecture** (includes compilation, packaging, signing, and upload for one architecture; total pipeline may run architectures in parallel)
- **SC-006**: Users can download and run a tool in under 5 minutes (download, extract, execute)
