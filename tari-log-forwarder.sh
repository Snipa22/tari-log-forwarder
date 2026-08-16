#!/usr/bin/env bash
#
# tari-log-forwarder.sh
#
# Tails a Tari base_node's base_layer.log and forwards every new line into
# the local systemd journal under a distinct syslog tag/identifier, so an
# existing rsyslog->Graylog journal-forwarding pipeline picks it up with
# zero receiver-side configuration changes.
#
# Why logger(1) and not systemd-cat: systemd-cat forks/execs a fresh helper
# process per invocation and negotiates a journal stream socket each time,
# which does not scale well to a burst of many lines/sec (e.g. a sync storm
# of ban/retry events). logger(1) also forks per line here, but it is a
# small, fast binary that writes straight to /dev/log via syslog(3) with no
# per-call journal handshake, giving materially lower per-line overhead and
# no observed reordering/loss under bursty load in testing (see README).
set -uo pipefail

TARI_LOG_PATH="${TARI_LOG_PATH:-/home/tari/.tari/mainnet/log/base_node/base_layer.log}"
readonly TAG="tari-basenode"

# -F (capital) tracks the *path*, not the file descriptor: when log4rs
# rotates base_layer.log (rename to base_layer.1.log, then recreate the
# original filename), `tail -F` detects the rename/truncate and re-opens
# the new file by name. `tail -f` would keep following the old (renamed)
# inode and go silently stale after rotation.
#
# `-n0` = start at end-of-file: on every (re)start we forward only lines
# written from this point forward, so restarting the service never replays
# or duplicates history that's already in the journal.
tail -F -n0 -- "$TARI_LOG_PATH" | while IFS= read -r line; do
    logger -t "$TAG" -p daemon.warning -- "$line"
done
