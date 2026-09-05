#!/bin/sh
# Apply bandwidth timer hardening and cron fallback to the installed system.

set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_FILE=${OALIVE_CONFIG:-/etc/oalive/oalive.conf}
ENABLED_FILE=${OALIVE_ENABLED_CONFIG:-/etc/oalive/enabled.conf}
INSTALL_DIR=${OALIVE_INSTALL_DIR:-/usr/local/bin}
SYSTEMD_DIR=${OALIVE_SYSTEMD_DIR:-/etc/systemd/system}
CRON_BEGIN="# OALIVE BEGIN"
CRON_END="# OALIVE END"

[ "$(id -u 2>/dev/null || echo 1)" = 0 ] || {
  printf '%s\n' "Please run as root / 请使用 root 运行" >&2
  exit 1
}

[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -r "$ENABLED_FILE" ] && . "$ENABLED_FILE"

BANDWIDTH_INTERVAL_MINUTES=${BANDWIDTH_INTERVAL_MINUTES:-45}
BANDWIDTH_ENABLED=${BANDWIDTH_ENABLED:-1}

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cron_escape() {
  printf '%s' "$1" | sed 's/%/\\%/g'
}

install_file() {
  src=$1
  dest=$2
  mode=$3
  tmp=$dest.tmp.$$
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$dest"
}

install_cron_fallback() {
  command -v crontab >/dev/null 2>&1 || {
    printf '%s\n' "crontab not found; skipped cron fallback / 未找到 crontab，跳过 cron 兜底"
    return 0
  }

  tmp=$(mktemp "${TMPDIR:-/tmp}/oalive-cron.XXXXXX")
  new=$(mktemp "${TMPDIR:-/tmp}/oalive-cron-new.XXXXXX")
  crontab -l >"$tmp" 2>/dev/null || : >"$tmp"
  awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$tmp" >"$new"
  cron_runner_cmd=$(cron_escape "/bin/sh $(sq "$INSTALL_DIR/oalive-cron-runner.sh") >/dev/null 2>&1")
  {
    printf '%s\n' "$CRON_BEGIN"
    printf '%s\n' "* * * * * $cron_runner_cmd"
    printf '%s\n' "$CRON_END"
  } >>"$new"
  crontab "$new"
  rm -f "$tmp" "$new"
}

is_uint "$BANDWIDTH_INTERVAL_MINUTES" || BANDWIDTH_INTERVAL_MINUTES=45
[ "$BANDWIDTH_INTERVAL_MINUTES" -ge 1 ] || BANDWIDTH_INTERVAL_MINUTES=45

mkdir -p "$INSTALL_DIR" "$SYSTEMD_DIR" "$SYSTEMD_DIR/bandwidth_occupier.timer.d"
install_file "$SCRIPT_DIR/bandwidth_occupier.sh" "$INSTALL_DIR/bandwidth_occupier.sh" 755
install_file "$SCRIPT_DIR/oalive-cron-runner.sh" "$INSTALL_DIR/oalive-cron-runner.sh" 755
install_file "$SCRIPT_DIR/bandwidth_occupier.service" "$SYSTEMD_DIR/bandwidth_occupier.service" 644
install_file "$SCRIPT_DIR/bandwidth_occupier.timer" "$SYSTEMD_DIR/bandwidth_occupier.timer" 644

cat >"$SYSTEMD_DIR/bandwidth_occupier.timer.d/interval.conf" <<EOF
[Timer]
OnUnitActiveSec=
OnUnitInactiveSec=
OnUnitInactiveSec=${BANDWIDTH_INTERVAL_MINUTES}min
EOF

if [ "$BANDWIDTH_ENABLED" = 1 ]; then
  install_cron_fallback
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  if [ "$BANDWIDTH_ENABLED" = 1 ]; then
    systemctl enable bandwidth_occupier.timer >/dev/null 2>&1 || true
    systemctl restart bandwidth_occupier.timer
  fi
fi

printf '%s\n' "Bandwidth timer fix applied / 带宽 timer 修复已应用"
