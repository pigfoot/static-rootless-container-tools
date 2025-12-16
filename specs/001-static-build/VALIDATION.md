# End-to-End Validation Checklist

This checklist validates the complete implementation of Feature 001: Static Container Tools Build System.

## Prerequisites

Before running this validation, ensure:

- [ ] Repository pushed to GitHub
- [ ] GitHub Actions enabled
- [ ] Repository secrets configured (if needed for cosign)
- [ ] At least one manual build workflow executed successfully

## Phase 1-2: Core Infrastructure (Local)

### Build System

- [ ] `make build-podman` successfully builds podman for current arch
- [ ] `make build-buildah` successfully builds buildah
- [ ] `make build-skopeo` successfully builds skopeo
- [ ] All binaries verified static with `ldd` (output: "not a dynamic executable")
- [ ] `make test` passes all smoke tests

### Build Scripts

- [ ] `./scripts/build-mimalloc.sh amd64` builds successfully
- [ ] `./scripts/build-mimalloc.sh arm64` builds successfully (if cross-compile env available)
- [ ] `./scripts/build-tool.sh podman amd64 full` completes without errors
- [ ] `./scripts/check-version.sh podman` reports correct latest version
- [ ] `./scripts/test-static.sh build/podman-amd64/install` passes all checks

## Phase 3: User Story 1 - Independent Tool Releases (GitHub)

### Podman Build Workflow

- [ ] Trigger `build-podman.yml` manually with version input (e.g., v5.3.1)
- [ ] Workflow builds all matrix combinations (3 variants × 2 architectures = 6):
  - [ ] podman-linux-amd64 (default variant - simplified name)
  - [ ] podman-linux-arm64 (default variant - simplified name)
  - [ ] podman-standalone-linux-amd64
  - [ ] podman-standalone-linux-arm64
  - [ ] podman-full-linux-amd64
  - [ ] podman-full-linux-arm64
- [ ] All artifacts uploaded successfully
- [ ] Release created with tag `podman-v5.3.1`
- [ ] Release includes:
  - [ ] 6 tarballs (.tar.zst) - 3 variants × 2 architectures
  - [ ] 6 cosign signature bundles (.tar.zst.bundle)
  - [ ] checksums.txt
  - [ ] Proper release notes with installation instructions

### Buildah Build Workflow

- [ ] Trigger `build-buildah.yml` manually with version input
- [ ] Workflow builds both architectures:
  - [ ] buildah-linux-amd64
  - [ ] buildah-linux-arm64
- [ ] Release created with tag `buildah-v1.35.0`
- [ ] All artifacts present and signed

### Skopeo Build Workflow

- [ ] Trigger `build-skopeo.yml` manually with version input
- [ ] Workflow builds both architectures:
  - [ ] skopeo-linux-amd64
  - [ ] skopeo-linux-arm64
- [ ] Release created with tag `skopeo-v1.14.0`
- [ ] All artifacts present and signed

### Independent Releases Verification

- [ ] Podman release is independent (doesn't include buildah/skopeo)
- [ ] Buildah release is independent (doesn't include podman/skopeo)
- [ ] Skopeo release is independent (doesn't include podman/buildah)
- [ ] Each tool has separate release tags
- [ ] Releases can be created in any order

## Phase 4: User Story 2 - Cryptographic Signing (GitHub)

### Artifact Signing

- [ ] All tarballs have corresponding `.sig` files
- [ ] Signatures created with cosign OIDC (keyless)
- [ ] `checksums.txt` contains SHA256 for all tarballs

### Signature Verification (Local)

Download a release and verify:

```bash
# Download artifacts
curl -fsSL -O https://github.com/pigfoot/static-rootless-container-tools/releases/download/podman-v5.3.1/podman-full-linux-amd64.tar.zst
curl -fsSL -O https://github.com/pigfoot/static-rootless-container-tools/releases/download/podman-v5.3.1/podman-full-linux-amd64.tar.zst.sig
curl -fsSL -O https://github.com/pigfoot/static-rootless-container-tools/releases/download/podman-v5.3.1/checksums.txt
```

- [ ] Checksum verification passes:
  ```bash
  sha256sum -c checksums.txt --ignore-missing
  # Output: podman-full-linux-amd64.tar.zst: OK
  ```

- [ ] Cosign signature verification passes:
  ```bash
  cosign verify-blob \
    --signature podman-full-linux-amd64.tar.zst.sig \
    --certificate-identity-regexp="https://github.com/pigfoot/static-rootless-container-tools/.*" \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    podman-full-linux-amd64.tar.zst
  # Output: Verified OK
  ```

## Phase 5: User Story 3 - Automatic Version Detection (GitHub)

### Daily Cron Workflow

- [ ] `check-releases.yml` workflow exists and has cron trigger `0 2 * * *`
- [ ] Workflow can be triggered manually via `workflow_dispatch`

### Manual Trigger Test

- [ ] Trigger `check-releases.yml` manually (Actions → Check New Releases → Run workflow)
- [ ] Workflow checks all three tools (podman, buildah, skopeo)
- [ ] For each tool:
  - [ ] Fetches latest upstream version
  - [ ] Compares with existing releases
  - [ ] Skips pre-release versions (alpha/beta/rc)
  - [ ] If new version: triggers build workflow
  - [ ] If version exists: skips build

### Version Detection Logic

- [ ] Test with existing version: No build triggered
- [ ] Test with force_build=true: Build triggered even for existing version
- [ ] Pre-release versions filtered out (e.g., v5.4.0-rc1 ignored)

### Automatic Trigger Verification

Wait for next cron execution (or manually trigger):

- [ ] Workflow runs at scheduled time
- [ ] Detects new upstream releases
- [ ] Triggers builds automatically
- [ ] New releases appear without manual intervention

## Phase 6: User Story 4 - Manual Build Trigger (GitHub)

### Workflow Dispatch Inputs

- [ ] `build-podman.yml` has `workflow_dispatch` with:
  - [ ] `version` input (required)
  - [ ] `variant` input (standalone/default/full/all)
  - [ ] `architecture` input (amd64/arm64/both)
- [ ] `build-buildah.yml` has `workflow_dispatch` with `version` input
- [ ] `build-skopeo.yml` has `workflow_dispatch` with `version` input

### Manual Trigger Test

- [ ] Trigger podman build for specific version via UI
- [ ] Trigger buildah build via GitHub CLI:
  ```bash
  gh workflow run build-buildah.yml -f version=v1.35.0
  ```
- [ ] Trigger skopeo build for older version (e.g., v1.13.0)

### Release Update Logic

- [ ] Build same version twice (e.g., podman v5.3.1)
- [ ] Second build replaces artifacts in existing release (doesn't create duplicate)
- [ ] `--clobber` flag works correctly
- [ ] Release notes remain intact

## Phase 7: Polish & Cross-Cutting Concerns

### Error Handling

- [ ] `check-version.sh` handles GitHub API rate limit:
  ```bash
  # Artificially trigger rate limit or check with low remaining calls
  ./scripts/check-version.sh podman
  # Should warn if rate limit low, exit gracefully if exceeded
  ```

### Retry Logic

- [ ] Test with simulated network failure (e.g., disconnect during git clone)
- [ ] Build script retries up to 3 times
- [ ] Proper error messages displayed
- [ ] Clean up on failure before retry

### Build Failure Handling

- [ ] Simulate build failure for one architecture (e.g., arm64)
- [ ] Matrix continues with `fail-fast: false`
- [ ] Release job does NOT run (due to `if: success()`)
- [ ] No partial releases created

### Documentation

- [ ] `README.md` has correct project description
- [ ] `quickstart.md` has working installation examples (after replacing placeholders)
- [ ] `CONTRIBUTING.md` has clear development workflow
- [ ] All file paths in docs are correct

## End-to-End User Workflow (Quickstart Validation)

Follow `quickstart.md` exactly as a new user would:

### User Installation

- [ ] Download latest release tarball
- [ ] Verify checksum
- [ ] Verify signature with cosign
- [ ] Extract tarball
- [ ] Binary is executable
- [ ] `./podman --version` works
- [ ] Run container: `./podman run --rm alpine echo "Hello"`

### Developer Workflow

- [ ] Clone repository
- [ ] Install prerequisites (Go, Zig, etc.)
- [ ] Build locally with Make
- [ ] Run tests
- [ ] Create feature branch
- [ ] Make changes
- [ ] Commit with conventional format
- [ ] Push and create PR

## Success Criteria

**All checkboxes must be checked for validation to pass.**

### Critical Path (Must Pass)

- [ ] All three tools build successfully for both architectures
- [ ] All artifacts are truly static (verified with ldd)
- [ ] Signatures verify correctly
- [ ] Automatic version detection works
- [ ] Manual triggers work
- [ ] End-to-end user installation succeeds

### Non-Critical (Should Pass)

- [ ] Retry logic handles network failures
- [ ] Rate limit handling works
- [ ] Build failure prevents partial releases
- [ ] Documentation is accurate

## Troubleshooting

If any check fails, refer to:

- **Build failures**: Check `CONTRIBUTING.md` troubleshooting section
- **Workflow failures**: Check GitHub Actions logs
- **Signature issues**: Ensure cosign v2.0+ installed
- **Version detection**: Check `scripts/check-version.sh` output

## Notes

- Replace `pigfoot/static-rootless-container-tools` with actual repository before testing
- Some tests require waiting for cron schedule
- ARM64 builds may use QEMU on GitHub-hosted runners (slower)
- Local validation can be done before GitHub push for most items
