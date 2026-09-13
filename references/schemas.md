# Output schemas

omp has no structured-output flag for print mode. `agent.sh --engine omp --schema FILE` appends the schema to the prompt
as an output contract and validates the final message after the run: valid JSON is written to
`<run>/agents/<label>/result.json`, and anything else sets `schema_error` in `meta.json` and
exits 65. The model is asked, not forced, so a violation is a real outcome — treat it as a failed
run and re-dispatch with a shorter, flatter schema rather than accepting prose.

Because the engine does not enforce anything, the constraints are about what a model reliably
produces, not about an API's limits:

- keep the object shallow — two or three levels, not ten
- name every field in `required` so a missing field is a violation rather than a default
- prefer `enum` over free text for anything you will branch on
- avoid unions; ask for one shape, and add a `status` field to express the alternatives
- keep it short: a schema longer than the task description invites a truncated answer

## Implementation

A `blocked` result is only usable when `unresolved` states the blocking fact, the commands already tried, and the decision the orchestrator has to make; a bare `blocked` goes back to the worker, not into review. `partial` names what landed and what did not, per file.

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["status", "summary", "files_changed", "commands_run", "regression",
               "not_verified", "unresolved"],
  "properties": {
    "status": {"type": "string", "enum": ["done", "partial", "blocked"]},
    "summary": {"type": "string"},
    "files_changed": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["path", "change"],
        "properties": {
          "path": {"type": "string"},
          "change": {"type": "string"}
        }
      }
    },
    "commands_run": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["command", "exit_code"],
        "properties": {
          "command": {"type": "string"},
          "exit_code": {"type": "integer"}
        }
      }
    },
    "regression": {
      "type": "object",
      "additionalProperties": false,
      "required": ["checked", "callers_reviewed", "full_suite_run"],
      "properties": {
        "checked": {"type": "array", "items": {"type": "string"}},
        "callers_reviewed": {"type": "array", "items": {"type": "string"}},
        "full_suite_run": {"type": "boolean"}
      }
    },
    "not_verified": {"type": "array", "items": {"type": "string"}},
    "unresolved": {"type": "array", "items": {"type": "string"}}
  }
}
```

`regression` keeps the blast-radius check honest and bounded: `checked` lists the tests that
were actually run, `callers_reviewed` the call sites that were read, and `full_suite_run` says
whether the expensive path was taken. A worker that ran the full suite for a one-file change is
burning time; one with an empty `checked` list verified nothing.

`commands_run` is what makes the report checkable: an empty list next to `status: "done"` means
the worker verified nothing, whatever its summary says. `not_verified` is required for the same
reason — a worker that claims complete coverage is either wrong or was not asked a hard enough
question. Re-run the listed commands yourself; their presence is a claim until you do.

`status: "blocked"` with a populated `unresolved` list is a successful outcome: the worker hit
a real contradiction instead of inventing a way around it.

## Findings (audit, bug hunt, review)

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["findings"],
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["file", "line", "severity", "claim", "evidence", "failure_scenario"],
        "properties": {
          "file": {"type": "string"},
          "line": {"type": "integer"},
          "severity": {"type": "string", "enum": ["high", "medium", "low"]},
          "claim": {"type": "string"},
          "evidence": {"type": "string"},
          "failure_scenario": {"type": "string"}
        }
      }
    }
  }
}
```

Requiring `failure_scenario` — concrete input, then wrong output — removes most style
complaints dressed up as bugs. Findings from parallel agents deduplicate on `file` plus
`line`.

## Research and data collection

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["answers", "gaps"],
  "properties": {
    "answers": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["question", "answer", "sources", "confidence"],
        "properties": {
          "question": {"type": "string"},
          "answer": {"type": "string"},
          "sources": {"type": "array", "items": {"type": "string"}},
          "confidence": {"type": "string", "enum": ["verified", "probable", "unverified"]}
        }
      }
    },
    "gaps": {"type": "array", "items": {"type": "string"}}
  }
}
```

Treat `unverified` as unusable until you check it yourself, and spot-check the sources behind
anything marked `verified`: fetch at least two of them and confirm the quoted number, publisher,
and date actually appear there. Fabricated and drifted citations are the normal failure mode of
research agents, and a confident answer with a plausible URL is exactly what they look like.
