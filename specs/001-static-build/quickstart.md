# Quickstart: Static Container Tools

> **Note**: Replace `pigfoot/static-rootless-container-tools` with your actual GitHub repository (e.g., `pigfoot/static-rootless-container-tools`)

## For Users

### Download and Install

1. **Download the latest release:**

   ```bash
   # Example: Download podman-full for amd64
   REPO="pigfoot/static-rootless-container-tools"  # e.g., "pigfoot/static-rootless-container-tools"
   curl -LO "https://github.com/${REPO}/releases/latest/download/podman-full-linux-amd64.tar.zst"
   ```

2. **Verify the checksum:**

   ```bash
   curl -LO "https://github.com/${REPO}/releases/latest/download/checksums.txt"
   sha256sum -c checksums.txt --ignore-missing
   ```

3. **Verify the signature (optional):**

   ```bash
   cosign verify-blob \
     --certificate-identity-regexp="https://github.com/${REPO}/.*" \
     --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
     --signature podman-full-linux-amd64.tar.zst.sig \
     podman-full-linux-amd64.tar.zst
   ```

4. **Extract and install:**

   ```bash
   # Extract to current directory
   tar -xf podman-full-linux-amd64.tar.zst

   # Install to system (recommended)
   cd podman-v5.3.1
   sudo cp -r usr/* /usr/
   sudo cp -r etc/* /etc/

   # Or add to PATH (user install)
   export PATH=$PWD/podman-v5.3.1/usr/local/bin:$PATH
   ```

5. **Verify installation:**

   ```bash
   podman --version
   # podman version 5.3.1
   ```

### Quick Test

```bash
# Run a container
podman run --rm alpine echo "Hello from static podman!"

# Build an image (with buildah)
buildah from alpine
buildah run alpine-working-container apk add curl
buildah commit alpine-working-container my-alpine

# Copy an image (with skopeo)
skopeo copy docker://alpine:latest dir:./alpine-image
```

---

## For Developers

### Prerequisites

**Required**:
- **podman** - Container runtime (4.0+)
- **Git** - Version control
- **Make** - Build automation (optional)

**Inside Container** (installed automatically):
- Clang 18+ with musl support
- Go 1.21+
- Rust/Cargo + protobuf-compiler
- Build tools (autoconf, automake, meson, ninja)

### Clone and Setup

```bash
REPO="pigfoot/static-rootless-container-tools"  # e.g., "pigfoot/static-rootless-container-tools"
git clone "https://github.com/${REPO}.git"
cd static-rootless-container-tools
```

### Build Locally (Containerized)

All builds run inside `docker.io/ubuntu:rolling` containers for reproducibility.

```bash
# Build podman for current architecture using container
make build-podman

# Build podman for specific target
make build-podman ARCH=arm64

# Build all tools
make build-all

# Run tests
make test
```

**What happens under the hood:**
```bash
# Makefile runs this for you:
podman run --rm \
  -v ./scripts:/workspace/scripts:ro,z \
  -v ./build:/workspace/build:rw,z \
  -e VERSION=5.3.1 -e TOOL=podman -e ARCH=amd64 \
  docker.io/ubuntu:rolling \
  bash -c "/workspace/scripts/container/setup-build-env.sh && \
           /workspace/scripts/build-tool.sh podman amd64 full"
```

### Project Structure

```
.
├── .github/workflows/        # CI/CD workflows
├── scripts/
│   ├── check-version.sh      # Version detection
│   ├── build-tool.sh         # Build logic (runs IN container)
│   ├── package.sh            # Create tarball (runs IN container)
│   ├── sign-release.sh       # Cosign signing (runs on runner)
│   └── container/
│       ├── setup-build-env.sh  # Install deps inside container
│       └── run-build.sh        # Wrapper for containerized builds
├── build/                    # Build dependencies (mimalloc, patches)
├── Containerfile.build       # Optional pre-built image definition
├── Makefile                  # Local build commands
└── specs/                    # Design documentation
```

### Key Scripts

| Script | Runs Where | Purpose |
|--------|------------|---------|
| `scripts/container/setup-build-env.sh` | Inside container | Install clang, go, rust, build deps |
| `scripts/container/run-build.sh` | Host (runner) | Wrapper to launch container + build |
| `scripts/build-tool.sh` | Inside container | Build tool with Clang + Go + mimalloc |
| `scripts/package.sh` | Inside container | Create tarball with proper structure |
| `scripts/sign-release.sh` | Host (runner) | Sign artifacts with cosign |
| `scripts/check-version.sh` | Host (runner) | Compare upstream vs local releases |

### Build Without Makefile (Manual Container Invocation)

```bash
# Pull container image
podman pull docker.io/ubuntu:rolling

# Run build in container
podman run --rm \
  -v ./scripts:/workspace/scripts:ro,z \
  -v ./build:/workspace/build:rw,z \
  -e VERSION=5.3.1 \
  -e TOOL=podman \
  -e ARCH=amd64 \
  -e VARIANT=full \
  docker.io/ubuntu:rolling \
  bash -c "
    /workspace/scripts/container/setup-build-env.sh && \
    /workspace/scripts/build-tool.sh podman amd64 full
  "

# Artifacts will be in ./build/podman-amd64/
ls -lh build/podman-amd64/install/
```

### Manual Release Trigger

```bash
# Trigger build via GitHub CLI
gh workflow run build-podman.yml -f version=5.3.1
```

---

## Troubleshooting

### "command not found" after extraction

Ensure the `usr/local/bin/` directory is in your PATH:

```bash
export PATH="$PWD/podman-v5.3.1/usr/local/bin:$PATH"
```

### Permission denied

The binaries should be executable. If not:

```bash
chmod +x podman-v5.3.1/usr/local/bin/*
```

### Missing fuse-overlayfs

For rootless containers, ensure `fuse-overlayfs` is available:

```bash
# It's included in podman-full
ls podman-v5.3.1/usr/local/bin/fuse-overlayfs
```

### Verification fails

Ensure you're using the correct cosign version (1.13+):

```bash
cosign version
```

---

## Links

- [Releases](https://github.com/pigfoot/static-rootless-container-tools/releases) - Replace `pigfoot/static-rootless-container-tools` with your repository
- [Source Code](https://github.com/pigfoot/static-rootless-container-tools)
- [Upstream Podman](https://github.com/containers/podman)
- [Upstream Buildah](https://github.com/containers/buildah)
- [Upstream Skopeo](https://github.com/containers/skopeo)
