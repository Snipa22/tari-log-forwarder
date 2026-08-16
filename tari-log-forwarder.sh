#!/usr/bin/env bash
#
# tari-log-forwarder.sh
#
# Tails all five of a Tari base_node's log files (base_layer.log,
# network.log, other.log, messages.log, grpc.log) and forwards every new
# line from each into the local systemd journal under a distinct syslog
# tag per file, so an existing rsyslog->Graylog journal-forwarding
# pipeline picks all five streams up with zero receiver-side
# configuration changes beyond matching on the new SYSLOG_IDENTIFIERs.
#
# Why logger(1) and not systemd-cat: systemd-cat forks/execs a fresh helper
# process per invocation and negotiates a journal stream socket each time,
# which does not scale well to a burst of many lines/sec (e.g. a sync storm
# of ban/retry events). logger(1) also forks per line here, but it is a
# small, fast binary that writes straight to /dev/log via syslog(3) with no
# per-call journal handshake, giving materially lower per-line overhead and
# no observed reordering/loss under bursty load in testing (see README).
#
# Why one tail -F per file instead of `tail -F file1 file2 ... file5`:
# GNU tail's multi-file mode prefixes lines with a "==> filename <==" header
# every time it switches between files, which pollutes forwarded output and
# is not something you want to try to strip back out downstream. Each file
# also needs to be able to rotate independently without affecting the
# others, so each gets its own tail -F | logger pipeline, all backgrounded
# under this one script/service.
set -uo pipefail

TARI_LOG_DIR="${TARI_LOG_DIR:-/home/tari/.tari/mainnet/log/base_node}"

# filename:syslog-tag pairs. One tail -F | logger pipeline per pair.
declare -A LOG_TAGS=(
    [base_layer.log]="tari-basenode-baselayer"
    [network.log]="tari-basenode-network"
    [other.log]="tari-basenode-other"
    [messages.log]="tari-basenode-messages"
    [grpc.log]="tari-basenode-grpc"
)

declare -a CHILD_PIDS=()

cleanup() {
    # Kill every backgrounded tail/logger pipeline child on stop. Each
    # entry in CHILD_PIDS is the PID of a `tail -F | logger` pipeline's
    # subshell (see start below) — killing it takes down both halves of
    # that pipe. We do this explicitly, rather than relying solely on
    # systemd's default KillMode=control-group, so shutdown behavior is
    # correct and testable even when this script is run outside systemd
    # (e.g. under the test harness, or interactively).
    trap - TERM INT EXIT
    for pid in "${CHILD_PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        # Kill the whole process group for this pipeline so both the
        # `tail -F` and `logger` processes inside it die, not just the
        # subshell wrapping them.
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM -- "$pid" 2>/dev/null || true
    done
    # Give children a moment to exit, then force anything still alive.
    wait 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# -F (capital) tracks the *path*, not the file descriptor: when log4rs
# rotates a log file (rename to e.g. base_layer.1.log, then recreate the
# original filename), `tail -F` detects the rename/truncate and re-opens
# the new file by name. `tail -f` would keep following the old (renamed)
# inode and go silently stale after rotation. Each file gets its own
# tail process so one file's rotation never disrupts another's stream.
#
# `-n0` = start at end-of-file: on every (re)start we forward only lines
# written from this point forward, so restarting the service never replays
# or duplicates history that's already in the journal.
start_tail() {
    local path="$1"
    local tag="$2"
    (
        # setsid puts this pipeline in its own process group so cleanup()
        # can kill tail+logger together via the group, without also
        # taking down the parent script or sibling pipelines.
        set -uo pipefail
        exec setsid bash -c '
            tail -F -n0 -- "$1" | while IFS= read -r line; do
                logger -t "$2" -p daemon.warning -- "$line"
            done
        ' _ "$path" "$tag"
    ) &
    CHILD_PIDS+=("$!")
}

for fname in "${!LOG_TAGS[@]}"; do
    start_tail "${TARI_LOG_DIR%/}/${fname}" "${LOG_TAGS[$fname]}"
done

# Block until signaled (SIGTERM/SIGINT); cleanup() (via trap) handles
# shutdown. `wait` with no args blocks on all backgrounded jobs and is
# interrupted immediately by an incoming signal, at which point the trap
# fires cleanup() to tear every pipeline down.
wait
