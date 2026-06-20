#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_FILE=${SOURCE_FILE:-$SCRIPT_DIR/bandwidth_occupier.sh}
LOG_FILE=${LOG_FILE:-/tmp/oalive-bandwidth-url-test.log}
RANGE_BYTES=${RANGE_BYTES:-1048575}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-5}
MAX_TIME=${MAX_TIME:-15}

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

log() {
  printf '%s %s\n' "$(now)" "$*" | tee -a "$LOG_FILE"
}

extract_urls() {
  awk '
    /^download_urls\(\)/ {in_func=1}
    in_func && /^URLS$/ {exit}
    in_func && /^(https?|ftp):\/\// {print}
  ' "$SOURCE_FILE"
}

resolve_host() {
  host=$1
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" 2>/dev/null | awk 'NR == 1 {print $1; exit}'
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" 2>/dev/null | awk 'NR == 1 {print; exit}'
    return 0
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2; exit}'
    return 0
  fi
  return 0
}

host_from_url() {
  printf '%s\n' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+).*#\1#'
}

test_url() {
  url=$1
  host=$(host_from_url "$url")
  ip=$(resolve_host "$host" | sed -n '1p')
  [ -n "$ip" ] || ip=unresolved

  tmp=$(mktemp "${TMPDIR:-/tmp}/oalive-url-test.XXXXXX")
  err=$(mktemp "${TMPDIR:-/tmp}/oalive-url-test-err.XXXXXX")
  if curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --range "0-$RANGE_BYTES" -A 'oalive-url-test/1.0' \
    -o "$tmp" \
    -w 'http=%{http_code} bytes=%{size_download} speed=%{speed_download} time=%{time_total} remote=%{remote_ip}' \
    "$url" >"$tmp.out" 2>"$err"; then
    result=$(cat "$tmp.out")
    log "OK host=$host ip=$ip $result url=$url"
  else
    rc=$?
    result=$(cat "$tmp.out" 2>/dev/null || true)
    error=$(tr '\n' ' ' <"$err" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//')
    [ -n "$result" ] || result='http=000 bytes=0 speed=0 time=0 remote='
    [ -n "$error" ] || error='curl failed'
    log "FAIL rc=$rc host=$host ip=$ip $result error=\"$error\" url=$url"
  fi
  rm -f "$tmp" "$tmp.out" "$err"
}

: >"$LOG_FILE"
log "START source=$SOURCE_FILE range=0-$RANGE_BYTES connect_timeout=${CONNECT_TIMEOUT}s max_time=${MAX_TIME}s"

count=0
ok=0
fail=0

extract_urls | while IFS= read -r url; do
  [ -n "$url" ] || continue
  count=$((count + 1))
  log "TEST index=$count url=$url"
  before=$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)
  test_url "$url"
  last=$(tail -n 1 "$LOG_FILE" 2>/dev/null || true)
  case "$last" in
    *' OK '*) ok=$((ok + 1)) ;;
    *' FAIL '*) fail=$((fail + 1)) ;;
  esac
done

ok=$(awk '/ OK / {n++} END {print n+0}' "$LOG_FILE")
fail=$(awk '/ FAIL / {n++} END {print n+0}' "$LOG_FILE")
total=$((ok + fail))
log "SUMMARY total=$total ok=$ok fail=$fail log=$LOG_FILE"
printf '%s\n' "$LOG_FILE"
