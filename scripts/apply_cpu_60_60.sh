#!/bin/sh
set -eu

CONFIG=${OALIVE_CONFIG:-/etc/oalive/oalive.conf}
CPU_TARGET=${CPU_TARGET:-60}
CPU_QUOTA=${CPU_QUOTA:-70}
export CPU_TARGET
DROPIN_DIR=${CPU_DROPIN_DIR:-/etc/systemd/system/cpu-limit.service.d}
DROPIN_FILE=$DROPIN_DIR/quota.conf

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  echo "Config not found: $CONFIG" >&2
  exit 1
fi

tmp=$(mktemp)
awk '
  BEGIN {
    seen = 0
    target = ENVIRON["CPU_TARGET"]
  }
  /^CPU_QUOTA_PERCENT=/ {
    print "CPU_QUOTA_PERCENT=" target
    seen = 1
    next
  }
  { print }
  END {
    if (!seen) print "CPU_QUOTA_PERCENT=" target
  }
' "$CONFIG" >"$tmp"
cat "$tmp" >"$CONFIG"
rm -f "$tmp"

mkdir -p "$DROPIN_DIR"
cat >"$DROPIN_FILE" <<EOF
[Service]
CPUQuota=$CPU_QUOTA%
EOF

systemctl daemon-reload
systemctl restart cpu-limit.service

echo "Applied CPU config: CPU_QUOTA_PERCENT=$CPU_TARGET, CPUQuota=$CPU_QUOTA%"
grep -E '^CPU_QUOTA_PERCENT=|^CPU_CYCLE_SECONDS=' "$CONFIG" || true
cat "$DROPIN_FILE"
systemctl status cpu-limit.service --no-pager || true
