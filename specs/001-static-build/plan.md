# Implementation Plan: Static Container Tools Build System

**Branch**: `001-static-build` | **Date**: 2025-12-14 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-static-build/spec.md`

## Summary

Build a fully automated release pipeline for static podman, buildah, and skopeo binaries targeting linux/amd64 and linux/arm64. **All builds execute inside Ubuntu containers (docker.io/ubuntu:rolling) using podman on GitHub Actions runners.** Uses Clang with musl target and mimalloc for optimal static binaries. Each tool is tracked and released independently based on upstream versions, with daily automated checks and manual trigger support.

## Technical Context

**Language/Version**: Bash scripts, YAML (GitHub Actions), Containerized builds (podman + Ubuntu:rolling)
**Compiler**: Clang 18+ with musl target (installed in container)
**Libc**: musl (for truly static binaries)
**Allocator**: mimalloc (static linked, replaces musl's slow allocator)
**Build Environment**: Ubuntu:rolling container (docker.io/ubuntu:rolling) running on GitHub Actions via podman
**Primary Dependencies**:
  - **Runner**: podman (only dependency on runner itself)
  - **Container**: Go toolchain, Clang, musl-dev, musl-tools, protobuf-compiler, Rust/Cargo
**Storage**: N/A (version tracking via GitHub Releases)
**Testing**: Shell-based smoke tests (ldd verification, version checks, binary execution)
**Target Platform**: GitHub Actions runners (ubuntu-latest) running podman containers
**Project Type**: Build infrastructure / CI-CD pipeline
**Performance Goals**: Build-to-release < 30 minutes per tool per architecture
**Constraints**:
  - GitHub Actions runner limits
  - Container startup overhead (~1-2 minutes)
  - Upstream release frequency
**Scale/Scope**: 3 tools × 3 variants × 2 architectures = 18 artifacts per release cycle

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Truly Static Binaries | ✅ PASS | Clang + musl target produces static binaries; verified with `ldd`; containerized build ensures clean environment |
| II. Independent Tool Releases | ✅ PASS | Separate workflows per tool; version tracking per tool |
| III. Reproducible Builds | ✅ PASS | **IMPROVED**: Container-based builds ensure exact same environment; Ubuntu:rolling provides consistent package versions; exact build steps in scripts |
| IV. Minimal Dependencies | ✅ PASS | Three variants (standalone/default/full); default has minimum required runtime; full has complete stack; **runner only needs podman** |
| V. Automated Release Pipeline | ✅ PASS | Daily cron + workflow_dispatch; cosign signing; auto GitHub Release |

**Constitution Alignment Improvements**:
- **Reproducibility**: Container-based builds provide **stronger** reproducibility than runner-native builds
- **Minimal Runner Dependencies**: Runner only needs podman, all other dependencies isolated in container
- **Clean Build Environment**: Each build starts from fresh Ubuntu container, eliminating state pollution

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
    ├── build-podman.yml         # Build + release podman (containerized)
    ├── build-buildah.yml        # Build + release buildah (containerized)
    └── build-skopeo.yml         # Build + release skopeo (containerized)

scripts/
├── check-version.sh             # Compare upstream vs local releases
├── build-tool.sh                # Common build logic (Clang + Go + mimalloc) - runs IN container
├── package.sh                   # Create tarball - runs IN container
├── sign-release.sh              # Cosign signing - runs on runner
└── container/
    ├── setup-build-env.sh       # Install dependencies inside container
    └── run-build.sh             # Wrapper script to execute build in container

build/
├── mimalloc/                    # mimalloc source for static compilation
└── patches/                     # Any patches needed for dependencies

Containerfile.build              # Container build environment definition (optional)
Makefile                         # Local build/test commands
```

**Structure Decision**: Build infrastructure project with **containerized GitHub Actions workflows** as primary. Podman runs Ubuntu:rolling container on each build; scripts execute inside container; runner only needs podman installed.

## Build Workflow Architecture

### Container-based Build Flow

```
GitHub Actions Runner (ubuntu-latest)
│
├── Install: podman (via apt-get)
│
├── Pull: docker.io/ubuntu:rolling
│
├── Run Container with:
│   ├── Mount: ./scripts → /workspace/scripts
│   ├── Mount: ./build → /workspace/build
│   ├── Env: VERSION, TOOL, ARCH, VARIANT
│   │
│   └── Inside Container:
│       ├── scripts/container/setup-build-env.sh
│       │   ├── apt-get install clang musl-dev musl-tools
│       │   ├── apt-get install golang-go
│       │   ├── apt-get install cargo rustc
│       │   ├── apt-get install protobuf-compiler
│       │   ├── apt-get install autoconf automake libtool
│       │   └── apt-get install meson ninja-build
│       │
│       └── scripts/build-tool.sh podman amd64 full
│           ├── Clone upstream sources
│           ├── Build mimalloc
│           ├── Build main tool (Go)
│           ├── Build runtime components (C/Rust)
│           └── Output: /workspace/build/podman-amd64/install/
│
├── Package: scripts/package.sh (in container)
│
├── Copy packaged tarballs from container to runner
│
└── Sign: scripts/sign-release.sh (on runner with cosign)
```

### Container Execution Strategy

**Option 1: Ephemeral containers** (RECOMMENDED)
```bash
podman run --rm \
  -v ./scripts:/workspace/scripts:ro \
  -v ./build:/workspace/build:rw \
  -e VERSION=$VERSION \
  -e TOOL=$TOOL \
  -e ARCH=$ARCH \
  docker.io/ubuntu:rolling \
  bash -c "
    /workspace/scripts/container/setup-build-env.sh && \
    /workspace/scripts/build-tool.sh $TOOL $ARCH $VARIANT
  "
```

**Benefits**:
- Fresh environment every build
- No state pollution between builds
- Automatic cleanup after build

**Option 2: Persistent build image** (FALLBACK)
- Build custom image with dependencies pre-installed
- Faster startup (no apt-get install delay)
- Trade-off: Need to maintain Containerfile

## Runtime Component Build Requirements

### Go Components (podman, buildah, skopeo)
- **Build System**: Go modules
- **Dependencies**: Go 1.21+ (installed via apt-get in container)
- **CGO**: Enabled with Clang cross-compiler
- **Static Linking**: `-ldflags "-linkmode external -extldflags '-static'"`

### Rust Components (netavark, aardvark-dns)
- **Build System**: Cargo
- **Dependencies**: Rust/Cargo (via apt-get), protobuf-compiler
- **Static Linking**: Use musl target (`--target x86_64-unknown-linux-musl`)
- **Fallback**: RUSTFLAGS with `+crt-static`

### C Components with Make (conmon, pasta, catatonit)
- **Build System**: Makefile
- **Dependencies**: Clang, musl-dev, make
- **Special Requirements**:
  - conmon: Requires libglib2.0-dev
  - pasta: Source from `git://passt.top/passt`
  - catatonit: Direct copy from build directory

### C Components with Autotools (crun)
- **Build System**: autotools (./configure)
- **Dependencies**: Clang, musl-dev, autoconf, automake, libcap-dev
- **Configure Flags**: `--disable-systemd --enable-embedded-yajl`
- **Static Linking**: `LDFLAGS='-static-libgcc -all-static'`
- **libseccomp**: Built from source (v2.5.5)

### C Components with Meson (fuse-overlayfs)
- **Build System**: meson + ninja
- **Dependencies**: Clang, musl-dev, meson, ninja
- **Two-Stage Build**: libfuse (meson) → fuse-overlayfs (autotools)
- **libfuse**: Built from source with manual install

## Build Artifacts

### Release Naming

- Tag format: `{tool}-v{version}` (e.g., `podman-v5.3.1`)
- Release title: `{Tool} {version}` (e.g., `Podman 5.3.1`)

### Artifact Structure

For podman (3 variants):
```
podman-linux-amd64.tar.zst          # default variant (simplified name)
podman-linux-arm64.tar.zst          # default variant (simplified name)
podman-standalone-linux-amd64.tar.zst
podman-standalone-linux-arm64.tar.zst
podman-full-linux-amd64.tar.zst
podman-full-linux-arm64.tar.zst
checksums.txt
cosign signature bundles (*.bundle)
```

For buildah/skopeo (3 variants each):
```
buildah-linux-amd64.tar.zst           # default variant (simplified name)
buildah-linux-arm64.tar.zst           # default variant (simplified name)
buildah-standalone-linux-amd64.tar.zst
buildah-standalone-linux-arm64.tar.zst
buildah-full-linux-amd64.tar.zst
buildah-full-linux-arm64.tar.zst
checksums.txt
cosign signature bundles (*.bundle)

# Skopeo follows same pattern (all variants identical for skopeo)
```

### Tarball Contents by Variant

Each variant follows a different directory layout optimized for its use case:

#### standalone variant (podman example)
```
podman-v5.3.1/
└── podman          ← Single binary at root level, no README
```

**Rationale**: Minimalist design for advanced users - just the binary, nothing else. Users run `./podman` directly or copy to their preferred location.

#### default variant (podman example)
```
podman-v5.3.1/
├── usr/local/bin/
│   ├── podman
│   ├── crun
│   └── conmon
├── usr/local/lib/podman/
│   └── conmon
├── etc/containers/
│   ├── policy.json
│   ├── registries.conf
│   ├── storage.conf
│   ├── containers.conf
│   └── seccomp.json
└── README.txt
```

**Rationale**: FHS-compliant structure for system-wide installation (`sudo cp -r usr/* /usr/`). Includes minimum runtime components.

#### full variant (podman example)
```
podman-v5.3.1/
├── usr/local/bin/
│   ├── podman
│   ├── crun
│   ├── fuse-overlayfs
│   ├── pasta
│   └── pasta.avx2
├── usr/local/lib/podman/
│   ├── conmon
│   ├── netavark
│   ├── aardvark-dns
│   ├── catatonit
│   └── rootlessport
├── usr/local/libexec/podman/
│   └── quadlet
├── usr/local/lib/systemd/
│   ├── system/          (service files)
│   ├── user/            (service files)
│   ├── system-generators/  (quadlet symlink)
│   └── user-generators/    (quadlet symlink)
├── etc/containers/
│   ├── policy.json
│   ├── registries.conf
│   ├── storage.conf
│   ├── containers.conf
│   └── seccomp.json
└── README.txt
```

**Rationale**: Complete rootless stack with all components. Same FHS structure as default but with additional runtime components.

**Note**: buildah follows the same pattern (skopeo variants differ only in binary name - no runtime components needed).

## Complexity Tracking

| Technical Choice | Why Needed | Fallback Plan | Status |
|------------------|------------|---------------|--------|
| Containerized builds via podman | Reproducibility, clean environment, runner independence | Direct runner execution (previous approach) | **NEW** - Recommended by user |
| Ubuntu:rolling as build image | Latest stable packages, regular security updates | Pin to Ubuntu 24.04 LTS | **NEW** - User specified |
| Clang + musl target with explicit CGO paths | **CRITICAL**: glibc NSS incompatible with static linking (causes SIGFPE in `podman build`); musl required for functional static binaries | musl-gcc wrapper (standard approach) | **ACTIVE** - Verified working |
| mimalloc static link | musl allocator is slow | Accept musl allocator for CLI tools | **ACTIVE** |
| Cross-compile arm64 on amd64 | Avoid ARM runner cost/complexity | Use ubuntu-24.04-arm native runner | **ACTIVE** |

**Historical Note**:
- Zig cross-compiler was initially considered but abandoned due to ecosystem compatibility issues. See [MIGRATION-ZIG-TO-CLANG.md](./MIGRATION-ZIG-TO-CLANG.md).
- **2025-12-14 Update**: Migrated from runner-native builds to containerized builds for improved reproducibility and isolation.
- **2025-12-15 Update**: Discovered glibc NSS (Name Service Switch) causes SIGFPE errors in statically linked binaries during user lookup operations (`getpwnam_r`). Migrated to explicit musl configuration. See detailed analysis in [MUSL_MIGRATION_REPORT.md](./MUSL_MIGRATION_REPORT.md).

## Migration from Runner-Native to Containerized Builds

### Rationale for Change

1. **Reproducibility**: Container ensures exact same build environment across all builds
2. **Isolation**: No dependency conflicts with runner-installed packages
3. **Simplicity**: Runner only needs podman; all other dependencies in container
4. **Debugging**: Can reproduce build failures locally with same container image
5. **Security**: Fresh container for each build reduces attack surface

### Impact Assessment

| Component | Before | After | Impact |
|-----------|--------|-------|--------|
| **Runner dependencies** | clang, musl-dev, Go, Rust, protobuf, ... | podman only | ✅ SIMPLIFIED |
| **Build time** | ~6-8 min | ~7-10 min (includes container setup) | ⚠️ +1-2 min |
| **Reproducibility** | Depends on runner state | Guaranteed by container | ✅ IMPROVED |
| **Debugging** | Difficult (need to reproduce runner env) | Easy (run same container locally) | ✅ IMPROVED |
| **Maintenance** | Update runner setup on package changes | Update container setup script | ≈ NEUTRAL |

### Breaking Changes

- **None for end users**: Release artifacts remain identical (static binaries)
- **CI/CD workflows**: Require modification to use podman containers
- **Local builds**: Now require podman installed (or fallback to previous scripts)

## Critical Technical Decision: musl vs glibc for Static Linking

### Problem Discovery (2025-12-15)

**Symptom**: `podman build` crashes with SIGFPE (floating-point exception) when using statically linked binary built without explicit musl configuration.

```bash
$ podman build -t test .
error in copier subprocess: SIGFPE: floating-point exception
```

**Root Cause**: glibc's NSS (Name Service Switch) system is fundamentally incompatible with static linking:

1. glibc NSS dynamically loads plugins at runtime (`libnss_files.so`, `libnss_dns.so`)
2. Static binaries cannot load these shared libraries
3. User lookup functions (`getpwnam_r`, `getpwuid_r`) fail during container builds
4. Error handling code triggers SIGFPE (division by zero)

**Build Warning (Initially Ignored)**:
```
warning: Using 'getpwnam_r' in statically linked applications requires
at runtime the shared libraries from the glibc version used for linking
```

### Why musl Instead of glibc

From industry research ([ref](https://eli.thegreenplace.net/2024/building-static-binaries-with-go-on-linux/)):
> "The first solution that may come to mind is to just link the glibc statically. However, that rarely works, as various warnings will tell you. The glibc just doesn't like that."

**musl libc advantages for static linking**:
- No NSS dependencies (simpler user/group lookup implementation)
- Designed for static linking from the ground up
- Smaller binary size (~43MB vs potentially larger with glibc workarounds)
- No runtime library requirements
- No SIGFPE errors in user lookup operations

### Implementation: Explicit musl Paths

**Original approach (BROKEN - defaults to glibc)**:
```bash
export CC="clang"
export CGO_ENABLED=1
go build -ldflags "-linkmode external -extldflags '-static'"
```

**Fixed approach (WORKING - explicit musl)**:
```bash
export CC="clang"
export CGO_ENABLED=1

# Architecture-aware musl paths
MUSL_ARCH="x86_64-linux-musl"  # or aarch64-linux-musl for arm64

# Point clang to musl libraries instead of glibc
export CGO_CFLAGS="-I/usr/include/${MUSL_ARCH} -w"
export CGO_LDFLAGS="-L/usr/lib/${MUSL_ARCH} -static"
```

**Critical difference**: Without explicit paths, clang defaults to glibc headers/libraries even when `-static` is specified.

### Alternative Approaches (Not Used)

**Standard Industry Approach: musl-gcc wrapper**
```bash
CC=/usr/local/musl/bin/musl-gcc go build --ldflags '-linkmode external -extldflags "-static"'
```

**Why we use clang + explicit paths instead**:
1. Already using clang from setup-build-env.sh
2. No additional dependencies (musl-dev already provides libraries)
3. Direct control over compiler flags
4. Same result: statically linked musl binaries

Both approaches are functionally equivalent - musl-gcc is just a wrapper that sets similar paths.

### Verification

**Binary Check**:
```bash
$ ldd build/podman-amd64/install/bin/podman
not a dynamic executable

$ strings podman | grep -i musl
musl libc (x86_64)
```

**Functional Test**:
```bash
$ podman build -t test .
STEP 1/6: FROM docker.io/node:lts-slim
...
Successfully tagged localhost/test:latest
```

✅ No SIGFPE errors with musl-linked binary

### Impact on Build System

| Aspect | Before (glibc default) | After (explicit musl) |
|--------|----------------------|----------------------|
| **C Library** | glibc | musl |
| **Configuration Complexity** | Low (defaults) | Medium (explicit paths) |
| **NSS Functions** | ❌ Fail (SIGFPE) | ✅ Work |
| **podman build** | ❌ Crashes | ✅ Success |
| **Binary Size** | ~43MB | ~43MB |
| **Maintenance** | Simple but broken | Slightly complex but working |

**Conclusion**: Explicit musl configuration is **mandatory** for functional static binaries. The additional complexity (CGO_CFLAGS/LDFLAGS) is necessary to avoid glibc's NSS incompatibility.

**Reference**: See [MUSL_MIGRATION_REPORT.md](./MUSL_MIGRATION_REPORT.md) for complete technical analysis and research references.

## Next Steps (Phase 0: Research)

Research tasks to resolve remaining unknowns:

1. **Container startup optimization**: Measure overhead of `podman pull` + `podman run` + `apt-get install`
   - Can we pre-build a custom image with dependencies?
   - Trade-off: faster builds vs. maintaining custom image

2. **Multi-architecture builds in containers**:
   - Can we cross-compile arm64 inside amd64 container?
   - Or do we need separate arm64 runner with native container?

3. **Artifact extraction patterns**:
   - Best practice for copying build artifacts from container to runner
   - Volume mounts vs. `podman cp`

4. **Container security**:
   - Rootless podman on GitHub Actions runners
   - Read-only mounts for scripts, read-write for build output

5. **Error handling**:
   - Container failures vs. build failures
   - Log extraction from failed containers
