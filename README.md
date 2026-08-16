# tari-log-forwarder

Rotation-safe forwarder that tails a Tari `base_node`'s `base_layer.log` and
pushes every new line, verbatim, into the local systemd journal under a
distinct syslog tag. This lets an existing rsyslog/journal → Graylog (or
similar) shipping pipeline pick up base-node logs with **zero
receiver-side configuration changes** — no filter tuning, no new log path
allowlisting, just a new `SYSLOG_IDENTIFIER` to match on.

Part of the `Snipa22` Tari fleet tooling ecosystem (sibling to the
`go-tari-*` repos); this one is plain bash + systemd because the job doesn't
need a compiled binary.

## Layout

Tool files live at the repo root rather than a subdirectory — this repo
ships exactly one script + one unit, there's no multi-tool aggregation
concern (unlike e.g. `go-tari-tools`), so a flat layout keeps install paths
obvious and 1:1 with what you copy onto a node.

- `tari-log-forwarder.sh` — the forwarder script
- `tari-log-forwarder.service` — systemd unit that runs it
- `.github/workflows/ci.yml` — CI: bash syntax check + systemd unit lint

## What it does

- Uses `tail -F` (capital F) on the configured log path — this tracks the
  *path*, not the file descriptor, so when Tari's `log4rs` rotates
  `base_layer.log` (rename to `base_layer.1.log`, recreate the original
  filename), the tailer detects the rename/truncate and reopens the new
  file by name instead of going stale on the old inode. This is the
  standard rotation-safe pattern for a rolling log — no separate rotation
  handling is needed in the script itself, no `logrotate` `copytruncate`
  gotchas, and no manual reload/restart needed on rotation.
- Starts at end-of-file (`tail -F -n0`) on every (re)start, so a service
  restart never replays or duplicates history already in the journal.
- Forwards every new line unmodified (no filtering/parsing) to the journal
  via `logger -t tari-basenode`, so `journalctl -t tari-basenode` (or a
  `SYSLOG_IDENTIFIER=tari-basenode` match downstream) surfaces the full,
  unfiltered base-node log stream.

See the comments in `tari-log-forwarder.sh` for why `logger(1)` is used
instead of `systemd-cat` (per-line fork overhead vs. per-call journal
stream handshake, under bursty log volume).

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

`TARI_LOG_PATH` (env var, set in the unit file) controls which log file is
tailed. Default:

```
/home/tari/.tari/mainnet/log/base_node/base_layer.log
```

Override it in the unit (or an override drop-in via
`systemctl edit tari-log-forwarder.service`) for non-default install paths
or non-mainnet networks (e.g. testnet/nextnet log paths).

## Verify it's working

```bash
systemctl status tari-log-forwarder.service
journalctl -u tari-log-forwarder.service -f      # unit's own stderr/status
journalctl -t tari-basenode -f                    # forwarded base-node lines
```

To confirm rotation-safety on a live node, watch `journalctl -t
tari-basenode -f` across a log rotation (log4rs rotates
`base_layer.log` on its own schedule/size threshold) and confirm lines
keep flowing with no gap and no duplication around the rotation boundary.

## Log rotation handling

Rotation is handled entirely by `tail -F`'s path-tracking behavior
(see above) — there is no separate logrotate config to manage for this
tool, and no coordination needed with however `base_layer.log` itself gets
rotated (log4rs is the one rotating it, this tool just needs to keep up,
which `-F` guarantees). If the *forwarder's own* systemd journal entries
grow large, that's governed by the host's normal `journald` retention
(`/etc/systemd/journald.conf`), not by anything in this repo.

## License

MIT — see `LICENSE`. No derivation from Tari core source.

## Fleet rollout

This tool is intended to be deployed identically across every Tari
base_node in the fleet — install steps above are copy-paste safe for that
purpose. No per-node customization is required beyond `TARI_LOG_PATH` for
nodes running a non-default network/install layout.
