#!/usr/bin/env bash
# Check if upstream has new version compared to local releases
# Usage: ./scripts/check-version.sh <tool> [repo-owner]
# Example: ./scripts/check-version.sh podman
#          ./scripts/check-version.sh buildah myuser

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
TOOL="${1:-}"
REPO_OWNER="${2:-}"

if [[ -z "$TOOL" ]]; then
  echo "Error: Tool name required" >&2
  echo "Usage: $0 <podman|buildah|skopeo> [repo-owner]" >&2
  exit 1
fi

# Validate tool
case "$TOOL" in
  podman|buildah|skopeo)
    ;;
  *)
    echo "Error: Unsupported tool: $TOOL" >&2
    exit 1
    ;;
esac

# Determine upstream repository
UPSTREAM_REPO="containers/$TOOL"

# Determine local repository (from environment or argument)
if [[ -n "$REPO_OWNER" ]]; then
  LOCAL_REPO="$REPO_OWNER/rootless-static-toolkits"
elif [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  LOCAL_REPO="$GITHUB_REPOSITORY"
else
  # Try to get from git remote
  LOCAL_REPO=$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null | sed -E 's#https://github.com/([^/]+/[^/]+)(\.git)?#\1#' || echo "")
  if [[ -z "$LOCAL_REPO" ]]; then
    echo "Error: Could not determine local repository" >&2
    echo "Please set GITHUB_REPOSITORY or pass repo-owner as argument" >&2
    exit 1
  fi
fi

echo "Checking versions for: $TOOL"
echo "Upstream: $UPSTREAM_REPO"
echo "Local: $LOCAL_REPO"
echo ""

# Check dependencies
if ! command -v gh &> /dev/null; then
  echo "Error: gh CLI not found" >&2
  exit 1
fi

# Check GitHub API rate limit
echo "Checking GitHub API rate limit..."
RATE_LIMIT=$(gh api rate_limit --jq '.rate.remaining' 2>/dev/null || echo "unknown")
if [[ "$RATE_LIMIT" != "unknown" && "$RATE_LIMIT" -lt 10 ]]; then
  RESET_TIME=$(gh api rate_limit --jq '.rate.reset' 2>/dev/null || echo "unknown")
  if [[ "$RESET_TIME" != "unknown" ]]; then
    RESET_DATE=$(date -d "@$RESET_TIME" 2>/dev/null || date -r "$RESET_TIME" 2>/dev/null || echo "unknown")
    echo "Warning: GitHub API rate limit low ($RATE_LIMIT remaining)" >&2
    echo "Rate limit resets at: $RESET_DATE" >&2
  fi
  if [[ "$RATE_LIMIT" -eq 0 ]]; then
    echo "Error: GitHub API rate limit exceeded" >&2
    exit 1
  fi
fi

# Get latest upstream version (excluding pre-releases)
echo "Fetching latest upstream version..."
UPSTREAM_VERSION=$(gh release list \
  --repo "$UPSTREAM_REPO" \
  --limit 50 \
  --exclude-drafts \
  --exclude-pre-releases \
  2>&1 | tee /tmp/gh_output.txt \
  | grep -v -E '(alpha|beta|rc|RC|HTTP)' \
  | head -1 \
  | awk '{print $1}')

# Check if rate limited
if grep -qi "rate limit" /tmp/gh_output.txt 2>/dev/null; then
  echo "Error: GitHub API rate limit exceeded while fetching releases" >&2
  rm -f /tmp/gh_output.txt
  exit 1
fi
rm -f /tmp/gh_output.txt

if [[ -z "$UPSTREAM_VERSION" ]]; then
  echo "Error: Could not fetch upstream version" >&2
  exit 1
fi

echo "Latest upstream: $UPSTREAM_VERSION"

# Normalize version (ensure it starts with 'v')
if [[ ! "$UPSTREAM_VERSION" =~ ^v ]]; then
  UPSTREAM_VERSION="v$UPSTREAM_VERSION"
fi

# Check if this version already exists in local releases
LOCAL_TAG="${TOOL}-${UPSTREAM_VERSION}"
echo "Checking for local release: $LOCAL_TAG"

if gh release view "$LOCAL_TAG" --repo "$LOCAL_REPO" &>/dev/null; then
  echo "✓ Release $LOCAL_TAG already exists"
  echo "NEW_VERSION=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "VERSION=$UPSTREAM_VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
else
  echo "✗ Release $LOCAL_TAG does not exist"
  echo "NEW_VERSION=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "VERSION=$UPSTREAM_VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo ""
  echo "New version detected: $UPSTREAM_VERSION"
  echo "Action required: Trigger build for $TOOL $UPSTREAM_VERSION"
  exit 0
fi
