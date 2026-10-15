#!/usr/bin/env python3
"""Expand @@VAR@@ placeholders in a rendered overlay file from the environment.

Why the @@VAR@@ values are not in the rendered output: render.py runs at
IMAGE BUILD time; the values that vary per deployment (Discord channel
ids, the Honcho peer id, a package's own deployment ids) are RUNTIME data
— they live in the host env file ($HERMES_ENV_DIR/hermes-main.env, for
stack-owned names) or in a profile package's own
profiles.d/<package>/package.env (loaded into the boot environment by the
entrypoint for package-owned names) — never in git.

WHY `@@VAR@@` AND NOT `${VAR}`: Hermes' own config.yaml uses `${...}` for
runtime secrets (e.g. `api_key: ${LITELLM_API_KEY}`) and resolves those itself
at startup. Expanding those here would inline secrets into config.yaml. The
`@@...@@` form is reserved for this expander and cannot collide.

An unset placeholder expands to the EMPTY STRING and is reported on stderr, so
the boot log says exactly which variable is missing. For a channel ID that
means the bot is fenced out of every channel — safe by default, and loud.

Usage:  expand-placeholders.py <file> [<file> ...]
"""

import os
import re
import sys

PLACEHOLDER = re.compile(r"@@([A-Z][A-Z0-9_]*)@@")


def expand(path: str) -> int:
    """Rewrite path in place. Returns the number of placeholders found.

    Returns -1 if the file could not be read/written (caller treats as fatal).
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return -1
    except OSError as exc:
        print(f"expand-placeholders: cannot read {path}: {exc}", file=sys.stderr)
        return -1

    found = PLACEHOLDER.findall(text)
    if not found:
        return 0

    missing = []
    for name in dict.fromkeys(found):
        if name not in os.environ:
            missing.append(name)
    if missing:
        print(
            f"expand-placeholders: WARNING {path}: unset "
            f"{', '.join(missing)} — expanded to empty. Set them in "
            f"$HERMES_ENV_DIR/hermes-main.env (stack-owned values) or in "
            f"the profile package's own profiles.d/<package>/package.env "
            f"(package-owned values).",
            file=sys.stderr,
        )

    text = PLACEHOLDER.sub(lambda m: os.environ.get(m.group(1), ""), text)

    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as exc:
        print(f"expand-placeholders: cannot write {path}: {exc}", file=sys.stderr)
        return -1
    return len(found)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    total = 0
    for path in argv[1:]:
        n = expand(path)
        if n < 0:
            return 1
        total += n
    if total:
        print(f"expand-placeholders: expanded {total} placeholder(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
