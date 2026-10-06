#!/bin/sh
set -eu

HANDLER="$1"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/crash-handler-test.XXXXXX")
trap 'kill "$PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/crash.conf" <<EOF
[Crash Reporter]
SpoolDir=$WORK/spool
[Handler]
MinUid=0
KeepCore=true
MaxCoreSizeMB=1
MaxReports=2
MaxCores=1
EOF

GIO_LAUNCHED_DESKTOP_FILE=/usr/share/applications/org.example.Test.desktop sleep 60 &
PID=$!
sleep 0.2
USER_ID=$(id -u)
GROUP_ID=$(id -g)
DIR="$WORK/spool/$USER_ID"

printf 'COREDATA' | SINGULARITY_CRASH_CONFIG="$WORK/crash.conf" "$HANDLER" "$PID" "$USER_ID" "$GROUP_ID" 11 1000 1 sleep
REPORT="$DIR/0000001000-$PID.crash"
test -f "$REPORT"
grep -q "^Pid=$PID$" "$REPORT"
grep -q "^Signal=11$" "$REPORT"
grep -q "^Executable=.*sleep$" "$REPORT"
grep -q "^CommandLine=sleep 60$" "$REPORT"
grep -q "^DesktopFile=/usr/share/applications/org.example.Test.desktop$" "$REPORT"
grep -q "^Core=0000001000-$PID.core$" "$REPORT"
test "$(cat "$DIR/0000001000-$PID.core")" = "COREDATA"
test "$(stat -c %a "$DIR")" = "700"
test "$(stat -c %a "$REPORT")" = "600"

printf 'X' | SINGULARITY_CRASH_CONFIG="$WORK/crash.conf" "$HANDLER" "$PID" "$USER_ID" "$GROUP_ID" 6 1001 0 sleep
grep -q "^Core=$" "$DIR/0000001001-$PID.crash"
test ! -e "$DIR/0000001001-$PID.core"

head -c 2000000 /dev/zero | SINGULARITY_CRASH_CONFIG="$WORK/crash.conf" "$HANDLER" "$PID" "$USER_ID" "$GROUP_ID" 11 1002 1 sleep
grep -q "^Core=$" "$DIR/0000001002-$PID.crash"
test ! -e "$DIR/0000001002-$PID.core"
test ! -e "$DIR/0000001002-$PID.core.tmp"

test "$(ls "$DIR" | grep -c '\.crash$')" = "2"
test ! -e "$REPORT"
test "$(ls "$DIR" | grep -c '\.core$')" = "1"

if SINGULARITY_CRASH_CONFIG="$WORK/crash.conf" "$HANDLER" 1 2 3 < /dev/null 2>/dev/null; then
	exit 1
fi
if SINGULARITY_CRASH_CONFIG="$WORK/crash.conf" "$HANDLER" abc "$USER_ID" "$GROUP_ID" 11 1 1 x < /dev/null 2>/dev/null; then
	exit 1
fi

cat > "$WORK/high.conf" <<EOF
[Crash Reporter]
SpoolDir=$WORK/spool2
[Handler]
MinUid=4000000000
EOF
printf 'X' | SINGULARITY_CRASH_CONFIG="$WORK/high.conf" "$HANDLER" "$PID" "$USER_ID" "$GROUP_ID" 11 1003 1 sleep
test ! -e "$WORK/spool2"

ln -s "$WORK/elsewhere" "$WORK/spool3"
mkdir -p "$WORK/elsewhere"
cat > "$WORK/link.conf" <<EOF
[Crash Reporter]
SpoolDir=$WORK/spool3
[Handler]
MinUid=0
EOF
if printf 'X' | SINGULARITY_CRASH_CONFIG="$WORK/link.conf" "$HANDLER" "$PID" "$USER_ID" "$GROUP_ID" 11 1004 1 sleep; then
	exit 1
fi
test -z "$(ls "$WORK/elsewhere")"

echo "crash-handler: ok"
