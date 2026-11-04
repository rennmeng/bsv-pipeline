#!/usr/bin/env bash
# ============================================================
# Install DIA-NN (pinned version, default 2.6.1 = reference workflow)
#
# Usage:
#   bash scripts/install_diann.sh [install-dir]
#   Default install dir: /opt/diann (called automatically at docker build);
#   for conda/bare-metal:
#     bash scripts/install_diann.sh ~/diann-bin
#   Force reinstall: DIANN_FORCE=1 bash scripts/install_diann.sh
#
# Download sources (override via env, e.g. at docker build):
#   DIANN_URL_PRIMARY  default: official GitHub release
#   DIANN_URL_BACKUP   default: https://www.spliceview.cn/static/files/
#                      (upload the release zip there once for offline builds)
#
# Source: official DIA-NN GitHub release (Academia licence package).
# Confirm licence terms at dia-nn.com for commercial use.
# All downloads are silent, with a 15 s connect probe (fast-fail).
# ============================================================
set -euo pipefail

DIANN_VERSION="${DIANN_VERSION:-2.6.1}"
DEST="${1:-/opt/diann}"
BIN="$DEST/diann-linux"
URL_PRIMARY="${DIANN_URL_PRIMARY:-https://github.com/vdemichev/DiaNN/releases/download/2.0/DIA-NN-${DIANN_VERSION}-Academia-Linux.zip}"
URL_BACKUP="${DIANN_URL_BACKUP:-https://www.spliceview.cn/static/files/DIA-NN-${DIANN_VERSION}-Academia-Linux.zip}"

# Idempotent: skip when present and not forced (same cache-first principle)
# complete = binary + models (DIA-NN 2.x needs ./models for the predictor);
# an incomplete install is treated as absent and repaired automatically
if [[ -x "$BIN" && -f "$DEST/models/dict.txt" && "${DIANN_FORCE:-0}" != "1" ]]; then
    echo "[SKIP] DIA-NN already present ($BIN); set DIANN_FORCE=1 to reinstall"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FETCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetch_url.sh"
[[ -f "$FETCH" ]] || { echo "[FAIL] fetch_url.sh not found next to install_diann.sh"; exit 1; }

# download to a STABLE part file so an interrupted attempt can resume
ZIP="$DEST/diann.zip.part"
echo "[RUN ] Downloading DIA-NN $DIANN_VERSION (~380 MB, resumable) ..."
if bash "$FETCH" "$URL_PRIMARY" "$URL_BACKUP" "$ZIP" 2 2; then
    :
else
    # tolerance: a resumed download may end non-zero when the file is already
    # complete (HTTP 416). Accept anything that looks like a zip.
    # the PK-magic tolerance only applies to the escalated RESUME path
    # (HTTP 416 = file already complete); a plain failed download leaves a
    # truncated file that merely starts with PK - rerun to resume it
    if [[ -n "${FETCH_RESUME:-}" && -s "$ZIP" && "$(head -c 2 "$ZIP" 2>/dev/null)" == "PK" ]]; then
        echo "[WARN] download ended non-zero but the archive looks complete; continuing"
    else
        echo "[FAIL] all download sources failed"
        exit 1
    fi
fi
[[ -s "$ZIP" ]] || { echo "[FAIL] archive missing: $ZIP"; exit 1; }

echo "[RUN ] Extracting ..."
mkdir -p "$TMP/unz" "$DEST"
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$ZIP" -d "$TMP/unz"
else
    python -m zipfile -e "$ZIP" "$TMP/unz"
fi

# locate the diann-linux binary (layout may vary between packages)
FOUND="$(find "$TMP/unz" -type f -name 'diann-linux' | head -1)"
[[ -n "$FOUND" ]] || { echo "[FAIL] diann-linux not found after extraction"; exit 1; }
cp "$FOUND" "$BIN"
chmod +x "$BIN"

# ship the ENTIRE package directory (models/, configs, ...) - DIA-NN 2.x
# loads its neural-network models from ./models next to the binary
SRC_DIR="$(dirname "$FOUND")"
cp -r "$SRC_DIR"/. "$DEST/" 2>/dev/null || true
rm -f "$DEST/diann.zip.part" "$DEST/diann.zip.part.pid" 2>/dev/null || true

rm -f "$ZIP"
echo "[ OK ] DIA-NN $DIANN_VERSION installed: $BIN"
"$BIN" --version 2>/dev/null || true
