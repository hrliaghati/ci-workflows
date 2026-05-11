#!/usr/bin/env bash
# Canonical wheel-builder driver for equiped-code repos.
#
# Runs inside wheel-builder:latest, with the caller's repo bind-mounted
# at /io. Produces wheels into /io/dist.
#
# Reads:
#   $ABI3            "true"|"false"
#   $PYTHON_VERSIONS JSON array of versions (only used when ABI3=false)
#   $MANIFEST_DIR    Path inside /io to the maturin pyproject (default ".")
#
# wheel-builder layout this script depends on:
#   /opt/python/cp3XX-cp3XX/bin/python  for each X (3.10..3.14)
#   /pyo3-cross/{x86_64,aarch64}/cp3XX/python/libs/  Windows sysroots per ABI
#   maturin (incl. --zig flag), xwin available on PATH.

set -euo pipefail

ABI3=${ABI3:-true}
PYTHON_VERSIONS=${PYTHON_VERSIONS:-'["3.11"]'}
MANIFEST_DIR=${MANIFEST_DIR:-.}

cd "/io/$MANIFEST_DIR"
mkdir -p /io/dist

# Each maturin invocation gets its own CARGO_TARGET_DIR. Sharing a
# single target/ across cross-compile slices can leave pyo3-build-config
# state stale enough to fail the next slice (seen with numpy's build
# script panicking on an empty config file).
TGT=/io/target/build-all

build_slice() {
  # build_slice <target-triple> <pyo3-cross-lib-dir-or-empty> <pyo3-cross-py-or-empty> <interpreter-or-empty> <extra-flags>
  local target=$1 lib_dir=$2 py_version=$3 interpreter=$4 extra=$5
  local sub
  sub=$(echo "$target" | tr / -)
  echo "::group::Build $target"
  (
    export CARGO_TARGET_DIR="$TGT/$sub"
    [ -n "$lib_dir" ]       && export PYO3_CROSS_LIB_DIR="$lib_dir"
    [ -n "$py_version" ]    && export PYO3_CROSS_PYTHON_VERSION="$py_version"
    if [ -n "$interpreter" ]; then
      # shellcheck disable=SC2086
      maturin build --release $extra --target "$target" --interpreter "$interpreter" --out /io/dist
    else
      # shellcheck disable=SC2086
      maturin build --release $extra --target "$target" --out /io/dist
    fi
  )
  echo "::endgroup::"
}

build_one_python() {
  # build_one_python <python-version like "3.11">
  local ver=$1
  local tag="cp$(echo "$ver" | tr -d .)"
  local PYTHON="/opt/python/${tag}-${tag}/bin/python"

  if [ ! -x "$PYTHON" ]; then
    echo "::warning::No Python $ver in image at $PYTHON — skipping this version" >&2
    return 0
  fi

  build_slice x86_64-unknown-linux-gnu  ""                                          ""    "$PYTHON" "--zig"
  build_slice aarch64-unknown-linux-gnu ""                                          ""    "$PYTHON" "--zig"
  build_slice x86_64-pc-windows-msvc    "/pyo3-cross/x86_64/${tag}/python/libs"     "$ver" ""        ""
  build_slice aarch64-pc-windows-msvc   "/pyo3-cross/aarch64/${tag}/python/libs"    "$ver" ""        ""
  build_slice universal2-apple-darwin   ""                                          ""    "$PYTHON" "--zig"
}

if [ "$ABI3" = "true" ]; then
  # abi3: one build pass against the abi3 base interpreter (cp311).
  # The same wheel is binary-compatible with all Python versions ≥ the
  # abi3 floor (set by the consumer's Cargo.toml feature, e.g. abi3-py310).
  build_one_python 3.11
else
  # Non-abi3: build per Python version in PYTHON_VERSIONS.
  # Parse the JSON array via python3 (the image has it on PATH).
  versions=$(python3 -c 'import json,os; print(" ".join(json.loads(os.environ["PYTHON_VERSIONS"])))')
  for ver in $versions; do
    build_one_python "$ver"
  done
fi

echo
echo "Built wheels:"
ls -la /io/dist/
