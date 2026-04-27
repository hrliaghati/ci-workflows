# Migration guide

Step-by-step for adopting `hrliaghati/ci-workflows` in an existing
cohort repo.

The order assumes the repo already has a working `pyproject.toml` and
either no CI or CI you're replacing.

## 0. Pre-flight

- Run `pytest` locally and note the current pass count and approximate
  coverage, if measurable.
- Check that `pyproject.toml` has a `[project].version` (the gate does
  not yet support `dynamic = ["version"]`).
- For Rust+Python repos, confirm `Cargo.toml` has a `[package].version`
  (or `[workspace.package].version`).

## 1. Open audit + test-allocation issues

Before opening the CI setup PR, file two issues per repo:

### Test allocation

> **Title:** Test allocation for CI markers
>
> **Body:** Checklist of every test (file or function). Three checkboxes
> per test — `[ ] short`, `[ ] slow`, `[ ] quick_e2e candidate`.
> Definition of `quick_e2e`: < 30 s, no network, no external services,
> exercises one happy-path full-stack flow.

The CI setup PR can land with all tests defaulted to short (no marker).
A follow-up PR applies markers per the issue's resolution.

### Repo audit

> **Title:** CI setup audit findings
>
> **Body:** A checklist of issues uncovered while preparing CI.
> Categories:
> - **Dependency source audit** (high priority): cross-repo deps using
>   `path = "..."`, `file:///`, or unpinned `git+https://...`. Fix
>   separately, **not** in the CI setup PR.
> - Missing or broken `pyproject.toml` metadata.
> - Coverage well below threshold (note current %; ratchet plan).
> - Outdated deps blocking newer Python.
> - Orphaned modules / files.
> - Version-string inconsistencies (`pyproject.toml` vs `__version__`).

Both issues should be assigned to the repo owner with an `@` mention.

## 2. CI setup PR

Add `.github/workflows/ci.yml` (the thin shim — see README) and
`.github/dependabot.yml` (copy from this repo).

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: pip
    directory: /
    schedule: { interval: weekly }
    groups:
      python-deps:
        update-types: [minor, patch]
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    groups:
      gha-deps:
        update-types: [minor, patch]

# Add this block only for Rust+Python repos:
#   - package-ecosystem: cargo
#     directory: /
#     schedule: { interval: weekly }
#     groups:
#       cargo-deps:
#         update-types: [minor, patch]
```

In the shim, set `cov-fail-under` per the per-repo plan (TODO comment
explaining the ratchet target).

The setup PR itself must:
- Bump `[project].version` (and `Cargo.toml` version, for Rust+Python)
  by a patch.
- Pass `ruff check` / `ruff format --check`. If the repo has no ruff
  config, add one (`line-length = 100`, `target-version = "py310"`).

The PR will trigger CI; review the resulting run. The first run
typically reveals missing dev deps, ruff format diffs, or test markers
that don't exist yet. Fix in the same PR, push, and re-run.

## 3. Validate gates (testbed only)

Before merging, prove the gates actually fail when expected. Open two
throwaway PRs:

### Throwaway PR 1: coverage failure

- Branch off the setup branch.
- Add a new module with no tests covering it (or lower the threshold
  in a non-shim file just to confirm).
- Confirm CI red-lights with `--cov-fail-under` not met.
- Close without merge.

### Throwaway PR 2: version-check failure

- Branch off `main` (or off the setup branch).
- Make a code change in a non-skip path (e.g. edit a `.py` file).
- **Don't** bump the version.
- Confirm `version-check` job fails.
- Close without merge.

Skip this validation step on subsequent rollouts (scotty alone is the
testbed); the workflow has been proven by then.

## 4. Merge setup PR + apply branch protection

Apply branch protection on `main` per the README's section. Required
status checks must include all the jobs listed there.

```bash
# Pure-Python repo:
gh api -X PUT \
  "repos/hrliaghati/$REPO/branches/main/protection" \
  --input branch-protection-python.json

# Rust+Python repo:
gh api -X PUT \
  "repos/hrliaghati/$REPO/branches/main/protection" \
  --input branch-protection-rust-python.json
```

The two JSON files live in `docs/` of this repo (sample configs).

## 5. Local development unblock

After CI lands, run locally:

- Pure Python: `uv sync --all-extras`
- Rust + Python: `uv venv && uv pip install -e .` (or `maturin develop`
  inside the maturin pyproject directory)

This is the original "set up to be used via uv" task and is independent
of CI/CD.

## 6. Test-allocation follow-up PR (later, not urgent)

Once the test-allocation issue is resolved, open a small PR that adds
the appropriate `pytest.mark.slow` / `pytest.mark.e2e` /
`pytest.mark.quick_e2e` markers and (optionally) reorganizes the test
tree into `tests/{unit,integration,e2e/{quick,...}}`.

The CI job for slow tests will then start exercising the slow set.

## 7. Coverage ratchet (later)

Each repo's shim has a `# TODO` next to `cov-fail-under` documenting
the target. When coverage rises, raise the threshold to within ~5
points of current. Don't ratchet in the same PR that adds tests; do
it as a follow-up so test additions and threshold changes are
separately reviewable.
