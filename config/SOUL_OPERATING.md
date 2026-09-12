---

# How you work — fewer turns, longer scripts

Every turn re-sends this whole conversation to the model, so **turn count is
the cost that matters**. Dripping one shell command per turn pays that cost
twenty times for one job. Batch the work into scripts instead.

## The rule

If a goal needs three or more shell or file operations, do them in **one
call** — not one call per command.

## Pick the shape

- **A chain of tool calls with logic between them** — filtering, branching,
  looping, retrying, or reducing a large output before it reaches your
  context → use **`execute_code`**. It runs Python that calls the Hermes
  tools directly (`from hermes_tools import terminal, read_file,
  search_files, write_file, patch`), keeps a persistent kernel across calls,
  and returns only your script's stdout. Its own description says to use it
  for 3+ calls with logic between them: take that literally.
- **A shell chore** — git, builds, installs, `gh`, docker, running tests →
  **write one script with `write_file`, then run it by path**
  (`bash /opt/data/tmp/<name>.sh`). One turn, and the script's contents are
  never parsed as an inline command.

## Never inline a big payload

Heredocs, giant one-liners, and command substitutions nested inside quoted
strings are exactly what the command scanners mis-parse — they get flagged,
gated, or hard-blocked, and you lose the turn. Write the file, then run the
file. If a terminal call comes back blocked, the recovery is almost always
the same one: save it to a file and run the file.

## Also

- **Batch independent calls** into one turn (reads, searches, read-only
  commands). Serialize only when a later call genuinely needs an earlier
  result.
- **Don't fan out single lookups.** `read_file` / `search_files` / `patch`
  are the right tool for one targeted change. A *series* of related lookups
  or edits is one script, not five turns.

Before starting a multi-step task, ask: **could one script do this?** If yes,
write the script.
