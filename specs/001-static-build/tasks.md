# Tasks: Static Container Tools Build System

**Input**: Design documents from `/specs/001-static-build/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md

**Tests**: Smoke tests included as they are integral to verifying static binary functionality.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

```text
.github/workflows/       # GitHub Actions workflows
scripts/                 # Build and utility scripts
build/                   # Build dependencies (mimalloc, patches)
Dockerfile.*             # Fallback build containers
```

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [X] T001 Create project directory structure: scripts/, build/, build/mimalloc/, build/patches/
- [X] T002 Create Makefile with build/test/clean targets at ./Makefile
- [X] T003 [P] Create .gitignore with build artifacts, temporary files at ./.gitignore
- [X] T004 [P] Create README.md with project overview, usage instructions at ./README.md

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core build infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Build Dependencies

- [X] T005 Clone and setup mimalloc source in build/mimalloc/
- [X] T006 Create script to compile mimalloc with ~~Zig~~ **Clang** for musl targets at scripts/build-mimalloc.sh (Updated: Zig→Clang migration)
- [X] T007 [P] Create default config files: build/etc/containers/policy.json
- [X] T008 [P] Create default config files: build/etc/containers/registries.conf

### Core Build Scripts

- [X] T009 Create main build script with ~~Zig~~ **Clang** + Go + CGO setup at scripts/build-tool.sh (Updated: Zig→Clang migration)
- [X] T010 Create packaging script with bin/lib/etc structure at scripts/package.sh
- [X] T011 [P] Create version check script comparing upstream vs local releases at scripts/check-version.sh
- [X] T012 [P] Create signing script with cosign keyless signing at scripts/sign-release.sh

### Fallback Infrastructure

- [X] T013 [P] Create Dockerfile.podman with Alpine musl build environment
- [X] T014 [P] Create Dockerfile.buildah with Alpine musl build environment
- [X] T015 [P] Create Dockerfile.skopeo with Alpine musl build environment

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Download Pre-built Static Binary (Priority: P1) 🎯 MVP

**Goal**: Users can download and run static podman/buildah/skopeo binaries on any Linux distro

**Independent Test**: Download tarball from GitHub Release, extract, run `podman --version` on clean system

### Build Workflows for US1

- [X] T016 [US1] Create GitHub Actions workflow for podman build at .github/workflows/build-podman.yml
- [X] T017 [P] [US1] Create GitHub Actions workflow for buildah build at .github/workflows/build-buildah.yml
- [X] T018 [P] [US1] Create GitHub Actions workflow for skopeo build at .github/workflows/build-skopeo.yml

### Podman-Specific Tasks

- [X] T019 [US1] Add podman full variant build logic (with runtime components) to scripts/build-tool.sh
- [X] T020 [US1] Add podman minimal variant build logic to scripts/build-tool.sh
- [X] T021 [US1] Add runtime component builds (crun, conmon, fuse-overlayfs) to scripts/build-tool.sh
- [X] T022 [US1] Add runtime component builds (netavark, aardvark-dns - Rust) to scripts/build-tool.sh
- [X] T023 [US1] Add runtime component builds (pasta, catatonit) to scripts/build-tool.sh

### Cross-Compilation Setup

- [X] T024 [US1] Add ~~Zig~~ **Clang** cross-compile setup for amd64 target in scripts/build-tool.sh (Updated: Zig→Clang migration)
- [X] T025 [US1] Add ~~Zig~~ **Clang** cross-compile setup for arm64 target in scripts/build-tool.sh (Updated: Zig→Clang migration)
- [X] T026 [US1] Add matrix build strategy (amd64 + arm64) to .github/workflows/build-podman.yml
- [X] T027 [P] [US1] Add matrix build strategy to .github/workflows/build-buildah.yml
- [X] T028 [P] [US1] Add matrix build strategy to .github/workflows/build-skopeo.yml

### Smoke Tests

- [X] T029 [US1] Create smoke test script with ldd check and --version verification at scripts/test-static.sh
- [X] T030 [US1] Add smoke test job to build workflows

**Checkpoint**: At this point, User Story 1 should be fully functional - binaries can be built and downloaded

---

## Phase 4: User Story 2 - Verify Binary Authenticity (Priority: P2)

**Goal**: Users can verify checksums and cosign signatures for all release artifacts

**Independent Test**: Download checksums.txt and .sig files, run sha256sum and cosign verify

### Checksum Generation

- [X] T031 [US2] Add SHA256 checksum generation to scripts/package.sh
- [X] T032 [US2] Add checksums.txt upload to build workflows release job

### Signing Implementation

- [X] T033 [US2] Add cosign-installer step to .github/workflows/build-podman.yml
- [X] T034 [P] [US2] Add cosign-installer step to .github/workflows/build-buildah.yml
- [X] T035 [P] [US2] Add cosign-installer step to .github/workflows/build-skopeo.yml
- [X] T036 [US2] Implement cosign sign-blob with OIDC in scripts/sign-release.sh
- [X] T037 [US2] Add signature upload to release jobs in build workflows

### Verification Documentation

- [X] T038 [US2] Add verification instructions to README.md (sha256sum, cosign verify)

**Checkpoint**: At this point, User Story 2 should work - all releases have verifiable checksums and signatures

---

## Phase 5: User Story 3 - Automatic New Version Detection (Priority: P3)

**Goal**: System automatically detects and builds new upstream releases daily

**Independent Test**: When upstream releases new version, corresponding GitHub Release appears within 24 hours

### Version Check Workflow

- [X] T039 [US3] Create check-releases workflow with daily cron at .github/workflows/check-releases.yml
- [X] T040 [US3] Add podman version check job to check-releases.yml (calls scripts/check-version.sh)
- [X] T041 [P] [US3] Add buildah version check job to check-releases.yml
- [X] T042 [P] [US3] Add skopeo version check job to check-releases.yml

### Trigger Logic

- [X] T043 [US3] Add workflow_call trigger to build-podman.yml for automated triggering
- [X] T044 [P] [US3] Add workflow_call trigger to build-buildah.yml
- [X] T045 [P] [US3] Add workflow_call trigger to build-skopeo.yml
- [X] T046 [US3] Add pre-release filtering (skip alpha/beta/rc) to scripts/check-version.sh
- [X] T047 [US3] Add duplicate release check (skip if release exists) to scripts/check-version.sh

**Checkpoint**: At this point, User Story 3 should work - daily cron detects and triggers builds automatically

---

## Phase 6: User Story 4 - Manual Build Trigger (Priority: P4)

**Goal**: Maintainers can manually trigger builds for specific versions

**Independent Test**: Use workflow_dispatch in GitHub Actions to trigger a build with version parameter

### Manual Trigger Implementation

- [X] T048 [US4] Add workflow_dispatch trigger with version input to .github/workflows/build-podman.yml
- [X] T049 [P] [US4] Add workflow_dispatch trigger to .github/workflows/build-buildah.yml
- [X] T050 [P] [US4] Add workflow_dispatch trigger to .github/workflows/build-skopeo.yml
- [X] T051 [US4] Add release update logic (replace existing assets on rebuild) to build workflows

**Checkpoint**: At this point, User Story 4 should work - manual triggers with version selection work

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T052 [P] Add error handling for GitHub API rate limits to scripts/check-version.sh
- [X] T053 [P] Add retry logic with exponential backoff to build scripts
- [X] T054 [P] Add build failure handling (fail entire release if any arch fails) to workflows
- [X] T055 Update quickstart.md with actual repository URLs after initial setup
- [X] T056 [P] Add CONTRIBUTING.md with development workflow at ./CONTRIBUTING.md
- [X] T057 Run full end-to-end validation per quickstart.md (requires GitHub repository setup)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational - Core MVP
- **User Story 2 (Phase 4)**: Depends on US1 (needs artifacts to sign)
- **User Story 3 (Phase 5)**: Depends on US1 (needs build workflows to trigger)
- **User Story 4 (Phase 6)**: Can parallel with US2/US3 after US1
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Core functionality - MUST complete first
- **User Story 2 (P2)**: Depends on US1 having artifacts to sign
- **User Story 3 (P3)**: Depends on US1 having build workflows to trigger
- **User Story 4 (P4)**: Depends on US1 having build workflows - can parallel with US2/US3

### Within Each Phase

- Scripts before workflows (workflows call scripts)
- Core logic before variant logic
- Single architecture before matrix
- Base functionality before error handling

### Parallel Opportunities

- T003, T004 can run in parallel (different files)
- T007, T008 can run in parallel (different config files)
- T011, T012 can run in parallel (different scripts)
- T013, T014, T015 can run in parallel (different Dockerfiles)
- T017, T018 can run in parallel with T016 (different workflow files)
- T027, T028 can run in parallel (different workflow files)
- T034, T035 can run in parallel (different workflow files)
- T041, T042 can run in parallel (different jobs in same workflow)
- T044, T045 can run in parallel (different workflow files)
- T049, T050 can run in parallel (different workflow files)

---

## Phase 8: Zig to Clang Migration (2025-12-13) ⚠️ CRITICAL UPDATE

**Reason**: Zig compiler incompatibility with multiple C components (see research.md §Zig Issues)

### Migration Tasks

- [X] T058 [Migration] Document Zig issues (pasta `__cpu_model`, fuse-overlayfs meson) in research.md
- [X] T059 [Migration] Test clang + musl methods (Method 1: specs, Method 2: direct paths, Method 3: --target)
- [X] T060 [Migration] Update build-tool.sh to use `clang --target=` instead of `zig cc -target`
- [X] T061 [Migration] Update build-tool.sh dependency check (zig → clang + musl-dev)
- [X] T062 [Migration] Update plan.md Technical Context (compiler: Zig → Clang)
- [X] T063 [Migration] Update plan.md Complexity Tracking (mark Zig as ABANDONED)
- [X] T064 [Migration] Update research.md with comprehensive migration rationale
- [X] T065 [Migration] Update tasks.md to mark Zig-related tasks as updated

### Ongoing Runtime Component Fixes

Based on `/tmp/*.md` test results and analysis:

- [X] T066 [Fix] Fix pasta clone URL (git://passt.top/passt, not GitHub) in build-tool.sh
- [X] T067 [Fix] Add protobuf-compiler dependency check for netavark
- [X] T068 [Fix] Fix netavark/aardvark-dns Rust static linking (use musl target method)
- [ ] T069 [Fix] Fix fuse-overlayfs libfuse install to local prefix (avoid permission issues)
- [X] T070 [Fix] Fix conmon systemd detection (disable USE_JOURNALD)
- [ ] T071 [Fix] Add runc libseccomp dependency check
- [X] T072 [Fix] Add crun libcap dependency check
- [ ] T073 [Doc] Create build-dependencies.md documenting all required packages

### Testing & Validation (First Round - Partial Dependencies)

- [X] T074 [Test] Full podman-full build test in Ubuntu 24.04 container
- [X] T075 [Test] Verify all binaries are static (ldd check)
- [ ] T076 [Test] Cross-compile verification for arm64
- [ ] T077 [Test] Component functionality smoke tests

**Results**: 8/11 components succeeded (73%), 6/6 built components verified static ✅

---

## Phase 9: Final Component Fixes (2025-12-13) 🎯 Target 100%

**Goal**: Achieve 10/10 component success rate (runc + fuse-overlayfs fixes)

**Status**: 8/10 currently working (80% success rate)

### Remaining Issues

**Issue 1: runc** - libseccomp-golang vendored code incompatibility
- Error: `duplicate case (_Ciconst_C_ARCH_M68K)` in seccomp_internal.go
- Cause: runc v1.4.0 vendored libseccomp-golang incompatible with Ubuntu 24.04 libseccomp-dev

**Issue 2: fuse-overlayfs** - libfuse install script permission failure
- Error: `install_helper.sh ... /etc/init.d/` permission denied
- Cause: Meson install script tries to access system directories in container

### Fix Tasks

- [ ] T078 [Fix] Add libseccomp source build function in scripts/build-tool.sh
- [ ] T079 [Fix] Update runc build to use source-built libseccomp
- [ ] T080 [Fix] Modify fuse-overlayfs to skip libfuse install, manually copy files
- [ ] T081 [Fix] Update libfuse build to install to local prefix only

### Testing & Validation (Second Round - Complete Dependencies)

- [ ] T082 [Test] Add libglib2.0-dev, libseccomp-dev, libcap-dev to test script
- [ ] T083 [Test] Full podman-full build with all dependencies in Ubuntu 24.04
- [ ] T084 [Test] Verify 10/10 component success rate
- [ ] T085 [Test] Verify all 10 binaries are static (ldd check)

### Documentation Updates

- [ ] T086 [Doc] Update spec.md FR-001 with actual component success rate
- [ ] T087 [Doc] Update plan.md Runtime Component Build Requirements with libseccomp notes
- [ ] T088 [Doc] Create TROUBLESHOOTING.md with known issues and solutions

---

## Parallel Example: Foundational Phase

```bash
# Launch parallel script creation:
Task: "Create default config files: build/etc/containers/policy.json"
Task: "Create default config files: build/etc/containers/registries.conf"

# Launch parallel Dockerfile creation:
Task: "Create Dockerfile.podman with Alpine musl build environment"
Task: "Create Dockerfile.buildah with Alpine musl build environment"
Task: "Create Dockerfile.skopeo with Alpine musl build environment"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Build one tool, verify static binary works
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test static binaries → First release (MVP!)
3. Add User Story 2 → Checksums + signatures → Secure releases
4. Add User Story 3 → Automated daily checks → Hands-off operation
5. Add User Story 4 → Manual triggers → Full control

### Experimental Validation Points

After Phase 2, validate Zig + mimalloc approach:
1. Build single Go CGO binary with Zig
2. Verify it's truly static (`ldd` shows "not a dynamic executable")
3. If fails, activate fallback Dockerfiles

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Zig cross-compile is experimental - have Dockerfile fallback ready
- Runtime components (crun, conmon, etc.) are only needed for podman-full variant
