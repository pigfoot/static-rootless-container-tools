<!--
Sync Impact Report
==================
Version change: 1.2.1 → 1.3.0
Bump rationale: Add third package variant (standalone/default/full) - MINOR

Modified sections:
  - Principle IV (Minimal Dependencies): Updated from 2 variants (full/minimal) to 3 variants (standalone/default/full)
  - Build Artifacts: Updated naming convention and artifact table for 3 variants
  - Added size information for all variants per tool

Rationale:
  - Standalone variant for users with compatible system runtimes (NOT RECOMMENDED)
  - Default variant with minimum required runtime (RECOMMENDED) - uses simplified naming
  - Full variant with complete rootless stack
  - Improves user experience with clearer variant purposes
  - Default variant gets simplified filename for ease of use

Templates requiring updates:
  - .specify/templates/plan-template.md: ✅ No changes needed (generic template)
  - .specify/templates/spec-template.md: ✅ No changes needed (generic template)
  - .specify/templates/tasks-template.md: ✅ No changes needed (generic template)

Follow-up TODOs: Update tasks.md to use new variant terminology

Previous changes:
==================
Version 1.2.0 → 1.2.1 (PATCH)
- Adjusted daily check schedule from UTC 00:00 to UTC 02:00

Version 1.1.0 → 1.2.0 (MINOR)
- Migration from Zig to Clang due to compatibility issues
- Updated Principle III (Reproducible Builds): "documented minimum versions"
- Updated Build Environment: Clang with musl target
- Updated Minimum Requirements: Clang, Go 1.21+, protobuf-compiler
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

- Use well-defined build dependencies with documented minimum versions
- Document exact build steps in scripts and Makefile
- Maintain Alpine-based Dockerfile as reproducibility fallback
- Same inputs MUST produce functionally equivalent outputs
- Build environment can be recreated from documentation

**Rationale**: Reproducibility enables verification, debugging, and trust in the build artifacts.

### IV. Minimal Dependencies

Include only components strictly necessary for functionality.

All tools provide three package variants:
- **standalone**: Binary only (for users with existing compatible system runtimes)
- **default**: Binary + minimum runtime components (crun, conmon) + configs (recommended for most users)
- **full**: Binary + all companion tools (complete rootless stack)

Specific variant contents:
- Podman default: podman + crun + conmon + configs (~49MB)
- Podman full: default + netavark + aardvark-dns + pasta + fuse-overlayfs + catatonit (~74MB)
- Buildah default: buildah + crun + conmon + configs (~55MB)
- Buildah full: default + fuse-overlayfs (~56MB)
- Skopeo: all variants identical (~30MB, no runtime components needed)

Principles:
- No optional features or plugins unless explicitly justified
- YAGNI: do not add components "just in case"
- Default variant recommended for most users (includes minimum required runtime)

**Rationale**: Minimal dependencies reduce attack surface, binary size, and maintenance burden. Three variants provide flexibility while keeping defaults lean.

### V. Automated Release Pipeline

Version detection and releases MUST be fully automated.

- Daily scheduled check (UTC 02:00) for new upstream versions via GitHub API
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

For each tool release, three variants are provided:

| Artifact | Description |
|----------|-------------|
| `{tool}-linux-{arch}.tar.zst` | Default variant (simplified name) - binary + crun + conmon + configs |
| `{tool}-standalone-linux-{arch}.tar.zst` | Standalone variant - binary only |
| `{tool}-full-linux-{arch}.tar.zst` | Full variant - complete rootless stack |
| `checksums.txt` | SHA256 checksums for all tarballs |
| `*.bundle` | Cosign signature bundles (keyless OIDC) |

**Naming Convention**:
- Default variant uses simplified filename for ease of use (e.g., `podman-linux-amd64.tar.zst`)
- Other variants include variant name (e.g., `podman-full-linux-amd64.tar.zst`)

**Per-tool Differences**:
- Podman full: Adds netavark, aardvark-dns, pasta, fuse-overlayfs, catatonit
- Buildah full: Adds fuse-overlayfs only
- Skopeo: All variants identical (no runtime components needed)

### Build Environment

- **Primary**: Clang with musl target (GCC compatibility, build system support)
- **Fallback**: Alpine Linux container with musl-based toolchain
- **Allocator**: mimalloc (statically linked, replaces musl's slow allocator)
- **Cross-compilation**: Clang cross-compile on amd64 runner; native arm64 runner as fallback
- **Minimum Requirements**: Clang (any version with musl support), Go 1.21+, protobuf-compiler (for Rust components)

## Release Pipeline

### Version Detection

```
Schedule: Daily at UTC 02:00
Method: curl + GitHub API (no authentication required for public repos)
  - Endpoint: https://api.github.com/repos/{org}/{repo}/releases
  - Fallback: https://api.github.com/repos/{org}/{repo}/tags
  - Filter: Semver regex ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ (excludes pre-releases)
Upstream repos:
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

**Version**: 1.3.0 | **Ratified**: 2025-12-12 | **Last Amended**: 2025-12-15
