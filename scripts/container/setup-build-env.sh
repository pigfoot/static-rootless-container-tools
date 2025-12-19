#!/bin/bash
# Setup build environment inside Ubuntu container
# This script installs all dependencies needed for building static binaries
# Uses latest stable versions of Clang, Go, and Rust (not Ubuntu packages)

set -euo pipefail

echo "=== Setting up build environment inside container ==="

# Update package list with retry logic (temporarily disable exit on error)
echo "Updating package list..."
set +e  # Disable exit on error for retry logic
for i in {1..3}; do
    apt-get update
    if [ $? -eq 0 ]; then
        echo "✓ apt-get update successful"
        set -e  # Re-enable exit on error
        break
    else
        if [ $i -lt 3 ]; then
            echo "⚠ Warning: apt-get update failed (attempt $i/3)"
            echo "Retrying in 10 seconds..."
            sleep 10
        else
            echo "✗ Error: apt-get update failed after 3 attempts"
            set -e  # Re-enable exit on error before exiting
            exit 1
        fi
    fi
done

# Install base dependencies (excluding toolchains)
echo "Installing base dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-install-suggests \
    musl-dev \
    musl-tools \
    libc6-dev \
    make \
    autoconf \
    automake \
    libtool \
    pkg-config \
    git \
    curl \
    ca-certificates \
    zstd \
    gperf \
    libcap-dev \
    protobuf-compiler \
    libffi-dev \
    libpcre2-dev \
    zlib1g-dev

# Install uv for Python-based build tools
echo "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="/root/.local/bin:$PATH"
echo 'export PATH="/root/.local/bin:$PATH"' >> /etc/profile.d/uv.sh

# Install Python via uv (needed for crun's configure script)
echo "Installing Python via uv..."
/root/.local/bin/uv python install

# Install Python-based build tools via uv
echo "Installing meson and ninja via uv..."
/root/.local/bin/uv tool install meson
/root/.local/bin/uv tool install ninja

# Install cmake via direct download from Kitware
echo "Installing cmake from Kitware..."
CMAKE_ARCH=$(uname -m)
CMAKE_VERSION=$(curl -s https://api.github.com/repos/Kitware/CMake/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p')
# Fallback to known stable version if API fails (rate limit, network issues)
if [[ -z "$CMAKE_VERSION" ]]; then
    CMAKE_VERSION="3.31.3"
    echo "  Warning: Could not detect latest CMake version, using fallback: $CMAKE_VERSION"
else
    echo "  Detected latest CMake version: $CMAKE_VERSION"
fi

if [[ "$CMAKE_ARCH" == "x86_64" ]]; then
    CMAKE_TARBALL="cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"
elif [[ "$CMAKE_ARCH" == "aarch64" ]]; then
    CMAKE_TARBALL="cmake-${CMAKE_VERSION}-linux-aarch64.tar.gz"
else
    echo "Error: Unsupported architecture for cmake: $CMAKE_ARCH"
    exit 1
fi

CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${CMAKE_TARBALL}"
echo "  Downloading $CMAKE_TARBALL..."
curl -fsSL "$CMAKE_URL" -o /tmp/cmake.tar.gz
mkdir -p /usr/local/cmake
tar -xzf /tmp/cmake.tar.gz -C /usr/local/cmake --strip-components=1
rm /tmp/cmake.tar.gz

# Add cmake to PATH
export PATH="/usr/local/cmake/bin:$PATH"
echo 'export PATH="/usr/local/cmake/bin:$PATH"' >> /etc/profile.d/cmake.sh

# Install latest stable Clang/LLVM from GitHub releases
if [[ "${USE_CACHED_LLVM:-0}" == "1" && -x /usr/local/llvm/bin/clang ]]; then
    echo "Using cached LLVM (mounted from host)..."
    export PATH="/usr/local/llvm/bin:$PATH"
    echo 'export PATH="/usr/local/llvm/bin:$PATH"' >> /etc/profile.d/llvm.sh
    ln -sf /usr/local/llvm/bin/clang /usr/bin/clang
    ln -sf /usr/local/llvm/bin/clang++ /usr/bin/clang++
    ln -sf /usr/local/llvm/bin/lld /usr/bin/lld
else
    echo "Installing latest stable Clang/LLVM from GitHub..."

    # Detect architecture
    LLVM_ARCH=$(uname -m)
    if [[ "$LLVM_ARCH" == "x86_64" ]]; then
        LLVM_ARCH="X64"
    elif [[ "$LLVM_ARCH" == "aarch64" ]]; then
        LLVM_ARCH="ARM64"
    else
        echo "Error: Unsupported architecture: $LLVM_ARCH"
        exit 1
    fi

    # Get latest LLVM release version with prebuilt binaries
    # Note: Latest release may not have prebuilt binaries yet, so we try with fallback
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      LLVM_TAG=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
          https://api.github.com/repos/llvm/llvm-project/releases/latest | \
          sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p')
    else
      LLVM_TAG=$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest | \
          sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p')
    fi
    LLVM_VERSION="${LLVM_TAG#llvmorg-}"
    echo "  Detected latest LLVM version: $LLVM_VERSION (tag: $LLVM_TAG)"

    # Download and extract LLVM (with retry fallback to previous version)
    LLVM_TARBALL="LLVM-${LLVM_VERSION}-Linux-${LLVM_ARCH}.tar.xz"
    LLVM_URL="https://github.com/llvm/llvm-project/releases/download/${LLVM_TAG}/${LLVM_TARBALL}"

    echo "  Downloading $LLVM_TARBALL..."
    if ! curl -fsSL "$LLVM_URL" -o /tmp/llvm.tar.xz; then
      echo "  Warning: Latest version prebuilt binary not available yet, trying previous version..."

      # Try previous versions (usually N-1 or N-2 has binaries)
      if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        LLVM_TAG=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/repos/llvm/llvm-project/releases" | \
            sed -n 's/.*"tag_name": "\(llvmorg-[^"]*\)".*/\1/p' | head -2 | tail -1)
      else
        LLVM_TAG=$(curl -fsSL \
            "https://api.github.com/repos/llvm/llvm-project/releases" | \
            sed -n 's/.*"tag_name": "\(llvmorg-[^"]*\)".*/\1/p' | head -2 | tail -1)
      fi

      LLVM_VERSION="${LLVM_TAG#llvmorg-}"
      LLVM_TARBALL="LLVM-${LLVM_VERSION}-Linux-${LLVM_ARCH}.tar.xz"
      LLVM_URL="https://github.com/llvm/llvm-project/releases/download/${LLVM_TAG}/${LLVM_TARBALL}"

      echo "  Trying LLVM $LLVM_VERSION instead..."
      curl -fsSL "$LLVM_URL" -o /tmp/llvm.tar.xz
    fi

    echo "  Using LLVM version: $LLVM_VERSION"

    echo "  Extracting to /usr/local/llvm..."
    mkdir -p /usr/local/llvm
    tar -xf /tmp/llvm.tar.xz -C /usr/local/llvm --strip-components=1
    rm /tmp/llvm.tar.xz

    # Add LLVM to PATH and set up symlinks
    export PATH="/usr/local/llvm/bin:$PATH"
    echo 'export PATH="/usr/local/llvm/bin:$PATH"' >> /etc/profile.d/llvm.sh

    # Create symlinks for standard names
    ln -sf /usr/local/llvm/bin/clang /usr/bin/clang
    ln -sf /usr/local/llvm/bin/clang++ /usr/bin/clang++
    ln -sf /usr/local/llvm/bin/lld /usr/bin/lld
fi

# Install latest stable Go from official golang.org
if [[ "${USE_CACHED_GO:-0}" == "1" && -x /usr/local/go/bin/go ]]; then
    echo "Using cached Go (mounted from host)..."
    export PATH="/usr/local/go/bin:$PATH"
    echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile.d/go.sh
else
    echo "Installing latest stable Go..."
    # Auto-detect latest Go version with retries
    for i in {1..3}; do
        GO_VERSION=$(curl -fsSL --retry 3 --retry-delay 2 "https://go.dev/VERSION?m=text" | head -n1 | sed 's/go//') && break
        echo "  Retry $i/3: Failed to fetch Go version, retrying..."
        sleep 2
    done
    if [[ -z "$GO_VERSION" ]]; then
        echo "Error: Failed to detect latest Go version after 3 attempts"
        exit 1
    fi
    echo "  Detected latest Go version: $GO_VERSION"

    GO_ARCH=$(dpkg --print-architecture)
    if [[ "$GO_ARCH" == "amd64" ]]; then
        GO_ARCH="amd64"
    elif [[ "$GO_ARCH" == "arm64" ]]; then
        GO_ARCH="arm64"
    fi

    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz

    # Add Go to PATH
    export PATH="/usr/local/go/bin:$PATH"
    echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile.d/go.sh
fi

# Install latest stable Rust via rustup
echo "Installing latest stable Rust via rustup..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal

# Source cargo environment
export PATH="/root/.cargo/bin:$PATH"
source /root/.cargo/env

# Add Rust musl targets for static linking
echo "Adding Rust musl targets..."
rustup target add x86_64-unknown-linux-musl
rustup target add aarch64-unknown-linux-musl

# Clean up
echo "Cleaning up package cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=== Build environment setup complete ==="
echo "Installed tools:"
echo "  - Clang: $(clang --version | head -n1)"
echo "  - Go: $(go version)"
echo "  - Rust: $(rustc --version)"
echo "  - Cargo: $(cargo --version)"
echo "  - CMake: $(/usr/local/cmake/bin/cmake --version | head -n1)"
echo "  - Meson: $(/root/.local/bin/uv tool run meson --version)"
echo "  - Ninja: $(/root/.local/bin/uv tool run ninja --version)"
echo "  - uv: $(/root/.local/bin/uv --version)"
echo "  - Python: $(/root/.local/bin/uv run python --version)"
echo ""
echo "Tool locations:"
echo "  - Clang: $(which clang)"
echo "  - Go: $(which go)"
echo "  - Rust: $(which rustc)"
echo "  - CMake: /usr/local/cmake/bin/cmake"
echo "  - uv: /root/.local/bin/uv"
echo "  - Python: /root/.local/bin/uv run python"
