# Quickstart: Static Container Tools

> **Note**: Replace `pigfoot/rootless-static-toolkits` with your actual GitHub repository (e.g., `pigfoot/rootless-static-toolkits`)

## For Users

### Download and Install

1. **Download the latest release:**

   ```bash
   # Example: Download podman-full for amd64
   REPO="pigfoot/rootless-static-toolkits"  # e.g., "pigfoot/rootless-static-toolkits"
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

   # Or extract directly to /usr/local (requires sudo)
   sudo tar -xf podman-full-linux-amd64.tar.zst -C /usr/local --strip-components=1
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

- Go 1.21+
- Zig 0.11+
- Git
- Make

### Clone and Setup

```bash
REPO="pigfoot/rootless-static-toolkits"  # e.g., "pigfoot/rootless-static-toolkits"
git clone "https://github.com/${REPO}.git"
cd rootless-static-toolkits
```

### Build Locally

```bash
# Build podman for current architecture
make build-podman

# Build podman for specific target
make build-podman ARCH=arm64

# Build all tools
make build-all

# Run tests
make test
```

### Project Structure

```
.
├── .github/workflows/     # CI/CD workflows
├── scripts/               # Build scripts
├── build/                 # Build dependencies (mimalloc, patches)
├── Dockerfile.*           # Fallback build containers
├── Makefile               # Local build commands
└── specs/                 # Design documentation
```

### Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/check-version.sh` | Compare upstream vs local releases |
| `scripts/build-tool.sh` | Build a tool with Zig + Go |
| `scripts/package.sh` | Create tarball with proper structure |
| `scripts/sign-release.sh` | Sign artifacts with cosign |

### Manual Release Trigger

```bash
# Trigger build via GitHub CLI
gh workflow run build-podman.yml -f version=5.3.1
```

---

## Troubleshooting

### "command not found" after extraction

Ensure the `bin/` directory is in your PATH:

```bash
export PATH="$PWD/podman-v5.3.1/bin:$PATH"
```

### Permission denied

The binaries should be executable. If not:

```bash
chmod +x podman-v5.3.1/bin/*
```

### Missing fuse-overlayfs

For rootless containers, ensure `fuse-overlayfs` is available:

```bash
# It's included in podman-full
ls podman-v5.3.1/bin/fuse-overlayfs
```

### Verification fails

Ensure you're using the correct cosign version (1.13+):

```bash
cosign version
```

---

## Links

- [Releases](https://github.com/pigfoot/rootless-static-toolkits/releases) - Replace `pigfoot/rootless-static-toolkits` with your repository
- [Source Code](https://github.com/pigfoot/rootless-static-toolkits)
- [Upstream Podman](https://github.com/containers/podman)
- [Upstream Buildah](https://github.com/containers/buildah)
- [Upstream Skopeo](https://github.com/containers/skopeo)
