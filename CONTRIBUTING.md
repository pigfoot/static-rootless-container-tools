# Contributing to Rootless Static Toolkits

Thank you for your interest in contributing! This document outlines the development workflow and guidelines.

## Development Environment Setup

### Prerequisites

- **podman or docker** - For containerized builds
- **Git** - Version control
- **GitHub CLI (gh)** - For version checking and releases (optional)
- **Make** - For convenient build commands (optional)

**Inside Container** (installed automatically):
- Clang 18+ with musl support
- Go 1.21+
- Rust/Cargo + protobuf-compiler
- CMake 3.15+ and Ninja - For building mimalloc
- Build tools (autoconf, automake, meson, ninja)

### Installation

```bash
# Clone the repository
git clone https://github.com/pigfoot/static-rootless-container-tools.git
cd static-rootless-container-tools

# Install podman (if not already installed)
# Ubuntu/Debian:
sudo apt-get install -y podman

# Fedora/RHEL:
sudo dnf install -y podman

# Verify podman works in rootless mode
podman info | grep -q "rootless: true" && echo "✓ Rootless podman ready"
```

## Project Structure

```
.
├── .github/workflows/      # GitHub Actions CI/CD
│   ├── build-podman.yml    # Podman build workflow
│   ├── build-buildah.yml   # Buildah build workflow
│   ├── build-skopeo.yml    # Skopeo build workflow
│   └── check-releases.yml  # Auto version detection
├── scripts/                # Build and utility scripts
│   ├── build-tool.sh       # Main build script (Clang + Go)
│   ├── build-mimalloc.sh   # Build mimalloc allocator
│   ├── package.sh          # Create release tarballs
│   ├── sign-release.sh     # Sign with cosign
│   ├── check-version.sh    # Version checking
│   └── test-static.sh      # Static binary verification
├── build/                  # Build artifacts (gitignored)
│   └── mimalloc/           # mimalloc source and builds
├── Dockerfile.*            # Fallback Alpine-based builds
├── Makefile                # Local build commands
├── specs/                  # Design documentation
│   └── 001-static-build/   # Feature 001 specification
└── CLAUDE.md               # Project-specific AI assistant config
```

## Development Workflow

### 1. Local Development

#### Building a Single Tool

```bash
# Build podman for current architecture (amd64)
make build-podman

# Build for specific architecture
make build-podman ARCH=arm64

# Build specific variant
make build-podman VARIANT=standalone  # Binary only
make build-podman VARIANT=default     # Recommended (binary + crun + conmon)
make build-podman VARIANT=full        # Complete stack
```

#### Building All Tools

```bash
# Build podman, buildah, and skopeo
make build-all
```

#### Testing

```bash
# Run static binary tests
make test

# Test a specific tool
./scripts/test-static.sh build/podman-amd64/install
```

### 2. Making Changes

1. **Create a feature branch**

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**

   - Follow existing code patterns
   - Update documentation if needed
   - Test locally before committing

3. **Test your changes**

   ```bash
   # Build and test
   make build-podman
   make test
   ```

4. **Commit your changes**

   Use conventional commit format:

   ```bash
   git add .
   git commit -m "feat: add support for new runtime component"
   # or
   git commit -m "fix: resolve static linking issue with lib64"
   # or
   git commit -m "docs: update quickstart with new examples"
   ```

   **Commit types:**
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation changes
   - `refactor:` - Code refactoring
   - `test:` - Test additions/changes
   - `chore:` - Build process or tooling changes
   - `ci:` - CI/CD workflow changes

5. **Push and create PR**

   ```bash
   git push origin feature/your-feature-name
   gh pr create --title "feat: your feature description"
   ```

### 3. Code Review Process

1. Automated checks will run (builds, tests)
2. Maintainer review
3. Address feedback if any
4. Merge once approved

## Build System Details

### How Static Builds Work

All builds run inside **Ubuntu:rolling containers** using podman for reproducibility.

1. **mimalloc** is compiled first using Clang with musl target
2. **Container tools** (podman/buildah/skopeo) are built with:
   - Go compiler with CGO enabled
   - Clang as C/C++ compiler (`CC="clang --target=x86_64-linux-musl"`)
   - Static linking flags (`-ldflags "-linkmode external -extldflags '-static'"`)
   - mimalloc linked statically for better performance

3. **Runtime components** (for full variants):
   - crun, conmon, fuse-overlayfs (C, built with Clang + musl)
   - netavark, aardvark-dns (Rust, cross-compiled with musl target)
   - pasta, catatonit (C, built with Clang + musl)

### Key Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `build-tool.sh` | Build podman/buildah/skopeo | `./scripts/build-tool.sh podman amd64 full` |
| `build-mimalloc.sh` | Build mimalloc for target arch | `./scripts/build-mimalloc.sh amd64` |
| `package.sh` | Create .tar.zst release archive | `./scripts/package.sh podman v5.3.1 amd64 full` |
| `sign-release.sh` | Sign with cosign OIDC | `./scripts/sign-release.sh podman-full.tar.zst` |
| `check-version.sh` | Check for new upstream versions | `./scripts/check-version.sh podman` |
| `test-static.sh` | Verify binaries are static | `./scripts/test-static.sh build/podman-amd64/install` |

## CI/CD Workflows

### Automatic Builds

The `check-releases.yml` workflow runs daily at 2 AM UTC and:

1. Checks for new upstream versions of podman, buildah, skopeo
2. Compares with existing releases in this repository
3. Triggers build workflows if new version detected
4. Skips pre-release versions (alpha/beta/rc)

### Manual Builds

Trigger builds manually via GitHub Actions:

```bash
# Using GitHub CLI
gh workflow run build-podman.yml -f version=v5.3.1 -f variant=all -f architecture=both

# Or via web UI
# Actions → Build Podman → Run workflow → Enter version, variant, architecture
```

### Release Process

1. Build completes for all architectures (amd64, arm64)
2. Artifacts are signed with cosign using OIDC
3. SHA256 checksums are generated
4. GitHub Release is created with:
   - Tarballs for each arch/variant
   - Signatures (`.sig` files)
   - `checksums.txt`
   - Installation instructions

## Testing

### Static Binary Verification

```bash
# Test that binary has no dynamic dependencies
./scripts/test-static.sh build/podman-amd64/install

# Expected output:
# ✓ Binary exists
# ✓ Binary is truly static (no dynamic dependencies)
# ✓ Binary is executable
# ✓ Binary runs successfully
```

### Smoke Tests

```bash
# Verify version output
build/podman-amd64/install/bin/podman --version

# Test basic functionality (requires rootless setup)
build/podman-amd64/install/bin/podman run --rm alpine echo "test"
```

## Troubleshooting

### Build Failures

**Container fails to start:**

Ensure podman is installed and running in rootless mode:

```bash
podman info | grep rootless
# Expected: rootless: true
```

**mimalloc build fails:**

Check that build happens inside container (should auto-install dependencies):

```bash
# If building manually, verify CMake and Ninja inside container:
podman run --rm docker.io/ubuntu:rolling bash -c "cmake --version && ninja --version"
```

**Go build fails with CGO errors:**

Verify environment variables inside container:

```bash
echo $CC        # Should be: clang --target=x86_64-linux-musl
echo $CGO_ENABLED  # Should be: 1
```

**Volume mount permission denied:**

Add `:z` flag for SELinux relabeling:

```bash
podman run -v ./build:/workspace/build:rw,z ...
```

### GitHub API Rate Limiting

If you hit rate limits while developing:

```bash
# Check your rate limit
gh api rate_limit

# Authenticate with GitHub CLI
gh auth login
```

### Local vs CI Differences

- **CI uses Ubuntu 22.04 runners** - Test locally with same `docker.io/ubuntu:rolling` container for consistency
- **CI uses containerized builds** - All builds happen inside containers, reproducible locally
- **CI uses cross-compilation for arm64** - Clang cross-compiles arm64 on amd64 runners
- **CI has OIDC token** - For cosign signing, can't be tested locally (use `--bundle` for local signing)

## Contributing Guidelines

### Code Style

- **Shell scripts**: Follow existing style, use `shellcheck` if available
- **YAML**: 2-space indentation
- **Markdown**: Use fenced code blocks with language tags

### Documentation

- Update `quickstart.md` for user-facing changes
- Update `CLAUDE.md` for project configuration changes
- Add comments for non-obvious code

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <description>

[optional body]

[optional footer]
```

**Examples:**

```
feat: add arm64 support for buildah

- Cross-compile with Clang for aarch64-linux-musl
- Update CI matrix to include arm64
- Add smoke tests for arm64 binaries

Closes #42
```

```
fix: handle lib64 path for mimalloc on 64-bit systems

CMake installs to lib64/ on some systems. Check both lib/ and lib64/
when linking mimalloc.
```

## Getting Help

- **Issues**: Open an issue for bugs or feature requests
- **Discussions**: For questions or ideas
- **Pull Requests**: For code contributions

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
