#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/glasses-pipeline.XXXXXX")"
trap 'rm -rf "$check_build_dir"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -warnings-as-errors -parse-as-library \
  -module-cache-path "$check_build_dir/module-cache" \
  "$repo_root/samples/CameraAccess/CameraAccess/Solver/SolverModels.swift" \
  "$repo_root/samples/CameraAccess/CameraAccess/Solver/BatchSolver.swift" \
  "$repo_root/tests/portable/ClaudePipelineChecks.swift" \
  -o "$check_build_dir/claude-pipeline-checks"
"$check_build_dir/claude-pipeline-checks"
