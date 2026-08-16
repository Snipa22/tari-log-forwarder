---
description: tari-log-forwarder — bash/systemd tool for the Tari fleet ecosystem
---

# AGENTS.md

Instructions for AI coding agents (OpenCode, Claude Code, or any
`agents.md`-compatible tool) working in this repository. Read this before
making changes.

## Project

- **What this repo is:** A standalone bash + systemd tool that tails a Tari
  `base_node`'s `base_layer.log` and forwards new lines verbatim into the
  local systemd journal, tagged for pickup by an existing journal-shipping
  pipeline. Sibling to the `go-tari-*` Go tooling repos in the same
  ecosystem, but deliberately not Go — no compiled binary needed for this
  job.
- **Files:** `tari-log-forwarder.sh` (the script), `tari-log-forwarder.service`
  (the systemd unit). No subdirectory nesting — see README "Layout" for why.
- **No runtime dependencies** beyond coreutils (`tail`) and `bsdutils`/`util-linux`
  (`logger`), which are present on any standard systemd Linux host.

## Commands

- **Syntax-check the script:** `bash -n tari-log-forwarder.sh`
- **Lint (if shellcheck is available locally):** `shellcheck tari-log-forwarder.sh`
- **Validate the unit file:** `systemd-analyze verify tari-log-forwarder.service`
  (requires a systemd host; CI falls back to a basic structural check if
  `systemd-analyze` isn't available in the runner — see `.github/workflows/ci.yml`)
- **Manual functional test:** run the script against a scratch file, append
  lines to it, rename+recreate it (simulating log4rs rotation) mid-stream,
  and confirm `journalctl -t tari-basenode` keeps receiving lines with no
  gap or duplication across the rotation.

Run the syntax-check + unit verify before considering any change complete.
CI re-checks both; catch failures locally first.

## Conventions

- **Conventional Commits** required — commit type (`feat`/`fix`/`chore`/`docs`/etc.)
  should match the actual change.
- **Rebase, never merge.** No merge commits in PR branches. Rebase onto
  `main` before pushing updates.
- **No direct commits/pushes to `main`.** Always via PR (the one exception
  in this repo's history is the initial scaffold commit, which bootstrapped
  an empty repo — there was no `main` to protect yet).
- Keep the script POSIX-ish/portable within `bash` — this runs unattended
  as a systemd service on every fleet node, so avoid bashisms that aren't
  widely available, and keep `set -uo pipefail` intact.
- The `tail -F` + `-n0` combination is load-bearing for rotation-safety and
  restart-idempotency (see comments in the script) — don't change the flags
  without re-reading and preserving that reasoning.

## Don't

- Don't push directly to `main` or force-push shared branches.
- Don't add merge commits — rebase instead.
- Don't swap `logger` for `systemd-cat` without re-reading the perf
  rationale in the script header (per-line fork+exec vs. per-call journal
  socket handshake) and re-testing under burst load.
- Don't add line filtering/parsing to the forwarder — it is intentionally
  a verbatim, zero-logic passthrough. Filtering belongs downstream in the
  journal-shipping pipeline, not here.
- Don't silently change the licensing header or LICENSE file — that's a
  human decision, flag it instead.

## Disclosure

If you (the agent) are making a substantial autonomous contribution, make
sure the human operator adds a disclosure note to the PR per
`CONTRIBUTING.md`. Don't assume this happens automatically — mention it if
it's about to be skipped.
