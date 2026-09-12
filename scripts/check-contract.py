#!/usr/bin/env python3
"""Check entry documents, one engine page, or the shared prompt template.

Exit codes: 0 all assertions hold, 1 the contract is broken, 2 the check could not run.
"""
import re
import sys
from pathlib import Path

TIERS = ["cheap", "standard", "deep", "frontier", "max"]
EFFORT = {"cheap": "low", "standard": "medium", "deep": "high",
          "frontier": "xhigh", "max": "max"}
TIMEOUT = {"cheap": "300–600", "standard": "900–1800", "deep": "1800–3600",
           "frontier": "3600–5400", "max": "3600–5400"}

# Each engine's own boundary sentence and its own profile names. Editing this is editing
# the contract, which is the point; it is not a way around the check.
ENGINES = {
    "omp": {
        "boundary": "`read-only` grants no `bash`",
        "profiles": ["read-only", "workspace-write", "full", "bypass"],
        "readme": {
            "README.md": "These profile names are omp's own.",
            "README.zh-TW.md": "這些設定檔名稱是 omp 自己的。",
        },
    },
    "codex": {
        "boundary": "`read-only` sandbox runs any command while the kernel blocks writes",
        "profiles": ["read-only", "workspace-write", "danger-full-access"],
        "readme": {
            "README.md": "the name does not carry to the siblings",
            "README.zh-TW.md": "這個名稱不能沿用到姊妹引擎",
        },
    },
    "opencode": {
        "boundary": "`read-only` is plan mode and runs no commands",
        "profiles": ["read-only", "inspect", "workspace-write", "full", "bypass"],
        "readme": {
            "README.md": "These profile names are opencode's own.",
            "README.zh-TW.md": "這些設定檔名稱是 opencode 自己的。",
        },
    },
}
INTEGRATED_ENGINES = ("omp", "codex", "opencode")
SKILL_NAME = "dispatch"

# The evidence rules a read-only worker is given. They are the same on all three engines and
# have already drifted once: a rule was added to one sibling's template and the other two kept
# the shorter list for a commit. Each repository asserts the whole list locally rather than
# comparing against a sibling, which is the same reason CI checks out nothing else.
EVIDENCE_RULES = [
    "Every claim carries a source",
    'Report "not found" rather than inferring',
    "Separate what the source states from what you conclude from it",
    "Report which document is wrong, not that they disagree",
    "A number is a claim",
]

CELL = re.compile(r"`([^`]+)`")


def flat(text):
    """Where a line wraps must not decide whether a sentence is present."""
    return re.sub(r"\s+", " ", text)


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    return text[4:end]


def name_of(fm):
    for line in fm.split("\n"):
        if line.startswith("name:"):
            return line[len("name:"):].strip() or None
    return None


def description_of(fm):
    out, taking = [], False
    for line in fm.split("\n"):
        if line.startswith("description:"):
            taking = True
            out.append(line[len("description:"):].strip())
        elif taking and line[:1] in (" ", "\t"):
            out.append(line.strip())
        elif taking:
            break
    value = " ".join(out)
    return value if value else None


def projections(text):
    """Read tier -> effort and effort -> timeout from any table, then compose.

    Codex splits the two halves across adjacent tables and keys the second by effort;
    omp and opencode keep both in one. Reading by meaning rather than by table shape is
    what lets one check serve all three.
    """
    tier_effort, effort_timeout, tier_timeout = {}, {}, {}
    for line in text.split("\n"):
        if not line.lstrip().startswith("|"):
            continue
        cs = cells(line)
        found = [t for c in cs for t in CELL.findall(c)]
        tier = next((t for t in found if t in TIERS), None)
        effort = next((t for t in found if t in set(EFFORT.values())), None)
        # A cell may carry a note: codex writes `900–1800 (default 1800)`. The contract is
        # the range, not whatever is written after it.
        timeout = next((m.group(1) for m in
                        (re.match(r"(\d+(?:–\d+|\+))(?:\s|$)", c) for c in cs) if m), None)
        if tier and effort:
            tier_effort[tier] = effort
        if effort and timeout:
            effort_timeout[effort] = timeout
        if tier and timeout:
            tier_timeout[tier] = timeout
    return tier_effort, effort_timeout, tier_timeout


def read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        print("cannot read %s: %s" % (path, exc), file=sys.stderr)
        return None


def report_findings(path, bad):
    if not bad:
        return False
    for line in bad:
        print("%s: %s" % (path, line))
    return True


def check_entry(skill_path, readme_path, readme_zh_path):
    skill = read_text(skill_path)
    readmes = [read_text(readme_path), read_text(readme_zh_path)]
    if skill is None or any(body is None for body in readmes):
        return 2

    bad = []
    fm = frontmatter(skill)
    if fm is None:
        bad.append("no YAML frontmatter, so there is no name or description to read")
    else:
        if name_of(fm) is None:
            bad.append("frontmatter has no name")
        elif name_of(fm) != SKILL_NAME:
            bad.append("frontmatter name is `%s`; the contract is `%s`" %
                       (name_of(fm), SKILL_NAME))
        desc = description_of(fm)
        if desc is None:
            bad.append("frontmatter has no description")
        else:
            for engine in INTEGRATED_ENGINES:
                boundary = ENGINES[engine]["boundary"]
                if boundary not in flat(desc):
                    bad.append("description does not state %s's read-only execution boundary; "
                               "missing: %s" % (engine, boundary))

    for engine in INTEGRATED_ENGINES:
        for index, path in enumerate((readme_path, readme_zh_path)):
            key = path.name
            needle = ENGINES[engine]["readme"][key]
            if needle not in flat(readmes[index]):
                bad.append("%s does not state %s's cross-engine profile boundary; missing: %s" %
                           (path, engine, needle))
    if report_findings(skill_path, bad):
        return 1
    print("%s: contract intact — name `%s`, %d engine boundaries, %d README notes" %
          (skill_path, SKILL_NAME, len(INTEGRATED_ENGINES),
           len(INTEGRATED_ENGINES) * len(readmes)))
    return 0


def check_engine(engine, path):
    if engine not in ENGINES:
        print("unknown engine: %s" % engine, file=sys.stderr)
        return 2
    text = read_text(path)
    if text is None:
        return 2
    spec = ENGINES[engine]
    bad = []

    tier_effort, effort_timeout, tier_timeout = projections(text)
    for tier in TIERS:
        want_e = EFFORT[tier]
        got_e = tier_effort.get(tier)
        if got_e is None:
            bad.append("the tier table has no `%s` row" % tier)
            continue
        if got_e != want_e:
            bad.append("`%s` maps to `%s`; the contract is `%s`" % (tier, got_e, want_e))
        got_t = tier_timeout.get(tier) or effort_timeout.get(got_e)
        if got_t is None:
            bad.append("`%s` has no timeout, neither directly nor through `%s`"
                       % (tier, got_e))
        elif got_t != TIMEOUT[tier]:
            bad.append("`%s` allows %s; the contract is %s" % (tier, got_t, TIMEOUT[tier]))

    # A profile cell may carry a note too: opencode writes `inspect` (default).
    listed = set()
    for line in text.split("\n"):
        if not line.lstrip().startswith("|"):
            continue
        m = CELL.match(cells(line)[0])
        if m:
            listed.add(m.group(1))
    for profile in spec["profiles"]:
        if profile not in listed:
            bad.append("the access table has no `%s` row" % profile)

    if report_findings(path, bad):
        return 1
    print("%s: contract intact — %d tiers, %d access profiles" %
          (path, len(TIERS), len(spec["profiles"])))
    return 0


def check_template(path):
    body = read_text(path)
    if body is None:
        return 2
    template = flat(body)
    bad = []
    for rule in EVIDENCE_RULES:
        if rule not in template:
            bad.append("prompt template is missing an evidence rule: %s" % rule)
    if report_findings(path, bad):
        return 1
    print("%s: contract intact — %d evidence rules" % (path, len(EVIDENCE_RULES)))
    return 0


def usage():
    print("usage: check-contract.py entry <SKILL.md> <README.md> <README.zh-TW.md>\n"
          "       check-contract.py engine <engine> <references/engines/<engine>.md>\n"
          "       check-contract.py template <references/prompt-template.md>", file=sys.stderr)
    return 2


def main():
    if len(sys.argv) < 2:
        return usage()
    mode = sys.argv[1]
    if mode == "entry" and len(sys.argv) == 5:
        return check_entry(*(Path(value) for value in sys.argv[2:]))
    if mode == "engine" and len(sys.argv) == 4:
        return check_engine(sys.argv[2], Path(sys.argv[3]))
    if mode == "template" and len(sys.argv) == 3:
        return check_template(Path(sys.argv[2]))
    return usage()


if __name__ == "__main__":
    sys.exit(main())
