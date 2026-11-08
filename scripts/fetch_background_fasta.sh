#!/usr/bin/env bash
# Download the background (reference) proteome FASTA from the mirror.
#
# Usage: bash fetch_background_fasta.sh <mouse|human> <output.fasta>
#
# Source (mirror, no UniProt REST involved):
#   mouse -> uniprotkb_AND_model_organism_10090_AND_2026_10_27.fasta.gz
#          (reviewed mouse proteome, 17,283 entries)
#   human -> uniprotkb_AND_reviewed_true_AND_model_o_2026_10_27.fasta.gz
#          (reviewed human proteome, 20,431 entries)
#   both gzipped, decompressed on arrival
set -euo pipefail

SPECIES="${1:?Usage: fetch_background_fasta.sh <mouse|human> <output.fasta>}"
OUT="${2:?missing output path}"

# mirror files (one per species, gzipped):
#   mouse: uniprotkb_AND_model_organism_10090_...  reviewed, 17,283 entries
#   human: uniprotkb_AND_reviewed_true_AND_model_o_...  reviewed, 20,431 entries
case "${SPECIES,,}" in
  mouse) MIRROR_FILE="uniprotkb_AND_model_organism_10090_AND_2026_10_27.fasta.gz" ;;
  human) MIRROR_FILE="uniprotkb_AND_reviewed_true_AND_model_o_2026_10_27.fasta.gz" ;;
  *) echo "FAIL  unknown species: $SPECIES (supported: mouse / human)"; exit 1 ;;
esac

URL="${PROTEOME_URL:-https://www.spliceview.cn/static/files/${MIRROR_FILE}}"

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
  || command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || {
  echo "FAIL  need curl / wget / python (any one) for downloading"; exit 1; }

echo "RUN  Downloading background proteome (species=${SPECIES})"
echo "       source: $URL"
RATE_ARGS=()
[[ -n "${DL_RATE_LIMIT-}" ]] && RATE_ARGS=(--limit-rate "$DL_RATE_LIMIT")
WGET_RATE=()
[[ -n "${DL_RATE_LIMIT-}" ]] && WGET_RATE=(--limit-rate="$DL_RATE_LIMIT")
DL_OK=0
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "${RATE_ARGS[@]}" -o "${OUT}.part" "$URL" && DL_OK=1
elif command -v wget >/dev/null 2>&1; then
    wget -q "${WGET_RATE[@]}" -O "${OUT}.part" "$URL" && DL_OK=1
fi
if [[ "$DL_OK" != "1" ]]; then
    # fallback: python stdlib (minimal containers often lack curl/wget)
    if PY_BIN="$(command -v python3 || command -v python)"; then
        "$PY_BIN" - "$URL" "${OUT}.part" <<'PY' && DL_OK=1
import sys, urllib.request
for attempt in range(3):
    try:
        urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
        sys.exit(0)
    except Exception as e:
        print(f"WARN  download attempt {attempt + 1}/3 failed: {e}", file=sys.stderr)
sys.exit(1)
PY
    fi
fi
if [[ "$DL_OK" != "1" || ! -s "${OUT}.part" ]]; then
    rm -f "${OUT}.part"
    echo "FAIL  download failed: $URL"
    echo "       check the mirror and the file name above"
    exit 1
fi

# decompress when gzipped (magic bytes 1f 8b), else move as-is
if [[ "$(head -c 2 "${OUT}.part" | od -An -tx1 | tr -d ' ' | tr -d '\n')" == "1f8b" ]]; then
    gunzip -c "${OUT}.part" > "$OUT"
    rm -f "${OUT}.part"
else
    mv "${OUT}.part" "$OUT"
fi
N="$(grep -c '^>' "$OUT" || true)"
echo "OK  Background proteome ready: $OUT (${N} sequences)"
