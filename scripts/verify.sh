#!/usr/bin/env bash
# Turn a review into evidence. Compares what the agent actually changed against the scope its
# spec declared, runs the acceptance checks, and records every command with its exit code.
# Writes <run>/agents/<label>/verify.json and prints a verdict that no check can be skipped in.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: verify.sh <run-dir> <label> [--repo DIR] [--base REF] [--check "CMD"]...

  --repo DIR    repository or worktree to inspect  (default: the agent's recorded cwd)
  --base REF    compare against this ref instead of the working tree (e.g. main)
  --check CMD   acceptance command, repeatable; run inside --repo
  --not-run CMD record an unavailable or skipped acceptance command without executing it

Acceptance commands may exit 77 to report a scarce resource or skipped run; this is not passed.

Set VERIFY_IGNORE to colon-separated globs to treat more paths as build artifacts.

Records: files changed, files outside the spec's declared Write scope, and every check with
its exit code and output tail. Exit 0 when at least one check ran and all passed, 1 otherwise.
A review with zero checks always fails: reading a diff is not verification.
EOF
}

case "${1:-}" in -h|--help|"") usage; exit 0 ;; esac
RUN=$1; LABEL=${2:-}; shift 2 2>/dev/null || { usage >&2; exit 2; }
[ -n "$LABEL" ] || { usage >&2; exit 2; }

REPO=; BASE=; CHECKS=(); NOT_RUN=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --check) CHECKS+=("$2"); shift 2 ;;
    --not-run) NOT_RUN+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="$RUN/agents/$LABEL"
[ -d "$OUT" ] || { echo "no agent $LABEL in $RUN" >&2; exit 2; }
[ -n "$REPO" ] || REPO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cwd"])' "$OUT/meta.json" 2>/dev/null)
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "cannot determine the repository; pass --repo" >&2; exit 2; }

# The scope half of the gate needs a change inventory, and only git provides one here. Without
# it a verdict of "verified" would mean "no files were examined", which is worse than a failure.
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$REPO is not a git repository: scope verification is impossible, review the files by hand" >&2
  exit 2
fi

collect_changed() {
  { [ -n "$BASE" ] && git -C "$REPO" diff --name-only "$BASE" 2>/dev/null
    git -C "$REPO" diff --name-only HEAD 2>/dev/null
    git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}
CHANGED_BEFORE=$(collect_changed)

RESULTS="$OUT/.checks.jsonl"; : > "$RESULTS"
FAILED=0
for cmd in ${CHECKS+"${CHECKS[@]}"}; do
  echo "== check: $cmd" >&2
  LOG=$(cd "$REPO" && eval "$cmd" 2>&1); CODE=$?
  [ "$CODE" = 0 ] || FAILED=1
  printf '%s' "$LOG" | tail -c 4000 > "$OUT/.check-log"
  CHECK_CMD=$cmd CHECK_CODE=$CODE python3 - "$RESULTS" "$OUT/.check-log" <<'PY'
import json, os, sys
tail = open(sys.argv[2], errors="replace").read()[-1500:]
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"command": os.environ["CHECK_CMD"],
                        "exit_code": int(os.environ["CHECK_CODE"]),
                        "status": "not run" if os.environ["CHECK_CODE"] == "77" else
                                  "passed" if os.environ["CHECK_CODE"] == "0" else "failed",
                        "output_tail": tail}, ensure_ascii=False) + "\n")
PY
  # An unrecorded check is an unverified check, however it exited.
  if [ $? -ne 0 ]; then
    echo "   could not record the result of this check" >&2
    FAILED=1
  fi
  rm -f "$OUT/.check-log"
  echo "   exit=$CODE" >&2
done
for cmd in "${NOT_RUN[@]}"; do
  FAILED=1
  CHECK_CMD="$cmd" python3 - "$RESULTS" <<'PY' || exit 1
import json, os, sys
with open(sys.argv[1], "a") as output:
    output.write(json.dumps({"command": os.environ["CHECK_CMD"], "exit_code": None,
                             "status": "not run", "output_tail": ""}) + "\n")
PY
  echo "   not run: $cmd" >&2
done

# A check can itself write files — a formatter, a generator, a careless test. Those changes are
# real and must face the scope gate too, so the inventory is taken again afterwards.
CHANGED=$( { printf '%s\n' "$CHANGED_BEFORE"; collect_changed; } | sort -u | sed '/^$/d')

CHANGED_LIST=$CHANGED python3 - "$OUT" "$LABEL" "$REPO" "$FAILED" "${#CHECKS[@]}" <<'PY'
import fnmatch, json, os, pathlib, re, sys
out = pathlib.Path(sys.argv[1]); label, repo = sys.argv[2], sys.argv[3]
failed, n_checks = int(sys.argv[4]), int(sys.argv[5])
changed = [p for p in os.environ.get("CHANGED_LIST", "").splitlines() if p.strip()]

# The spec's "Write:" line is the declared scope; anything else the agent touched is a finding.
scope = []
spec = out / "prompt.md"
if spec.exists():
    for line in spec.read_text(errors="replace").splitlines():
        m = re.match(r"\s*Write:\s*(.+)", line)
        if not m:
            continue
        # Quoted or backticked entries keep their spaces; bare entries split on commas and
        # whitespace. Globs are honored rather than compared literally.
        rest = m.group(1)
        for token in re.findall(r'"([^"]+)"|`([^`]+)`|\'([^\']+)\'|([^,\s]+)', rest):
            value = next((v for v in token if v), "").strip().strip("`,")
            if value:
                scope.append(value)

def in_scope(path):
    if not scope:
        return None
    return any(path == s or path.startswith(s.rstrip("/") + "/") or fnmatch.fnmatch(path, s)
               for s in scope)

# Build and cache artifacts are produced by running the tests, not by the agent deciding to
# edit something. Reported separately so nothing is dropped silently.
ARTIFACTS = ("__pycache__/", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/", "node_modules/",
             ".venv/", "target/", "dist/", "build/", ".gradle/", ".tox/", "coverage/")
ARTIFACT_SUFFIX = (".pyc", ".pyo", ".class", ".o", ".so", ".a", ".log", ".coverage")
extra = [g for g in os.environ.get("VERIFY_IGNORE", "").split(":") if g]
def is_artifact(p):
    return (any(part + "/" in p + "/" for part in (a.rstrip("/") for a in ARTIFACTS))
            or p.endswith(ARTIFACT_SUFFIX)
            or any(fnmatch.fnmatch(p, g) for g in extra))

artifacts = [p for p in changed if is_artifact(p)]
changed = [p for p in changed if p not in artifacts]
outside = [p for p in changed if in_scope(p) is False]
checks = []
cf = out / ".checks.jsonl"
if cf.exists():
    checks = [json.loads(l) for l in cf.read_text().splitlines() if l.strip()]
    cf.unlink()

verdict = "verified" if (n_checks and not failed and not outside) else "not-verified"
reasons = []
if not n_checks:
    reasons.append("no acceptance check was run")
if failed:
    reasons.append("an acceptance check failed or was not run")
if outside:
    reasons.append(f"files changed outside the declared Write scope: {outside}")

report = {"label": label, "repo": repo, "declared_write_scope": scope or None,
          "files_changed": changed, "files_outside_scope": outside,
          "build_artifacts_ignored": artifacts,
          "checks": checks, "verdict": verdict, "reasons": reasons}
(out / "verify.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"verdict": verdict, "reasons": reasons, "changed": len(changed),
                  "outside_scope": len(outside), "artifacts_ignored": len(artifacts),
                  "checks_run": n_checks}, ensure_ascii=False))
PY

python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["verdict"]=="verified" else 1)' "$OUT/verify.json"
