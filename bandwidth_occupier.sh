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
STATE_DIR=${OALIVE_STATE_DIR:-/var/lib/oalive}
RUN_DIR=${OALIVE_RUN_DIR:-${TMPDIR:-/tmp}}
LOG_FILE=${BANDWIDTH_LOG_FILE:-$LOG_DIR/bandwidth_occupier.log}
LOCK_DIR=$RUN_DIR/oalive-bandwidth.lock
LOG_MAX_BYTES=${OALIVE_LOG_MAX_BYTES:-131072}

BANDWIDTH_MODE=${BANDWIDTH_MODE:-wget}
BANDWIDTH_INTERVAL_MINUTES=${BANDWIDTH_INTERVAL_MINUTES:-45}
BANDWIDTH_DURATION_MINUTES=${BANDWIDTH_DURATION_MINUTES:-6}
BANDWIDTH_RATE_PERCENT=${BANDWIDTH_RATE_PERCENT:-30}
BANDWIDTH_RATE_MBPS=${BANDWIDTH_RATE_MBPS:-auto}
BANDWIDTH_DEFAULT_MBPS=${BANDWIDTH_DEFAULT_MBPS:-10}
BANDWIDTH_SPEEDTEST_COUNT=${BANDWIDTH_SPEEDTEST_COUNT:-10}
BANDWIDTH_URL_CHECKS=${BANDWIDTH_URL_CHECKS:-3}
BANDWIDTH_URL=${BANDWIDTH_URL:-}
SPEEDTEST_GO_BIN=${SPEEDTEST_GO_BIN:-/etc/speedtest-cli/speedtest-go}

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_number() {
  awk -v n="${1:-}" 'BEGIN {exit (n ~ /^[0-9]+([.][0-9]+)?$/ ? 0 : 1)}'
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

should_skip_recent_run() {
  [ "${BANDWIDTH_FORCE:-0}" = 1 ] && return 1
  is_uint "$BANDWIDTH_INTERVAL_MINUTES" || BANDWIDTH_INTERVAL_MINUTES=45
  [ "$BANDWIDTH_INTERVAL_MINUTES" -ge 1 ] || BANDWIDTH_INTERVAL_MINUTES=45
  last_file=$STATE_DIR/bandwidth.last
  [ -r "$last_file" ] || return 1
  last=$(sed -n '1p' "$last_file" 2>/dev/null || echo 0)
  is_uint "$last" || last=0
  now_s=$(date '+%s' 2>/dev/null || echo 0)
  is_uint "$now_s" || now_s=0
  [ "$last" -gt 0 ] && [ "$now_s" -gt 0 ] || return 1
  interval_seconds=$((BANDWIDTH_INTERVAL_MINUTES * 60))
  if [ $((now_s - last)) -lt "$interval_seconds" ]; then
    log "距离上次带宽占用未满间隔，跳过本轮 / Last bandwidth run is still within interval, skipping this run"
    return 0
  fi
  return 1
}

mark_run_started() {
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  now_s=$(date '+%s' 2>/dev/null || echo 0)
  is_uint "$now_s" || return 0
  [ "$now_s" -gt 0 ] || return 0
  printf '%s\n' "$now_s" >"$STATE_DIR/bandwidth.last" 2>/dev/null || true
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
    log "带宽占用已在运行，PID: $old_pid / Bandwidth occupier is already running, PID: $old_pid"
    exit 0
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  log "无法创建带宽锁目录 / Failed to create bandwidth lock directory: $LOCK_DIR"
  exit 1
}

cleanup() {
  trap - INT TERM EXIT
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" 2>/dev/null || true
  [ -n "${TIMER_PID:-}" ] && kill "$TIMER_PID" 2>/dev/null || true
  [ -n "${TIMEOUT_FLAG:-}" ] && rm -f "$TIMEOUT_FLAG" 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

terminate() {
  cleanup
  exit 0
}

normalize_settings() {
  is_uint "$BANDWIDTH_DURATION_MINUTES" || BANDWIDTH_DURATION_MINUTES=6
  is_uint "$BANDWIDTH_INTERVAL_MINUTES" || BANDWIDTH_INTERVAL_MINUTES=45
  is_uint "$BANDWIDTH_RATE_PERCENT" || BANDWIDTH_RATE_PERCENT=30
  is_uint "$BANDWIDTH_SPEEDTEST_COUNT" || BANDWIDTH_SPEEDTEST_COUNT=10
  is_uint "$BANDWIDTH_URL_CHECKS" || BANDWIDTH_URL_CHECKS=3
  is_number "$BANDWIDTH_DEFAULT_MBPS" || BANDWIDTH_DEFAULT_MBPS=10
  [ "$BANDWIDTH_DURATION_MINUTES" -ge 1 ] || BANDWIDTH_DURATION_MINUTES=6
  [ "$BANDWIDTH_DURATION_MINUTES" -le 1440 ] || BANDWIDTH_DURATION_MINUTES=1440
  [ "$BANDWIDTH_INTERVAL_MINUTES" -ge 1 ] || BANDWIDTH_INTERVAL_MINUTES=45
  [ "$BANDWIDTH_RATE_PERCENT" -ge 1 ] || BANDWIDTH_RATE_PERCENT=30
  [ "$BANDWIDTH_RATE_PERCENT" -le 100 ] || BANDWIDTH_RATE_PERCENT=100
  [ "$BANDWIDTH_SPEEDTEST_COUNT" -ge 1 ] || BANDWIDTH_SPEEDTEST_COUNT=10
  [ "$BANDWIDTH_SPEEDTEST_COUNT" -le 100 ] || BANDWIDTH_SPEEDTEST_COUNT=100
  [ "$BANDWIDTH_URL_CHECKS" -ge 1 ] || BANDWIDTH_URL_CHECKS=3
  [ "$BANDWIDTH_URL_CHECKS" -le 10 ] || BANDWIDTH_URL_CHECKS=10
  case "$BANDWIDTH_MODE" in
    speedtest|speedtest-go|speedtest_go) BANDWIDTH_MODE=speedtest ;;
    *) BANDWIDTH_MODE=wget ;;
  esac
}

download_urls() {
  cat <<'URLS' | awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {print}
  '
# Asia: Tokyo
http://tyo.download.datapacket.com/100mb.bin
http://tyo.download.datapacket.com/1000mb.bin
http://tyo.download.datapacket.com/10000mb.bin
https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin
https://hnd-jp-ping.vultr.com/vultr.com.1000MB.bin

# Asia: Hong Kong
http://hkg.download.datapacket.com/100mb.bin
http://hkg.download.datapacket.com/1000mb.bin
http://hkg.download.datapacket.com/10000mb.bin

# Asia: Singapore
http://sgp.download.datapacket.com/100mb.bin
http://sgp.download.datapacket.com/1000mb.bin
http://sgp.download.datapacket.com/10000mb.bin
https://sgp.proof.ovh.net/files/100Mb.dat
https://sgp-ping.vultr.com/vultr.com.100MB.bin
https://sgp.proof.ovh.net/files/1Gb.dat
https://sgp-ping.vultr.com/vultr.com.1000MB.bin
https://sgp.proof.ovh.net/files/10Gb.dat

# North America: US West
http://lax.download.datapacket.com/100mb.bin
http://lax.download.datapacket.com/1000mb.bin
http://lax.download.datapacket.com/10000mb.bin
https://hil.proof.ovh.us/files/100Mb.dat
https://lax-ca-us-ping.vultr.com/vultr.com.100MB.bin
https://hil.proof.ovh.us/files/1Gb.dat
https://lax-ca-us-ping.vultr.com/vultr.com.1000MB.bin
https://hil.proof.ovh.us/files/10Gb.dat
https://hil-speed.hetzner.com/10GB.bin

# Existing general fallback
http://speedtest.tele2.net/1GB.zip
URLS
}

probe_url() {
  url=$1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 5 --max-time 10 --range 0-1023 \
      -o /dev/null "$url" >/dev/null 2>&1
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=10 --tries=1 --header='Range: bytes=0-1023' \
      -O /dev/null "$url" >/dev/null 2>&1
    return $?
  fi
  if command -v fetch >/dev/null 2>&1; then
    fetch -q -o /dev/null -T 5 "$url" >/dev/null 2>&1
    return $?
  fi
  return 1
}

candidate_urls() {
  if [ -n "$BANDWIDTH_URL" ]; then
    printf '%s\n' "$BANDWIDTH_URL"
  fi
  download_urls
}

speedtest_bin() {
  if command -v speedtest-cli >/dev/null 2>&1; then
    printf '%s\n' speedtest-cli
    return 0
  fi
  if [ -x "$SPEEDTEST_GO_BIN" ]; then
    printf '%s\n' "$SPEEDTEST_GO_BIN"
    return 0
  fi
  if command -v speedtest-go >/dev/null 2>&1; then
    printf '%s\n' speedtest-go
    return 0
  fi
  return 1
}

parse_download_mbps() {
  awk '
    tolower($0) ~ /download/ {
      for (i = 1; i <= NF; i++) {
        gsub(/[^0-9.]/, "", $i)
        if ($i ~ /^[0-9]+([.][0-9]+)?$/ && $i > 0) {
          print $i
          exit
        }
      }
    }
  '
}

measure_bandwidth_mbps() {
  if is_number "$BANDWIDTH_RATE_MBPS"; then
    printf '%s\n' "$BANDWIDTH_RATE_MBPS"
    return 0
  fi

  bin=$(speedtest_bin 2>/dev/null || true)
  if [ -n "$bin" ]; then
    if [ "$bin" = speedtest-cli ]; then
      value=$("$bin" --simple 2>/dev/null | parse_download_mbps | sed -n '1p')
    else
      value=$("$bin" 2>/dev/null | parse_download_mbps | sed -n '1p')
    fi
    if is_number "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  printf '%s\n' "$BANDWIDTH_DEFAULT_MBPS"
}

rate_bytes_per_second() {
  mbps=$1
  awk -v mbps="$mbps" -v pct="$BANDWIDTH_RATE_PERCENT" 'BEGIN {
    rate = mbps * 1000000 / 8 * pct / 100
    if (rate < 1024) rate = 1024
    printf "%.0f\n", rate
  }'
}

run_with_timeout() {
  seconds=$1
  shift
  TIMEOUT_FLAG=$RUN_DIR/oalive-bandwidth-timeout.$$
  rm -f "$TIMEOUT_FLAG" 2>/dev/null || true
  "$@" &
  RUN_PID=$!
  (
    sleep "$seconds"
    : >"$TIMEOUT_FLAG"
    kill "$RUN_PID" 2>/dev/null || true
  ) &
  TIMER_PID=$!
  wait "$RUN_PID" 2>/dev/null
  rc=$?
  kill "$TIMER_PID" 2>/dev/null || true
  wait "$TIMER_PID" 2>/dev/null || true
  RUN_PID=
  TIMER_PID=
  if [ -f "$TIMEOUT_FLAG" ]; then
    rm -f "$TIMEOUT_FLAG" 2>/dev/null || true
    return 124
  fi
  rm -f "$TIMEOUT_FLAG" 2>/dev/null || true
  return "$rc"
}

download_with_limit() {
  url=$1
  rate=$2
  seconds=$3

  if command -v curl >/dev/null 2>&1; then
    run_with_timeout "$seconds" curl -fsSL --connect-timeout 10 --limit-rate "$rate" -o /dev/null "$url"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    run_with_timeout "$seconds" wget -q --timeout=10 --tries=1 --limit-rate="$rate" -O /dev/null "$url"
    return $?
  fi
  if command -v fetch >/dev/null 2>&1; then
    log "fetch不支持可靠限速，将仅按时长下载 / fetch has no reliable rate limit, using duration limit only"
    run_with_timeout "$seconds" fetch -q -o /dev/null -T 10 "$url"
    return $?
  fi

  log "未找到curl/wget/fetch，无法执行带宽占用 / curl/wget/fetch not found, cannot run bandwidth occupier"
  return 1
}

run_wget_mode() {
  mbps=$(measure_bandwidth_mbps)
  rate=$(rate_bytes_per_second "$mbps")
  seconds=$((BANDWIDTH_DURATION_MINUTES * 60))
  start_ts=$(date '+%s' 2>/dev/null || echo 0)
  is_uint "$start_ts" || start_ts=0
  end_ts=$((start_ts + seconds))
  tried=0

  for url in $(candidate_urls); do
    now_ts=$(date '+%s' 2>/dev/null || echo 0)
    is_uint "$now_ts" || now_ts=0
    remaining=$((end_ts - now_ts))
    if [ "$remaining" -le 0 ]; then
      log "带宽占用结束 / Bandwidth occupier finished"
      return 0
    fi

    [ -n "$url" ] || continue
    tried=$((tried + 1))
    if ! probe_url "$url"; then
      log "下载源探测失败，跳过 URL=$url / URL probe failed, skipping URL=$url"
      continue
    fi

    now_ts=$(date '+%s' 2>/dev/null || echo 0)
    is_uint "$now_ts" || now_ts=0
    remaining=$((end_ts - now_ts))
    if [ "$remaining" -le 0 ]; then
      log "带宽占用结束 / Bandwidth occupier finished"
      return 0
    fi

    log "开始带宽占用：剩余${remaining}秒，配置=${BANDWIDTH_DURATION_MINUTES}分钟，测速=${mbps}Mbps，限速=${rate}B/s，URL=$url / Starting bandwidth occupier: remaining=${remaining}s, configured=${BANDWIDTH_DURATION_MINUTES} minutes, measured=${mbps}Mbps, limit=${rate}B/s"
    download_with_limit "$url" "$rate" "$remaining"
    rc=$?
    if [ "$rc" -eq 124 ]; then
      log "带宽占用结束 / Bandwidth occupier finished"
      return 0
    fi
    log "下载源下载提前结束或失败，切换下一个 URL=$url / Download ended early or failed, trying next URL=$url"
  done

  if [ "$tried" -eq 0 ]; then
    log "未找到可用下载源 / No download sources available"
  else
    log "所有下载源都失败，本轮未产生有效流量 / All download sources failed, no effective bandwidth usage this run"
  fi
  return 1
}

run_speedtest_mode() {
  bin=$(speedtest_bin 2>/dev/null || true)
  if [ -z "$bin" ]; then
    log "未找到speedtest工具，无法执行speedtest模式 / speedtest tool not found, cannot run speedtest mode"
    return 1
  fi

  i=1
  log "开始speedtest带宽占用，共${BANDWIDTH_SPEEDTEST_COUNT}次 / Starting speedtest bandwidth occupier, count=${BANDWIDTH_SPEEDTEST_COUNT}"
  while [ "$i" -le "$BANDWIDTH_SPEEDTEST_COUNT" ]; do
    if [ "$bin" = speedtest-cli ]; then
      "$bin" --simple >/dev/null 2>&1 || true
    else
      "$bin" >/dev/null 2>&1 || true
    fi
    i=$((i + 1))
  done
  log "speedtest带宽占用结束 / Speedtest bandwidth occupier finished"
}

case ${1:-} in
  --help|-h)
    printf '%s\n' "Usage: sh bandwidth_occupier.sh"
    printf '%s\n' "配置 / Config: BANDWIDTH_MODE, BANDWIDTH_DURATION_MINUTES, BANDWIDTH_RATE_PERCENT, BANDWIDTH_RATE_MBPS, BANDWIDTH_SPEEDTEST_COUNT"
    exit 0
    ;;
  --check)
    normalize_settings
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || command -v fetch >/dev/null 2>&1; then
      printf '%s\n' "Bandwidth script OK / 带宽脚本检查通过"
      exit 0
    fi
    printf '%s\n' "No downloader found / 未找到下载工具"
    exit 1
    ;;
esac

RUN_PID=
TIMER_PID=
normalize_settings
acquire_lock
if should_skip_recent_run; then
  cleanup
  exit 0
fi
mark_run_started
trap terminate INT TERM
trap cleanup EXIT

case "$BANDWIDTH_MODE" in
  speedtest) run_speedtest_mode ;;
  *) run_wget_mode ;;
esac
