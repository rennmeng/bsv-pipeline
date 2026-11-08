#!/usr/bin/env bash
# Install a .NET runtime user-locally (no root required) via the official
# dot.net/v1/dotnet-install.sh. Needed by DIA-NN to read Thermo .raw files.
#
# Usage: bash install_dotnet.sh <install-dir> [channel]
#   channel: major .NET channel, e.g. 8.0 (default) or 6.0
# Channels install side by side into the same root (host/fxr/<major>.x,
# shared/Microsoft.NETCore.App/<major>.x).
# Cache-first: skips when <install-dir>/dotnet already SERVES the wanted
# channel - a root holding only a different major does not count.
set -euo pipefail

DEST="${1:?Usage: install_dotnet.sh <install-dir> [channel]}"
CHANNEL="${2:-8.0}"
CHANNEL_MAJOR="${CHANNEL%%.*}"
# DIA-NN 2.6.1 refuses .NET 8 runtimes older than 8.0.17: a root holding
# only, say, 8.0.11 does NOT count as serving channel 8 and must be
# upgraded (dotnet-install puts the newest 8.0.x alongside it).
DOTNET8_FLOOR="8.0.17"

serving_ok() {  # serving_ok <install-dir> <channel-major>: binary exists
    local out v # and serves a version recent enough for DIA-NN
    [[ -x "$1/dotnet" ]] || return 1
    out="$("$1/dotnet" --list-runtimes 2>/dev/null || true)"
    printf '%s\n' "$out" | grep -q "Microsoft\.NETCore\.App ${2}\." || return 1
    if [[ "$2" == "8" ]]; then
        v="$(printf '%s\n' "$out" | awk '/Microsoft\.NETCore\.App 8\./{v=$2} END{print v}')"
        [[ -n "$v" ]] || return 1
        [[ "$(printf '%s\n%s\n' "$DOTNET8_FLOOR" "$v" | sort -V | head -n1)" == "$DOTNET8_FLOOR" ]]
    else
        return 0
    fi
}

if serving_ok "$DEST" "$CHANNEL_MAJOR"; then
    echo "SKIP  .NET $CHANNEL runtime already present and recent enough ($DEST)"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DEST"

echo "RUN  Fetching the official dotnet-install script ..."
DL_OK=0
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$TMP/dotnet-install.sh" "https://dot.net/v1/dotnet-install.sh" && DL_OK=1
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$TMP/dotnet-install.sh" "https://dot.net/v1/dotnet-install.sh" && DL_OK=1
fi
[[ "$DL_OK" == "1" && -s "$TMP/dotnet-install.sh" ]] || {
    echo "FAIL  could not fetch https://dot.net/v1/dotnet-install.sh (check network)"; exit 1; }

echo "RUN  Installing .NET $CHANNEL runtime to $DEST (user-local, no root) ..."
bash "$TMP/dotnet-install.sh" --channel "$CHANNEL" --runtime dotnet --install-dir "$DEST" --no-path

[[ -x "$DEST/dotnet" ]] || { echo "FAIL  dotnet binary not found after install"; exit 1; }
"$DEST/dotnet" --list-runtimes 2>/dev/null | grep -q "Microsoft\.NETCore\.App ${CHANNEL_MAJOR}\." \
    || { echo "FAIL  .NET $CHANNEL runtime not served after install"; exit 1; }
echo "OK  .NET $CHANNEL runtime installed: $DEST"
