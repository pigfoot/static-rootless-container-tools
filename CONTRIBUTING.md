# Contributing to Rootless Static Toolkits

Thank you for your interest in contributing! This document outlines the development workflow and guidelines.

## Development Environment Setup

### Prerequisites

- **Go 1.21+** - For building container tools
- **Zig 0.11+** - Cross-compiler for static linking with musl
- **CMake 3.15+** - For building mimalloc
- **Ninja** - Build system for mimalloc
- **Git** - Version control
- **GitHub CLI (gh)** - For version checking and releases
- **Make** - For convenient build commands

### Installation

```bash
# Clone the repository
git clone https://github.com/pigfoot/rootless-static-toolkits.git
cd rootless-static-toolkits

# Install Zig (if not already installed)
# Download from https://ziglang.org/download/
# Or use your package manager

# Verify prerequisites
make check-deps  # Will be implemented if not exists
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
│   ├── build-tool.sh       # Main build script (Zig + Go)
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

# Build specific variant (podman only)
make build-podman VARIANT=minimal
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

1. **mimalloc** is compiled first using Zig cross-compiler
2. **Container tools** (podman/buildah/skopeo) are built with:
   - Go compiler with CGO enabled
   - Zig as C/C++ compiler (`CC="zig cc -target x86_64-linux-musl"`)
   - Static linking flags (`-ldflags "-linkmode external -extldflags '-static'"`)
   - mimalloc linked statically for better performance

3. **Runtime components** (for podman-full):
   - crun, conmon, fuse-overlayfs (C, built with Zig)
   - netavark, aardvark-dns (Rust, cross-compiled)
   - pasta, catatonit (C, built with Zig)

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
gh workflow run build-podman.yml -f version=v5.3.1 -f variant=both

# Or via web UI
# Actions → Build Podman → Run workflow → Enter version
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

**CMake can't find Zig compiler:**

Ensure Zig is in PATH and version is 0.11+:

```bash
which zig
zig version
```

**mimalloc build fails:**

Check that CMake and Ninja are installed:

```bash
cmake --version  # 3.15+
ninja --version
```

**Go build fails with CGO errors:**

Verify environment variables:

```bash
echo $CC        # Should be: zig cc -target x86_64-linux-musl
echo $CGO_ENABLED  # Should be: 1
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

- **CI uses Ubuntu 22.04** - Test locally on similar environment if issues occur
- **CI uses GitHub-hosted runners** - No ARM64 native runners, uses QEMU or cross-compilation
- **CI has OIDC token** - For cosign signing, can't be tested locally

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

- Cross-compile with zig for aarch64-linux-musl
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
