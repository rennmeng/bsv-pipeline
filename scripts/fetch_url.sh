#!/usr/bin/env bash
# ============================================================
# Generic dual-source downloader: retries the primary source N times,
# then automatically falls back to the backup source.
#
# Usage:
#   bash fetch_url.sh <primary-url> <backup-url> <output-file> [primary-tries=2] [backup-tries=3]
#
# Downloader order: curl -> wget -> python urllib (minimal containers
# often lack curl/wget). What counts as primary/backup is decided by the
# caller (e.g. GitHub primary + self-hosted mirror).
#
# Visibility & stall handling: downloads are silent, but any stall
# (<1 KB/s for 30 s) aborts the attempt quickly; each attempt reports
# the bytes received and the time spent.
# ============================================================
set -uo pipefail

PRIMARY="${1:?Usage: fetch_url.sh <primary-url> <backup-url> <output-file> [primary-tries] [backup-tries]}"
BACKUP="${2:?missing backup URL}"
OUT="${3:?missing output path}"
P_TRIES="${4:-2}"
B_TRIES="${5:-3}"

# Optional bandwidth cap (politeness toward self-hosted mirrors):
#   DL_RATE_LIMIT=2m    -> 2 MB/s per download   (default)
#   DL_RATE_LIMIT=500k  -> 500 KB/s
#   DL_RATE_LIMIT=      -> empty disables limiting
# Applies to curl / wget / python alike. DIA-NN (~380 MB) at 2 MB/s
# takes ~3.5 min - comfortably inside the rMATS window.
DL_RATE_LIMIT="${DL_RATE_LIMIT-2m}"   # ${VAR-}: only unset falls back, so empty = unlimited

dl() {  # dl <url> <output> <tries>  -> 0 success / 1 failure
    local url="$1" out="$2" tries="$3" i sz start cpid
    if command -v curl >/dev/null 2>&1; then
        # expected total size for the progress bar (empty if unavailable)
        local total
        total="$(curl -fsIL --connect-timeout 10 --max-time 20 "$url" 2>/dev/null | awk '{gsub(/\r/, ""); if (tolower($1) == "content-length:") v = $2} END {print v}' | tail -n1)"
        for ((i = 1; i <= tries; i++)); do
            if [[ -n "$total" ]]; then
                echo "RUN  Downloading ($i/$tries, $((total / 1048576)) MB): $url"
            else
                echo "RUN  Downloading ($i/$tries): $url"
            fi
            # fast-fail: 15 s connect probe; abort if stalled (<1 KB/s for 30 s)
            start=$SECONDS
            local rate_args=() resume_args=()
            [[ -n "$DL_RATE_LIMIT" ]] && rate_args=(--limit-rate "$DL_RATE_LIMIT")
            # resume: continue a partial file (FETCH_RESUME=1 set on escalation)
            [[ -n "${FETCH_RESUME:-}" && -s "$out" ]] && resume_args=(-C -)
            curl -fsSL --retry 2 --connect-timeout 15 --max-time 3600 \
                 --speed-time 30 --speed-limit 1024 "${rate_args[@]}" \
                 -o "$out" "$url" &
            local cpid=$!
            # record the curl PID so an impatient caller can stop it precisely
            [[ -n "$out" ]] && printf '%s' "$cpid" > "${out}.pid"
            # heartbeat (15 s) + stall watchdog (no growth for 30 s -> abort)
            local last=-1 shown=-1 stuck=0 sz
            while kill -0 "$cpid" 2>/dev/null; do
                sleep 15
                kill -0 "$cpid" 2>/dev/null || break
                sz=0; [[ -f "$out" ]] && sz=$(wc -c < "$out" 2>/dev/null || echo 0)
                if [[ "$sz" == "$last" ]]; then
                    stuck=$((stuck + 15))
                    if (( stuck >= 30 )); then
                        echo "WARN  stalled at $((sz / 1024)) KB - aborting attempt"
                        kill "$cpid" 2>/dev/null || true
                        break
                    fi
                else
                    stuck=0; last=$sz
                    if [[ -n "$total" ]]; then
                        local pct=$(( sz * 100 / total ))
                        local filled=$(( pct / 4 ))
                        local emp=$(( 25 - filled ))
                        local bar="" j
                        for ((j = 0; j < filled; j++)); do bar+="#"; done
                        for ((j = 0; j < emp;  j++)); do bar+="."; done
                        echo "       [${bar}] ${pct}%  ($((sz / 1048576))/$((total / 1048576)) MB)"
                    else
                        echo "       received $((sz / 1024)) KB"
                    fi
                fi
            done
            wait "$cpid" 2>/dev/null; local rc=$?
            rm -f "${out}.pid" 2>/dev/null || true
            if [[ $rc -eq 0 && -s "$out" ]]; then
                sz2=0; [[ -f "$out" ]] && sz2=$(wc -c < "$out" 2>/dev/null || echo 0)
                echo "OK  received $((sz2 / 1024)) KB in $(( ${SECONDS:-0} - start ))s"
                return 0
            fi
            sz2=0; [[ -f "$out" ]] && sz2=$(wc -c < "$out" 2>/dev/null || echo 0)
            echo "WARN  attempt failed after $(( ${SECONDS:-0} - start ))s, received $((sz2 / 1024)) KB"
            sleep 2
        done
    elif command -v wget >/dev/null 2>&1; then
        for ((i = 1; i <= tries; i++)); do
            echo "RUN  Downloading ($i/$tries): $url"
            start=$SECONDS
            local wget_rate=()
            [[ -n "$DL_RATE_LIMIT" ]] && wget_rate=(--limit-rate="$DL_RATE_LIMIT")
            wget --progress=bar:force --connect-timeout=15 --read-timeout=60 --tries=2 "${wget_rate[@]}" \
                 -O "$out" "$url"
            local wrc=$?
            if [[ $wrc -eq 0 && -s "$out" ]]; then
                sz=$(wc -c < "$out" 2>/dev/null || echo 0)
                echo "OK  received $((sz / 1024)) KB in $(( ${SECONDS:-0} - start ))s"
                return 0
            fi
            sz=0; [[ -f "$out" ]] && sz=$(wc -c < "$out" 2>/dev/null || echo 0)
            echo "WARN  attempt failed after $(( ${SECONDS:-0} - start ))s, received $((sz / 1024)) KB"
            sleep 2
        done
    else
        local py_bin
        py_bin="$(command -v python3 || command -v python)"
        "$py_bin" - "$url" "$out" "$tries" <<'PY'
import os, re, sys, time, urllib.request
url, out, tries = sys.argv[1], sys.argv[2], int(sys.argv[3])
# honour DL_RATE_LIMIT like curl/wget do (chunked copy, sleep to pace)
bps = None
limit = os.environ.get("DL_RATE_LIMIT", "")
m = re.fullmatch(r"(\d+)([kKmMgG]?)", limit.strip()) if limit else None
if m:
    mult = {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[m.group(2).lower()]
    bps = int(m.group(1)) * mult
for i in range(1, tries + 1):
    try:
        print(f"RUN  Downloading ({i}/{tries}): {url}", flush=True)
        req = urllib.request.Request(url, headers={"User-Agent": "BioSpliceView-pipeline"})
        t0, done = time.time(), 0
        with urllib.request.urlopen(req, timeout=30) as r, open(out, "wb") as f:
            while True:
                piece = r.read(65536)
                if not piece:
                    break
                f.write(piece)
                done += len(piece)
                if bps:
                    behind = done / bps - (time.time() - t0)
                    if behind > 0:
                        time.sleep(behind)
        if os.path.getsize(out) > 0:
            print(f"OK  received {os.path.getsize(out) // 1024} KB", flush=True)
            sys.exit(0)
        print("WARN  empty file", file=sys.stderr)
    except Exception as e:
        print(f"WARN  failed: {e}", file=sys.stderr)
    time.sleep(2)
sys.exit(1)
PY
        [[ $? -eq 0 ]] && return 0
    fi
    return 1
}

if dl "$PRIMARY" "$OUT" "$P_TRIES"; then
    echo "OK  Primary source OK: $PRIMARY"
    exit 0
fi
echo "WARN  Primary source failed ${P_TRIES}x, switching to backup ..."
if dl "$BACKUP" "$OUT" "$B_TRIES"; then
    echo "OK  Backup source OK: $BACKUP"
    exit 0
fi
echo "FAIL  Both primary and backup sources failed"
exit 1
