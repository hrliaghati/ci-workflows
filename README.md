# ci-workflows

Reusable GitHub Actions workflows for the `hrliaghati/*` cohort of
private Python and Rust+Python repos.

This repo is **public** so that private cohort repos can reference its
workflows without per-repo access toggles. The workflow YAML itself is
not sensitive; the consuming repos (and their secrets) remain private.

---

## What's in here

| Workflow | Use it for |
| --- | --- |
| `.github/workflows/python-ci.yml` | Pure-Python repos. Builds the wheel via `uv build`, runs short + slow tests, surfaces wheel + coverage on the PR. |
| `.github/workflows/rust-python-ci.yml` | PyO3 + maturin repos. Builds wheels (abi3 or per-CPython), runs Rust tests with `cargo-llvm-cov`, runs Python tests against the freshly built wheel. |
| `.github/workflows/version-check.yml` | Version-bump gate. Called by both reusable workflows above. Can also be called directly. |

All three are reusable workflows (`on: workflow_call`). Consumers add a
**thin shim** at `.github/workflows/ci.yml` that delegates to the
appropriate reusable workflow with a few inputs filled in.

---

## How to consume (cohort repo)

### Pure Python repo

`.github/workflows/ci.yml`:

```yaml
name: ci
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  ci:
    # Required: caller must grant the permissions the called workflow needs.
    # If you skip this, the run will fail with `startup_failure` because the
    # caller's default token (read-only on most repos) can't grant
    # pull-requests:write to the sticky-comment jobs.
    permissions:
      contents: read
      pull-requests: write
      actions: read
    uses: hrliaghati/ci-workflows/.github/workflows/python-ci.yml@main
    secrets: inherit
    with:
      package-name: scotty                     # [project].name in pyproject.toml
      package-path: beam_search                # what to pass to --cov=
      cov-fail-under: 70                       # TODO: ratchet up over time
      mypy-path: beam_search                   # set "" to skip mypy
```

### Rust + Python repo (abi3, default)

```yaml
jobs:
  ci:
    permissions:
      contents: read
      pull-requests: write
      actions: read
    uses: hrliaghati/ci-workflows/.github/workflows/rust-python-ci.yml@main
    secrets: inherit
    with:
      package-name: routelib
      package-path: routelib
      manifest-dir: routelib-py                # where the maturin pyproject lives
      abi3: true
      cov-fail-under: 60                       # TODO: ratchet
      cargo-fail-under-lines: 60               # TODO: ratchet
```

### Rust + Python repo (per-CPython, e.g. orbprop)

```yaml
jobs:
  ci:
    permissions:
      contents: read
      pull-requests: write
      actions: read
    uses: hrliaghati/ci-workflows/.github/workflows/rust-python-ci.yml@main
    secrets: inherit
    with:
      package-name: orbprop
      package-path: orbprop
      manifest-dir: orbprop-py
      abi3: false                              # numpy C API forces per-CPython
      cov-fail-under: 60
      cargo-fail-under-lines: 60
```

### terrain-model: Windows allowed to fail

```yaml
jobs:
  ci:
    permissions:
      contents: read
      pull-requests: write
      actions: read
    uses: hrliaghati/ci-workflows/.github/workflows/python-ci.yml@main
    secrets: inherit
    with:
      package-name: terrain-model
      package-path: terrain_model
      cov-fail-under: 60
      windows-allow-fail: true                 # tracking issue: <link>
```

---

## Cross-repo dependency pattern (canonical)

When `repo A` in this cohort depends on `repo B` in this cohort,
**always use the GitHub HTTPS git source pinned to a tag or SHA.**

### Python (pyproject.toml `[project] dependencies`)

```toml
dependencies = [
    "routelib @ git+https://github.com/hrliaghati/routelib.git@v0.2.0",
]
```

For a development branch (rare, prefer tags):

```toml
"routelib @ git+https://github.com/hrliaghati/routelib.git@<sha>",
```

### Rust (Cargo.toml `[dependencies]`)

```toml
routelib-core = { git = "https://github.com/hrliaghati/routelib", tag = "v0.2.0" }
```

### **Not acceptable** for cross-repo deps

- `path = "../routelib"` or `file:///Users/.../routelib`
- `git+https://...` with no tag/sha/branch (pulls `main` indefinitely)
- A fork or personal-account variant instead of the canonical
  `hrliaghati/<repo>` repo

These slip in during local development. They work for the original
developer and silently break for everyone else and CI.

> Workspace-internal Rust crates (e.g. `routelib-py` depending on
> `routelib-core` inside the same repo) **are** allowed to use
> `path = ...` because that is intra-repo, not cross-repo.

---

## Permissions setup (one-time per consumer repo)

Reusable workflows in a **public** repo can be called from any private
repo of the same owner with no extra setup. This repo is intentionally
public.

**Required**: each consumer's shim must set `permissions:` on the `ci`
job (see snippets above). Without it, the run fails with
`startup_failure` because the caller's default GITHUB_TOKEN (typically
read-only) cannot grant `pull-requests: write` to the sticky-comment
jobs.

Optional (alternative): set the repo default to "Read and write" in
`Settings → Actions → General → Workflow permissions`. Per-job
permissions are still safer (least privilege) and recommended.

---

## Inputs (full reference)

### `python-ci.yml`

| Input | Type | Default | Notes |
| --- | --- | --- | --- |
| `package-name` | string | **required** | `[project].name` |
| `package-path` | string | **required** | What `--cov=` gets. Dir or file. |
| `python-versions` | JSON array | `["3.10","3.11","3.12","3.13","3.14"]` | Linux + Windows short-test matrix |
| `slow-test-versions` | JSON array | `["3.10","3.14"]` | Slow tests: Linux + Windows only |
| `macos-short-test-version` | string | `"3.12"` | Single canary version on macOS |
| `cov-fail-under` | number | `80` | TODO comment in shim: ratchet plan |
| `mypy-path` | string | `""` | Empty disables mypy |
| `windows-allow-fail` | bool | `false` | `continue-on-error` on Windows test jobs |
| `version-files` | JSON array | `["pyproject.toml"]` | Files compared against `main` for version bump |
| `version-skip-paths-regex` | string | docs/CI/.md skip pattern | If every changed file matches, gate skips |
| `uv-version` | string | `""` | Pin uv (empty = latest) |

### `rust-python-ci.yml`

All `python-ci.yml` inputs **plus**:

| Input | Type | Default | Notes |
| --- | --- | --- | --- |
| `manifest-dir` | string | `"."` | Dir containing maturin `pyproject.toml` |
| `abi3` | bool | `true` | `false` for per-CPython (numpy C API etc.) |
| `cargo-fail-under-lines` | number | `80` | `cargo-llvm-cov --fail-under-lines` |
| `version-files` (default) | — | `["pyproject.toml","Cargo.toml"]` | Both checked |

### `version-check.yml`

| Input | Type | Default | Notes |
| --- | --- | --- | --- |
| `version-files` | JSON array | `["pyproject.toml"]` | |
| `base-ref` | string | PR base | Override only when calling outside a PR context |
| `skip-paths-regex` | string | docs/CI/.md pattern | All-skip means gate is bypassed |

---

## Branch protection (apply once per cohort repo, after first PR lands)

Required status checks:

- **Pure Python**: `lint`, `version-check`, `build`, `test-short-linux-windows`, `test-short-macos`, `test-slow`
- **Rust + Python**: `lint-py`, `rust`, `version-check`, `build`, `test-short-linux-windows`, `test-short-macos`, `test-slow`

Plus:
- ✅ Require PRs (no direct pushes)
- ✅ No force-pushes
- ✅ Dismiss stale approvals on new commits
- ✅ Require conversation resolution
- ✅ At least 1 approving review
- ✅ Require all status checks to pass

---

## Future, intentionally not implemented yet

- **Self-hosted Mac mini runners for orbprop** — per-CPython × 5 ×
  macOS (×10 wall-clock multiplier) is the single biggest CI cost. A
  self-hosted M-series runner would amortize this. Track in
  `hrliaghati/ci-workflows#1` once we have data on actual cost.
- **Cross-repo local-path enforcement** — once the
  dependency-source audit (per-repo issue) is closed and all repos
  use git+https pins, add a CI check that scans
  `pyproject.toml` / `Cargo.toml` / lockfiles for any `path = "..."`
  or `file:///` references to cohort repos and fails the build.
  Track as a follow-up issue here.

---

## Migration

See [`docs/migration-guide.md`](docs/migration-guide.md).
