#!/bin/bash
# Setup build environment inside Ubuntu container
# This script installs all dependencies needed for building static binaries
# Uses latest stable versions of Clang, Go, and Rust (not Ubuntu packages)

set -euo pipefail

echo "=== Setting up build environment inside container ==="

# Update package list
echo "Updating package list..."
apt-get update

# Install base dependencies (excluding toolchains)
echo "Installing base dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gnupg \
    software-properties-common \
    musl-dev \
    musl-tools \
    make \
    cmake \
    ninja-build \
    autoconf \
    automake \
    libtool \
    pkg-config \
    git \
    curl \
    ca-certificates \
    zstd \
    gperf \
    libglib2.0-dev \
    libcap-dev \
    meson \
    protobuf-compiler

# Install latest stable Clang/LLVM from official LLVM apt repository
echo "Installing latest stable Clang/LLVM..."
# Add LLVM repository
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc
add-apt-repository -y "deb http://apt.llvm.org/noble/ llvm-toolchain-noble main"
apt-get update

# Install latest LLVM/Clang (version 19 as of 2025-12)
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    clang-19 \
    llvm-19 \
    lld-19

# Set up alternatives to use clang-19 as default
update-alternatives --install /usr/bin/clang clang /usr/bin/clang-19 100
update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-19 100
update-alternatives --install /usr/bin/lld lld /usr/bin/lld-19 100

# Install latest stable Go from official golang.org
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
echo ""
echo "Tool locations:"
echo "  - Clang: $(which clang)"
echo "  - Go: $(which go)"
echo "  - Rust: $(which rustc)"
