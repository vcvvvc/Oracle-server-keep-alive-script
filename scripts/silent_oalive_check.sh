#!/bin/sh
set -eu

DURATION_SECONDS=${DURATION_SECONDS:-300}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-5}
LOG_DIR=${CHECK_LOG_DIR:-/tmp}
LOG_FILE=${CHECK_LOG_FILE:-$LOG_DIR/oalive-silent-check-$(date '+%Y%m%d-%H%M%S').log}

CONFIG_FILE=${OALIVE_CONFIG:-/etc/oalive/oalive.conf}
ENABLED_FILE=${OALIVE_ENABLED_CONFIG:-${OALIVE_ENABLED_FILE:-/etc/oalive/enabled.conf}}
CPU_CGROUP=/sys/fs/cgroup/system.slice/cpu-limit.service
MEMORY_CGROUP=/sys/fs/cgroup/system.slice/memory-limit.service

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

log() {
  printf '%s %s\n' "$(now)" "$*" >>"$LOG_FILE"
}

section() {
  log "===== $* ====="
}

compact() {
  printf '%s' "$*" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

read_kv() {
  file=$1
  key=$2
  awk -F= -v k="$key" '$1 == k {print $2; exit}' "$file" 2>/dev/null | sed "s/^'//; s/'$//"
}

service_line() {
  unit=$1
  active=unknown
  enabled=unknown
  active_rc=127
  enabled_rc=127
  if command -v systemctl >/dev/null 2>&1; then
    active_rc=0
    active=$(systemctl is-active "$unit" 2>&1) || active_rc=$?
    enabled_rc=0
    enabled=$(systemctl is-enabled "$unit" 2>&1) || enabled_rc=$?
    active=$(compact "$active")
    enabled=$(compact "$enabled")
  fi
  log "SERVICE unit=$unit active=$active active_rc=$active_rc enabled=$enabled enabled_rc=$enabled_rc"
}

timer_line() {
  unit=$1
  if command -v systemctl >/dev/null 2>&1; then
    timer_rc=0
    timer_out=$(systemctl show "$unit" \
      -p ActiveState -p SubState -p NextElapseUSecRealtime -p LastTriggerUSec \
      --no-pager 2>&1) || timer_rc=$?
    timer_out=$(compact "$timer_out")
    log "TIMER unit=$unit rc=$timer_rc $timer_out"
  else
    log "TIMER unit=$unit systemctl=missing"
  fi
}

cpu_usage_usec() {
  awk '/^usage_usec / {print $2}' "$CPU_CGROUP/cpu.stat" 2>/dev/null || echo 0
}

cpu_throttled_usec() {
  awk '/^throttled_usec / {print $2}' "$CPU_CGROUP/cpu.stat" 2>/dev/null || echo 0
}

machine_cpu_count() {
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -gt 0 ] || n=1
  printf '%s\n' "$n"
}

log_config() {
  section "config"
  if [ -r "$ENABLED_FILE" ]; then
    while IFS= read -r line; do
      case "$line" in
        CPU_ENABLED=*|MEMORY_ENABLED=*|BANDWIDTH_ENABLED=*) log "ENABLED $line" ;;
      esac
    done <"$ENABLED_FILE"
  else
    log "WARN enabled_file_unreadable path=$ENABLED_FILE"
  fi

  if [ -r "$CONFIG_FILE" ]; then
    for key in CPU_QUOTA_PERCENT CPU_CYCLE_SECONDS MEMORY_TARGET_PERCENT MEMORY_HOLD_SECONDS MEMORY_REST_SECONDS BANDWIDTH_INTERVAL_MINUTES BANDWIDTH_DURATION_MINUTES BANDWIDTH_RATE_MBPS BANDWIDTH_RATE_PERCENT BANDWIDTH_URL; do
      value=$(read_kv "$CONFIG_FILE" "$key")
      log "CONFIG $key=$value"
      if [ "$key" = CPU_QUOTA_PERCENT ] && [ -z "$value" ]; then
        log "WARN CPU_QUOTA_PERCENT is empty; cpu-limit.sh will fall back to its default"
      fi
    done
  else
    log "WARN config_unreadable path=$CONFIG_FILE"
  fi

  if [ -r /etc/systemd/system/cpu-limit.service.d/quota.conf ]; then
    while IFS= read -r line; do log "CPU_DROPIN $line"; done </etc/systemd/system/cpu-limit.service.d/quota.conf
  else
    log "WARN cpu_dropin_unreadable"
  fi
}

log_services() {
  section "services"
  service_line cpu-limit.service
  service_line memory-limit.service
  service_line bandwidth_occupier.timer
  service_line bandwidth_occupier.service
  timer_line bandwidth_occupier.timer
}

log_cgroups_once() {
  section "cgroups"
  if [ -r "$CPU_CGROUP/cpu.max" ]; then
    log "CPU_CGROUP cpu.max=$(cat "$CPU_CGROUP/cpu.max")"
  else
    log "WARN cpu_cgroup_missing path=$CPU_CGROUP"
  fi
  if [ -r "$CPU_CGROUP/cpu.stat" ]; then
    while IFS= read -r line; do log "CPU_CGROUP $line"; done <"$CPU_CGROUP/cpu.stat"
  fi
  if [ -r "$MEMORY_CGROUP/memory.current" ]; then
    log "MEMORY_CGROUP memory.current=$(cat "$MEMORY_CGROUP/memory.current")"
  fi
}

log_recent_logs() {
  section "recent_logs"
  for file in /var/log/oalive/cpu-limit.log /var/log/oalive/memory-limit.log /var/log/oalive/bandwidth_occupier.log; do
    if [ -r "$file" ]; then
      log "LOG_TAIL file=$file"
      tail -n 8 "$file" 2>/dev/null | while IFS= read -r line; do log "  $line"; done
    else
      log "WARN log_unreadable file=$file"
    fi
  done
}

mkdir -p "$LOG_DIR" 2>/dev/null || true
: >"$LOG_FILE"

log "START duration=${DURATION_SECONDS}s interval=${INTERVAL_SECONDS}s log=$LOG_FILE"
log_config
log_services
log_cgroups_once
log_recent_logs

cpu_count=$(machine_cpu_count)
prev_usage=$(cpu_usage_usec)
prev_throttled=$(cpu_throttled_usec)
elapsed=0

section "samples"
while [ "$elapsed" -lt "$DURATION_SECONDS" ]; do
  sleep "$INTERVAL_SECONDS"
  elapsed=$((elapsed + INTERVAL_SECONDS))
  usage=$(cpu_usage_usec)
  throttled=$(cpu_throttled_usec)
  du=$((usage - prev_usage))
  dt=$INTERVAL_SECONDS
  dthr=$((throttled - prev_throttled))
  awk -v elapsed="$elapsed" -v du="$du" -v dt="$dt" -v cpu_count="$cpu_count" -v dthr="$dthr" 'BEGIN {
    one = du / (dt * 1000000) * 100
    machine = one / cpu_count
    printf "%s SAMPLE elapsed=%ss cpu_service_one_cpu=%.2f%% cpu_service_machine_%svc=%0.2f%% throttled_delta_usec=%d\n", strftime("%Y-%m-%d %H:%M:%S"), elapsed, one, cpu_count, machine, dthr
  }' >>"$LOG_FILE"
  prev_usage=$usage
  prev_throttled=$throttled
done

log_services
log_recent_logs
log "END log=$LOG_FILE"

printf '%s\n' "$LOG_FILE"
