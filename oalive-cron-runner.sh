#!/bin/sh
# POSIX cron supervisor for Oracle-server-keep-alive-script.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

init_locale() {
  utf8_locale=$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ {print; exit}')
  if [ -n "$utf8_locale" ]; then
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
  fi
}

init_locale

OALIVE_CONFIG=${OALIVE_CONFIG:-/etc/oalive/oalive.conf}
OALIVE_ENABLED_CONFIG=${OALIVE_ENABLED_CONFIG:-/etc/oalive/enabled.conf}
[ -r "$OALIVE_CONFIG" ] && . "$OALIVE_CONFIG"
[ -r "$OALIVE_ENABLED_CONFIG" ] && . "$OALIVE_ENABLED_CONFIG"

LOG_DIR=${OALIVE_LOG_DIR:-/var/log/oalive}
STATE_DIR=${OALIVE_STATE_DIR:-/var/lib/oalive}
RUN_DIR=${OALIVE_RUN_DIR:-${TMPDIR:-/tmp}}
LOG_FILE=${CRON_LOG_FILE:-$LOG_DIR/cron-runner.log}
LOG_MAX_BYTES=${OALIVE_LOG_MAX_BYTES:-131072}

CPU_ENABLED=${CPU_ENABLED:-0}
MEMORY_ENABLED=${MEMORY_ENABLED:-0}
BANDWIDTH_ENABLED=${BANDWIDTH_ENABLED:-0}
BANDWIDTH_INTERVAL_MINUTES=${BANDWIDTH_INTERVAL_MINUTES:-45}

CPU_SCRIPT=${CPU_SCRIPT:-/usr/local/bin/cpu-limit.sh}
MEMORY_SCRIPT=${MEMORY_SCRIPT:-/usr/local/bin/memory-limit.sh}
BANDWIDTH_SCRIPT=${BANDWIDTH_SCRIPT:-/usr/local/bin/bandwidth_occupier.sh}

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

ensure_dirs() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE=/dev/null
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
}

rotate_log() {
  [ "$LOG_FILE" = /dev/null ] && return 0
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
  is_uint "$size" || size=0
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || : >"$LOG_FILE"
  fi
}

log() {
  ensure_dirs
  rotate_log
  line="$(now) $*"
  printf '%s\n' "$line"
  [ "$LOG_FILE" = /dev/null ] || printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

pid_is_alive() {
  pid=${1:-}
  is_uint "$pid" || return 1
  kill -0 "$pid" 2>/dev/null
}

lock_pid_alive() {
  name=$1
  lock_dir=$RUN_DIR/oalive-$name.lock
  [ -r "$lock_dir/pid" ] || return 1
  pid=$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)
  pid_is_alive "$pid"
}

start_daemon_if_needed() {
  name=$1
  script=$2
  [ -x "$script" ] || {
    log "$script 不存在或不可执行 / $script does not exist or is not executable"
    return 1
  }
  if lock_pid_alive "$name"; then
    return 0
  fi
  log "启动 $name / Starting $name"
  nohup /bin/sh "$script" >/dev/null 2>&1 &
}

with_schedule_lock() {
  lock=$RUN_DIR/oalive-cron-schedule.lock
  [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid"
    return 0
  fi
  old_pid=
  [ -r "$lock/pid" ] && old_pid=$(sed -n '1p' "$lock/pid" 2>/dev/null || true)
  if pid_is_alive "$old_pid"; then
    return 1
  fi
  rm -rf "$lock" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid"
    return 0
  fi
  return 1
}

release_schedule_lock() {
  rm -rf "$RUN_DIR/oalive-cron-schedule.lock" 2>/dev/null || true
}

run_bandwidth_if_due() {
  [ -x "$BANDWIDTH_SCRIPT" ] || {
    log "$BANDWIDTH_SCRIPT 不存在或不可执行 / $BANDWIDTH_SCRIPT does not exist or is not executable"
    return 1
  }

  is_uint "$BANDWIDTH_INTERVAL_MINUTES" || BANDWIDTH_INTERVAL_MINUTES=45
  [ "$BANDWIDTH_INTERVAL_MINUTES" -ge 1 ] || BANDWIDTH_INTERVAL_MINUTES=45
  interval_seconds=$((BANDWIDTH_INTERVAL_MINUTES * 60))
  last_file=$STATE_DIR/bandwidth.last
  now_s=$(date '+%s' 2>/dev/null || echo 0)
  is_uint "$now_s" || now_s=0
  last=0
  [ -r "$last_file" ] && last=$(sed -n '1p' "$last_file" 2>/dev/null || echo 0)
  is_uint "$last" || last=0

  [ "$now_s" -eq 0 ] && return 0
  [ $((now_s - last)) -ge "$interval_seconds" ] || return 0
  lock_pid_alive bandwidth && return 0

  with_schedule_lock || return 0
  now_s=$(date '+%s' 2>/dev/null || echo 0)
  is_uint "$now_s" || now_s=0
  last=0
  [ -r "$last_file" ] && last=$(sed -n '1p' "$last_file" 2>/dev/null || echo 0)
  is_uint "$last" || last=0
  if [ "$now_s" -eq 0 ] || [ $((now_s - last)) -lt "$interval_seconds" ] || lock_pid_alive bandwidth; then
    release_schedule_lock
    return 0
  fi
  release_schedule_lock

  log "触发带宽占用 / Triggering bandwidth occupier"
  nohup /bin/sh "$BANDWIDTH_SCRIPT" >/dev/null 2>&1 &
}

case ${1:-tick} in
  --help|-h)
    printf '%s\n' "Usage: sh oalive-cron-runner.sh [tick|--check]"
    exit 0
    ;;
  --check)
    ensure_dirs
    printf '%s\n' "Cron runner OK / Cron监督器检查通过"
    exit 0
    ;;
esac

ensure_dirs
[ "$CPU_ENABLED" = 1 ] && start_daemon_if_needed cpu-limit "$CPU_SCRIPT"
[ "$MEMORY_ENABLED" = 1 ] && start_daemon_if_needed memory-limit "$MEMORY_SCRIPT"
[ "$BANDWIDTH_ENABLED" = 1 ] && run_bandwidth_if_due
