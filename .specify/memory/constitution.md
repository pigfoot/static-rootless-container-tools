<!--
Sync Impact Report
==================
Version change: 0.0.0 → 1.0.0
Bump rationale: Initial constitution creation (MAJOR)

Modified principles: N/A (initial creation)
Added sections:
  - Core Principles (5 principles)
  - Build Requirements
  - Release Pipeline
  - Governance

Templates requiring updates:
  - .specify/templates/plan-template.md: ✅ No changes needed (generic template)
  - .specify/templates/spec-template.md: ✅ No changes needed (generic template)
  - .specify/templates/tasks-template.md: ✅ No changes needed (generic template)

Follow-up TODOs: None
-->

# Rootless Static Toolkits Constitution

## Core Principles

### I. Truly Static Binaries

All produced binaries MUST be fully statically linked with zero runtime library dependencies.

- Build using musl libc (Alpine-based) to achieve true static linking
- Binaries MUST run on any Linux distribution without additional libraries
- No dynamic linking to glibc, NSS, or other system libraries
- Verify static linking with `ldd` showing "not a dynamic executable"

**Rationale**: Static binaries ensure portability across any Linux environment without dependency conflicts or missing library issues.

### II. Independent Tool Releases

Each tool (podman, buildah, skopeo) MUST be tracked and released independently.

- Version tracking follows upstream releases (e.g., `podman-v5.3.1`, `buildah-v1.38.0`)
- A new upstream version of one tool does NOT trigger rebuilds of other tools
- Each tool has its own GitHub Release with tool-specific assets
- Release tags follow pattern: `{tool}-v{version}` (e.g., `podman-v5.3.1`)

**Rationale**: Independent releases reduce unnecessary builds and allow users to update tools selectively.

### III. Reproducible Builds

Build processes MUST be deterministic and reproducible.

- All builds run in containerized environments (Alpine-based Dockerfile)
- Pin specific versions of build dependencies where possible
- Document exact build steps in Dockerfile and Makefile
- Same inputs MUST produce functionally equivalent outputs

**Rationale**: Reproducibility enables verification, debugging, and trust in the build artifacts.

### IV. Minimal Dependencies

Include only components strictly necessary for functionality.

- Podman full package: include required runtime components (crun, conmon, fuse-overlayfs, netavark, aardvark-dns, pasta, catatonit)
- Podman minimal package: include only podman binary
- Buildah and skopeo: include only the tool binary (no additional runtime needed)
- No optional features or plugins unless explicitly justified
- YAGNI: do not add components "just in case"

**Rationale**: Minimal dependencies reduce attack surface, binary size, and maintenance burden.

### V. Automated Release Pipeline

Version detection and releases MUST be fully automated.

- Daily scheduled check (UTC 00:00) for new upstream versions via GitHub API
- Manual trigger support via workflow_dispatch for on-demand builds
- Automatic GitHub Release creation with:
  - Tarballs for linux/amd64 and linux/arm64
  - SHA256 checksums
  - Sigstore/cosign signatures (keyless signing)
- No manual intervention required for standard releases

**Rationale**: Automation ensures timely releases, eliminates human error, and reduces maintenance overhead.

## Build Requirements

### Target Platforms

| Architecture | OS | Status |
|--------------|------|--------|
| amd64 | Linux | Required |
| arm64 | Linux | Required |

### Build Artifacts

For each tool release:

| Artifact | Description |
|----------|-------------|
| `{tool}-linux-amd64.tar.gz` | Binary tarball for amd64 |
| `{tool}-linux-arm64.tar.gz` | Binary tarball for arm64 |
| `checksums.txt` | SHA256 checksums for all tarballs |
| `*.sig` or cosign signature | Sigstore/cosign signatures |

Podman additionally provides:
- `podman-full-linux-{arch}.tar.gz` - includes all runtime components
- `podman-minimal-linux-{arch}.tar.gz` - podman binary only

### Build Environment

- Base image: Alpine Linux (latest stable)
- Compiler: musl-based GCC toolchain
- Cross-compilation: buildx or native arm64 runners for arm64 builds

## Release Pipeline

### Version Detection

```
Schedule: Daily at UTC 00:00
Method: GitHub API check against upstream repos
  - github.com/containers/podman
  - github.com/containers/buildah
  - github.com/containers/skopeo
```

### Trigger Conditions

- **Automatic**: New release tag detected in upstream repo
- **Manual**: workflow_dispatch with tool name and version parameters

### Release Process

1. Detect new version (scheduled or manual trigger)
2. Build binaries for all target architectures
3. Generate checksums
4. Sign with sigstore/cosign
5. Create GitHub Release with tag `{tool}-v{version}`
6. Upload all artifacts

## Governance

### Amendment Process

1. Propose changes via pull request modifying this constitution
2. Document rationale for changes
3. Update dependent templates if principles change
4. Increment version according to semver:
   - MAJOR: Principle removal or fundamental change
   - MINOR: New principle or significant expansion
   - PATCH: Clarification or typo fix

### Compliance

- All PRs MUST verify alignment with these principles
- Build failures due to principle violations MUST be fixed, not worked around
- Exceptions require documented justification in the PR

### Reference Documents

- Upstream reference: https://github.com/mgoltzsche/podman-static
- Container tools: https://github.com/containers

**Version**: 1.0.0 | **Ratified**: 2025-12-12 | **Last Amended**: 2025-12-12
