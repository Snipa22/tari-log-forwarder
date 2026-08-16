# tari-log-forwarder

Rotation-safe forwarder that tails all five of a Tari `base_node`'s log
files and pushes every new line, verbatim, into the local systemd journal
— each file under its own distinct syslog tag. This lets an existing
rsyslog/journal → Graylog (or similar) shipping pipeline pick up all five
base-node log streams with **zero receiver-side configuration changes**
beyond matching on the five new `SYSLOG_IDENTIFIER`s.

Part of the `Snipa22` Tari fleet tooling ecosystem (sibling to the
`go-tari-*` repos); this one is plain bash + systemd because the job doesn't
need a compiled binary.

## Layout

Tool files live at the repo root rather than a subdirectory — this repo
ships exactly one script + one unit, there's no multi-tool aggregation
concern (unlike e.g. `go-tari-tools`), so a flat layout keeps install paths
obvious and 1:1 with what you copy onto a node.

- `tari-log-forwarder.sh` — the forwarder script (spawns five tail/logger
  pipelines, one per log file)
- `tari-log-forwarder.service` — systemd unit that runs it (still just
  **one** service/unit for all five streams)
- `.github/workflows/ci.yml` — CI: bash syntax check + systemd unit lint

## What it does

Tails all five Tari `base_node` log files under one log directory and
forwards each to the journal under its own tag:

| Log file          | Syslog tag                  |
|--------------------|------------------------------|
| `base_layer.log`   | `tari-basenode-baselayer`   |
| `network.log`       | `tari-basenode-network`     |
| `other.log`         | `tari-basenode-other`       |
| `messages.log`      | `tari-basenode-messages`    |
| `grpc.log`          | `tari-basenode-grpc`        |

- Runs **one `tail -F` process per file** (five total), each piped into its
  own `logger` invocation with that file's tag. GNU `tail` supports
  watching multiple files in a single invocation, but it prefixes lines
  with a `==> filename <==` header every time it switches between files —
  that pollutes forwarded output and isn't something you want to try to
  strip back out downstream, so each file gets its own dedicated
  `tail -F | logger` pipeline instead. This also means each file's
  rotation is handled completely independently — one file rotating never
  disrupts, delays, or drops lines from any other file's stream.
- Uses `tail -F` (capital F) on each file — this tracks the *path*, not the
  file descriptor, so when Tari's `log4rs` rotates a log file (rename to
  e.g. `base_layer.1.log`, recreate the original filename), the tailer for
  that file detects the rename/truncate and reopens the new file by name
  instead of going stale on the old inode. This is the standard
  rotation-safe pattern for a rolling log — no separate rotation handling
  is needed in the script itself, no `logrotate` `copytruncate` gotchas,
  and no manual reload/restart needed on rotation, for any of the five
  files.
- Starts at end-of-file (`tail -F -n0`) on every (re)start, for every file,
  so a service restart never replays or duplicates history already in the
  journal.
- Forwards every new line unmodified (no filtering/parsing) to the
  journal via `logger -t <tag>`, so `journalctl -t <tag>` (or a
  `SYSLOG_IDENTIFIER=<tag>` match downstream) surfaces the full,
  unfiltered stream for that specific log file.
- Runs all five tail/logger pipelines as background jobs of **one script,
  under one systemd service** — there is no per-file service/unit
  sprawl. On SIGTERM/SIGINT (service stop/restart), the script's own trap
  explicitly kills every pipeline it spawned (both the `tail -F` and the
  in-flight `logger` process in each), so a stop/restart never leaves an
  orphaned `tail` or `logger` process behind. `KillMode=control-group`
  (systemd's default) also applies as a second line of defense.

See the comments in `tari-log-forwarder.sh` for why `logger(1)` is used
instead of `systemd-cat` (per-line fork overhead vs. per-call journal
stream handshake, under bursty log volume) and why each file gets its own
tail process instead of tail's built-in multi-file mode.

## Install

```bash
sudo install -m 0755 tari-log-forwarder.sh /usr/local/bin/tari-log-forwarder.sh
sudo install -m 0644 tari-log-forwarder.service /etc/systemd/system/tari-log-forwarder.service
sudo systemctl daemon-reload
sudo systemctl enable --now tari-log-forwarder.service
```

The unit runs as the `tari` user/group and expects that user to have read
access to the base-node log directory (true by default on a standard Tari
node install where the base_node process itself runs as `tari`).

### Configuration

`TARI_LOG_DIR` (env var, set in the unit file) controls which directory
holds the five base-node log files; the script derives all five file paths
(`base_layer.log`, `network.log`, `other.log`, `messages.log`, `grpc.log`)
from that one directory. Default:

```
/home/tari/.tari/mainnet/log/base_node
```

Override it in the unit (or an override drop-in via
`systemctl edit tari-log-forwarder.service`) for non-default install paths
or non-mainnet networks (e.g. testnet/nextnet log paths). All five files
are expected directly inside this directory with their standard names —
there's no per-file path override; if you need that, you're probably
running a non-standard base_node log layout and should adapt the script.

> **Breaking change note:** earlier versions of this tool used
> `TARI_LOG_PATH` (a single full file path to `base_layer.log`) and only
> forwarded that one file under the single tag `tari-basenode`. That env
> var is gone. If you have an existing unit override setting
> `TARI_LOG_PATH`, replace it with `TARI_LOG_DIR` pointing at the log
> *directory*, and update any downstream Graylog/journal filters that
> matched on `tari-basenode` to match on the five new
> `tari-basenode-*` tags instead.

## Verify it's working

```bash
systemctl status tari-log-forwarder.service
journalctl -u tari-log-forwarder.service -f      # unit's own stderr/status

# One stream per log file:
journalctl -t tari-basenode-baselayer -f
journalctl -t tari-basenode-network -f
journalctl -t tari-basenode-other -f
journalctl -t tari-basenode-messages -f
journalctl -t tari-basenode-grpc -f
```

To confirm rotation-safety on a live node, watch the relevant
`journalctl -t tari-basenode-<stream> -f` across that file's rotation
(log4rs rotates each file independently, on its own schedule/size
threshold) and confirm lines keep flowing with no gap and no duplication
around the rotation boundary — and that the *other* four streams are
unaffected by that rotation.

## Log rotation handling

Rotation is handled entirely by each file's own `tail -F` path-tracking
behavior (see above) — there is no separate logrotate config to manage for
this tool, and no coordination needed with however each file gets rotated
(log4rs is the one rotating them, this tool just needs to keep up with
each independently, which `-F` guarantees per file). If the *forwarder's
own* systemd journal entries grow large, that's governed by the host's
normal `journald` retention (`/etc/systemd/journald.conf`), not by
anything in this repo.

## Shutdown behavior

On `systemctl stop`/`restart`, systemd sends SIGTERM to the script. The
script traps SIGTERM (and SIGINT, for interactive/manual runs) and
explicitly terminates every `tail -F | logger` pipeline it started —
there are five independent pipelines running as background jobs of this
one script/service, and the trap tears all of them down before the script
exits. `ps -ef | grep tail` (or `logger`) immediately after a stop should
show none of this tool's processes remaining.

## License

MIT — see `LICENSE`. No derivation from Tari core source.
