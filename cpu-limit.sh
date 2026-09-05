#!/bin/sh
# by spiritlhl
# from https://github.com/spiritLHLS/Oracle-server-keep-alive-script

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
[ -r "$OALIVE_CONFIG" ] && . "$OALIVE_CONFIG"

LOG_DIR=${OALIVE_LOG_DIR:-/var/log/oalive}
RUN_DIR=${OALIVE_RUN_DIR:-${TMPDIR:-/tmp}}
LOG_FILE=${CPU_LOG_FILE:-$LOG_DIR/cpu-limit.log}
LOCK_DIR=$RUN_DIR/oalive-cpu-limit.lock
LOG_MAX_BYTES=${OALIVE_LOG_MAX_BYTES:-131072}
CPU_QUOTA_PERCENT=${CPU_QUOTA_PERCENT:-${CPU_TARGET_PERCENT:-25}}
CPU_CYCLE_SECONDS=${CPU_CYCLE_SECONDS:-10}

worker_pids=

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

ensure_log_dir() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE=/dev/null
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
  ensure_log_dir
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

acquire_lock() {
  [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  old_pid=
  [ -r "$LOCK_DIR/pid" ] && old_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null)
  if pid_is_alive "$old_pid"; then
    log "CPU占用已在运行，PID: $old_pid / CPU occupier is already running, PID: $old_pid"
    exit 0
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  log "无法创建CPU锁目录 / Failed to create CPU lock directory: $LOCK_DIR"
  exit 1
}

cleanup() {
  trap - INT TERM EXIT
  for pid in $worker_pids; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $worker_pids; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

terminate() {
  cleanup
  exit 0
}

get_cores() {
  cores=
  if command -v getconf >/dev/null 2>&1; then
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  fi
  if ! is_uint "$cores" || [ "$cores" -lt 1 ]; then
    cores=$(sysctl -n hw.ncpu 2>/dev/null || true)
  fi
  if ! is_uint "$cores" || [ "$cores" -lt 1 ]; then
    cores=$(awk '/^processor[[:space:]]*:/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null || true)
  fi
  if ! is_uint "$cores" || [ "$cores" -lt 1 ]; then
    cores=1
  fi
  printf '%s\n' "$cores"
}

normalize_settings() {
  is_uint "$CPU_QUOTA_PERCENT" || CPU_QUOTA_PERCENT=25
  is_uint "$CPU_CYCLE_SECONDS" || CPU_CYCLE_SECONDS=10
  [ "$CPU_QUOTA_PERCENT" -gt 0 ] || CPU_QUOTA_PERCENT=25
  [ "$CPU_CYCLE_SECONDS" -ge 2 ] || CPU_CYCLE_SECONDS=10
}

cpu_is_busy() {
  # What：采样实例实际 CPU 运算时间，判断是否达到指定阈值。
  # Why：steal 和 I/O 等待不是实例自身运算，不能误判为 CPU 使用率。
  threshold=${1:-30}
  is_uint "$threshold" || threshold=30
  [ -r /proc/stat ] || return 1
  first=$(awk '$1 == "cpu" {busy=$2+$3+$4+$7+$8; printf "%.0f %.0f\n", busy, busy+$5+$6+$9; exit}' /proc/stat 2>/dev/null)
  sleep 1
  second=$(awk '$1 == "cpu" {busy=$2+$3+$4+$7+$8; printf "%.0f %.0f\n", busy, busy+$5+$6+$9; exit}' /proc/stat 2>/dev/null)
  first_busy=${first%% *}; first_total=${first#* }
  second_busy=${second%% *}; second_total=${second#* }
  is_uint "$first_busy" && is_uint "$first_total" || return 1
  is_uint "$second_busy" && is_uint "$second_total" || return 1
  busy_delta=$((second_busy - first_busy))
  total_delta=$((second_total - first_total))
  [ "$busy_delta" -ge 0 ] && [ "$total_delta" -gt 0 ] || return 1
  [ $((busy_delta * 100)) -ge $((total_delta * threshold)) ]
}

full_worker() {
  trap 'exit 0' INT TERM
  if command -v yes >/dev/null 2>&1; then
    exec yes >/dev/null
  fi
  while :; do :; done
}

throttle_worker() {
  percent=$1
  cycle=$2
  busy=$((cycle * percent / 100))
  [ "$busy" -ge 1 ] || busy=1
  [ "$busy" -le "$cycle" ] || busy=$cycle
  idle=$((cycle - busy))
  load_pid=
  trap 'kill "$load_pid" 2>/dev/null || true; exit 0' INT TERM

  while :; do
    if command -v yes >/dev/null 2>&1; then
      yes >/dev/null &
    else
      dd if=/dev/zero of=/dev/null bs=1048576 count=1024 >/dev/null 2>&1 &
    fi
    load_pid=$!
    sleep "$busy"
    kill "$load_pid" 2>/dev/null || true
    wait "$load_pid" 2>/dev/null || true
    load_pid=
    [ "$idle" -gt 0 ] && sleep "$idle"
  done
}

start_workers() {
  cores=$(get_cores)
  max_quota=$((cores * 100))
  [ "$CPU_QUOTA_PERCENT" -le "$max_quota" ] || CPU_QUOTA_PERCENT=$max_quota

  full=$((CPU_QUOTA_PERCENT / 100))
  partial=$((CPU_QUOTA_PERCENT % 100))
  started=0

  while [ "$started" -lt "$full" ] && [ "$started" -lt "$cores" ]; do
    full_worker &
    worker_pids="$worker_pids $!"
    started=$((started + 1))
  done

  if [ "$partial" -gt 0 ] && [ "$started" -lt "$cores" ]; then
    throttle_worker "$partial" "$CPU_CYCLE_SECONDS" &
    worker_pids="$worker_pids $!"
    started=$((started + 1))
  fi

  if [ "$started" -eq 0 ]; then
    log "CPU占用目标为0，保持空闲 / CPU target is 0, staying idle"
  else
    log "CPU占用已启动，核心数=$cores, 目标=${CPU_QUOTA_PERCENT}%单核配额 / CPU occupier started, cores=$cores, target=${CPU_QUOTA_PERCENT}% of one-core quota"
  fi
}

monitor_workers() {
  # What：运行期间周期检查 CPU，并在高负载时清理 worker。
  # Why：启动后的外部负载变化不能由一次性启动检查覆盖。
  while :; do
    sleep 30
    if cpu_is_busy 50; then
      log "当前CPU使用率达到50%，停止本轮占用 / Current CPU usage is at least 50%, stopping this run"
      cleanup
      return 0
    fi
    for pid in $worker_pids; do
      pid_is_alive "$pid" || return 0
    done
  done
}

case ${1:-} in
  --help|-h)
    printf '%s\n' "Usage: sh cpu-limit.sh"
    printf '%s\n' "配置 / Config: CPU_QUOTA_PERCENT, CPU_CYCLE_SECONDS, OALIVE_LOG_DIR"
    exit 0
    ;;
  --check)
    normalize_settings
    printf '%s\n' "CPU script OK / CPU脚本检查通过"
    exit 0
    ;;
esac

normalize_settings
acquire_lock
trap terminate INT TERM
trap cleanup EXIT
if cpu_is_busy 30; then
  log "当前CPU使用率达到30%，跳过本轮占用 / Current CPU usage is at least 30%, skipping this run"
  exit 0
fi
start_workers

monitor_workers
rc=$?
log "CPU工作进程已退出，返回码=$rc / CPU worker exited, rc=$rc"
exit "$rc"
