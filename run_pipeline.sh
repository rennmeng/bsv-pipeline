#!/usr/bin/env bash
# ============================================================
#  BioSpliceView end-to-end splicing pipeline (standalone)
#
#  FASTQ/BAM -> rMATS -> BioSpliceView -> search DB -> DIA-NN -> summary
#
#  Usage:
#    bash run_pipeline.sh <pipeline.conf>
#
#  * All tunable parameters live in the config file
#    (Part 1 = the only paths to edit)
#  * Tools are resolved from the managed conda env (CONDA_ENV_NAME, created
#    by environment.yml) first, then PATH; explicit config paths always win
#    - a new machine runs seamlessly after `conda env create -f environment.yml`
#  * Heavy tools log to files; the terminal shows conclusions only
#  * Interrupted runs resume in place; NO_COLOR=1 disables colors
# ============================================================
set -euo pipefail

CONF="${1:?Usage: bash run_pipeline.sh <pipeline.conf>}"
CONF="$(realpath "$CONF")"
# shellcheck source=/dev/null
source "$CONF"

# ------------------------------------------------------------
# Terminal styles
# ------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" ]]; then
    R='\033[0m'; B='\033[1m'; DIM='\033[2m'
    # status hues come in three brightness levels: bright (key message),
    # bold (tags), dim (secondary detail in the same hue)
    CYAN='\033[36m';  CB='\033[1;36m'; CD='\033[2;36m'
    GREEN='\033[32m'; GB='\033[1;32m'; GD='\033[2;32m'
    YELLOW='\033[33m'; YB='\033[1;33m'; YD='\033[2;33m'
    RED='\033[31m';   RB='\033[1;31m'; RD='\033[2;31m'
    WHITE='\033[97m'; WB='\033[1;97m'
    BLUE='\033[34m'; MAGENTA='\033[35m'
else
    R=''; B=''; DIM=''; BLUE=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; MAGENTA=''; WHITE=''
    CB=''; CD=''; GB=''; GD=''; YB=''; YD=''; RB=''; RD=''; WB=''
fi

# ------------------------------------------------------------
# Output language: boxes, tags, notes
# ------------------------------------------------------------
# Glyph set: braille dot spinner everywhere; block bar / middot only in
# Windows Terminal (WT_SESSION) or UNICODE_FANCY=1; NO_UNICODE=1 pure ASCII.
UI_H='─'
UI_BAR_F='#'; UI_BAR_E='.'; UI_SEP='|'; UI_ARROW='→'; UI_ELL='...'
UI_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)   # standard braille dot spinner, white, at line head
if [[ -n "${WT_SESSION:-}" || "${UNICODE_FANCY:-0}" == 1 ]]; then
    UI_BAR_F='█'; UI_BAR_E='░'; UI_SEP='·'
fi
if [[ "${NO_UNICODE:-0}" == 1 ]]; then
    UI_H='-'; UI_BAR_F='#'; UI_BAR_E='.'; UI_SEP='-'
    UI_ARROW='->'; UI_ELL='...'
    UI_SPIN=( '-' '\' '|' '/' )   # pure-ASCII fallback
fi

BOXW=64   # inner width of boxes (adapts to the terminal, clamped to 60..100)
if _tc="$( { stty size < /dev/tty; } 2>/dev/null | cut -d' ' -f2)" \
   && [[ "$_tc" =~ ^[0-9]+$ && "$_tc" -ge 62 ]]; then
    BOXW=$(( _tc - 2 )); (( BOXW > 100 )) && BOXW=100
fi

# headline <content-with-colors>: full-width section rule, content
# embedded after a double dash, padded to the terminal width
headline() {  # headline <content>
    local content="$1" vis fill rule
    vis=$(vislen "$content")
    fill=$(( BOXW + 2 - 3 - vis - 1 )); (( fill < 3 )) && fill=3
    rule=$(printf -- "${UI_H}%.0s" $(seq 1 $fill))
    echo -e "${DIM}── ${R}${content} ${DIM}${rule}${R}"
}

banner() {  # banner <n/total | label> <title> [subtitle] [timeline-label]
    local n="${1%%/*}" total="${1##*/}"
    local title="$2" sub="${3:-}" lbl="${4:-}" bar="" filled empty seg i head
    if [[ "$n" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]]; then
        head="${B}${CYAN}STAGE $n/$total${R} ${DIM}─${R} ${B}${WHITE}$title${R}"
        filled=$(( (n - 1) * 24 / total )); (( filled < 0 )) && filled=0
        empty=$(( 24 - filled )); seg=""
        for ((i = 0; i < filled; i++)); do seg+="$UI_BAR_F"; done
        bar="[${CYAN}${seg}${R}${DIM}$(printf -- "${UI_BAR_E}%.0s" $(seq 1 $empty))${R}]  progress ${B}${CYAN}${n}/${total}${R}"
    else
        head="${B}${WHITE}$title${R}"
    fi
    echo ""
    headline "$head"
    [[ -n "$sub" ]] && echo -e "  ${DIM}$sub${R}"
    [[ -n "$bar" ]] && echo -e "  $bar"
    STAGE_CUR="${lbl:-$1}"
}

# Tag functions paint the WHOLE line in the status hue, with brightness
# hierarchy inside it: bold tag, bright key message, dim secondary detail
# (paths in parentheses, log locations after "->", multi-line fix hints).
ok()   { local m lbl; m="$*"; lbl="OK  "; if [[ "$m" == *" -> "* ]]; then echo -e "${GB}${lbl}${R}  ${GREEN}${m%% -> *}${GD} -> ${m#* -> }${R}"; else echo -e "${GB}${lbl}${R}  ${GREEN}$m${R}"; fi; }
skip() { local m lbl; m="$*"; lbl="SKIP"; if [[ "$m" == *"("* ]]; then echo -e "${GB}${lbl}${R}  ${DIM}${m%%(*}${GD}(${m#*(}${R}"; else echo -e "${GB}${lbl}${R}  ${DIM}$m${R}"; fi; }
run_() { local m lbl; m="$*"; lbl="RUN "; if [[ "$m" == *"("* ]]; then echo -e "${CB}${lbl}${R}  ${CYAN}${m%%(*}${CD}(${m#*(}${R}"; else echo -e "${CB}${lbl}${R}  ${CYAN}$m${R}"; fi; }
have() { local m lbl; m="$*"; lbl="HAVE"; if [[ "$m" == *"("* ]]; then echo -e "${DIM}${lbl}${R}  ${DIM}${m%%(*}${DIM}(${m#*(}${R}"; else echo -e "${DIM}${lbl}${R}  ${DIM}$m${R}"; fi; }
warn() { echo -e "${YB}WARN${R}  ${YELLOW}$*${R}"; }
die()  { local m first rest; m="$*"; first="${m%%$'\n'*}"; rest="${m#*$'\n'}"; if [[ "$rest" != "$m" ]]; then echo -e "${RB}FAIL${R}  ${RED}$first${R}" >&2; echo -e "${DIM}${rest}${R}" >&2; else echo -e "${RB}FAIL${R}  ${RED}$m${R}" >&2; fi; exit 1; }
note() { echo -e "${DIM}      $*${R}"; }
kv() {  # kv <label> <value>: info line with a dim label, bright value
    local lbl
    printf -v lbl '%-8s' "$1"
    echo -e "  ${DIM}${lbl}${R} $2"
}
stage_begin() { STAGE_T0="${SECONDS:-0}"; }
stage_end() {
    local dt=$(( (${SECONDS:-0}) - STAGE_T0 ))
    STAGE_TIMELINE+=("${STAGE_CUR}|$dt")
    note "elapsed $(fmt_secs "$dt")"
}
fmt_secs() {  # seconds -> "1h 03m 12s" / "42s"
    local t="$1" h m s
    if (( t < 60 )); then echo "${t}s"; return; fi
    h=$(( t / 3600 )); m=$(( (t % 3600) / 60 )); s=$(( t % 60 ))
    if (( h > 0 )); then echo "${h}h $(printf '%02d' $m)m $(printf '%02d' $s)s"
    else echo "${m}m $(printf '%02d' $s)s"; fi
}
fmt_bytes() {  # bytes -> "813 B" / "12 kB" / "4.2 MB" / "1.8 GB"
    awk -v b="${1:-0}" 'BEGIN {
        if      (b < 1024)       printf "%d B",  b
        else if (b < 1048576)    printf "%d kB", b / 1024
        else if (b < 1073741824) printf "%.1f MB", b / 1048576
        else                     printf "%.1f GB", b / 1073741824
    }'
}
vislen() {  # vislen <text containing \033 escapes>: rendered char count
    printf '%b' "$1" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*[mK]//g' | wc -m | tr -d ' '
}

# Run a heavy tool with its output captured to a log file; the terminal
# only sees our conclusion lines. On failure, print the log tail.
tail_fail() {  # tail_fail <log>
    echo -e "${RED}[FAIL]${R} last lines of $1:" >&2
    { printf '%b' "$DIM"; tail -n 15 "$1" 2>/dev/null | sed "s/^/        /"; printf '%b' "$R"; } >&2
}
run_logged() {  # run_logged <log-file> <cmd> [args...]
    local log="$1"; shift
    if "$@" >"$log" 2>&1; then return 0; fi
    tail_fail "$log"
    return 1
}

# Sum of %cpu over a pid AND all of its descendants (each value is that
# process's lifetime average). The direct child of run_streamed is often a
# wrapper (rmats.py, DIA-NN) that just waits on worker children (STAR), so
# sampling the child alone reads ~0% while the whole tree is fully busy.
tree_cpu() {  # tree_cpu <root-pid>
    ps -eo pid=,ppid=,pcpu= 2>/dev/null | awk -v root="$1" '
        { cpu[$1] = $3; par[$1] = $2 }
        END {
            sum = 0
            for (p in par) {
                q = p
                while (q in par) {
                    if (q == root) { sum += cpu[p]; break }
                    q = par[q]
                }
            }
            printf "%.0f\n", sum
        }'
}

# Live status line support: while a streamed tool runs, ONE line is redrawn
# in place on the terminal (via /dev/tty, so the run log stays clean: only
# durable lines go to stdout). STREAM_BAR=0 disables it; without a tty
# (CI, pipes) the heartbeat falls back to plain per-beat lines.
bar_tty() {  # prints the tty path usable for live redraws, or nothing
    [[ "${STREAM_BAR:-1}" == "1" ]] || return 0
    # probe by writing (a bare CR): stat-based -w can pass on broken ttys
    { printf '\r' > /dev/tty; } 2>/dev/null || return 0
    echo /dev/tty
}
tty_clear_line() {  # tty_clear_line <tty-dev>: erase a drawn status line
    [[ -n "${1:-}" ]] || return 0
    { printf '\r\033[K' > "$1"; } 2>/dev/null || true
}

# Streamed run: full output to <log>, milestone lines matching
# STREAM_FILTER print live, plus one in-place status line on the tty.
# Call-site env: STREAM_HEARTBEAT=<s> (beat interval, default 45),
# STREAM_WATCH_DIR=<dir> (size shown), STREAM_TOTAL=<n> +
# STREAM_COUNT_CMD=<cmd> (+ STREAM_UNIT=<name>) for a real progress bar.
# The tool's exit code is preserved; on failure the log tail is printed.
run_streamed() {  # run_streamed <log-file> <cmd> [args...]
    local log="$1"; shift
    local filter="${STREAM_FILTER:-.}"
    local hb="${STREAM_HEARTBEAT:-45}"   # liveness heartbeat interval in s; 0 = off
    mkdir -p "$(dirname "$log")"
    : > "$log"
    "$@" >"$log" 2>&1 &
    local pid=$!
    local tty_dev="${STREAM_BAR_TTY:-$(bar_tty)}"   # probe once, shared below
    STREAM_TTY_DEV="$tty_dev"   # for the INT/TERM trap's line clear
    # the animator's orphan guard needs the MAIN script's pid: inside a ()
    # subshell both $$ and PPID keep the OUTER shell's values, so capture
    # it here ($$ is the main script even when run_streamed runs in the
    # per-stage subshell) and hand it down explicitly
    local main_pid
    main_pid="$$"
    # live milestone stream: tail the log through the stage filter
    local last_file="$log.last"
    rm -f "$last_file"   # a stale milestone from a previous run would mislead the "last:" field
    ( tail -f -n +1 --pid="$pid" "$log" 2>/dev/null \
        | grep --line-buffered -iE "$filter" \
        | while IFS= read -r l; do
              [[ -n "$l" ]] || continue
              tty_clear_line "$tty_dev"   # keep the milestone clear of the bar
              note "$l"
              printf '%s' "$l" > "$last_file"
          done ) &
    local mon=$!
    # liveness heartbeat -> ONE in-place status line on the terminal:
    # ⠸ [████████████░░░░░░░░] 60% 3/5 samples · 12m 03s · CPU 6.4/8 cores · 14G
    # The spinner animates continuously (~10 fps) so liveness is visible at
    # a glance; the stats refresh once per beat (STREAM_HEARTBEAT). A real
    # bar needs a countable total (STREAM_TOTAL + STREAM_COUNT_CMD at the
    # call site); otherwise spinner + elapsed / tree CPU / watched dir /
    # last milestone. No fake percentages without a denominator. Without a
    # tty the heartbeat falls back to one plain line per beat.
    if (( hb > 0 )); then
        ( TTY="$tty_dev"
          MAIN_PID="$main_pid"
          NCPU="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
          SPIN=("${UI_SPIN[@]}"); SI=0
          SPIN_DELAY=0.1
          sleep "$SPIN_DELAY" 2>/dev/null || SPIN_DELAY=1   # busybox fallback
          # stats refresh at least every 5s even while animating (a 45s
          # beat otherwise freezes elapsed/CPU/counter between beats)
          local anim_secs
          anim_secs=$hb
          (( anim_secs > 5 )) && anim_secs=5
          while kill -0 "$pid" 2>/dev/null; do
              local cpu=0
              command -v ps >/dev/null 2>&1 && cpu="$(tree_cpu "$pid")"
              local cpu_txt="CPU ${cpu}%"
              if [[ "$NCPU" =~ ^[0-9]+$ && "$NCPU" -gt 0 ]]; then
                  cpu_txt="CPU $(awk -v c="$cpu" -v n="$NCPU" 'BEGIN{printf "%.1f/%d", c/100, n}') cores"
              fi
              local out=""
              if [[ -n "${STREAM_WATCH_DIR:-}" ]]; then
                  local osz; osz="$(du -sh "$STREAM_WATCH_DIR" 2>/dev/null | cut -f1)"
                  [[ -n "$osz" ]] && out=" ${UI_SEP} $osz"
              fi
              local ms="-"
              if [[ -f "$last_file" ]]; then
                  # strip log prefixes (timestamps/levels) and STAR's
                  # leading dot separators - they eat the width budget
                  # without adding information
                  ms="$(tail -n 1 "$last_file" 2>/dev/null | sed -E $'s/^[0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]+[A-Z]+[ \t]+//; s/^[A-Z][a-z]{2}[ \t]+[ 0-9][0-9][ \t]+[0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]+//; s/^[.]+[ \t]*//')"
                  [[ -n "$ms" ]] || ms="-"
              fi
              local prog=""
              if [[ "${STREAM_TOTAL:-0}" =~ ^[0-9]+$ && "${STREAM_TOTAL:-0}" -gt 0 && -n "${STREAM_COUNT_CMD:-}" ]]; then
                  local d; d="$( { eval "$STREAM_COUNT_CMD"; } 2>/dev/null )"
                  [[ "$d" =~ ^[0-9]+$ ]] || d=0
                  (( d > STREAM_TOTAL )) && d="$STREAM_TOTAL"
                  # NB: never compute a local from another local declared in
                  # the SAME local statement - expansion may run before the
                  # earlier assignment lands (observed on bash 5.3 subshells)
                  local cells=20 f=0 i seg=""
                  f=$(( d * cells / STREAM_TOTAL ))
                  for ((i = 0; i < f;    i++)); do seg+="$UI_BAR_F"; done
                  for ((i = f; i < cells; i++)); do seg+="$UI_BAR_E"; done
                  # step-level bar is GREEN: distinct from the CYAN overall
                  # stage-progress bar in the banner
                  prog=" [${GREEN}${seg}${R}] ${B}${WHITE}$(( d * 100 / STREAM_TOTAL ))%${R} ${d}/${STREAM_TOTAL} ${STREAM_UNIT:-steps}"
                  # the counter may hit its ceiling while the tool is still
                  # working (rMATS maps all samples, then quantifies) - say so
                  # instead of letting a full bar spin like a hang
                  (( d >= STREAM_TOTAL )) && prog+=" ${DIM}(wrapping up)${R}"
              fi
              # clamp the line to a width KNOWN to render on this terminal:
              # the box width (+2 borders) fits by construction, while the
              # pty-reported width can LIE (some SSH clients report more
              # columns than they render) and a wrapped status line cannot
              # be redrawn in place - every refresh scrolls instead.
              # STATUS_COLS=<n> (env or config) forces a smaller ceiling.
              # The elapsed time is assumed at its widest (10 chars, "1h
              # 03m 12s") and is re-rendered EVERY animation frame, so the
              # seconds tick live between stats refreshes.
              local rest_txt tail_rest budget maxline live vis
              maxline=$(( BOXW + 2 ))
              live="$( { stty size < /dev/tty; } 2>/dev/null | cut -d' ' -f2 )"
              if [[ "$live" =~ ^[0-9]+$ && "$live" -ge 20 ]] && (( live < maxline )); then
                  maxline=$live
              fi
              local sc="${STATUS_COLS:-${status_cols:-}}"
              if [[ "$sc" =~ ^[0-9]+$ ]] && (( sc < maxline )); then
                  maxline=$sc
              fi
              local sep1=" ${UI_SEP} "
              [[ -z "$prog" ]] && sep1=""   # spinner-only mode: no leading separator
              rest_txt="${cpu_txt}${out}"
              vis=$(( 2 + $(vislen "$prog") + 3 + 10 + 3 + ${#rest_txt} + 9 ))   # +2 = trailing space + spinner
              if (( vis > maxline )); then
                  out=""
                  rest_txt="${cpu_txt}"
                  prog="${prog/" ${DIM}(wrapping up)${R}"/}"
                  vis=$(( 2 + $(vislen "$prog") + 3 + 10 + 3 + ${#rest_txt} + 9 ))   # +2 = trailing space + spinner
              fi
              budget=$(( maxline - vis ))
              if (( budget >= 8 )); then
                  [[ "$ms" == "-" ]] || ms="${ms:0:budget}"
                  tail_rest=" ${UI_SEP} last: ${ms}"
              else
                  tail_rest=""
              fi
              if [[ -n "$TTY" ]]; then
                  # animate the spinner AND the elapsed seconds between stats
                  # refreshes (cpu/counter/last stay per-refresh); NB: declare
                  # THEN assign - see the local-expansion note above
                  local steps t el_txt
                  steps=$anim_secs
                  [[ "$SPIN_DELAY" == 0.1 ]] && steps=$(( anim_secs * 10 ))
                  for ((t = 0; t < steps; t++)); do
                      kill -0 "$pid" 2>/dev/null || break 2
                      # orphan guard: if the main script died for any
                      # reason, stop drawing within one frame ($$ and PPID
                      # are useless in a subshell - see MAIN_PID above)
                      kill -0 "$MAIN_PID" 2>/dev/null || exit
                      el_txt="$(fmt_secs $(( ${SECONDS:-0} - STAGE_T0 )))"
                      # spinner via %s (a '\' frame through %b would fuse
                      # with the next code and print "033[0m"); elapsed via
                      # %s too - the surrounding escape codes ride with %b
printf '\r\033[K%b%s%b%s%b%s%b' "${WB}" "${SPIN[SI]}" "${R}${prog}${DIM} ${UI_SEP} ${B}" "${el_txt}" "${R}${DIM} ${UI_SEP} ${rest_txt}${tail_rest}${R}" > "$TTY" 2>/dev/null
                      SI=$(( (SI + 1) % ${#SPIN[@]} ))
                      sleep "$SPIN_DELAY"
                  done
              else
                  local el_txt
                  el_txt="$(fmt_secs $(( ${SECONDS:-0} - STAGE_T0 )))"
                  local sz=0; [[ -f "$log" ]] && sz=$(wc -c < "$log" 2>/dev/null || echo 0)
                  echo -e "${WB}${SPIN[SI]}${R} still working${prog}${sep1}${B}${el_txt}${R}${DIM} ${UI_SEP} ${rest_txt} ${UI_SEP} log $(fmt_bytes "$sz")${tail_rest} ${CYAN}${SPIN[SI]}${R}"
                  SI=$(( (SI + 1) % ${#SPIN[@]} ))
                  sleep "$hb"
              fi
          done ) &
        local hb_out=$!
    fi
    wait "$pid"; local rc=$?
    [[ -n "${hb_out:-}" ]] && kill "$hb_out" 2>/dev/null || true
    [[ -n "${mon:-}" ]] && kill "$mon" 2>/dev/null || true
    tty_clear_line "$tty_dev"
    sleep 1   # let the tail drain
    if [[ $rc -ne 0 ]]; then tail_fail "$log"; return "$rc"; fi
    return 0
}

# ------------------------------------------------------------
# Tool resolution: current environment first, then the environment.yml
# install location; explicit paths (star_bin / rmats_py) always win
# ------------------------------------------------------------
child_pids() {  # child_pids <pid>: direct children, one pid per line
    local pids stat
    pids="$(pgrep -P "$1" 2>/dev/null)" && { [[ -n "$pids" ]] && echo "$pids"; return 0; }
    if [[ -d /proc ]]; then
        for stat in /proc/[0-9]*/stat; do
            [[ -r "$stat" ]] || continue
            read -r _p _comm _state ppid _rest < "$stat" 2>/dev/null || continue
            [[ "$ppid" == "$1" ]] && echo "$_p"
        done
    fi
    return 0
}

kill_tree() {  # kill_tree <pid>: kill a process and all its descendants
    local pid="$1" kid
    for kid in $(child_pids "$pid"); do kill_tree "$kid"; done
    kill "$pid" 2>/dev/null || true
}

# Ctrl-C / kill must take down the whole tree: background children of a
# non-interactive shell inherit SIGINT ignored (POSIX), so without help
# the tool, the log monitor and the status-line animator would survive as
# orphans and keep drawing to the terminal ("cannot terminate").
on_signal() {
    trap '' INT TERM   # mash-proof: further Ctrl-C cannot abort the teardown
    tty_clear_line "${STREAM_TTY_DEV:-}" 2>/dev/null || true
    echo "" >&2
    echo -e "${RED}[FAIL]${R} interrupted - rerun the same command to resume (completed stages are reused)" >&2
    local kid
    for kid in $(child_pids "$$"); do kill_tree "$kid"; done
    # final sweep: the whole tree shares this process group, so this
    # reaches anything the enumeration missed; it also TERM's this shell
    # (traps are ignored now) - the teardown is done either way
    kill -TERM -- "-$$" 2>/dev/null || true
    sleep 0.3          # grace for TERM, then KILL whatever is left
    for kid in $(child_pids "$$"); do kill -9 "$kid" 2>/dev/null || true; done
    kill -KILL -- "-$$" 2>/dev/null || true
    exit 130
}
trap on_signal INT TERM

conda_env_bin() {
    local base="" env_name="${CONDA_ENV_NAME:-bsv-pipeline}"
    if [[ -n "${CONDA_BASE:-}" ]]; then base="$CONDA_BASE"
    elif command -v conda >/dev/null 2>&1; then base="$(conda info --base 2>/dev/null || true)"
    elif [[ -n "${MAMBA_ROOT_PREFIX:-}" ]]; then base="$MAMBA_ROOT_PREFIX"
    fi
    [[ -n "$base" && -d "$base/envs/$env_name/bin" ]] || return 1
    echo "$base/envs/$env_name/bin"
}

# Automatic tool resolution order: the MANAGED ENV first (CONDA_ENV_NAME,
# created by environment.yml - version-pinned and complete), then PATH,
# then the active conda env. This is what makes a new machine run
# seamlessly: after `conda env create -f environment.yml` the pipeline
# finds everything from any shell, without activating anything. Explicit
# config paths (star_bin / rmats_py / bsv_repo / python_bin) always win.
find_tool() {  # find_tool <binary-name>: prints the path, or returns 1
    local name="$1" env_bin=""
    if env_bin="$(conda_env_bin)" && [[ -x "$env_bin/$name" ]]; then
        echo "$env_bin/$name"
        return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    if [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/$name" ]]; then
        echo "$CONDA_PREFIX/bin/$name"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# rMATS samples: explicit lists win; otherwise prefix auto-discovery
# in fastq_dir (paired: R1/R2 mate pairing by common naming patterns)
# ------------------------------------------------------------
resolve_group() {  # resolve_group <group-name> <current-list>; result stdout, progress stderr
    local name="$1" val="$2"
    if [[ -n "$val" ]]; then
        have "$name samples: using explicit list" >&2
        echo "$val"
        return 0
    fi
    [[ -n "${fastq_dir:-}" ]] || die "Group $name has no samples: set group1_samples / group2_samples explicitly in the config, or fastq_dir for prefix auto-discovery" >&2
    [[ -d "$fastq_dir" ]]     || die "fastq_dir not found: $fastq_dir" >&2
    local r1 r2 cand f pair list="" n=0
    for r1 in "$fastq_dir"/"$name"-* "$fastq_dir"/"$name"_*; do
        [[ -f "$r1" ]] || continue
        case "$r1" in
            *_R1.*|*.R1.*|*_R1_*|*_1.*|*.1.fq*|*.1.fastq*) ;;
            *) continue ;;
        esac
        if [[ "$read_type" == "paired" ]]; then
            r2=""
            for cand in "${r1/_R1./_R2.}" "${r1/.R1./.R2.}" "${r1/_R1_/_R2_}" "${r1/_1./_2.}" "${r1/.1./.2.}"; do
                [[ "$cand" != "$r1" && -f "$cand" ]] && { r2="$cand"; break; }
            done
            [[ -n "$r2" ]] || die "No R2 mate found for: $r1 (check naming, or use explicit sample lists)" >&2
            pair="$r1:$r2"
        else
            pair="$r1"
        fi
        list="${list:+$list,}$pair"
        n=$((n + 1))
    done
    if [[ $n -eq 0 && "$read_type" == "single" ]]; then
        for f in "$fastq_dir"/"$name"-* "$fastq_dir"/"$name"_*; do
            [[ -f "$f" ]] || continue
            case "$f" in *.fq|*.fq.gz|*.fastq|*.fastq.gz)
                list="${list:+$list,}$f"; n=$((n + 1)) ;;
            esac
        done
    fi
    [[ $n -gt 0 ]] || die "No '$name'-prefixed samples found in $fastq_dir" >&2
    list="$(echo "$list" | tr ',' '\n' | sort -t: -k1,1V | paste -sd, -)"
    run_ "Group $name: auto-discovered $n samples" >&2
    local p r1p r2p
    for p in ${list//,/ }; do
        r1p="${p%%:*}"; r2p="${p#*:}"
        if [[ "$p" == *:* && "$r1p" != "$r2p" ]]; then
            note "$(basename "$r1p")  +  $(basename "$r2p")" >&2
        else
            note "$(basename "$p")" >&2
        fi
    done
    echo "$list"
}

# ------------------------------------------------------------
# MS raw files: explicit lists win; otherwise prefix discovery in
# ms_dir (Bruker .d directory / Thermo .raw file, case-insensitive)
# ------------------------------------------------------------

# ------------------------------------------------------------
# DIA-NN — prepared in parallel with the transcriptome stages:
#   start_diann_background : fire-and-forget (called at the Stage 1 entry)
#   wait_diann             : collect before the DIA-NN search (Stage 4)
# Resolution: config diann_bin -> image bundle -> ref/ cache -> download
# ------------------------------------------------------------
diann_complete() {  # diann_complete <bin>: binary + its models/dict.txt
    [[ -x "$1" && -f "$(dirname "$1")/models/dict.txt" ]]
}

start_diann_background() {
    DIANN_BG_PID=""
    diann_version="${diann_version:-2.6.1}"
    export DIANN_VERSION="$diann_version"      # consumed by scripts/install_diann.sh
    if [[ -n "$diann_bin" && ! -x "$diann_bin" ]]; then
        warn "Configured diann_bin not found: $diann_bin - switching to the automatic DIA-NN installation"
        diann_bin=""
    fi
    if [[ -n "$diann_bin" ]] && ! diann_complete "$diann_bin"; then
        warn "Configured diann_bin lacks ./models/dict.txt - switching to the managed ref/diann install"
        diann_bin=""
    fi
    if [[ -n "$diann_bin" ]]; then
        have "DIA-NN ready ($diann_bin)"
        return 0
    fi
    if [[ -x /opt/diann/diann-linux ]] && diann_complete /opt/diann/diann-linux; then
        diann_bin="/opt/diann/diann-linux"   # bundled at docker build time
        have "DIA-NN ready ($diann_bin, bundled)"
        return 0
    fi
    if diann_complete "$REF_DIR/diann/diann-linux"; then
        diann_bin="$REF_DIR/diann/diann-linux"
        have "DIA-NN ready ($diann_bin)"
        return 0
    fi
    if [[ -x "$REF_DIR/diann/diann-linux" ]]; then
        warn "DIA-NN installation incomplete (models/dict.txt absent) - reinstalling automatically before use"
        rm -rf "$REF_DIR/diann/models"
        rm -f "$REF_DIR/diann/diann-linux"
    fi
    diann_bin="$REF_DIR/diann/diann-linux"
    run_ "DIA-NN not installed yet - downloading 2.6.1 in the background now; it will be ready before Stage 4 (runs alongside the STAR index build and rMATS)"
    mkdir -p "$REF_DIR/diann"
    ( bash "$SCRIPT_DIR/scripts/install_diann.sh" "$REF_DIR/diann" \
        >"$REF_DIR/diann/install.log" 2>&1 ) &
    DIANN_BG_PID=$!
    note "download log: $REF_DIR/diann/install.log"
}

wait_diann() {
    [[ -n "$diann_bin" ]] || diann_bin="$REF_DIR/diann/diann-linux"
    if diann_complete "$diann_bin"; then
        have "DIA-NN ready ($diann_bin)"
        return 0
    fi
    [[ -x "$diann_bin" ]] && warn "DIA-NN installation incomplete (models/dict.txt absent) - reinstalling before the search"
    if [[ -n "$DIANN_BG_PID" ]] && kill -0 "$DIANN_BG_PID" 2>/dev/null; then
        # limited background download still running + user blocked here:
        # stop it and resume the remainder at full speed
        warn "Still downloading at limited speed - escalating to full speed (you are waiting)"
        local pid_file="$REF_DIR/diann/diann.zip.part.pid"
        [[ -f "$pid_file" ]] && {
            kill "$(cat "$pid_file")" 2>/dev/null || true
            rm -f "$pid_file"
        }
        kill_tree "$DIANN_BG_PID"
        sleep 1
    fi
    rm -rf "$REF_DIR/diann/models"          # drop any partial models dir
    [[ -x "$diann_bin" ]] && rm -f "$diann_bin"
    # the user is blocked here: hit the verified mirror first (GitHub already proved unreachable)
    DIANN_URL_PRIMARY="https://www.spliceview.cn/static/files/DIA-NN-${diann_version}-Academia-Linux.zip"
    run_ "Installing DIA-NN v$diann_version (log: $REF_DIR/diann/install.log)"
    FETCH_RESUME=1 DL_RATE_LIMIT="" \
        run_streamed "$REF_DIR/diann/install.log" \
        bash "$SCRIPT_DIR/scripts/install_diann.sh" "$REF_DIR/diann" \
        || die "DIA-NN install failed - see $REF_DIR/diann/install.log"
    diann_complete "$diann_bin" \
        || die "DIA-NN installed but models/dict.txt is still missing - the mirror package may be incomplete"
    ok "DIA-NN ready ($diann_bin)"
}

# ------------------------------------------------------------
# Startup
# ------------------------------------------------------------
: "${work_dir:?set work_dir in the config}"
: "${job_id:?set job_id in the config}"
[[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "job_id may only contain letters, digits, dot, dash, underscore (got: $job_id)"
mkdir -p "$work_dir" 2>/dev/null \
    || die "Cannot create work directory: $work_dir — permission denied or invalid path. Set work_dir to a writable absolute path"

LOG_DIR="$work_dir/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${job_id}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(sed -u 's/\x1B\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

T0="${SECONDS:-0}"
STAGE_TIMELINE=()

# ------------------------------------------------------------
# Run mode: full (stages 1-5, incl. proteomics) | splicing (stages 1-2:
# rMATS + BioSpliceView annotation / GenBank splice-alteration views)
# Precedence: env PIPELINE_MODE > config mode > splicing
# ------------------------------------------------------------
PIPELINE_MODE="${PIPELINE_MODE:-${mode:-splicing}}"
PIPELINE_MODE="${PIPELINE_MODE,,}"
[[ "$PIPELINE_MODE" =~ ^(full|splicing)$ ]] \
    || die "mode must be 'full' or 'splicing' (config mode= / env PIPELINE_MODE; got: $PIPELINE_MODE)"
IS_FULL=1; [[ "$PIPELINE_MODE" == "splicing" ]] && IS_FULL=0
STAGE_TOTAL=5; [[ "$PIPELINE_MODE" == "splicing" ]] && STAGE_TOTAL=2

echo ""
headline "${B}${CYAN}BioSpliceView${R} ${DIM}─${R} ${B}${WHITE}end-to-end splicing pipeline${R}"
echo -e "  ${DIM}FASTQ ${UI_ARROW} rMATS ${UI_ARROW} BioSpliceView ${UI_ARROW} search DB ${UI_ARROW} DIA-NN ${UI_ARROW} summary${R}"
kv "job:" "$B$WHITE$job_id$R   ${DIM}mode: $PIPELINE_MODE (stages 1-$STAGE_TOTAL)${R}"
kv "workdir:" "$work_dir ${DIM}(ref/ = shared cache, jobs/$job_id/ = this job)${R}"
kv "config:" "$CONF"
kv "log:" "$LOG_FILE"

# ------------------------------------------------------------
# Defaults (reference configuration)
# ------------------------------------------------------------
threads="${threads:-16}"; min_aa="${min_aa:-10}"; p_cutoff="${p_cutoff:-0.05}"
dl_rate_limit="${dl_rate_limit-2m}"   # ${dl_rate_limit-}: only unset falls back, so empty = unlimited
export DL_RATE_LIMIT="$dl_rate_limit"      # download bandwidth cap (empty = unlimited)
read_type="${read_type:-paired}"; read_length="${read_length:-150}"
fdr="${fdr:-0.05}"; psi="${psi:-0.05}"; minjc="${minjc:-10}"
diann_version="${diann_version:-2.6.1}"
# Full DIA-NN tuning flags, passed verbatim to BOTH commands (4a library +
# 4b search); the pipeline appends only the file-management arguments
# (--fasta/--lib/--f/--out-lib/--out) after them. This ONE string is the
# DIA-NN configuration - edit it in the config to retune the search.
# DDA data: add --dda to the string.
diann_params="${diann_params:-}"
if [[ -z "$diann_params" ]]; then
    diann_params="--threads $threads --verbose 1 --qvalue 0.01 --semi --rt-profiling --direct-quant --ids-to-names --min-pep-len 7 --max-pep-len 30 --min-pr-mz 300 --max-pr-mz 1800 --min-pr-charge 1 --max-pr-charge 4 --min-fr-mz 200 --max-fr-mz 1800 --cut K*,R* --missed-cleavages 1 --unimod4 --met-excision"
fi
diann_bin="${diann_bin:-}"            # resolved in Stage 0c / start_diann_background
DIANN_BG_PID=""                       # background download PID (set at the Stage 1 entry)

: "${gtf:?set gtf}" "${genome_fa:?set genome_fa}" \
  "${group1:?set group1}" "${group2:?set group2}"
[[ -f "$gtf" ]]       || die "gtf not found: $gtf"
[[ -f "$genome_fa" ]] || die "Genome FASTA not found: $genome_fa"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Workspace layout
# ------------------------------------------------------------
REF_DIR="$work_dir/ref"                       # shared cache (reused across jobs)
JOB_DIR="$work_dir/jobs/$job_id"              # all outputs of this job
mkdir -p "$REF_DIR" "$JOB_DIR"

# ============================================================
banner "0/$STAGE_TOTAL" "Resource preparation & preflight" "cache-first: ref/ and explicit paths" "preflight"
# ============================================================
stage_begin

# --- 0a Background proteome ---
if [[ "$IS_FULL" == "1" ]]; then
uniprot_fasta="${uniprot_fasta:-}"
if [[ -z "$uniprot_fasta" ]]; then
    [[ -n "${species:-}" ]] || die "Background proteome: set uniprot_fasta or species"
    uniprot_fasta="$REF_DIR/uniprot_${species,,}.fasta"
fi
if [[ -f "$uniprot_fasta" ]]; then
    have "Background proteome ready ($uniprot_fasta)"
else
    [[ -n "${species:-}" ]] || die "uniprot_fasta not found: $uniprot_fasta"
    run_ "Downloading UniProt reviewed proteome (species=$species, log: $REF_DIR/uniprot_download.log)"
    STREAM_FILTER="uniprot|entries|saved|download|error" STREAM_HEARTBEAT=15 \
    STREAM_WATCH_DIR="$REF_DIR" \
    run_streamed "$REF_DIR/uniprot_download.log" \
        bash "$SCRIPT_DIR/scripts/fetch_background_fasta.sh" "$species" "$uniprot_fasta" \
    || die "UniProt download failed - see $REF_DIR/uniprot_download.log"
fi
else
    have "Background proteome not required (PIPELINE_MODE=splicing)"
fi

# --- 0-pre: DIA-NN background download (full mode) ---
# starts after the proteome fetch completes (no mirror bandwidth
# overlap), still overlapping the STAR index build + the rMATS
# alignment; Stage 4 collects it via wait_diann
if [[ "$IS_FULL" == "1" ]]; then
    start_diann_background
fi

# --- 0b STAR: locate, then verify the pinned version ---
star_version="${star_version:-2.7.10b}"   # pinned version; empty skips the check
star_bin="${star_bin:-}"
if [[ -z "$star_bin" && -n "${rmats_py:-}" ]]; then
    [[ -x "$(dirname "$rmats_py")/STAR" ]] && star_bin="$(dirname "$rmats_py")/STAR"
fi
[[ -z "$star_bin" ]] && star_bin="$(find_tool STAR || true)"
if [[ -z "$star_bin" ]]; then
    BASE_HINT="$(conda info --base 2>/dev/null || echo '<conda-base>')"
    die "STAR not found (looked in: managed env '${CONDA_ENV_NAME:-bsv-pipeline}', PATH, active env).
       environment.yml installs STAR at: $BASE_HINT/envs/${CONDA_ENV_NAME:-bsv-pipeline}/bin/STAR
       fixes (any):
         1) conda env create -f environment.yml && conda activate ${CONDA_ENV_NAME:-bsv-pipeline}
         2) conda install -c bioconda star=$star_version
         3) set star_bin in the config"
fi
STAR_V="$("$star_bin" --version 2>/dev/null | head -n1 | awk '{print $1}')"
if [[ -n "$star_version" && "$STAR_V" != "$star_version" ]]; then
    die "STAR version mismatch:
       found : $star_bin (v$STAR_V)
       needed: v$star_version (pinned reference version)
       fix   : conda install -n ${CONDA_ENV_NAME:-bsv-pipeline} -c bioconda star=$star_version"
fi
star_note=""
[[ -n "$STAR_V" ]] && star_note=", v$STAR_V"
[[ -n "$star_version" ]] && star_note="${star_note}, matches the pinned version"
have "STAR ready ($star_bin$star_note)"

star_index="${star_index:-$REF_DIR/star_index}"
star_index_ok() {  # the files STAR needs before it can even load a genome
    [[ -s "$1/genomeParameters.txt" && -s "$1/Genome" && -s "$1/SA" ]]
}
if [[ -d "$star_index" ]] && star_index_ok "$star_index"; then
    have "STAR index ready, skipping build ($star_index)"
else
    if [[ -d "$star_index" ]]; then
        warn "Existing STAR index is incomplete (likely an interrupted build) - rebuilding it now; the finished index will be cached"
    fi
    run_ "Building STAR index (first run: 10-30 min; reused afterwards)"
    # progress: genomeGenerate drops 5 checkpoint files in this order
    STAR_CK="{ for f in genomeParameters.txt Genome sjdbList.out.tab SA; do [ -e '$star_index/'\$f ] && echo x; done; ls '$star_index'/genomeSAsuffix.* >/dev/null 2>&1 && echo x; true; } | wc -l"
    STREAM_TOTAL=5 STREAM_UNIT="phases" STREAM_COUNT_CMD="$STAR_CK" \
    STREAM_FILTER="^[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2}|EXITING|FATAL" \
    STREAM_WATCH_DIR="$star_index" \
    run_streamed "$REF_DIR/star_index_build.log" \
        env STAR_BIN="$star_bin" READ_LENGTH_OVERRIDE="$((read_length - 1))" \
            bash "$SCRIPT_DIR/scripts/build_star_index.sh" \
            "$genome_fa" "$gtf" "$star_index" "$threads" \
    || die "STAR index build failed — see $REF_DIR/star_index_build.log"
    star_index_ok "$star_index" \
        || die "STAR index build reported success but validation fails on $star_index - check permissions (ls -la) and $REF_DIR/star_index_build.log"
    ok "STAR index built ($star_index)"
fi

# --- 0c Environment preflight (fail fast) ---
# python for the helper scripts (merge_db.py / summarize_splice_peptides.py):
# they import pandas, so candidates are validated by CAPABILITY - the first
# interpreter that can actually import pandas wins. Automatic order: the
# managed env (environment.yml includes pandas) first, then PATH, then the
# active conda env; a PATH python without pandas (a random active env) is
# skipped. Explicit python_bin is validated strictly.
PYTHON_BIN=""
if [[ -n "${python_bin:-}" ]]; then
    # explicit config override: validated strictly (this is user intent)
    if "$python_bin" -c 'import pandas' >/dev/null 2>&1; then
        PYTHON_BIN="$python_bin"
    else
        die "python_bin in the config ($python_bin) cannot import pandas - the helper scripts need it.
       fix: pip install pandas into that interpreter, or point python_bin at one that has it"
    fi
fi
if [[ -z "$PYTHON_BIN" ]]; then
    py_cands=()
    if ENV_BIN="$(conda_env_bin)" && [[ -x "$ENV_BIN/python" ]]; then
        py_cands+=("$ENV_BIN/python")
    fi
    command -v python  >/dev/null 2>&1 && py_cands+=("$(command -v python)")
    command -v python3 >/dev/null 2>&1 && py_cands+=("$(command -v python3)")
    [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/python" ]] && py_cands+=("$CONDA_PREFIX/bin/python")
    for pc in ${py_cands[@]+"${py_cands[@]}"}; do
        if "$pc" -c 'import pandas' >/dev/null 2>&1; then PYTHON_BIN="$pc"; break; fi
    done
    if [[ -z "$PYTHON_BIN" ]]; then
        BASE_HINT="$(conda info --base 2>/dev/null || echo '<conda-base>')"
        die "no python with pandas found for the helper scripts (tried: ${py_cands[*]:-none}).
       fixes (any):
         1) conda env create -f environment.yml   (includes pandas)
         2) pip install pandas   into the interpreter you want to use
         3) set python_bin in the config (absolute path to a python that has pandas)
       environment.yml installs python at: $BASE_HINT/envs/${CONDA_ENV_NAME:-bsv-pipeline}/bin/python"
    fi
fi
have "python ready ($PYTHON_BIN, pandas ok)"

# rMATS: explicit rmats_py wins; otherwise managed env -> PATH -> active env
rmats_py="${rmats_py:-}"   # initialize: the config may not set it (set -u)
if [[ -n "$rmats_py" && ! -f "$rmats_py" ]]; then
    warn "Configured rmats_py not found: $rmats_py - locating rMATS in the managed environment instead"
    rmats_py=""
fi
[[ -z "$rmats_py" ]] && rmats_py="$(find_tool rmats.py || true)"
if [[ -z "$rmats_py" ]]; then
    BASE_HINT="$(conda info --base 2>/dev/null || echo '<conda-base>')"
    die "rmats.py not found (looked in: managed env '${CONDA_ENV_NAME:-bsv-pipeline}', PATH, active env).
       environment.yml installs rMATS at: $BASE_HINT/envs/${CONDA_ENV_NAME:-bsv-pipeline}/bin/rmats.py
       fixes (any):
         1) conda env create -f environment.yml && conda activate ${CONDA_ENV_NAME:-bsv-pipeline}
         2) conda install -c bioconda rmats=4.3.0
         3) set rmats_py in the config"
fi
RMATS_ENV_PY="$(dirname "$rmats_py")/python"
RMATS_PY_NOTE="its own env python"
if [[ ! -x "$RMATS_ENV_PY" ]]; then
    RMATS_ENV_PY="$PYTHON_BIN"
    RMATS_PY_NOTE="pandas python: $PYTHON_BIN"
fi
have "rMATS ready ($rmats_py, $RMATS_PY_NOTE)"
if [[ -n "${bsv_repo:-}" ]]; then
    [[ -f "$bsv_repo/scripts/spliceproduce.py" ]] || die "Invalid bsv_repo: $bsv_repo"
    have "BioSpliceView ready (local repo $bsv_repo)"
else
    BSV_BIN="$(find_tool biospliceview || true)"
    if [[ -z "$BSV_BIN" ]]; then
        BASE_HINT="$(conda info --base 2>/dev/null || echo '<conda-base>')"
        die "biospliceview not found (looked in: managed env '${CONDA_ENV_NAME:-bsv-pipeline}', PATH, active env).
       environment.yml installs it at: $BASE_HINT/envs/${CONDA_ENV_NAME:-bsv-pipeline}/bin/biospliceview
       fixes (any):
         1) conda env create -f environment.yml && conda activate ${CONDA_ENV_NAME:-bsv-pipeline}
         2) pip install https://www.spliceview.cn/static/files/main.tar.gz
         3) set bsv_repo in the config to a local checkout"
    fi
    have "BioSpliceView ready ($BSV_BIN)"
fi

# --- 0d rMATS sample resolution (explicit lists win; else prefix discovery) ---
group1_samples="$(resolve_group "$group1" "${group1_samples:-}")"
group2_samples="$(resolve_group "$group2" "${group2_samples:-}")"

# --- 0e MS raw files: explicit lists -> prefix match -> unclaimed leftovers ---
# MS naming is independent of the transcriptome ("what the files are called
# is what gets displayed"). When a group prefix misses, the unclaimed files
# are auto-assigned if their count equals the group's FASTQ sample count;
# anything ambiguous is reported, never guessed.
count_list() { local IFS=,; read -ra _a <<< "$1"; echo ${#_a[@]}; }
norm_path() { realpath "$1" 2>/dev/null || echo "$1"; }
list_ms_dir() {  # all .d/.raw under a directory, natural order
    local dir="$1" f out=()
    for f in "$dir"/*; do
        [[ -e "$f" ]] || continue
        case "$f" in *.d|*.D|*.raw|*.RAW) out+=("$f") ;; esac
    done
    ((${#out[@]})) && printf '%s
' "${out[@]}" | sort -V
    return 0
}
ms_prefix_match() {  # <dir> <group-prefix> -> matched files, one per line
    local dir="$1" name="$2" f out=()
    for f in "$dir"/"$name"-* "$dir"/"$name"_*; do
        [[ -e "$f" ]] || continue
        case "$f" in *.d|*.D|*.raw|*.RAW) out+=("$f") ;; esac
    done
    ((${#out[@]})) || return 1
    printf '%s
' "${out[@]}" | sort -V
}
if [[ "$IS_FULL" == "1" ]]; then
group1_ms_files="${group1_ms_files:-}"
group2_ms_files="${group2_ms_files:-}"
if [[ -z "$group1_ms_files" || -z "$group2_ms_files" ]]; then
    [[ -n "${ms_dir:-}" ]] || die "MS files: set ms_dir, or explicit group1_ms_files / group2_ms_files in the config"
    [[ -d "$ms_dir" ]]     || die "ms_dir not found: $ms_dir"
    MS_ALL="$(list_ms_dir "$ms_dir")"
    [[ -n "$MS_ALL" ]] || die "No .d/.raw files found in $ms_dir"
    for g in 1 2; do
        gname_var="group${g}"; gname="${!gname_var}"
        out_var="group${g}_ms_files"
        [[ -n "${!out_var}" ]] && continue
        if match="$(ms_prefix_match "$ms_dir" "$gname")"; then
            n="$(echo "$match" | grep -c .)"
            run_ "Group $gname: auto-discovered $n MS files (prefix match)" >&2
            while read -r f; do note "$(basename "$f")" >&2; done <<< "$match"
            printf -v "$out_var" '%s' "$(echo "$match" | paste -sd, -)"
        fi
    done
fi
# leftovers fallback: hand the unclaimed files to the group(s) still empty,
# but only when the count matches that group's FASTQ sample count
    MS_ALL="${MS_ALL:-}"
    CLAIMED=()
    [[ -n "$group1_ms_files" ]] && { IFS=, read -ra _c1 <<< "$group1_ms_files"; for _c in "${_c1[@]}"; do CLAIMED+=("$(norm_path "$_c")"); done; }
    [[ -n "$group2_ms_files" ]] && { IFS=, read -ra _c2 <<< "$group2_ms_files"; for _c in "${_c2[@]}"; do CLAIMED+=("$(norm_path "$_c")"); done; }
    LEFT=()
    while IFS= read -r _f; do
        [[ -n "$_f" ]] || continue
        _f="$(norm_path "$_f")"
        _skip=0
        for _c in "${CLAIMED[@]}"; do
            [[ "$_f" == "$_c" ]] && { _skip=1; break; }
        done
        [[ "$_skip" == 0 ]] && LEFT+=("$_f")
    done <<< "$MS_ALL" || true
    for g in 1 2; do
        out_var="group${g}_ms_files"
        [[ -n "${!out_var}" ]] && continue
        gname_var="group${g}"; gname="${!gname_var}"
        samp_var="group${g}_samples"; n_exp="$(count_list "${!samp_var}")"
        n_left=${#LEFT[@]}
        if [[ "$n_left" -eq "$n_exp" && "$n_left" -gt 0 ]]; then
            run_ "Group $gname: auto-assigned $n_left unclaimed MS files (name-independent)" >&2
            for _f in "${LEFT[@]}"; do note "$(basename "$_f")" >&2; done
            printf -v "$out_var" '%s' "$(IFS=,; echo "${LEFT[*]}")"
            LEFT=()
        fi
    done
    if [[ -z "$group1_ms_files" || -z "$group2_ms_files" ]]; then
        die "MS file assignment incomplete (${#LEFT[@]} unclaimed). Name the files with the group prefixes, or set explicit group1_ms_files / group2_ms_files in the config"
    fi
else
    note "MS raw files not required (PIPELINE_MODE=splicing)"
fi
run_ "Input file preflight"
for pair in ${group1_samples//,/ } ${group2_samples//,/ }; do
    for fq in ${pair//:/ }; do
        [[ -e "$fq" ]] || die "FASTQ not found: $fq"
    done
done
if [[ "$IS_FULL" == "1" ]]; then
for f in ${group1_ms_files//,/ } ${group2_ms_files//,/ }; do
    [[ -e "$f" ]] || die "MS file not found: $f"
done
    ok "All FASTQ and MS files present"
else
    ok "All FASTQ files present (proteomics stages skipped)"
fi

ok "Resources and environment ready"
stage_end

# ------------------------------------------------------------
# Per-job output layout
# ------------------------------------------------------------
RMATS_DIR="$JOB_DIR/01_rmats"
BSV_DIR="$JOB_DIR/02_biospliceview"
DB_DIR="$JOB_DIR/03_search_db"
DIANN_DIR="$JOB_DIR/04_diann"
SUM_DIR="$JOB_DIR/05_summary"
FINAL_DIR="$JOB_DIR/final"
mkdir -p "$RMATS_DIR" "$BSV_DIR" "$DB_DIR" "$DIANN_DIR" "$SUM_DIR" "$FINAL_DIR"

BSV_XLSX="$BSV_DIR/Job_${job_id}/Job_${job_id}_results.xlsx"
COMBINED_FA="$DB_DIR/${job_id}_combined_search_db.fasta"
ANNOT_TSV="$DB_DIR/${job_id}_event_annotation.tsv"
SPECLIB="$DIANN_DIR/${job_id}_predicted_library.predicted.speclib"
DIANN_OUT="$DIANN_DIR/${job_id}_report.parquet"
PR_MATRIX="$DIANN_DIR/${job_id}_report.pr_matrix.tsv"
SUMMARY_XLSX="$SUM_DIR/${job_id}_peptide_summary.xlsx"

echo ""
headline "${B}${WHITE}Configuration${R}"
echo -e "  ${DIM}rMATS${R}   $group1 vs $group2 ${DIM}| $read_type, RL=$read_length, threads=$threads${R}"
echo -e "  ${DIM}BSV${R}     FDR<=$fdr, |dPSI|>$psi, minJC>=$minjc"
if [[ "$IS_FULL" == "1" ]]; then
    DIANN_STATE=""
    if [[ -n "$DIANN_BG_PID" ]]; then
        if diann_complete "$REF_DIR/diann/diann-linux"; then DIANN_STATE=" ${DIM}(background download complete)${R}"
        else DIANN_STATE=" ${DIM}(downloading in background)${R}"; fi
    fi
    echo -e "  ${DIM}DB${R}      minAA=$min_aa, background=$(basename "$uniprot_fasta")"
    echo -e "  ${DIM}DIA-NN${R}  v$diann_version$DIANN_STATE"
    echo -e "  ${DIM}params${R}  $diann_params"
    echo -e "  ${DIM}summary${R} nominal p < $p_cutoff (exploratory)"
fi

# DIA-NN argument assembly (shared by both passes)
# DIA-NN tuning flags from the config (one string, verbatim), parsed once
DIANN_PARAMS_ARR=()
read -ra DIANN_PARAMS_ARR <<< "$diann_params"


# ============================================================
banner "1/$STAGE_TOTAL" "rMATS differential splicing" "$group1 vs $group2" "rMATS"
# ============================================================
stage_begin
RMATS_DONE=1
for _ev in SE A5SS A3SS MXE RI; do
    [[ -s "$RMATS_DIR/${_ev}.MATS.JC.txt" ]] || { RMATS_DONE=0; break; }
done
if (( RMATS_DONE )); then
    skip "rMATS outputs already exist ($RMATS_DIR)"
else
    if compgen -G "$RMATS_DIR/*.MATS.JC.txt" > /dev/null; then
        warn "rMATS outputs incomplete (interrupted run) - rerunning Stage 1"
    fi
    printf '%s\n' "$group1_samples" > "$RMATS_DIR/s1.txt"
    printf '%s\n' "$group2_samples" > "$RMATS_DIR/s2.txt"
    RMATS_ARGS=(
        --s1 "$RMATS_DIR/s1.txt" --s2 "$RMATS_DIR/s2.txt"
        --bi "$star_index" --gtf "$gtf"
        -t "$read_type" --readLength "$read_length"
        --nthread "$threads" --od "$RMATS_DIR" --tmp "$RMATS_DIR/tmp"
    )
    run_ "rMATS alignment + event quantification (log: $RMATS_DIR/rmats_run.log)"
    # progress: one STAR run per sample + a final step for the event tables
    # (rMATS maps everything, then quantifies - a plain sample count would
    # pin the bar at 100% for the whole quantification phase). The tmp dir
    # is wiped so a previous run's leftover SJ.out.tab cannot inflate the
    # count from the start.
    rm -rf "$RMATS_DIR/tmp"
    N_SAMP=$(( $(count_list "$group1_samples") + $(count_list "$group2_samples") ))
    # rMATS shells out to `STAR` by name via /bin/sh - put the resolved STAR's
    # directory (and the rMATS env's bin) on PATH for this run only.
    # PYTHONUNBUFFERED: rmats.py block-buffers stdout when redirected, hiding
    # every milestone until ~8 kB accumulate; force live output instead.
    ( export PATH="$(dirname "$star_bin"):$(dirname "$rmats_py"):$PATH"
      export PYTHONUNBUFFERED=1
      STREAM_TOTAL=$(( N_SAMP + 1 )) STREAM_UNIT="steps" \
      STREAM_COUNT_CMD="{ find '$RMATS_DIR/tmp' -name SJ.out.tab 2>/dev/null | wc -l; ls '$RMATS_DIR'/*.MATS.JC.txt >/dev/null 2>&1 && echo 1 || true; } | awk '{s+=\$1} END{print s+0}'" \
      STREAM_FILTER="mapping|quantif|indexing|filtering|junction|status|done|error" \
      STREAM_WATCH_DIR="$RMATS_DIR" \
      run_streamed "$RMATS_DIR/rmats_run.log" "$RMATS_ENV_PY" "$rmats_py" "${RMATS_ARGS[@]}"
    ) || die "rMATS failed - see $RMATS_DIR/rmats_run.log"
    ok "rMATS done -> $RMATS_DIR"
fi
stage_end

# ============================================================
banner "2/$STAGE_TOTAL" "BioSpliceView event annotation" "CDS reconstruction / NMD / GenBank" "BioSpliceView"
# ============================================================
stage_begin
if [[ -f "$BSV_XLSX" ]]; then
    skip "$BSV_XLSX"
else
    if [[ -n "${bsv_repo:-}" ]]; then
        run_ "Running from local repo ($bsv_repo)"
        STREAM_FILTER="." STREAM_WATCH_DIR="$BSV_DIR" \
        STREAM_TOTAL=5 STREAM_UNIT="event types" \
        STREAM_COUNT_CMD="grep -c 'Annotated .* events in' '$BSV_DIR/bsv_run.log' 2>/dev/null; true" \
        run_streamed "$BSV_DIR/bsv_run.log" bash -c \
            "cd '$bsv_repo' && '$PYTHON_BIN' scripts/spliceproduce.py \
            -r '$RMATS_DIR' -g '$genome_fa' -t '$gtf' \
            -o '$BSV_DIR' --job-id '$job_id' \
            --fdr '$fdr' --psi '$psi' --minjc '$minjc'" \
            || die "BioSpliceView failed — see $BSV_DIR/bsv_run.log"
    else
        run_ "Running biospliceview CLI (log: $BSV_DIR/bsv_run.log)"
        STREAM_FILTER="." STREAM_WATCH_DIR="$BSV_DIR" \
        STREAM_TOTAL=5 STREAM_UNIT="event types" \
        STREAM_COUNT_CMD="grep -c 'Annotated .* events in' '$BSV_DIR/bsv_run.log' 2>/dev/null; true" \
        run_streamed "$BSV_DIR/bsv_run.log" "$BSV_BIN" \
            -r "$RMATS_DIR" -g "$genome_fa" -t "$gtf" \
            -o "$BSV_DIR" --job-id "$job_id" \
            --fdr "$fdr" --psi "$psi" --minjc "$minjc" \
            || die "BioSpliceView failed — see $BSV_DIR/bsv_run.log"
    fi
    [[ -f "$BSV_XLSX" ]] || die "BioSpliceView finished but $BSV_XLSX is missing"
    ok "Done -> $BSV_XLSX"
fi
stage_end

# ============================================================
if [[ "$IS_FULL" == "1" ]]; then
banner "3/$STAGE_TOTAL" "Search database" "UniProt background + splice-derived proteins" "search DB"
# ============================================================
stage_begin
DB_FP="$DB_DIR/.params"
db_fp_text="fdr=$fdr psi=$psi minjc=$minjc min_aa=$min_aa prot=$(basename "$uniprot_fasta")"
if [[ -f "$COMBINED_FA" && -f "$ANNOT_TSV" ]]; then
    if [[ -f "$DB_FP" && "$(cat "$DB_FP" 2>/dev/null)" != "$db_fp_text" ]]; then
        warn "Stage 3 parameters changed - rebuilding the search database"
        rm -f "$COMBINED_FA" "$ANNOT_TSV"
    else
        skip "$COMBINED_FA"
    fi
fi
if [[ ! -f "$COMBINED_FA" || ! -f "$ANNOT_TSV" ]]; then
    run_ "Merging background proteome with splice-derived sequences"
    "$PYTHON_BIN" "$SCRIPT_DIR/scripts/merge_db.py" \
        --results-xlsx "$BSV_XLSX" --uniprot-fasta "$uniprot_fasta" \
        --out-fasta "$COMBINED_FA" --out-annotation "$ANNOT_TSV" \
        --min-aa "$min_aa"
    printf '%s\n' "$db_fp_text" > "$DB_FP"
    ok "Search DB done -> $COMBINED_FA"
fi
stage_end

# ============================================================
# subtitle reflects the search mode actually configured
diann_mode_txt="pure DIA search"
[[ "$diann_params" == *"--dda"* ]] && diann_mode_txt="DDA-aided search (spectral library + DDA files)"
banner "4/$STAGE_TOTAL" "DIA-NN search" "$diann_mode_txt + DIA quantification" "DIA-NN"
# ============================================================
stage_begin
LIB_FP="$DIANN_DIR/.lib_params"
SEARCH_FP="$DIANN_DIR/.search_params"
lib_fp_text="db:$db_fp_text | v$diann_version | $diann_params"
search_fp_text="$lib_fp_text | ms1=$group1_ms_files ms2=$group2_ms_files"
if [[ -f "$PR_MATRIX" ]]; then
    if [[ -f "$SEARCH_FP" && "$(cat "$SEARCH_FP" 2>/dev/null)" != "$search_fp_text" ]]; then
        warn "DIA-NN parameters or MS inputs changed - rerunning the search"
        rm -f "$PR_MATRIX"
    else
        skip "$PR_MATRIX"
    fi
fi
if [[ ! -f "$PR_MATRIX" ]]; then
    wait_diann   # collect the background download (started before Stage 1)
    if [[ -s "$SPECLIB" && -f "$LIB_FP" && "$(cat "$LIB_FP" 2>/dev/null)" != "$lib_fp_text" ]]; then
        warn "Search database or DIA-NN parameters changed - regenerating the spectral library"
        rm -f "$SPECLIB"
    fi
    [[ -f "$SPECLIB" && ! -s "$SPECLIB" ]] && { rm -f "$SPECLIB"; warn "Removed empty spectral library from a failed run"; }
    if [[ ! -s "$SPECLIB" ]]; then
        run_ "4a Predicted spectral library (log: $DIANN_DIR/diann_lib.log)"
        # --reanalyse (MBR) and the mass accuracies are main-search
        # parameters - meaningless in a library-generation-only pass.
        # Filter them here, together with their values (state machine:
        # after one of these flags, the next token is its value).
        lib_args=(--fasta "$COMBINED_FA" --fasta-search --gen-spec-lib --predictor)
        pa= skip_next=0
        for pa in "${DIANN_PARAMS_ARR[@]}"; do
            if (( skip_next )); then skip_next=0; continue; fi
            case "$pa" in
                --mass-acc|--mass-acc-ms1) skip_next=1 ;;   # value-taking
                --reanalyse) ;;                             # boolean
                --reanalyse=*|--mass-acc=*|--mass-acc-ms1=*) ;;
                *) lib_args+=("$pa") ;;
            esac
        done
        lib_args+=(--out-lib "$DIANN_DIR/${job_id}_predicted_library.tsv")
        printf -v lib_cmd "%s " "$diann_bin" "${lib_args[@]}"; lib_cmd="${lib_cmd% }"
        note "cmd: $lib_cmd"
        STREAM_FILTER="predict|library|writing|error|warn" STREAM_HEARTBEAT=60 STREAM_WATCH_DIR="$DIANN_DIR" \
        run_streamed "$DIANN_DIR/diann_lib.log" "$diann_bin" "${lib_args[@]}" \
            || die "DIA-NN library generation failed - see $DIANN_DIR/diann_lib.log"
        [[ -s "$SPECLIB" ]] || die "DIA-NN library generation finished but $SPECLIB is missing"
        printf '%s\n' "$lib_fp_text" > "$LIB_FP"
    else
        skip "Spectral library exists ($SPECLIB)"
    fi
    if [[ "$diann_params" == *"--dda"* ]]; then
        run_ "4b DDA-aided search (log: $DIANN_DIR/diann_search.log)"
    else
        run_ "4b pure DIA search (log: $DIANN_DIR/diann_search.log)"
    fi
    search_args=()
    for f in ${group1_ms_files//,/ } ${group2_ms_files//,/ }; do
        search_args+=(--f "$f")
    done
    search_args+=("--lib" "$SPECLIB" "--fasta" "$COMBINED_FA" \
        --out "$DIANN_OUT" \
        "${DIANN_PARAMS_ARR[@]}")
    case " ${DIANN_PARAMS_ARR[*]} " in
        *" --matrices "*) ;;
        *) search_args+=(--matrices) ;;
    esac
    printf -v search_cmd "%s " "$diann_bin" "${search_args[@]}"; search_cmd="${search_cmd% }"
    note "cmd: $search_cmd"
    # progress: DIA-NN processes each raw file in two passes (pre-
    # processing, then analysis), so the step total is 2 x the file count
    N_MS=$(( $(count_list "$group1_ms_files") + $(count_list "$group2_ms_files") ))
    STREAM_FILTER="processing|error|warn" STREAM_HEARTBEAT=60 STREAM_WATCH_DIR="$DIANN_DIR" \
    STREAM_TOTAL=$((2 * N_MS)) STREAM_UNIT="passes (2 per file)" \
    STREAM_COUNT_CMD="grep -cE 'Pre-processing|Analys' '$DIANN_DIR/diann_search.log' 2>/dev/null; true" \
    run_streamed "$DIANN_DIR/diann_search.log" "$diann_bin" "${search_args[@]}" \
        || die "DIA-NN search failed - see $DIANN_DIR/diann_search.log"
    [[ -f "$PR_MATRIX" ]] || die "DIA-NN finished but $PR_MATRIX is missing (add --matrices to diann_params)"
    printf '%s\n' "$search_fp_text" > "$SEARCH_FP"
    ok "DIA-NN done -> $PR_MATRIX"
fi
stage_end

# ============================================================
banner "5/$STAGE_TOTAL" "Splice-peptide summary" "exploratory between-group comparison" "summary"
# ============================================================
stage_begin
if [[ -f "$SUMMARY_XLSX" ]]; then
    skip "$SUMMARY_XLSX"
else
    run_ "Mapping splice peptides back to events"
    MS1_NAMES="$(echo "$group1_ms_files" | tr ',' '\n' | sed 's|.*/||' | paste -sd, -)"
    MS2_NAMES="$(echo "$group2_ms_files" | tr ',' '\n' | sed 's|.*/||' | paste -sd, -)"
    "$PYTHON_BIN" "$SCRIPT_DIR/scripts/summarize_splice_peptides.py" \
        --pr-matrix "$PR_MATRIX" \
        --annotation "$ANNOT_TSV" \
        --group1-name "$group1" --group1-files "$MS1_NAMES" \
        --group2-name "$group2" --group2-files "$MS2_NAMES" \
        --p-cutoff "$p_cutoff" \
        --out "$SUMMARY_XLSX"
    ok "Summary done -> $SUMMARY_XLSX"
fi
stage_end

# ============================================================
else
    note "PIPELINE_MODE=splicing - proteomics stages (3-5) skipped"
fi
banner "Collect" "Final deliverables" "$FINAL_DIR"
# ============================================================
cp -f "$BSV_XLSX"     "$DB_DIR/${job_id}_BioSpliceView_results.xlsx"
if [[ "$IS_FULL" == "1" ]]; then cp -f "$PR_MATRIX"    "$FINAL_DIR/${job_id}_pr_matrix.tsv"; fi
if [[ "$IS_FULL" == "1" ]]; then cp -f "$SUMMARY_XLSX" "$FINAL_DIR/${job_id}_peptide_summary.xlsx"; fi
rm -rf "$FINAL_DIR/${job_id}_GenBank"
if [[ -d "$BSV_DIR/Job_${job_id}/GB_Files" ]]; then
    cp -r "$BSV_DIR/Job_${job_id}/GB_Files" "$FINAL_DIR/${job_id}_GenBank"
fi

# ============================================================
# Final summary
# ============================================================
echo ""
headline "${B}${GREEN}Pipeline complete${R} ${DIM}─${R} ${DIM}job: $job_id${R}"
echo -e "  ${B}${WHITE}total${R} $(fmt_secs $(( (${SECONDS:-0}) - T0 )))"
echo ""
headline "${B}${WHITE}Final deliverables${R} ${DIM}─${R} ${DIM}$FINAL_DIR${R}"
if [[ "$IS_FULL" == "1" ]]; then echo -e "  ${GREEN}→${R} ${job_id}_combined_search_db.fasta      ${DIM}merged search database${R}"; fi
if [[ "$IS_FULL" == "1" ]]; then echo -e "  ${GREEN}→${R} ${job_id}_event_annotation.tsv          ${DIM}peptide-to-event traceability${R}"; fi
echo -e "  ${GREEN}→${R} ${job_id}_BioSpliceView_results.xlsx    ${DIM}CDS/NMD annotation (all events)${R}"
echo -e "  ${GREEN}→${R} ${job_id}_GenBank/                      ${DIM}dual GenBank views per event${R}"
if [[ "$IS_FULL" == "1" ]]; then echo -e "  ${GREEN}→${R} ${job_id}_pr_matrix.tsv                 ${DIM}DIA-NN quantities (1% FDR)${R}"; fi
if [[ "$IS_FULL" == "1" ]]; then echo -e "  ${GREEN}→${R} ${job_id}_peptide_summary.xlsx          ${DIM}event-mapped splice-peptide evidence${R}"; fi
echo ""
headline "${B}${WHITE}Stage timings${R}"
local_total=$(( (${SECONDS:-0}) - T0 ))
for entry in "${STAGE_TIMELINE[@]}"; do
    lbl="${entry%%|*}"; secs="${entry##*|}"
    echo -e "  $(printf '%-22s %8s' "$lbl" "$(fmt_secs "$secs")")"
done
echo -e "  ${B}${WHITE}$(printf '%-22s %8s' "total" "$(fmt_secs "$local_total")")${R}"
echo -e "  ${DIM}Heavy-tool logs: rmats_run.log / bsv_run.log / diann_*.log / star_index_build.log${R}"
echo -e "  ${DIM}Shared cache (ref/, reused by future jobs): $REF_DIR${R}"
echo -e "  ${DIM}Job outputs: $JOB_DIR   Log: $LOG_FILE${R}"
echo ""
echo ""
