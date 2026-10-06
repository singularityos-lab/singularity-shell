#!/bin/sh
set -eu
HELPER="$1"
DIR=$(mktemp -d "${TMPDIR:-/tmp}/parental-helper.XXXXXX")
export SINGULARITY_PARENTAL_DIR="$DIR/policies"
printf '[Time]\nDailyLimitMinutes=60\n' | "$HELPER" set sam
grep -q DailyLimitMinutes=60 "$DIR/policies/sam.conf"
if printf '[Evil]\nx=1\n' | "$HELPER" set sam 2>/dev/null; then echo "accepted a bad group"; exit 1; fi
if printf '[Time]\n' | "$HELPER" set ../etc 2>/dev/null; then echo "accepted a bad user"; exit 1; fi
if printf '[Time]\n' | "$HELPER" set -rf 2>/dev/null; then echo "accepted a dash user"; exit 1; fi
if "$HELPER" remove sam 2>/dev/null; then echo "accepted a bad verb"; exit 1; fi
grep -q DailyLimitMinutes=60 "$DIR/policies/sam.conf"
"$HELPER" clear sam
test ! -e "$DIR/policies/sam.conf"
"$HELPER" clear sam
rmdir "$DIR/policies" "$DIR"
echo ok
