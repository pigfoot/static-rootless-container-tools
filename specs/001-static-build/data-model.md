# Data Model: Static Container Tools Build System

**Feature**: 001-static-build
**Created**: 2025-12-14
**Context**: Containerized build system using podman + Ubuntu containers

## Overview

This document defines the core entities, their relationships, and state transitions for the automated static binary build and release system. **Updated to reflect containerized builds using podman + docker.io/ubuntu:rolling**.

## Core Entities

### 1. Tool

Represents a container tool to be built and released.

**Fields**:
```yaml
name: string              # "podman" | "buildah" | "skopeo"
upstreamRepo: string      # GitHub repo path (e.g., "containers/podman")
latestVersion: Version    # Latest detected upstream version
lastChecked: timestamp    # Last time upstream was checked
variants: Variant[]       # Build variants (all tools have "standalone", "default", "full")
```

**Validation Rules**:
- `name` MUST be one of: "podman", "buildah", "skopeo"
- `upstreamRepo` MUST follow pattern "org/repo"
- `latestVersion` MUST match semver pattern `^v?[0-9]+\.[0-9]+(\.[0-9]+)?$`
- `lastChecked` MUST NOT be older than 25 hours (daily check requirement)

**Invariants**:
- All tools provide 3 variants (standalone, default, full)
- Default variant recommended for most users (includes minimum required runtime)
- Skopeo variants are functionally identical (skopeo doesn't run containers)

**Example**:
```yaml
name: podman
upstreamRepo: containers/podman
latestVersion: v5.3.1
lastChecked: 2025-12-14T00:00:00Z
variants:
  - name: standalone
    components: [podman]
  - name: default
    components: [podman, crun, conmon]
  - name: full
    components: [podman, crun, conmon, fuse-overlayfs, netavark, aardvark-dns, pasta, catatonit]
```

---

### 2. Version

Represents a semantic version from upstream releases.

**Fields**:
```yaml
tag: string               # Git tag (e.g., "v5.3.1")
semver: string           # Normalized semver (e.g., "5.3.1")
isStable: boolean        # true if NOT pre-release (alpha, beta, rc)
detectedAt: timestamp    # When this version was first detected
source: string           # "releases" | "tags"
```

**Validation Rules**:
- `tag` MUST match pattern `^v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-z0-9.]+)?$`
- `semver` MUST be pure semver without 'v' prefix
- `isStable` = true IFF tag does NOT contain: alpha, beta, rc, dev, pre
- `source` MUST be "releases" or "tags"

**State Transitions**:
```
[Upstream Release] → (detected) → [Version Created]
                  → (isStable=false) → [Ignored]
                  → (isStable=true) → [Queued for Build]
```

**Example**:
```yaml
tag: v5.3.1
semver: 5.3.1
isStable: true
detectedAt: 2025-12-14T00:05:23Z
source: releases
```

---

### 3. BuildJob

Represents a single GitHub Actions workflow execution for building a tool variant.

**Fields**:
```yaml
id: string                # GitHub Actions run ID
tool: Tool               # Reference to Tool entity
version: Version         # Version being built
variant: string          # Variant name ("standalone" | "default" | "full")
architecture: string     # "amd64" | "arm64"
status: BuildStatus      # Current build status
triggeredBy: string      # "schedule" | "workflow_dispatch" | "manual"
startedAt: timestamp
completedAt: timestamp?
containerImage: string   # "docker.io/ubuntu:rolling"
artifacts: Artifact[]    # Generated artifacts
logs: string            # Container build logs
```

**Validation Rules**:
- `architecture` MUST be one of: "amd64", "arm64"
- `variant` MUST exist in Tool.variants[]
- `status` MUST follow state machine (see below)
- `triggeredBy` MUST be one of: "schedule", "workflow_dispatch", "manual"
- `containerImage` MUST be valid OCI image reference

**State Machine**:
```
┌─────────┐
│ Queued  │
└────┬────┘
     │
     ├─→ [Container Pull] ─→ Pulling
     │
     ├─→ [Setup Failed] ─→ Failed (container_setup)
     │
     └─→ [Build Started] ─→ Building
              │
              ├─→ [Build Failed] ─→ Failed (build_error)
              │
              ├─→ [Test Failed] ─→ Failed (test_error)
              │
              └─→ [Build Success] ─→ Packaging
                       │
                       ├─→ [Package Failed] ─→ Failed (package_error)
                       │
                       └─→ [Package Success] ─→ Completed
```

**Status Values**:
- `queued`: Workflow triggered, waiting to start
- `pulling`: Pulling container image (docker.io/ubuntu:rolling)
- `building`: Running build inside container
- `packaging`: Creating tarball from artifacts
- `completed`: Successfully built and packaged
- `failed`: Build failed (see substatus for details)

**Failure Substatus**:
- `container_setup`: Failed to pull/start container
- `build_error`: Compilation failed
- `test_error`: Static linking verification failed
- `package_error`: Tarball creation failed

**Example**:
```yaml
id: "12345678"
tool: podman
version: v5.3.1
variant: full
architecture: amd64
status: building
triggeredBy: schedule
startedAt: 2025-12-14T00:10:00Z
containerImage: docker.io/ubuntu:rolling
artifacts: []
logs: "Pulling image...\nInstalling dependencies..."
```

---

### 4. Artifact

Represents a release artifact (tarball, checksum, signature).

**Fields**:
```yaml
id: string               # Unique artifact ID
type: ArtifactType       # "tarball" | "checksum" | "signature"
filename: string         # Final filename (e.g., "podman-full-linux-amd64.tar.zst")
path: string            # Local build path before upload
size: number            # File size in bytes
sha256: string?         # SHA256 hash (for tarballs)
uploadedAt: timestamp?  # When uploaded to GitHub Release
uploadUrl: string?      # GitHub asset URL
```

**Validation Rules**:
- `type` MUST be one of: "tarball", "checksum", "signature"
- `filename` MUST follow pattern:
  - Tarball: `{tool}(-{variant})?-linux-{arch}.tar.zst`
  - Checksum: `checksums.txt`
  - Signature: `*.sig` or cosign bundle
- `sha256` MUST be 64-character hex string (for type=tarball)
- `size` MUST be > 0 and < 100MB (NFR-001)

**Relationships**:
- Each BuildJob produces 1 tarball Artifact
- Each Release consolidates checksums from all BuildJobs into 1 checksum Artifact
- Each tarball gets 1 signature Artifact (cosign)

**Example**:
```yaml
id: "art_001"
type: tarball
filename: podman-full-linux-amd64.tar.zst
path: /workspace/build/podman-amd64/podman-full-linux-amd64.tar.zst
size: 75497472  # ~72MB
sha256: "a1b2c3d4..."
uploadedAt: 2025-12-14T00:25:00Z
uploadUrl: https://github.com/.../releases/download/podman-v5.3.1/podman-full-linux-amd64.tar.zst
```

---

### 5. Release

Represents a GitHub Release for a specific tool version.

**Fields**:
```yaml
id: string               # GitHub Release ID
tool: Tool              # Reference to Tool entity
version: Version        # Version being released
tag: string             # Git tag (e.g., "podman-v5.3.1")
status: ReleaseStatus   # Current release status
createdAt: timestamp
publishedAt: timestamp?
artifacts: Artifact[]   # All artifacts for this release
buildJobs: BuildJob[]   # Associated build jobs
checksumFile: Artifact? # Consolidated checksums.txt
```

**Validation Rules**:
- `tag` MUST follow pattern `{tool}-v{version}`
- `status` MUST follow state machine (see below)
- ALL buildJobs MUST have status="completed" before publishing
- MUST have artifacts for both amd64 and arm64 (FR-011: no partial releases)
- All tool releases MUST have artifacts for all 3 variants (standalone, default, full) and both architectures

**State Machine**:
```
┌─────────┐
│ Pending │  ← Release detected, no builds yet
└────┬────┘
     │
     ├─→ [Builds Queued] ─→ Building
     │                         │
     │                         ├─→ [Any Build Failed] ─→ Failed
     │                         │
     │                         └─→ [All Builds Complete] ─→ Signing
     │                                                        │
     │                                                        ├─→ [Sign Failed] ─→ Failed
     │                                                        │
     │                                                        └─→ [Sign Success] ─→ Publishing
     │                                                                               │
     │                                                                               └─→ Published
     │
     └─→ [Already Released] ─→ Skipped
```

**Release Completeness Check**:
```python
def is_release_complete(release: Release) -> bool:
    required_architectures = ["amd64", "arm64"]
    required_variants = ["standalone", "default", "full"]

    # All tools must have all 3 variants for both architectures
    for arch in required_architectures:
        for variant in required_variants:
            if not has_artifact(release, arch, variant):
                return False

    return has_checksums(release) and all_signed(release)
```

**Example**:
```yaml
id: "rel_001"
tool: podman
version: v5.3.1
tag: podman-v5.3.1
status: building
createdAt: 2025-12-14T00:10:00Z
artifacts:
  - podman-linux-amd64.tar.zst           # default variant (simplified name)
  - podman-linux-arm64.tar.zst           # default variant (simplified name)
  - podman-standalone-linux-amd64.tar.zst
  - podman-standalone-linux-arm64.tar.zst
  - podman-full-linux-amd64.tar.zst
  - podman-full-linux-arm64.tar.zst
buildJobs:
  - [amd64, standalone]
  - [amd64, default]
  - [amd64, full]
  - [arm64, standalone]
  - [arm64, default]
  - [arm64, full]
```

---

### 6. Container

Represents the containerized build environment (NEW for containerized builds).

**Fields**:
```yaml
id: string               # Podman container ID
image: string           # "docker.io/ubuntu:rolling"
buildJob: BuildJob      # Associated build job
status: ContainerStatus # Current container status
createdAt: timestamp
stoppedAt: timestamp?
exitCode: number?       # Container exit code (0 = success)
volumeMounts: Mount[]   # Volume mounts
environment: Map<string, string>  # Environment variables
logs: string            # Container stdout/stderr
```

**Validation Rules**:
- `image` MUST be "docker.io/ubuntu:rolling" (per user requirement)
- `exitCode` values:
  - 0: Success
  - 1-2: Build errors
  - 3: Test failures
  - 125-127: Container runtime errors
- `volumeMounts` MUST include:
  - `/workspace/scripts` (ro) - Build scripts
  - `/workspace/build` (rw) - Build output

**Mount Schema**:
```yaml
source: string          # Host path
target: string          # Container path
readonly: boolean       # Read-only flag
selinuxLabel: string?   # ":z" for shared SELinux label
```

**State Machine**:
```
┌─────────┐
│ Created │
└────┬────┘
     │
     ├─→ [Container Started] ─→ Running
     │                            │
     │                            ├─→ [Exit Code 0] ─→ Exited (success)
     │                            │
     │                            └─→ [Exit Code ≠ 0] ─→ Exited (failed)
     │
     └─→ [Start Failed] ─→ Failed
```

**Example**:
```yaml
id: "abc123def"
image: docker.io/ubuntu:rolling
buildJob: [BuildJob ref]
status: running
createdAt: 2025-12-14T00:10:30Z
volumeMounts:
  - source: ./scripts
    target: /workspace/scripts
    readonly: true
    selinuxLabel: :z
  - source: ./build
    target: /workspace/build
    readonly: false
    selinuxLabel: :z
environment:
  VERSION: "5.3.1"
  TOOL: "podman"
  ARCH: "amd64"
  VARIANT: "full"
logs: "Pulling image...\nRunning setup-build-env.sh..."
```

---

## Entity Relationships

```
Tool (1) ──────< (N) Release
  │                    │
  │                    └──< (N) BuildJob ──< (1) Container
  │                            │
  │                            └──< (N) Artifact
  │
  └──< (1) Version (latestVersion)
```

**Cardinality**:
- 1 Tool → N Releases (one per version)
- 1 Release → N BuildJobs (one per architecture × variant)
- 1 BuildJob → 1 Container (ephemeral)
- 1 BuildJob → N Artifacts (tarball + signature)
- 1 Release → 1 Checksum Artifact (consolidated)

---

## State Transition Constraints

### Build Pipeline Invariants

1. **No Partial Releases** (FR-011):
   - Release status CANNOT transition to "published" if ANY BuildJob failed
   - ALL architectures (amd64, arm64) MUST complete successfully
   - For podman: ALL variants (full, minimal) MUST complete successfully

2. **Container Isolation**:
   - Each BuildJob gets a fresh ephemeral Container
   - Container is ALWAYS destroyed after BuildJob completes/fails
   - No container reuse between BuildJobs

3. **Artifact Integrity**:
   - Tarball Artifacts MUST have sha256 before upload
   - Signature Artifacts MUST reference a tarball Artifact
   - Checksum Artifact generated ONLY after ALL tarballs complete

4. **Version Tracking**:
   - Tool.latestVersion updates ONLY when new stable Version detected
   - Pre-release Versions (isStable=false) NEVER trigger BuildJobs
   - Existing Release tags prevent duplicate builds

### Failure Handling

**BuildJob Failure**:
```
BuildJob.status = failed
  ↓
Container.logs extracted
  ↓
Release.status = failed (if any BuildJob fails)
  ↓
GitHub Release NOT published
  ↓
User notified via GitHub Actions output
```

**Container Failure**:
```
Container.exitCode ≠ 0
  ↓
BuildJob.status = failed (substatus from exitCode)
  ↓
Container logs copied to runner
  ↓
Logs uploaded as GitHub Actions artifact
```

---

## Data Flow Example

### Daily Scheduled Check Flow

```
1. Scheduled Trigger (UTC 00:00)
   ↓
2. Query upstream GitHub API
   ↓
3. Detect new Version: podman v5.3.1 (isStable=true)
   ↓
4. Check existing Releases: podman-v5.3.1 does NOT exist
   ↓
5. Create Release (status=pending)
   ↓
6. Queue BuildJobs (3 variants × 2 architectures = 6 jobs):
   - podman/amd64/standalone
   - podman/amd64/default
   - podman/amd64/full
   - podman/arm64/standalone
   - podman/arm64/default
   - podman/arm64/full
   ↓
7. For each BuildJob:
   a. Create Container (docker.io/ubuntu:rolling)
   b. Mount volumes (/workspace/scripts:ro, /workspace/build:rw)
   c. Run setup-build-env.sh (install dependencies)
   d. Run build-tool.sh podman amd64 full
   e. Extract artifacts from /workspace/build
   f. Destroy Container
   ↓
8. All BuildJobs complete successfully
   ↓
9. Generate checksums.txt (consolidated)
   ↓
10. Sign artifacts with cosign
   ↓
11. Release.status = publishing
   ↓
12. Upload all Artifacts to GitHub Release
   ↓
13. Release.status = published
   ↓
14. Tool.latestVersion = v5.3.1
```

---

## Validation Rules Summary

| Entity | Key Validations |
|--------|----------------|
| **Tool** | name ∈ {podman, buildah, skopeo}, upstreamRepo valid, lastChecked < 25h |
| **Version** | semver pattern, isStable = !contains(alpha\|beta\|rc) |
| **BuildJob** | arch ∈ {amd64, arm64}, variant in Tool.variants, status follows state machine |
| **Artifact** | filename pattern, size < 100MB (NFR-001), sha256 for tarballs |
| **Release** | tag = {tool}-v{version}, ALL builds complete, both archs present |
| **Container** | image = ubuntu:rolling, exitCode semantics, required mounts |

---

## Performance Constraints

From NFR-001 and NFR-002:

- **Podman-full package**: SHOULD NOT exceed 100MB total (currently ~74MB)
- **Individual binaries**: SHOULD remain under 50MB (podman at 44MB is largest)

**Monitoring**:
- Track Artifact.size for each tarball
- Alert if podman-full exceeds 85MB (15MB buffer)
- Alert if any binary exceeds 45MB (5MB buffer)

---

## Appendix: Type Definitions

```typescript
type ArtifactType = "tarball" | "checksum" | "signature"

type BuildStatus =
  | "queued"
  | "pulling"
  | "building"
  | "packaging"
  | "completed"
  | "failed"

type ReleaseStatus =
  | "pending"
  | "building"
  | "signing"
  | "publishing"
  | "published"
  | "failed"
  | "skipped"

type ContainerStatus =
  | "created"
  | "running"
  | "exited"
  | "failed"

type Architecture = "amd64" | "arm64"

type TriggerSource = "schedule" | "workflow_dispatch" | "manual"
```
