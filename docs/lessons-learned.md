# Lessons learned

Captured while bootstrapping `hrliaghati/scotty` as the cohort testbed
(2026-04-27). Each entry exists because a real run failed in a way
that wasn't obvious from docs. Keep adding to this file the next time
someone hits a new gotcha — these debug loops are expensive.

---

## 1. `startup_failure` with empty logs almost always means caller-permission shortfall

**Symptom**: GitHub Actions reports `conclusion: startup_failure`,
`status: completed`, `total_count: 0` check-runs, no logs available.
The web UI says "This run likely failed because of a workflow file
issue."

**Cause**: A reusable workflow's job requested `permissions: { ... }`
that exceeded what the caller's GITHUB_TOKEN was granted. By default,
many cohort repos ship with `default_workflow_permissions: read`. The
called workflow asks for `pull-requests: write` for sticky-comment
jobs, and GitHub silently aborts the whole run before any job starts.

**Fix**: Caller must set `permissions:` on the `ci` job in the shim:

```yaml
jobs:
  ci:
    permissions:
      contents: read
      pull-requests: write
      actions: read         # for download-artifact in coverage-comment
    uses: hrliaghati/ci-workflows/.github/workflows/python-ci.yml@main
    secrets: inherit
    with: { ... }
```

**Rule of thumb**: if `gh run view` shows `startup_failure` with no
job-level logs, run `gh api repos/$OWNER/$REPO/actions/permissions/workflow`
and check `default_workflow_permissions`. If it's `read` and your
called workflow has any `permissions:` block requesting write, that's
the issue.

---

## 2. `astral-sh/setup-uv@v4` with `enable-cache: true` requires a lockfile

**Symptom**: Step fails with
`##[error] No file matched to [**/uv.lock], make sure you have checked out the target repository`.

**Cause**: setup-uv's default cache key globs `**/uv.lock`. Most cohort
repos don't ship a lock (they're development-mode `pyproject.toml`
+ git deps).

**Fix**: explicitly broaden the glob to include `pyproject.toml`:

```yaml
- uses: astral-sh/setup-uv@v4
  with:
    enable-cache: true
    version: 'latest'
    cache-dependency-glob: "**/pyproject.toml\n**/uv.lock"
```

The `\n` is interpreted as a literal newline by YAML's double-quoted
scalar, making this a multi-glob. Either lockfile-lacking or
lockfile-having repos work.

---

## 3. `astral-sh/setup-uv@v4` rejects empty `version: ''`

**Symptom**: `##[error] No version found for ` (literally, with empty
trailing whitespace).

**Cause**: Passing `version: ''` is *different from* not passing
`version:` at all. The action's resolution code can't handle an empty
string and logs the empty version after "No version found for ".

**Fix**: default reusable-workflow inputs to `'latest'`, not `''`:

```yaml
inputs:
  uv-version:
    type: string
    default: 'latest'      # NOT '' — empty string errors at runtime
```

---

## 4. `MishaKav/pytest-coverage-comment` mis-parses standard pytest-cov output

**Symptom**: The action runs successfully (job conclusion:
`success`) but the step logs `##[error] Generating coverage report.
Cannot read properties of null (reading 'missing')` and "Nothing to
report". No PR comment appears.

**Cause**: Even with `--cov-report=term-missing`, the action's parser
chokes on the standard pytest-cov footer ("Coverage HTML written to
dir htmlcov", "Required test coverage of N% reached", etc.). It
silently exits 0, so the job goes green but the comment never lands.

**Fix**: replace MishaKav with a home-grown step that
`grep` + `awk`'s the TOTAL line and posts via
`marocchino/sticky-pull-request-comment@v2` (which we already use for
the wheel sticky). Pattern is in
`.github/workflows/python-ci.yml`'s `coverage-comment` job.

---

## 5. Don't gate `--cov-fail-under` on the slow-test job

**Symptom**: `test-slow` job fails with `Required test coverage of 70%
not reached. Total coverage: 35%`, even though short tests passed
70%+.

**Cause**: `--cov-append` only appends within the same job's working
directory. A separate job (test-slow) doesn't see short-test coverage,
so the slow tests' isolated coverage is what's measured against the
threshold.

**Fix**: gate `--cov-fail-under` *only* on the short-test job. Keep
`--cov-append` on slow tests for completeness if you ever combine
artifacts later, but don't fail-gate.

```yaml
# short tests:
pytest -m "not slow" --cov=... --cov-fail-under=70 ...

# slow tests:
pytest -m slow --cov=... --cov-append ...     # NO --cov-fail-under
```

---

## 6. Reusable-workflow nested calls work cross-repo with `org/repo/path@ref`

**Symptom (avoided here)**: When debugging, I almost replaced the
inner `version-check.yml` reference with `./.github/workflows/version-check.yml`,
which would have broken everything.

**Rule**: A reusable workflow calling another reusable workflow in
the **same repo** must use the fully qualified
`org/repo/.github/workflows/foo.yml@ref` form when that workflow itself
is being called externally. The `./` form resolves against the
**caller's** repo, not the workflow's home repo.

(`./` is fine for "I'm a workflow being run directly in this repo and
calling a sibling reusable workflow." It is **not** fine for a
reusable workflow that's being consumed externally.)

---

## 7. Bisect missing-startup-failure issues by progressively reusing scaled probes

When the run startup-fails with no logs, the only signal is
"workflow YAML doesn't validate." Bisect by:

1. **Probe 0**: a reusable workflow with one job, one step (`echo`),
   one input. Confirm calling chain itself is healthy.
2. **Probe 1**: add concurrency, matrix, nested reusable call (the
   structural pieces).
3. **Probe 2**: add the action you suspect (setup-uv, sticky-comment,
   etc.) one at a time.

Cheaper than commenting jobs out in a 300-line workflow because
each probe is small enough to read top-to-bottom. We did this with
`_probe.yml` → `_lite.yml` → `_lite2.yml` → `_lite3.yml`. Drop the
probes once root cause is identified.

---

## 8. The first CI run on an existing repo will surface ruff format diffs

**Symptom**: `ruff format --check .` fails with "Would reformat: foo.py"
across many files on the first PR.

**Cause**: The codebase has never been ruff-formatted; merging the
new lint gate means committing to consistent formatting. Per-file
formatter drift is normal here.

**Fix**: bundle a `ruff format` pass in the CI setup PR. Acknowledge
in the PR description that the diff is large but mechanical.

This is also why the version-bump gate kicks in on the setup PR:
`*.py` files change, so a patch bump is required.

---

## 9. `gh run download` fails silently when an artifact doesn't exist

**Symptom**: `gh run download <run-id> -n missing-name -D /tmp/x` exits
0 but produces nothing.

**Workaround**: `gh api .../runs/<id>/artifacts --jq '.artifacts[].name'`
to list what's actually there before downloading.

---

## 10. `continue-on-error: ${{ matrix.os == 'X' && inputs.bool }}` works fine

When debugging startup_failure, I suspected this expression. It is
in fact valid: GitHub evaluates it per-matrix-instance, both operands
are accessible, and the resulting boolean is accepted by
`continue-on-error`. Don't waste time here next round.

---

## Open / unresolved items

- **Coverage combination across jobs.** Right now slow-test coverage
  is reported but not combined with short-test coverage in the sticky
  comment. If we want one unified percentage, we need to upload
  per-job `.coverage` files, download all, `coverage combine`, then
  post. Worth doing once we care about the slow-test contribution.
- **MishaKav upstream**. Worth filing an issue on
  `MishaKav/pytest-coverage-comment` once we can reproduce the parse
  failure cleanly. Their action is otherwise good — we'd switch back
  if they fix it.
