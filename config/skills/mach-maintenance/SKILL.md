---
name: mach-maintenance
description: "Handoff notes for Hermes profiles continuing work on the mach repo (github.com/<owner>/mach) — architecture, invariants, gaps to close, and how to verify"
version: 1.0.0
metadata:
  hermes:
    tags: [mach, handoff, security, golang]
    category: devops
---

# mach — handoff for the next profile

You are continuing work on **`mach`** (`github.com/<owner>/mach`, private,
branch `main`). It is finished and green as of commit `710a6cc`: a
remote-CLI fleet tool where every target machine makes only OUTBOUND
connections. Read `AGENTS.md` and `SECURITY-NOTES.md` in that repo
before touching code — they carry the hard invariants (do not regress
them) and the deployment model. This skill is the "what to do next"
companion to those files.

## Architecture in one paragraph

Three roles, one repo. `machd`-style agent + console merged into the
single `mach` binary (`cmd/mach`): on a fresh target, bare `mach`
prompts for the control-plane URL, enrolls via QR (challenge code typed
blind on the phone), then holds the live outbound WebSocket. On an admin
box it prints the fleet table. `mach-server` (`cmd/mach-server`) is the
control plane — the ONLY public component — broker, pairing, audit
(SQLite default, Postgres optional), phone approve page, admin
subcommands (`add-api-key`, `revoke-machine`, `push-update`). Wire
contract in `internal/protocol`; crypto helpers in `internal/e2e`;
DB in `internal/store` (SQLite via modernc, Postgres via pgx/stdlib —
driver chosen by `MACH_DB` DSN prefix).

## How to verify (do this after every change)

```
mise run lint     # go vet
mise run test     # go test ./... -race -cover
mise run e2e      # scripts/e2e.sh — 25 checks, spins up loopback server+agents
```
Go toolchain: if the host has none, a user-space one works fine
(`/opt/data/tools/go/bin` on the hermes-main box). e2e needs nothing but
loopback + bash + curl + jq. Green = 25/25 with the summary line
`e2e: 25 passed, 0 failed`.

## Security invariants (from AGENTS.md — repeated because they get violated easily)

1. Agents never listen inbound. Only the control plane is public.
2. Agent hello signs `name|challenge` — challenge is per-connection
   (server's hello `ReqID`), so captured hellos are useless (replay-proof).
3. The server has a persisted ed25519 identity key; agents PIN its public
   half at enrollment (`server_key` in config.json) and verify
   `ServerAuth` on every hello AND every update manifest
   (sig over `version|sha256`). Never weaken either check.
4. Challenge codes: 12 chars, Crockford-ish alphabet (~60 bits), printed
   ONLY on the agent console; the phone types them blind; 5 wrong
   attempts expire the pairing.
5. Machine names are `<org>-<machine>` (org validated, UNIQUE); taken
   names error and REQUIRE a new name; revoked names stay reserved.
6. API keys: server-generated 192-bit, shown once, stretched salted
   hashes; scopes `enroll` / `readonly` / `exec:*` / `exec:m1|m2`.
7. Output capped at 8 MiB/stream agent-side; audit snippets redacted.
8. Revocation is sticky: agents self-retire, keys can't re-enroll, names
   stay reserved.
9. `X-Forwarded-For` trusted only with `MACH_TRUST_PROXY=1`.

## Known gaps to close (in priority order — each was deliberately
deferred, none is hidden)

1. **Policy layer is a foot-guard, not a sandbox.**
   `internal/agent/policy.go` does substring deny/allow matching —
   bypassable (`rm -rf` → `rm -r -f`, base64 pipes, etc.). The real fix
   is OS confinement profiles: seccomp allowlist on Linux
   (`internal/agent/confine_linux.go` already sets Setpgid; add a
   seccomp profile via `golang.org/x/sys/unix.SockFprog` or ship
   `prlimit`+bubblewrap as an optional wrapper), Seatbelt
   (`sandbox-exec`) on macOS, restricted token + Job Object on Windows.
   Acceptance: a policy unit test where an allowlist key cannot execute
   anything outside the allowlist even via shell metacharacter tricks.
2. **Streaming console is not a PTY.**
   `/v1/console/stream` (server/stream.go) + `handleStream`
   (agent/streamexec.go) give live 32 KiB chunks and remote Ctrl-C, but
   no echo/line discipline/TUI support. Fix: allocate a kernel PTY on
   the agent (`github.com/creack/pty`, already pure-Go) behind a
   `pty: true` flag in `StreamStart`, relay the pty master the same way,
   and teach `mach console` terminal raw mode locally (golang.org/x/term).
   Keep the non-PTY path as fallback (Windows).
3. **No signed release manifests for shipped binaries.**
   The Docker image ships prebuilt agents in `/opt/mach-agents/` with no
   provenance. Fix: in the Dockerfile build stage, after the
   cross-compile loop, sha256 each binary and sign the manifest with the
   control-plane identity key (same ed25519 flow as `push-update`), emit
   `manifest.signed` next to the binaries; `mach` learns a
   `mach verify <binary> <manifest>` subcommand. Acceptance: tampered
   binary fails verification in a unit test.
4. **Single control plane = SPOF.** Acceptable for a household fleet;
   if scale is needed, the Postgres backing (`MACH_DB=postgres://…`) is
   the foundation — next step would be multiple stateless mach-server
   replicas behind one domain (the broker is in-memory: `internal/
   broker/broker.go` maps machine→conn, which pins sessions to one
   server; a redesign would route via a shared pub/sub, e.g. Postgres
   LISTEN/NOTIFY or Redis).

## Non-obvious gotchas (learned the hard way — don't rediscover)

- **E2E wire format**: `SealedB64` is base64 of the *SealedMessage JSON*
  (`{"v":1,"eph":...,"body":...}`), and the console's local
  `e2eWire`/`OpenB64` copy must carry the `v:1` field — a missing `v`
  fails on the agent with "unsupported sealed message version". AAD is
  the sender's ephemeral pubkey.
- **Nonce size**: chacha20poly1305.NonceSize (12), NOT NonceSizeX —
  mixing them panics on Open.
- **`mach exec` E2E mode ignores `command`/`argv`**: when `sealed` is
  set, the server requires `e2e_pub` and ignores the plaintext fields
  (and vice versa). The console always tries E2E first and falls back
  to plaintext only when the machine has no `pub_e2e` (pre-E2E
  enrollment) — don't "fix" that fallback away.
- **Audit in E2E mode** writes a `[E2E sealed command]` placeholder with
  exit code only — if you need command content in audit, that's a
  deliberate policy change to propose, not silently implement.
- **The agent re-exec on update** runs `self run` detached (Setsid on
  unix); if you touch update logic, verify the new process survives the
  old one exiting (the e2e checks "post-update exec works" twice).
- **Rate limiters are per-IP** with port-stripped keys; behind a proxy
  they need `MACH_TRUST_PROXY=1` or every client shares the proxy IP.
- **Tests that touch time**: pairing TTL/expiry tests sleep tiny
  amounts; keep tolerances loose or they flake on loaded machines.

## Repo workflow (team conventions apply — <owner>/hermes AGENTS.md)

- Branch off `main`, PR into `main`. The GitHub App
  (`hermes-main[bot]`) can push and file issues but CANNOT create
  user-account repos — the repo already exists, so just branch + PR.
- Keep `go.mod` minimal; `internal/protocol` must stay on stdlib +
  gorilla/websocket only.
- Commit messages: imperative, explain the security property when one
  is touched.

## Where things stand (as of handoff, commit 710a6cc)

- All four v0.2 limitations CLOSED: E2E encryption, confinement,
  streaming console, Postgres backing.
- Unit tests green (`go test ./... -race`), e2e 25/25.
- Remaining gaps are the four listed above, none blocking household use.