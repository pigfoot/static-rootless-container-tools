# Tasks: Static Container Tools Build System

**Input**: Design documents from `/specs/001-static-build/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Not explicitly requested in spec - tasks focus on build infrastructure implementation

**Organization**: Tasks grouped by user story to enable independent implementation and testing

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and containerized build infrastructure

- [X] T001 Create build directory structure at /build/{mimalloc,patches}
- [X] T002 Create scripts directory structure at /scripts/container/
- [X] T003 [P] Add etc/containers/policy.json with insecureAcceptAnything default
- [X] T004 [P] Add etc/containers/registries.conf with docker.io config
- [X] T005 [P] Create Makefile with build-podman, build-buildah, build-skopeo targets
- [X] T006 [P] Create Containerfile.build (optional pre-built image definition)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core containerized build scripts that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T007 Implement scripts/container/setup-build-env.sh - Install clang, musl-dev, musl-tools, go, rust, protobuf-compiler inside Ubuntu container
- [X] T008 [P] Implement scripts/container/run-build.sh - Wrapper to launch podman container with volume mounts and environment variables
- [X] T009 Migrate scripts/build-tool.sh to containerized approach - Remove runner-native dependencies, add container-specific logic for mimalloc build, Go/Rust/C component builds with Clang + musl
- [X] T010 [P] Migrate scripts/package.sh to run inside container - Create variant-specific tarball structures: standalone variant uses root-level binary only (no subdirs, no README), default/full variants use usr/local/bin/, usr/local/lib/podman/, etc/ directories from /workspace/build output
- [X] T011 Implement libseccomp v2.5.5 source build in scripts/build-tool.sh for crun static linking
- [X] T012 [P] Implement libfuse manual build in scripts/build-tool.sh with libfuse_config.h for fuse-overlayfs
- [X] T013 Add Rust musl target support for netavark/aardvark-dns builds

**Checkpoint**: Foundation ready - all build scripts can execute inside Ubuntu container, producing static binaries

---

## Phase 3: User Story 1 - Download Pre-built Static Binary (Priority: P1) 🎯 MVP

**Goal**: Users can download and run static podman/buildah/skopeo binaries from GitHub Releases without installing dependencies

**Independent Test**: Download podman-full-linux-amd64.tar.zst from GitHub Release, extract, run `./bin/podman --version` on clean Alpine system

### Implementation for User Story 1

- [X] T014 [P] [US1] Create .github/workflows/build-podman.yml with containerized build steps (pull ubuntu:rolling, mount volumes, run build)
- [X] T015 [P] [US1] Create .github/workflows/build-buildah.yml with containerized build steps
- [X] T016 [P] [US1] Create .github/workflows/build-skopeo.yml with containerized build steps
- [X] T017 [US1] Add workflow_dispatch inputs for tool, version, architecture, variant in build-podman.yml
- [X] T018 [US1] Add workflow_dispatch inputs for tool, version, architecture in build-buildah.yml and build-skopeo.yml
- [X] T019 [US1] Implement container execution in build-podman.yml - `podman run --rm -v ./scripts:/workspace/scripts:ro,z -v ./build:/workspace/build:rw,z -e VERSION -e TOOL -e ARCH docker.io/ubuntu:rolling`
- [X] T020 [US1] Implement container execution in build-buildah.yml and build-skopeo.yml with same pattern
- [X] T021 [US1] Add artifact upload steps in all workflows - Tarballs already created in container at /workspace/build/*.tar.zst, upload to GitHub Actions artifacts
- [X] T022 [US1] Add static linking verification step - Run `ldd` on all binaries, ensure output shows "not a dynamic executable"
- [X] T023 [US1] Add GitHub Release creation step - Create release with tag `{tool}-v{version}`, upload tarballs for amd64 and arm64
- [X] T024 [US1] Test podman-full build end-to-end - Trigger workflow, verify all 8 components (podman, crun, conmon, fuse-overlayfs, netavark, aardvark-dns, pasta, catatonit) in tarball
- [X] T025 [US1] Test podman-default build - Verify podman + crun + conmon + configs included
- [X] T025b [US1] Test podman-standalone build - Verify only podman binary included
- [X] T026 [US1] Test buildah and skopeo builds - Verify all 3 variants (standalone/default/full) per tool

**Checkpoint**: At this point, users can download static binaries from GitHub Releases and run them on any Linux distribution

---

## Phase 4: User Story 2 - Verify Binary Authenticity (Priority: P2)

**Goal**: Users can verify downloaded binaries using checksums and cosign signatures to ensure integrity and authenticity

**Independent Test**: Download tarball + checksums.txt, run `sha256sum -c checksums.txt --ignore-missing`, verify checksum matches; download cosign signature, verify against Sigstore transparency log

### Implementation for User Story 2

- [X] T027 [P] [US2] Implement scripts/sign-release.sh - Generate SHA256 checksums for all tarballs, create checksums.txt
- [X] T028 [US2] Add cosign keyless signing to scripts/sign-release.sh - Sign each tarball with `cosign sign-blob --bundle`, use GitHub OIDC token
- [X] T029 [US2] Update build-podman.yml - Add checksums generation step after tarball creation
- [X] T030 [US2] Update build-podman.yml - Add cosign signing step after checksums, upload signatures to release
- [X] T031 [P] [US2] Update build-buildah.yml with checksums and signing steps
- [X] T032 [P] [US2] Update build-skopeo.yml with checksums and signing steps
- [X] T033 [US2] Add cosign installation to workflows - Using sigstore/cosign-installer@v4.0.0 action
- [X] T034 [US2] Test checksum verification - Download release, verify sha256sum matches
- [X] T035 [US2] Test cosign signature verification - Documented in release notes with example commands (requires GitHub Actions OIDC for actual signing)

**Checkpoint**: At this point, all releases include checksums.txt and cosign signatures; users can verify integrity and authenticity

---

## Phase 5: User Story 3 - Automatic New Version Detection (Priority: P3)

**Goal**: System automatically detects new upstream releases and triggers builds within 24 hours without manual intervention

**Independent Test**: Simulate upstream release (mock GitHub API response), verify daily check workflow triggers corresponding build workflow

### Implementation for User Story 3

- [X] T036 [P] [US3] Implement scripts/check-version.sh - Query GitHub API `https://api.github.com/repos/containers/{tool}/releases`, parse latest stable version (exclude alpha/beta/rc)
- [X] T037 [US3] Add existing release check to scripts/check-version.sh - Query `https://api.github.com/repos/{this_repo}/releases`, compare with upstream, skip if already released
- [X] T038 [US3] Add semver filtering to scripts/check-version.sh - Use regex `^v?[0-9]+\.[0-9]+(\.[0-9]+)?$`, exclude pre-releases
- [X] T039 [P] [US3] Create .github/workflows/check-releases.yml - Daily cron schedule `0 2 * * *` (UTC 02:00)
- [X] T040 [US3] Add version detection jobs to check-releases.yml - Run scripts/check-version.sh for podman, buildah, skopeo in parallel
- [X] T041 [US3] Add conditional workflow dispatch to check-releases.yml - Trigger build-{tool}.yml if new version detected
- [X] T042 [US3] Add GitHub API rate limit handling - Implement exponential backoff (3 attempts: 1s, 2s, 4s delays), fallback to tags API if releases API fails after retries
- [X] T043 [US3] Test daily check workflow - Mock upstream release, verify build workflow triggered with correct version
- [X] T044 [US3] Test pre-release filtering - Ensure alpha/beta/rc versions are skipped
- [X] T045 [US3] Test duplicate release prevention - Verify already-released versions don't trigger duplicate builds

**Checkpoint**: At this point, new upstream releases automatically trigger builds within 24 hours; no manual intervention required

---

## Phase 6: User Story 4 - Manual Build Trigger (Priority: P4)

**Goal**: Maintainers can manually trigger builds for specific tool versions to rebuild after fixes or build older versions

**Independent Test**: Use GitHub CLI `gh workflow run build-podman.yml -f version=5.3.0`, verify build starts with specified version and completes successfully

### Implementation for User Story 4

- [X] T046 [P] [US4] Add workflow_dispatch trigger to build-podman.yml with inputs (version, architecture [amd64/arm64/both], variant [standalone/default/full/all])
- [X] T047 [P] [US4] Add workflow_dispatch trigger to build-buildah.yml with inputs (version, architecture, variant [standalone/default/full/all])
- [X] T048 [P] [US4] Add workflow_dispatch trigger to build-skopeo.yml with inputs (version, architecture, variant [standalone/default/full/all])
- [X] T049 [US4] Add version validation in workflows - Ensure version follows semver pattern before proceeding
- [X] T050 [US4] Add existing release handling - Check if release exists, update assets instead of creating duplicate
- [X] T051 [US4] Test manual trigger via GitHub UI - Navigate to Actions tab, select workflow, click "Run workflow", specify parameters
- [X] T052 [US4] Test manual trigger via gh CLI - Run `gh workflow run build-podman.yml -f version=5.3.0 -f architecture=amd64 -f variant=default`
- [X] T053 [US4] Test rebuild scenario - Trigger build for already-released version, verify assets are updated not duplicated

**Checkpoint**: All user stories complete - maintainers can manually trigger builds with full control over version/architecture/variant

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories, quality assurance, documentation

- [ ] T054 [P] Add workflow failure notifications - Configure GitHub Actions to create issue on build failure with logs (DEFERRED: Requires actual workflow failures to test)
- [X] T055 [P] Add build time monitoring - Track build duration per tool/architecture, ensure < 30 minutes (NFR SC-005)
- [X] T056 [P] Add artifact size validation - Verify podman-full < 100MB (NFR-001), individual binaries < 50MB (NFR-002)
- [X] T056b [P] Validate FR-008 3-variant packaging - Verify all tools produce exactly 3 variants (standalone/default/full) with correct components per variant; default variant uses simplified naming
- [ ] T057 End-to-end validation on real distributions - Test downloads on Alpine, Ubuntu, CentOS; verify static binaries run (SC-001) (DEFERRED: Requires actual releases and real systems)
- [X] T058 Update quickstart.md with real release URLs - Replace placeholders with actual repository path
- [X] T059 [P] Add MIGRATION-ZIG-TO-CLANG.md to feature directory if not exists - Document: (1) Zig issues (pasta __cpu_model, fuse-overlayfs meson), (2) Clang solution, (3) Build time impact, (4) 8/8 components success proof, (5) Containerization benefits
- [X] T060 Create README.md with quickstart instructions - Link to releases, basic usage examples
- [X] T061 [P] Add workflow badges to README.md - Show build status for podman, buildah, skopeo
- [X] T062 Validate Constitution compliance - Verify all principles (static binaries, independent releases, reproducible builds, minimal deps, automated pipeline) are satisfied

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - **US1 (P1) - Static Binary Builds**: Can start after Foundational - No dependencies on other stories
  - **US2 (P2) - Verification**: Depends on US1 - Requires working builds to verify
  - **US3 (P3) - Auto-Detection**: Depends on US1 - Requires build workflows to trigger
  - **US4 (P4) - Manual Trigger**: Depends on US1 - Requires build workflows to exist
- **Polish (Phase 7)**: Depends on US1-US4 completion

### User Story Dependencies

```
Setup (Phase 1)
    ↓
Foundational (Phase 2) ← BLOCKS ALL USER STORIES
    ↓
US1 (Phase 3) - Static Binary Builds ← MVP
    ↓
US2 (Phase 4) - Verification (depends on US1)
    ↓
US3 (Phase 5) - Auto-Detection (depends on US1)
    ↓
US4 (Phase 6) - Manual Trigger (depends on US1)
    ↓
Polish (Phase 7)
```

### Within Each User Story

- **US1**: Container workflows (T014-T016 parallel) → Container execution (T019-T020 parallel) → Artifact handling → Verification → Testing
- **US2**: Checksums script (T027) → Cosign integration (T028) → Workflow updates (T029-T032 parallel) → Testing
- **US3**: Version check script (T036-T038) → Daily cron workflow (T039) → Conditional triggers (T040-T041) → Testing
- **US4**: Workflow dispatch inputs (T046-T048 parallel) → Validation → Testing

### Parallel Opportunities

- **Phase 1 Setup**: T003, T004, T005, T006 can run in parallel
- **Phase 2 Foundational**: T008, T010, T012, T013 can run in parallel (different files)
- **US1**: T014, T015, T016 (workflows) in parallel; T019, T020 (execution) in parallel
- **US2**: T029, T031, T032 (workflow updates) in parallel
- **US3**: T036 (check script) can be implemented while T039 (cron workflow) is being created
- **US4**: T046, T047, T048 (dispatch triggers) in parallel
- **Phase 7 Polish**: T054, T055, T056, T059, T061 in parallel

---

## Parallel Example: User Story 1 (Static Binary Builds)

```bash
# Launch workflow creation tasks together:
Task: "Create .github/workflows/build-podman.yml"
Task: "Create .github/workflows/build-buildah.yml"
Task: "Create .github/workflows/build-skopeo.yml"

# After workflows created, launch container execution in parallel:
Task: "Implement container execution in build-podman.yml"
Task: "Implement container execution in build-buildah.yml and build-skopeo.yml"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. **Complete Phase 1: Setup** (T001-T006) → 6 tasks
2. **Complete Phase 2: Foundational** (T007-T013) → 7 tasks (CRITICAL - blocks all stories)
3. **Complete Phase 3: User Story 1** (T014-T026) → 13 tasks
4. **STOP and VALIDATE**: Test podman-full build end-to-end on 3 distributions (Alpine, Ubuntu, CentOS)
5. **Deploy**: Tag first release, announce availability

**MVP Deliverable**: Users can download static podman/buildah/skopeo binaries from GitHub Releases and run them on any Linux distribution without dependencies

### Incremental Delivery

1. **MVP (26 tasks)**: Setup + Foundational + US1 → Static binary downloads available
2. **+US2 (9 tasks)**: Add verification → Checksums and signatures available
3. **+US3 (10 tasks)**: Add auto-detection → Automatic releases for new upstream versions
4. **+US4 (8 tasks)**: Add manual trigger → Maintainers can rebuild any version
5. **+Polish (9 tasks)**: Quality improvements → Production-ready

**Total**: 62 tasks organized into 7 phases

### Parallel Team Strategy

With multiple developers (after Foundational complete):

1. **Team completes Setup + Foundational together** (13 tasks)
2. **Once Foundational done**:
   - **Developer A**: US1 (T014-T026) - Core build workflows
   - **Developer B**: Starts US2 after US1 T023 complete (T027-T035) - Verification
   - **Developer C**: Starts US3 after US1 T023 complete (T036-T045) - Auto-detection
3. **US4 and Polish**: Added sequentially after core functionality proven

---

## Implementation Notes

### Container Build Pattern

All build workflows follow this pattern:

```yaml
steps:
  - uses: actions/checkout@v6

  - name: Install podman
    run: sudo apt-get update && sudo apt-get install -y podman

  - name: Pull container image
    run: podman pull docker.io/ubuntu:rolling

  - name: Run build and package in container
    run: |
      podman run --rm \
        -v ./scripts:/workspace/scripts:ro,z \
        -v ./build:/workspace/build:rw,z \
        -e VERSION=${{ inputs.version }} \
        -e TOOL=${{ inputs.tool }} \
        -e ARCH=${{ inputs.architecture }} \
        -e VARIANT=${{ inputs.variant || 'default' }} \
        docker.io/ubuntu:rolling \
        bash -c "
          /workspace/scripts/container/setup-build-env.sh && \
          /workspace/scripts/build-tool.sh \$TOOL \$ARCH \$VARIANT && \
          /workspace/scripts/package.sh \$TOOL \$ARCH \$VARIANT
        "

  - name: Verify static linking
    run: |
      for binary in build/$TOOL-$ARCH/install/bin/*; do
        ldd "$binary" 2>&1 | grep -q "not a dynamic executable" || exit 1
      done

  - name: Upload artifacts
    uses: actions/upload-artifact@v5
    with:
      name: ${{ inputs.tool }}-${{ inputs.architecture }}
      path: build/${{ inputs.tool }}-*.tar.zst
```

### Critical Success Factors

1. **Containerization**: All builds MUST run inside Ubuntu:rolling containers for reproducibility
2. **Static Linking**: ALL binaries MUST pass `ldd` check showing "not a dynamic executable"
3. **No Partial Releases**: FR-011 - If any architecture build fails, entire release fails
4. **Independent Releases**: FR-003 - Each tool (podman, buildah, skopeo) released independently
5. **Semver Filtering**: FR-009 - Skip pre-release versions (alpha, beta, rc)

### Testing Checkpoints

- **After T013**: Verify containerized build script produces static binary for single component
- **After T026**: Verify end-to-end podman-full build with all 8 components
- **After T035**: Verify checksum and cosign signature validation works
- **After T045**: Verify daily check detects new version and triggers build
- **After T053**: Verify manual trigger rebuilds existing release
- **After T057**: Verify downloads work on Alpine, Ubuntu, CentOS

---

## Notes

- **[P] tasks** = Different files, can run in parallel
- **[Story] label** maps task to specific user story for traceability
- **Containerized approach**: All builds isolated in ephemeral Ubuntu:rolling containers
- **No tests requested**: Focus on build infrastructure implementation, not test suites
- **Commit strategy**: Commit after each task or logical group (e.g., all T014-T016 together)
- **Stop at checkpoints**: Validate each user story independently before proceeding
- **Avoid**: Cross-story dependencies that break independence, modifying same file in parallel tasks
