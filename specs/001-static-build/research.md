# Research: Static Container Tools Build System

**Date**: 2025-12-12
**Branch**: `001-static-build`

## Research Summary

This document consolidates research findings from the brainstorming session and validates key technical decisions.

---

## 1. Static Linking Strategy

### ⚠️ DECISION CHANGED (2025-12-13): Clang + musl + mimalloc

**Previous Decision**: Zig + musl + mimalloc (**ABANDONED** - see §Zig Issues below)

### Current Decision: Clang with musl target

| Approach | Pros | Cons | Status |
|----------|------|------|--------|
| Alpine + musl-gcc | Proven (podman-static uses it), well-documented | Requires Docker build, complex cross-compile | Fallback available |
| ~~Zig cross-compiler~~ | ~~Single binary, built-in musl support, easy cross-compile~~ | **FAILED**: See §Zig Issues | **ABANDONED** |
| **Clang + musl target** | **GCC compatibility, standard tooling, build system support** | Requires musl-dev packages | **ACTIVE** ✅ |
| glibc static | Better compatibility | Not truly static (NSS, DNS issues) | Not suitable |

**Chosen**: Clang with `--target=x86_64-linux-musl` because:
1. **GCC Built-in Compatibility**: Supports `__builtin_cpu_supports()` and other GCC built-ins required by pasta and other C components
2. **Build System Support**: Works seamlessly with make, meson, cmake, autotools (unlike zig which requires special handling)
3. **Standard Tooling**: Available in all distributions (clang, musl-dev, musl-tools)
4. **Cross-Compilation**: Clean cross-compile with `--target` flag (amd64↔arm64)
5. **Proven Track Record**: Widely used for musl static builds
6. **Fallback Available**: Can still use Alpine/Docker if needed

### Zig Issues (Why Migration Was Necessary)

#### Issue 1: pasta Build Failure - Missing `__cpu_model` Symbol

**Component**: pasta (network namespace tool)
**Error**:
```
ld.lld: error: undefined symbol: __cpu_model
>>> referenced by arch.c:41
>>>               arch.o:(arch_avx2_exec)
```

**Root Cause**:
- pasta uses `__builtin_cpu_supports("avx2")` for CPU feature detection (AVX2-optimized code path)
- This GCC built-in requires the `__cpu_model` runtime symbol
- Zig's linker (lld) doesn't provide this symbol
- Clang provides full GCC built-in compatibility

**Code Location**: `build/podman-amd64/src/pasta/arch.c:41`

#### Issue 2: fuse-overlayfs Build Failure - Meson Linker Detection

**Component**: fuse-overlayfs (overlay filesystem)
**Error**:
```
ERROR: Unable to detect linker for compiler `zig cc -target x86_64-linux-musl`
stdout: zig ld 0.13.0
```

**Root Cause**:
- Meson build system cannot recognize zig's linker output format
- Meson expects standard linker responses (GNU ld, LLVM lld with standard output)
- Zig reports "zig ld" which meson doesn't recognize
- Clang uses standard lld that meson recognizes

#### Issue 3: Limited Ecosystem Support

**Problems Identified**:
- Many C build systems (make, meson, autotools) not designed to work with zig
- GCC-specific built-ins not supported (or partially supported)
- Requires workarounds that increase maintenance burden
- Build scripts often need patches to work with zig

**Solution**: Clang is the de-facto standard for musl cross-compilation and has broad ecosystem support

### Clang + musl Methods Evaluated

During migration testing, three methods were evaluated:

#### Method 1: musl-gcc.specs (Failed)
```bash
CC="clang -specs=/usr/lib/x86_64-linux-musl/musl-gcc.specs"
```
**Problem**: Clang issues warning and ignores `-specs` at link time (GCC-specific feature)
**Result**: Produces dynamic binaries, not static ❌

#### Method 2: Direct Paths (Not Reliable)
```bash
export CC="clang"
export CFLAGS="-nostdinc -isystem /usr/include/x86_64-linux-musl -isystem /usr/include"
export LDFLAGS="-static -L/usr/lib/x86_64-linux-musl"
```
**Problem**: Missing kernel headers (`asm/types.h`), requires extensive manual configuration
**Result**: Error-prone, not recommended ⚠️

#### Method 3: --target Flag (Recommended) ✅
```bash
CC="clang --target=x86_64-linux-musl"
CXX="clang++ --target=x86_64-linux-musl"
```
**Advantages**:
- ✅ Clang auto-configures include/library paths for musl
- ✅ Produces true static binaries
- ✅ Works with all build systems (make, meson, cmake, autotools)
- ✅ Clean, simple configuration
- ✅ Portable across distributions

**Verification**: Successfully built pasta (all binaries static: passt 1.3M, qrap 828K, passt-repair 784K)

### Implementation Changes

**Updated Build Environment**:
```bash
# Old (zig):
export CC="zig cc -target $ZIG_TARGET"
export CXX="zig c++ -target $ZIG_TARGET"
export AR="zig ar"
export RANLIB="zig ranlib"

# New (clang):
export CC="clang --target=$ZIG_TARGET"
export CXX="clang++ --target=$ZIG_TARGET"
export AR="ar"
export RANLIB="ranlib"
```

**Dependencies Updated**:
```bash
# Ubuntu/Debian
apt-get install -y clang musl-dev musl-tools protobuf-compiler

# Gentoo
emerge sys-devel/clang dev-libs/musl dev-libs/protobuf
```

### Advantages of Clang over Zig

1. **GCC Compatibility**: Full support for GCC built-ins (`__builtin_cpu_supports`, `__cpu_model`, etc.)
2. **Build System Support**: Works seamlessly with make, meson, cmake, autotools without patches
3. **Mature Ecosystem**: Better tested for cross-compilation scenarios
4. **Distribution Availability**: Standard package in all major distributions
5. **Static Linking**: Proven track record with musl for static binaries
6. **Debugging**: Better error messages and debugging support

### Alternatives Considered

- **Nix**: Excellent reproducibility but steep learning curve
- **xx (Docker cross-compile)**: Still requires Docker build context
- **Native ARM runners**: Works but adds complexity and cost
- **gcc + musl-gcc wrapper**: Works but less clean than clang --target

---

## 2. Allocator Choice

### Decision: mimalloc (statically linked)

### Rationale

musl's built-in allocator is 7-10x slower than glibc malloc in multi-threaded workloads. While podman/buildah/skopeo are CLI tools (short-lived), using mimalloc:
1. Eliminates potential performance issues
2. Provides consistent memory behavior
3. Minimal overhead to integrate

### Integration Approach

```bash
# Compile mimalloc as static library with Zig
git clone https://github.com/microsoft/mimalloc
cd mimalloc
zig cc -target x86_64-linux-musl -c -O3 src/static.c -I include -o mimalloc.o
zig ar rcs libmimalloc.a mimalloc.o

# Link with Go CGO builds
export CGO_LDFLAGS="-L/path/to/mimalloc -lmimalloc"
```

### Alternatives Considered

- **jemalloc**: Good but larger, more complex build
- **Accept musl allocator**: Simpler but potential performance issues
- **tcmalloc**: Google's allocator, less portable

---

## 3. Cross-Compilation Strategy

### Decision: Cross-compile arm64 on amd64 runner (Updated for Clang)

### Rationale

Clang's cross-compilation capabilities allow building arm64 binaries on standard amd64 runners:

```bash
# Build for arm64 from amd64
export CC="clang --target=aarch64-linux-musl"
export CXX="clang++ --target=aarch64-linux-musl"
export AR="ar"
export RANLIB="ranlib"
CGO_ENABLED=1 GOARCH=arm64 go build ...
```

Benefits:
1. No need for QEMU (slow emulation)
2. No need for ARM runners (cost, availability)
3. Faster builds (native speed, no emulation overhead)
4. **Better compatibility** than zig (standard LLVM toolchain)

### Fallback

If clang cross-compile fails for certain dependencies:
1. First try: Patch the problematic dependency
2. Second try: Use `ubuntu-24.04-arm` native runner
3. Last resort: Docker build with QEMU

### Known Risks

Some build systems may:
- Run compiled binaries during build (impossible with cross-compile)
- Use architecture-specific assembly
- Have autoconf scripts that detect host incorrectly

**Note**: These risks are the same for any cross-compiler (zig, clang, gcc). Clang has better ecosystem support which reduces the likelihood of encountering these issues.

---

## 4. Archive Format

### Decision: .tar.zst (Zstandard compression)

### Rationale

| Format | Compression Ratio | Decompression Speed | Compatibility |
|--------|-------------------|---------------------|---------------|
| .tar.gz | Baseline | Baseline | Universal |
| .tar.zst | ~20-30% better | 3-5x faster | Modern tar (2019+) |
| .tar.xz | Best | Slowest | Universal |

**Chosen**: .tar.zst because:
1. Better compression than gzip
2. Much faster decompression
3. Modern tar versions auto-detect (`tar -xf file.tar.zst`)
4. Users can extract directly to `/` to install

### Compatibility Note

Users on older systems without zstd support can:
```bash
zstd -d file.tar.zst && tar -xf file.tar
```

---

## 5. Version Detection Mechanism

### ⚠️ DECISION CHANGED (2025-12-13): Use curl + GitHub API (No gh CLI)

**Previous Decision**: Use `gh` CLI (**CHANGED** - see below)

### Current Decision: curl + GitHub API

**Rationale**: Using `curl` with GitHub API is simpler and doesn't require authentication for public repositories.

```bash
# Get latest stable release from upstream (no auth required)
VERSION=$(curl -sk "https://api.github.com/repos/containers/podman/releases" \
  | sed -En '/\"tag_name\"/ s#.*\"([^\"]+)\".*#\1#p' \
  | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  | head -1)

# Fallback to tags endpoint if releases endpoint is empty
if [[ -z "$VERSION" ]]; then
  VERSION=$(curl -sk "https://api.github.com/repos/containers/podman/tags" \
    | sed -En '/\"name\"/ s#.*\"([^\"]+)\".*#\1#p' \
    | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    | head -1)
fi
```

**Benefits**:
1. ✅ No authentication required for public repos
2. ✅ Works in containers without gh CLI setup
3. ✅ Simpler, fewer dependencies
4. ✅ Standard tool available everywhere
5. ✅ Filters for semver format automatically

**Note**: Pre-release filtering is handled by the semver regex (`'^v?[0-9]+\.[0-9]+(\.[0-9]+)?$'`) which excludes alpha/beta/rc versions.

### Release Existence Check

```bash
# Check if release exists in our repository
curl -sk "https://api.github.com/repos/owner/repo/releases/tags/podman-v5.3.1" | grep -q '"tag_name"'
if [ $? -ne 0 ]; then
  # Release doesn't exist, trigger build
fi
```

---

## 6. Signing Strategy

### Decision: Sigstore/cosign keyless signing

### Rationale

| Method | Key Management | Verification | Complexity |
|--------|----------------|--------------|------------|
| GPG | Must manage keys | Manual download of public key | High |
| Sigstore/cosign | Keyless (OIDC) | Automatic via transparency log | Low |
| None | N/A | N/A | None |

**Chosen**: Sigstore/cosign because:
1. No key management needed
2. GitHub Actions has built-in OIDC support
3. Verification is straightforward: `cosign verify-blob`
4. Transparency log provides audit trail

### Implementation

```yaml
# In GitHub Actions
- uses: sigstore/cosign-installer@v3

- name: Sign artifacts
  run: |
    cosign sign-blob --yes \
      --oidc-issuer https://token.actions.githubusercontent.com \
      --output-signature $FILE.sig \
      $FILE
```

---

## 7. Podman Runtime Components

### Decision: Bundle all required components in podman-full

### Components List

| Component | Purpose | Required for Rootless |
|-----------|---------|----------------------|
| podman | Main binary | Yes |
| crun | OCI runtime | Yes |
| conmon | Container monitor | Yes |
| fuse-overlayfs | Rootless overlay FS | Yes |
| netavark | CNI networking | Yes |
| aardvark-dns | DNS for containers | Yes |
| pasta | Rootless networking | Yes (or slirp4netns) |
| catatonit | Minimal init | Recommended |

### Source Repositories

- podman: github.com/containers/podman
- buildah: github.com/containers/buildah
- skopeo: github.com/containers/skopeo
- crun: github.com/containers/crun
- conmon: github.com/containers/conmon
- fuse-overlayfs: github.com/containers/fuse-overlayfs
- netavark: github.com/containers/netavark
- aardvark-dns: github.com/containers/aardvark-dns
- pasta: git://passt.top/passt (primary source, NOT on GitHub)
- catatonit: github.com/openSUSE/catatonit

### Version Strategy

**Decision: Use latest stable release for each component**

For each build:
1. Query upstream repository for latest non-prerelease version
2. Build all components with their respective latest versions
3. Bundle together in podman-full tarball

**Rationale:**
- Simpler implementation (no version mapping maintenance)
- Runtime components maintain backward compatibility
- Users get security fixes and improvements
- If incompatibility occurs, can add version pinning later

**Alternative considered:**
- Follow podman's recommended versions (complex, requires parsing release notes)

---

## 8. Directory Structure in Tarball

### Decision: Match podman-static structure

```
{tool}-v{version}/
├── bin/           # All executables
├── lib/           # Helper libraries (if any)
│   └── podman/
└── etc/           # Configuration files
    └── containers/
        ├── policy.json
        └── registries.conf
```

### Rationale

1. Familiar to podman-static users
2. Can extract directly to `/` or `/usr/local`
3. Config files in etc/ allow easy overwrite updates
4. Follows FHS-like structure

---

## Open Questions (Resolved)

| Question | Resolution |
|----------|------------|
| musl vs glibc? | musl for true static |
| ARM build method? | Cross-compile first, native runner fallback |
| Allocator? | mimalloc statically linked |
| Archive format? | .tar.zst |
| Signing? | Sigstore/cosign keyless |
| Notifications? | GitHub Actions built-in |

---

## 9. Additional Dependencies Discovered During Testing

### Rust Components (netavark, aardvark-dns)

**Requirement**: `protobuf-compiler` (protoc)

**Reason**: netavark's build.rs requires protoc to compile .proto files
**Error if missing**:
```
thread 'main' panicked at build.rs:39:29:
  Failed at builder: "Could not find `protoc`.
  To install it on Debian, run `apt-get install protobuf-compiler`
```

**Installation**:
```bash
# Ubuntu/Debian
apt-get install protobuf-compiler

# Gentoo
emerge dev-libs/protobuf
```

### Rust Static Linking Method

**Decision**: Use musl target (NOT RUSTFLAGS)

```bash
# Check if musl target is available
if rustup target list | grep -q "x86_64-unknown-linux-musl (installed)"; then
  RUST_TARGET="--target x86_64-unknown-linux-musl"
  BUILD_PATH="target/x86_64-unknown-linux-musl/release"
else
  # Fallback to RUSTFLAGS (less reliable)
  export RUSTFLAGS='-C target-feature=+crt-static -C link-arg=-s'
  BUILD_PATH="target/release"
fi

cargo build --release $RUST_TARGET
```

**Why musl target**:
1. ✅ Produces truly static binaries
2. ✅ Standard approach for Rust static linking
3. ✅ Consistent with clang musl target
4. ✅ Works with proc-macro crates (RUSTFLAGS +crt-static doesn't)

### C Components Build System Specifics

#### conmon
- Build system: Plain Makefile
- Special requirement: Disable systemd support (`USE_JOURNALD=0`)
- Static linking: Use `-static` in CFLAGS and LDFLAGS

#### fuse-overlayfs
- Build system: autotools + meson (for libfuse dependency)
- Two-stage build: libfuse → fuse-overlayfs
- Install path: Use local prefix to avoid permission issues

#### crun
- Build system: autotools
- Special flags: `--disable-systemd --enable-embedded-yajl`
- Static linking: `LDFLAGS='-static-libgcc -all-static'`

#### pasta
- Build system: Custom Makefile
- Source: git://passt.top/passt (NOT on GitHub!)
- Version detection: Use `git ls-remote --tags` instead of GitHub API
- Special handling required in version check and clone logic

## Next Steps

1. ~~Phase 1: Generate data-model.md and quickstart.md~~ ✅ Complete
2. ~~Phase 2: Generate tasks.md with implementation steps~~ ✅ Complete
3. Implementation: ~~Start with proof-of-concept for Zig + Go CGO build~~ **Migrated to Clang** ✅
4. **Current**: Address remaining runtime component build issues (Phase 1 fixes applied, testing in progress)
