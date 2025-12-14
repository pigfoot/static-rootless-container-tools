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

# Function: Fetch GitHub releases with exponential backoff
# Args: $1 = repository (e.g., "containers/podman")
# Returns: Release list or exits on failure after retries
fetch_releases_with_retry() {
  local repo="$1"
  local attempt=1
  local max_attempts=3
  local delay=1

  while [[ $attempt -le $max_attempts ]]; do
    echo "  Attempt $attempt/$max_attempts: Fetching releases from $repo" >&2

    # Check rate limit before attempting
    local rate_limit=$(gh api rate_limit --jq '.rate.remaining' 2>/dev/null || echo "0")
    if [[ "$rate_limit" -eq 0 ]]; then
      echo "  Rate limit exceeded" >&2
      if [[ $attempt -lt $max_attempts ]]; then
        echo "  Waiting ${delay}s before retry..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
        continue
      else
        echo "Error: GitHub API rate limit exceeded after $max_attempts attempts" >&2
        exit 1
      fi
    fi

    # Attempt to fetch releases
    local output
    if output=$(gh release list --repo "$repo" --limit 50 --exclude-drafts 2>&1); then
      # Success
      echo "$output"
      return 0
    else
      # Check if error is rate limit related
      if echo "$output" | grep -qi "rate limit"; then
        echo "  Rate limit error" >&2
      else
        echo "  API error: $output" >&2
      fi

      if [[ $attempt -lt $max_attempts ]]; then
        echo "  Waiting ${delay}s before retry..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
      else
        echo "Error: Failed to fetch releases after $max_attempts attempts" >&2
        exit 1
      fi
    fi
  done
}

# Check GitHub API rate limit (initial check)
echo "Checking GitHub API rate limit..."
RATE_LIMIT=$(gh api rate_limit --jq '.rate.remaining' 2>/dev/null || echo "unknown")
if [[ "$RATE_LIMIT" != "unknown" && "$RATE_LIMIT" -lt 10 ]]; then
  RESET_TIME=$(gh api rate_limit --jq '.rate.reset' 2>/dev/null || echo "unknown")
  if [[ "$RESET_TIME" != "unknown" ]]; then
    RESET_DATE=$(date -d "@$RESET_TIME" 2>/dev/null || date -r "$RESET_TIME" 2>/dev/null || echo "unknown")
    echo "Warning: GitHub API rate limit low ($RATE_LIMIT remaining)" >&2
    echo "Rate limit resets at: $RESET_DATE" >&2
  fi
fi

# Semver pattern: v1.2.3 or v1.2 or 1.2.3 or 1.2
SEMVER_PATTERN='^v?[0-9]+\.[0-9]+(\.[0-9]+)?$'

# Get latest upstream version (excluding pre-releases)
echo "Fetching latest upstream version..."
UPSTREAM_VERSION=""

# Fetch releases with retry and filter by semver pattern
RELEASES_OUTPUT=$(fetch_releases_with_retry "$UPSTREAM_REPO")

while IFS=$'\t' read -r version rest; do
  # Skip empty lines
  [[ -z "$version" ]] && continue

  # Skip pre-releases (alpha, beta, rc, etc.)
  if [[ "$version" =~ (alpha|beta|rc|RC|dev|pre|snapshot) ]]; then
    echo "  Skipping pre-release: $version" >&2
    continue
  fi

  # Validate semver pattern
  if [[ ! "$version" =~ $SEMVER_PATTERN ]]; then
    echo "  Skipping invalid semver: $version" >&2
    continue
  fi

  # First valid version is the latest
  UPSTREAM_VERSION="$version"
  echo "  Latest stable version: $UPSTREAM_VERSION" >&2
  break
done < <(echo "$RELEASES_OUTPUT")

if [[ -z "$UPSTREAM_VERSION" ]]; then
  echo "Error: Could not find valid upstream version" >&2
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
