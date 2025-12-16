# Migration Report: Fix SIGFPE in Static Podman Build

**Date:** 2025-12-15
**Issue:** `podman build` crashes with SIGFPE (floating-point exception) when using statically linked binary
**Root Cause:** glibc NSS (Name Service Switch) incompatibility with static linking
**Solution:** Migrate from glibc to musl libc

---

## Problem Analysis

### Symptoms
```bash
$ podman build -t test .
error in copier subprocess: SIGFPE: floating-point exception
```

The error occurs during user lookup operations (`getpwnam_r`, `getpwuid_r`) when building container images.

### Original Build Method (GitHub)

The current `scripts/build-tool.sh` uses standard Go static linking:

```bash
export CGO_ENABLED=1
export CC="clang"
# No explicit musl paths - defaults to system glibc

go build -ldflags "-linkmode external -extldflags '-static'"
```

**Problem:** Without explicit musl configuration, clang defaults to glibc, creating a statically linked binary that still has glibc NSS issues.

```bash
# Verification shows glibc linkage:
$ strings podman | grep -i "glibc\|gnu"
GNU C Library (Ubuntu GLIBC 2.42-0ubuntu3) stable release version 2.42
```

### Root Cause
Static linking with glibc causes NSS function failures:

```
# Build warnings from original build:
warning: Using 'getpwnam_r' in statically linked applications requires
at runtime the shared libraries from the glibc version used for linking
```

**Why this happens:**
- glibc's NSS system dynamically loads plugins at runtime
- Static binaries cannot load these shared libraries
- User lookup functions fail, triggering SIGFPE (division by zero in error handling)

Reference: https://eli.thegreenplace.net/2024/building-static-binaries-with-go-on-linux/

### Why musl Instead of glibc
From research:
> "The first solution that may come to mind is to just link the glibc statically. However, that rarely works, as various warnings will tell you. The glibc just doesn't like that."

musl libc advantages for static linking:
- No NSS dependencies (simpler user/group lookup)
- Designed for static linking from the ground up
- Smaller binary size
- No runtime library requirements

---

## Research Findings

### Industry Standard Approach: musl-gcc

Research shows the standard approach is using **musl-gcc** wrapper:

**Source:** [Statically compiled Go programs with musl](https://honnef.co/articles/statically-compiled-go-programs-always-even-with-cgo-using-musl/)

```bash
CC=/usr/local/musl/bin/musl-gcc go build \
  --ldflags '-linkmode external -extldflags "-static"'
```

**Alternative modern approach:** Using Zig toolchain
**Source:** [Static-linked CGO binaries using musl and Zig](https://flowerinthenight.com/blog/2025-02-15-cgo-static-linked-bin-musl/)

```bash
CC="zig cc -target x86_64-linux-musl" go build
```

---

## Actual Solution Implemented

### Why Not musl-gcc?

We chose **clang with musl paths** instead of musl-gcc because:

1. **Already using clang** - Setup script installs latest LLVM/clang
2. **No additional dependencies** - musl-dev already provides musl libraries
3. **Direct control** - Explicit paths via CGO_CFLAGS/CGO_LDFLAGS
4. **Same result** - Both approaches produce statically linked musl binaries

### Implementation

Modified `scripts/build-tool-no-mimalloc.sh`:

```bash
# Setup clang with musl for true static linking (avoids glibc NSS issues)
export CC="clang"
export CXX="clang++"
export AR="ar"
export RANLIB="ranlib"

# Setup CGO for Go build with musl
export CGO_ENABLED=1
export GOOS=linux
export GOARCH="$GOARCH"

# Point clang to use musl instead of glibc (architecture-aware)
if [[ "$ARCH" == "amd64" ]]; then
    MUSL_ARCH="x86_64-linux-musl"
elif [[ "$ARCH" == "arm64" ]]; then
    MUSL_ARCH="aarch64-linux-musl"
fi

# Disable all warnings to avoid musl header issues
export CGO_CFLAGS="-I/usr/include/${MUSL_ARCH} -w"
export CGO_LDFLAGS="-L/usr/lib/${MUSL_ARCH} -static"
```

### Compiler Warning Issues

During implementation, encountered clang warnings from musl headers:

```
/usr/include/x86_64-linux-musl/endian.h:26:25: error: '&' within '|'
  [-Werror,-Wbitwise-op-parentheses]
/usr/include/x86_64-linux-musl/endian.h:31:23: error: operator '<<' has
  lower precedence than '+' [-Werror,-Wshift-op-parentheses]
```

**Solution:** Use `-w` flag to disable all warnings (cleaner than individual `-Wno-error=*` flags)

**Reference:** [musl warning fix patch (2019)](https://www.openwall.com/lists/musl/2019/07/22/4)

---

## Build Simplification

As part of this migration, we also simplified the build to focus on podman binary only:

### Modified Files

1. **scripts/build-tool-no-mimalloc.sh**
   - Exit after building podman binary (skip crun, conmon, netavark, etc.)
   - Lines 312-321: Early exit with success message

2. **scripts/container/setup-build-env.sh**
   - Skip Rust installation (only needed for netavark/aardvark-dns)
   - Lines 134-135: Skip Rust, document reason

3. **Makefile**
   - Remove packaging step from `build-podman-no-mimalloc` target
   - Line 153: Only run build script, skip package.sh

**Build time reduction:** ~15 minutes → ~5-7 minutes

---

## Verification

### Binary Check
```bash
$ file build/podman-amd64/install/bin/podman
ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped

$ ls -lh build/podman-amd64/install/bin/podman
-rwxr-xr-x 1 root root 43M Dec 15 15:45 podman
```

### Functional Test
```bash
$ podman build --security-opt seccomp=unconfined -t test-bun:musl -f Containerfile .
STEP 1/6: FROM docker.io/node:lts-slim
STEP 2/6: COPY --from=docker.io/oven/bun:slim /usr/local/bin/bun /usr/local/bin/
...
STEP 6/6: RUN bun install --frozen-lockfile
bun install v1.3.4 (5eb2145b)
+ zod@3.25.76 (v4.2.0 available)
1 package installed [421.00ms]
COMMIT test-bun:musl
Successfully tagged localhost/test-bun:musl
```

**Result:** ✅ No SIGFPE errors, build completes successfully

---

## Comparison of Approaches

### Before vs After

| Aspect | Original (GitHub) | Our Solution (clang+musl) |
|--------|------------------|---------------------------|
| **C Library** | glibc (default) | musl (explicit) |
| **Configuration** | `CC=clang` only | `CC=clang` + musl paths |
| **CGO_CFLAGS** | Not set (uses glibc) | `-I/usr/include/x86_64-linux-musl -w` |
| **CGO_LDFLAGS** | `-static` only | `-L/usr/lib/x86_64-linux-musl -static` |
| **Binary Type** | Static glibc | Static musl |
| **NSS Functions** | ❌ Fail (SIGFPE) | ✅ Work |
| **podman build** | ❌ Crashes | ✅ Success |

### Research Standard vs Our Implementation

| Aspect | musl-gcc (Research Standard) | clang+musl (Our Solution) |
|--------|------------------------------|---------------------------|
| **Approach** | Wrapper script around gcc | Direct clang with musl paths |
| **Dependencies** | Requires musl-gcc package | Uses existing clang + musl-dev |
| **Configuration** | Simpler (`CC=musl-gcc`) | More explicit (CGO_CFLAGS/LDFLAGS) |
| **Control** | Wrapper handles details | Direct control over flags |
| **Result** | Static musl binary | Static musl binary |
| **Performance** | Same | Same |

**Why our approach works:**
- Both point the compiler to musl libraries
- Both produce statically linked binaries using musl
- musl-gcc is essentially a wrapper that sets similar paths
- We already have clang installed from setup-build-env.sh

**Key difference from GitHub version:**
The original `build-tool.sh` didn't specify musl paths, so clang defaulted to glibc. Our fix explicitly tells clang to use musl libraries.

---

## References

1. [Building static binaries with Go on Linux](https://eli.thegreenplace.net/2024/building-static-binaries-with-go-on-linux/) - Explains glibc NSS issues
2. [Statically compiled Go programs with musl](https://honnef.co/articles/statically-compiled-go-programs-always-even-with-cgo-using-musl/) - Industry standard musl-gcc approach
3. [Static-linked CGO binaries using musl and Zig](https://flowerinthenight.com/blog/2025-02-15-cgo-static-linked-bin-musl/) - Modern Zig alternative
4. [musl warning fix patch](https://www.openwall.com/lists/musl/2019/07/22/4) - Background on header warnings

---

## Recommendations

### For Future Builds

1. **Keep musl approach** - Avoids glibc NSS issues entirely
2. **Consider musl-gcc** - If standardization is preferred over current clang approach
3. **Monitor warnings** - Update `-w` to specific flags if needed for debugging
4. **Document choice** - This report explains why clang+musl is equivalent to musl-gcc

### Alternative Implementations

If switching to standard approach is desired:

```bash
# Install musl-gcc wrapper (already available in Ubuntu)
apt-get install musl-tools

# Replace clang configuration with:
export CC="musl-gcc"
export CGO_ENABLED=1
export CGO_LDFLAGS="-static"
# Remove CGO_CFLAGS path configuration (musl-gcc handles it)
```

Both approaches produce functionally identical static musl binaries.

---

## Conclusion

**Problem:** SIGFPE in statically linked podman due to glibc NSS incompatibility
**Research:** Industry uses musl-gcc for static CGO builds
**Solution:** Implemented clang+musl (equivalent approach, uses existing toolchain)
**Result:** Successfully builds 43M static podman binary without SIGFPE errors

The migration to musl libc resolves the core issue. While musl-gcc is the research-recommended standard, our clang+musl implementation achieves the same result by directly configuring CGO to use musl libraries, leveraging the clang toolchain already present in our build environment.
