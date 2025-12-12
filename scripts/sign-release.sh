#!/usr/bin/env bash
# Sign release artifacts with cosign (keyless OIDC signing)
# Usage: ./scripts/sign-release.sh <file> [file2 file3 ...]
# Example: ./scripts/sign-release.sh podman-full-linux-amd64.tar.zst
#          ./scripts/sign-release.sh *.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check if files were provided
if [[ $# -eq 0 ]]; then
  echo "Error: No files specified" >&2
  echo "Usage: $0 <file> [file2 file3 ...]" >&2
  exit 1
fi

# Check dependencies
if ! command -v cosign &> /dev/null; then
  echo "Error: cosign not found" >&2
  echo "Please install cosign: https://docs.sigstore.dev/cosign/installation/" >&2
  exit 1
fi

# Check cosign version (require 2.0+)
COSIGN_VERSION=$(cosign version 2>&1 | grep GitVersion | sed -E 's/.*v([0-9]+\.[0-9]+).*/\1/')
if [[ -n "$COSIGN_VERSION" ]]; then
  echo "Cosign version: $COSIGN_VERSION"
fi

echo "========================================"
echo "Signing release artifacts with cosign"
echo "========================================"
echo ""

# In GitHub Actions, OIDC token is automatically available
# In local environment, user must authenticate interactively
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "Running in GitHub Actions (OIDC mode)"
  COSIGN_EXPERIMENTAL=1
else
  echo "Running locally (interactive mode)"
  echo "Note: You may need to authenticate with your identity provider"
fi

# Sign each file
SUCCESS_COUNT=0
FAIL_COUNT=0

for FILE in "$@"; do
  # Convert to absolute path
  if [[ "$FILE" != /* ]]; then
    FILE="$PROJECT_ROOT/$FILE"
  fi

  # Check if file exists
  if [[ ! -f "$FILE" ]]; then
    echo "⚠ Warning: File not found: $FILE" >&2
    ((FAIL_COUNT++))
    continue
  fi

  echo "----------------------------------------"
  echo "Signing: $(basename "$FILE")"
  echo "----------------------------------------"

  SIGNATURE_FILE="${FILE}.sig"

  # Sign the blob
  # --yes flag: Skip confirmation prompts in automated environments
  # For GitHub Actions with OIDC, this automatically uses the workflow identity
  if cosign sign-blob \
    --yes \
    --output-signature "$SIGNATURE_FILE" \
    "$FILE"; then

    echo "✓ Signature created: $(basename "$SIGNATURE_FILE")"

    # Show signature info
    ls -lh "$SIGNATURE_FILE"

    # If in GitHub Actions, show the identity that signed
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "  Signed by: ${GITHUB_REPOSITORY:-unknown}@${GITHUB_REF:-unknown}"
      echo "  Workflow: ${GITHUB_WORKFLOW:-unknown}"
      echo "  Run ID: ${GITHUB_RUN_ID:-unknown}"
    fi

    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "✗ Failed to sign: $(basename "$FILE")" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  echo ""
done

# Summary
echo "========================================"
echo "Signing Summary"
echo "========================================"
echo "Total files: $#"
echo "Successful: $SUCCESS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "⚠ Some files failed to sign" >&2
  exit 1
fi

echo "✓ All files signed successfully"
echo ""
echo "Verification command:"
echo "  cosign verify-blob \\"
echo "    --signature <file>.sig \\"
echo "    --certificate-identity-regexp 'https://github.com/.*' \\"
echo "    --certificate-oidc-issuer https://token.actions.githubusercontent.com \\"
echo "    <file>"
