#!/usr/bin/env bash
# Build a STAR genome index for rMATS FASTQ mode (rmats.py --bi).
# One-off per genome build (~30 GB for mouse/human).
#
# Usage:
#   bash build_star_index.sh <genome.fa> <annotation.gtf> <out_dir> [threads]
#   STAR_BIN=/path/to/STAR bash build_star_index.sh ...   # explicit STAR
# (run_pipeline.sh passes the resolved STAR path via STAR_BIN automatically)
set -euo pipefail
FA="${1:?genome fasta}"; GTF="${2:?annotation gtf}"; OUT="${3:?output dir}"; T="${4:-8}"
# STAR_BIN (or star_bin) - full path to the STAR executable; bare "STAR"
# only works when it is already on PATH
STAR_BIN="${STAR_BIN:-${star_bin:-STAR}}"
if [[ ! -x "$STAR_BIN" ]] && ! command -v "$STAR_BIN" >/dev/null 2>&1; then
    echo "[FAIL] STAR not found: $STAR_BIN"
    exit 1
fi
[[ -f "$FA"  ]] || { echo "[FAIL] not found: $FA";  exit 1; }
[[ -f "$GTF" ]] || { echo "[FAIL] not found: $GTF"; exit 1; }
mkdir -p "$OUT"
echo "[RUN ] STAR genomeGenerate ($(basename "$STAR_BIN")) threads=$T ..."
"$STAR_BIN" --runMode genomeGenerate \
     --genomeDir "$OUT" \
     --genomeFastaFiles "$FA" \
     --sjdbGTFfile "$GTF" \
     --sjdbOverhang "${READ_LENGTH_OVERRIDE:-149}" \
     --runThreadN "$T"
echo "[ OK ] STAR index ready: $OUT"
