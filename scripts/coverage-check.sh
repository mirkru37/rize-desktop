#!/usr/bin/env bash
# RIZ-42: computes total line coverage for the app target(s) from an
# .xcresult bundle produced with -enableCodeCoverage YES, prints a
# human-readable summary, and fails the build if coverage is below
# COVERAGE_THRESHOLD (default 50).
#
# Usage:
#   COVERAGE_THRESHOLD=50 scripts/coverage-check.sh TestResults.xcresult
#
# Outputs (relative to the current working directory):
#   coverage-report.json  - raw `xccov view --report --json` output
#   coverage-report.txt   - human-readable per-file table
#   coverage-summary.txt  - markdown summary (per-target table + totals)
#
# Requires: xcrun (Xcode), python3.

set -euo pipefail

RESULT_BUNDLE="${1:-TestResults.xcresult}"
THRESHOLD="${COVERAGE_THRESHOLD:-50}"
JSON_REPORT="${COVERAGE_JSON_REPORT:-coverage-report.json}"
TEXT_REPORT="${COVERAGE_TEXT_REPORT:-coverage-report.txt}"

# Repo root used to filter the coverage report down to first-party code:
# third-party SPM dependency sources (e.g. GRDB) build under
# DerivedData/SourcePackages, outside this tree, so filtering by path drops
# them automatically. Prefer $GITHUB_WORKSPACE (set by Actions to the repo
# checkout); fall back to git for local runs.
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}"

if [ ! -d "$RESULT_BUNDLE" ]; then
  echo "error: result bundle not found at '$RESULT_BUNDLE'" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found (requires full Xcode, not just Command Line Tools)" >&2
  exit 1
fi

echo "Extracting coverage from $RESULT_BUNDLE ..."

# Human-readable per-file table (unfiltered; the pass/fail decision and the
# per-target table are computed against the JSON report below).
if ! xcrun xccov view --report "$RESULT_BUNDLE" >"$TEXT_REPORT"; then
  echo "error: failed to generate text coverage report" >&2
  exit 1
fi

# Machine-readable report used for the actual threshold computation.
if ! xcrun xccov view --report --json "$RESULT_BUNDLE" >"$JSON_REPORT"; then
  echo "error: failed to generate JSON coverage report" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found" >&2
  exit 1
fi

python3 - "$JSON_REPORT" "$THRESHOLD" "$REPO_ROOT" <<'PYEOF'
import json
import os
import sys

json_path, threshold_str, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    threshold = float(threshold_str)
except ValueError:
    print(f"error: invalid COVERAGE_THRESHOLD '{threshold_str}'", file=sys.stderr)
    sys.exit(1)

with open(json_path) as f:
    data = json.load(f)

targets = data.get("targets", [])
if not targets:
    print("error: no targets found in coverage report", file=sys.stderr)
    sys.exit(1)


def is_test_target(name: str) -> bool:
    # Suffix-only match: xccov reports test bundle targets with a trailing
    # ".xctest" product suffix. Do not substring-match "test" anywhere in
    # the name, that would also exclude legitimate app-target names.
    return name.endswith(".xctest")


# Only measure first-party code: files that live under this repo checkout.
# Third-party SPM dependencies (e.g. GRDB) are built into
# DerivedData/SourcePackages, outside the repo root, so path-filtering
# drops them (and any future dependency) without hardcoding target/dep
# names. This never touches which *targets* run, only which files within
# an app target count toward the coverage total.
repo_root_real = os.path.realpath(repo_root)


def is_first_party(path: str) -> bool:
    if not path:
        return False
    real_path = os.path.realpath(path)
    return real_path == repo_root_real or real_path.startswith(repo_root_real + os.sep)


app_targets = [t for t in targets if not is_test_target(t.get("name", ""))]
if not app_targets:
    print("error: no non-test targets found in coverage report", file=sys.stderr)
    sys.exit(1)

total_executable = 0
total_covered = 0
files = []
target_rows = []

for target in app_targets:
    target_files = [f for f in target.get("files", []) if is_first_party(f.get("path", ""))]
    if not target_files:
        # Third-party dependency target (or a target with no first-party
        # files instrumented) - excluded entirely from the measurement.
        continue

    target_executable = 0
    target_covered = 0
    for f in target_files:
        executable = f.get("executableLines", 0)
        covered = f.get("coveredLines", 0)
        target_executable += executable
        target_covered += covered
        files.append(
            {
                "name": f.get("name", "?"),
                "path": f.get("path", "?"),
                "coverage": (covered / executable * 100) if executable else 0.0,
                "executableLines": executable,
            }
        )
    total_executable += target_executable
    total_covered += target_covered
    target_pct = (target_covered / target_executable * 100) if target_executable else 0.0
    target_rows.append(
        {
            "name": target.get("name", "?"),
            "covered": target_covered,
            "executable": target_executable,
            "pct": target_pct,
        }
    )

if total_executable == 0:
    print("error: no executable lines found in any first-party app target", file=sys.stderr)
    sys.exit(1)

total_pct = total_covered / total_executable * 100

files_with_lines = [f for f in files if f["executableLines"] > 0]
least_covered = sorted(files_with_lines, key=lambda f: f["coverage"])[:10]

summary_lines = []
summary_lines.append("## Coverage report (RizeDesktop)")
summary_lines.append("")
summary_lines.append("| Target | Covered | Executable | % |")
summary_lines.append("|---|---:|---:|---:|")
for row in target_rows:
    summary_lines.append(
        f"| {row['name']} | {row['covered']} | {row['executable']} | {row['pct']:.2f}% |"
    )
summary_lines.append(f"| **Total** | **{total_covered}** | **{total_executable}** | **{total_pct:.2f}%** |")
summary_lines.append("")
summary_lines.append(f"Threshold: {threshold:.2f}%")
summary_lines.append("")
summary_lines.append("Least-covered files:")
for f in least_covered:
    summary_lines.append(f"  {f['coverage']:6.2f}%  {f['path']} ({f['executableLines']} lines)")

summary = "\n".join(summary_lines)
print(summary)

# Also write a small machine-parseable summary for CI steps that want to
# embed these numbers without re-parsing the full JSON report.
with open("coverage-summary.txt", "w") as f:
    f.write(summary + "\n")

if total_pct + 1e-9 < threshold:
    print(f"\nFAIL: coverage {total_pct:.2f}% is below threshold {threshold:.2f}%", file=sys.stderr)
    sys.exit(1)

print(f"\nPASS: coverage {total_pct:.2f}% meets threshold {threshold:.2f}%")
PYEOF
