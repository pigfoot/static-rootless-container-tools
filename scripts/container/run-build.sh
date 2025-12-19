#!/bin/bash
# Wrapper script to launch podman container with volume mounts and environment variables
# This script runs on the host (GitHub Actions runner or local machine)
# Usage: ./scripts/container/run-build.sh <tool> [arch] [variant] [libc]
# Example: ./scripts/container/run-build.sh podman amd64 default static
#          ./scripts/container/run-build.sh buildah arm64 full glibc

set -euo pipefail

# Configuration
CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/ubuntu:latest}"
TOOL="${1:-podman}"
ARCH="${2:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"
VARIANT="${3:-default}"
LIBC="${4:-static}"
VERSION="${VERSION:-latest}"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
BUILD_DIR="${REPO_ROOT}/build"

# Cache directories (can be overridden via environment)
CACHE_DIR="${TOOLCHAIN_CACHE_DIR:-${HOME}/.cache/static-build-tools}"
LLVM_CACHE="${CACHE_DIR}/llvm-${ARCH}"
GO_CACHE="${CACHE_DIR}/go-${ARCH}"

echo "=== Containerized Build Wrapper ==="
echo "Tool: ${TOOL}"
echo "Architecture: ${ARCH}"
echo "Variant: ${VARIANT}"
echo "Libc: ${LIBC}"
echo "Version: ${VERSION}"
echo "Container Image: ${CONTAINER_IMAGE}"
echo ""

# Detect container runtime (podman or docker)
if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    echo "Using podman as container runtime"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
    echo "Using docker as container runtime (fallback)"
else
    echo "ERROR: Neither podman nor docker is installed"
    echo "Please install podman (https://podman.io) or docker (https://docker.com)"
    exit 1
fi

# Pull container image
echo "Pulling container image: ${CONTAINER_IMAGE}"
${CONTAINER_RUNTIME} pull "${CONTAINER_IMAGE}"

# Create build directory if it doesn't exist
mkdir -p "${BUILD_DIR}"

# Detect LLVM arch
if [[ "${ARCH}" == "amd64" ]]; then LLVM_ARCH="X64"; else LLVM_ARCH="ARM64"; fi

# Get latest versions
echo "Checking for toolchain updates..."
LLVM_TAG=$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest 2>/dev/null | jq -r '.tag_name')
LLVM_VERSION="${LLVM_TAG#llvmorg-}"
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -n1 | sed 's/go//')

echo "  Latest LLVM: ${LLVM_VERSION}"
echo "  Latest Go: ${GO_VERSION}"

# Check LLVM version and download if needed
LLVM_VERSION_FILE="${LLVM_CACHE}/.version"
INSTALLED_LLVM=""
[[ -f "$LLVM_VERSION_FILE" ]] && INSTALLED_LLVM=$(cat "$LLVM_VERSION_FILE")

if [[ "$LLVM_VERSION" != "$INSTALLED_LLVM" ]]; then
    if [[ -n "$INSTALLED_LLVM" ]]; then
        echo "Updating LLVM: $INSTALLED_LLVM → $LLVM_VERSION"
    else
        echo "Downloading LLVM ${LLVM_VERSION}..."
    fi
    rm -rf "${LLVM_CACHE}"
    mkdir -p "${LLVM_CACHE}"

    LLVM_URL="https://github.com/llvm/llvm-project/releases/download/${LLVM_TAG}/LLVM-${LLVM_VERSION}-Linux-${LLVM_ARCH}.tar.xz"

    if ! curl -fsSL "$LLVM_URL" -o /tmp/llvm.tar.xz; then
        # Fallback to previous version
        echo "  Failed to download latest, trying previous version..."
        LLVM_TAG=$(curl -fsSL "https://api.github.com/repos/llvm/llvm-project/releases" | \
          jq -r '.[].tag_name | select(startswith("llvmorg-"))' | head -2 | tail -1)
        LLVM_VERSION="${LLVM_TAG#llvmorg-}"
        LLVM_URL="https://github.com/llvm/llvm-project/releases/download/${LLVM_TAG}/LLVM-${LLVM_VERSION}-Linux-${LLVM_ARCH}.tar.xz"
        curl -fsSL "$LLVM_URL" -o /tmp/llvm.tar.xz
    fi

    echo "  Extracting LLVM..."
    tar -xf /tmp/llvm.tar.xz -C "${LLVM_CACHE}" --strip-components=1
    rm /tmp/llvm.tar.xz
    echo "$LLVM_VERSION" > "$LLVM_VERSION_FILE"
    echo "  LLVM ${LLVM_VERSION} cached at: ${LLVM_CACHE}"
else
    echo "LLVM ${LLVM_VERSION} already cached"
fi

# Check Go version and download if needed
GO_VERSION_FILE="${GO_CACHE}/.version"
INSTALLED_GO=""
[[ -f "$GO_VERSION_FILE" ]] && INSTALLED_GO=$(cat "$GO_VERSION_FILE")

if [[ "$GO_VERSION" != "$INSTALLED_GO" ]]; then
    if [[ -n "$INSTALLED_GO" ]]; then
        echo "Updating Go: $INSTALLED_GO → $GO_VERSION"
    else
        echo "Downloading Go ${GO_VERSION}..."
    fi
    rm -rf "${GO_CACHE}"
    mkdir -p "${GO_CACHE}"

    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
    echo "  Extracting Go..."
    tar -xzf /tmp/go.tar.gz -C "${GO_CACHE}" --strip-components=1
    rm /tmp/go.tar.gz
    echo "$GO_VERSION" > "$GO_VERSION_FILE"
    echo "  Go ${GO_VERSION} cached at: ${GO_CACHE}"
else
    echo "Go ${GO_VERSION} already cached"
fi

# Check for cached toolchains and setup mounts
CACHE_MOUNTS=()
CACHE_ENV=()

if [[ -d "${LLVM_CACHE}" && -x "${LLVM_CACHE}/bin/clang" ]]; then
    echo "Using cached LLVM from: ${LLVM_CACHE}"
    CACHE_MOUNTS+=("-v" "${LLVM_CACHE}:/usr/local/llvm:ro,z")
    CACHE_ENV+=("-e" "USE_CACHED_LLVM=1")
else
    echo "No LLVM cache found (will download during build)"
    CACHE_ENV+=("-e" "USE_CACHED_LLVM=0")
fi

if [[ -d "${GO_CACHE}" && -x "${GO_CACHE}/bin/go" ]]; then
    echo "Using cached Go from: ${GO_CACHE}"
    CACHE_MOUNTS+=("-v" "${GO_CACHE}:/usr/local/go:ro,z")
    CACHE_ENV+=("-e" "USE_CACHED_GO=1")
else
    echo "No Go cache found (will download during build)"
    CACHE_ENV+=("-e" "USE_CACHED_GO=0")
fi

# Run build in container
echo ""
echo "=== Starting containerized build ==="
${CONTAINER_RUNTIME} run --rm \
    ${CACHE_MOUNTS[@]+"${CACHE_MOUNTS[@]}"} \
    ${CACHE_ENV[@]+"${CACHE_ENV[@]}"} \
    -v "${SCRIPTS_DIR}:/workspace/scripts:ro,z" \
    -v "${BUILD_DIR}:/workspace/build:rw,z" \
    -e VERSION="${VERSION}" \
    -e TOOL="${TOOL}" \
    -e ARCH="${ARCH}" \
    -e VARIANT="${VARIANT}" \
    -e LIBC="${LIBC}" \
    "${CONTAINER_IMAGE}" \
    bash -c "
        source /workspace/scripts/container/setup-build-env.sh && \
        /workspace/scripts/build-tool.sh ${TOOL} ${ARCH} ${VARIANT} ${LIBC} && \
        DETECTED_VERSION=\$(cat /workspace/build/.detected-version) && \
        /workspace/scripts/package.sh ${TOOL} ${ARCH} ${LIBC} ${VARIANT} \"\${DETECTED_VERSION}\"
    "

echo ""
echo "=== Containerized build complete ==="
if [[ "$LIBC" == "glibc" ]]; then
    echo "Artifacts available in: ${BUILD_DIR}/${TOOL}-${ARCH}-glibc/"
else
    echo "Artifacts available in: ${BUILD_DIR}/${TOOL}-${ARCH}/"
fi
