#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
merge_db.py — merge a UniProt background proteome with BioSpliceView
splice-derived proteins into a combined search FASTA.

Merge policy (reference workflow):
1. All UniProt entries are kept (highest priority).
2. SpliceView Ref/Alt sequences are cleaned, QC'd and pair-deduplicated
   (Ref == Alt drops the whole row).
3. NMD_Target filtering is applied to Ref and Alt INDEPENDENTLY via the
   Ref_Absolute_NMD / Alt_Absolute_NMD columns: a side annotated NMD_Target
   is dropped, the other side is kept; both sides NMD_Target -> no sequence.
   NMDER1/2/3, NON_CODING, NO_STOP_CODON, NO_START_CODON, Normal and empty
   values are all kept.
4. Splice sequences identical to a UniProt entry are skipped (UniProt wins).
   NMD filtering is applied before UniProt dedup statistics.
5. An annotation TSV records the NMD values and final outcome per side.

Usage:
  python merge_db.py --results-xlsx Job_myjob_results.xlsx \
      --uniprot-fasta uniprot_mouse.fasta \
      --out-fasta combined.fasta --out-annotation annotation.tsv
"""
import argparse
import os
import re
import sys

import pandas as pd

# shared terminal-style helpers: same tag standard as run_pipeline.sh
# (see bsvterm.py for the format reference)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bsvterm import _c, tag_ok, tag_info, tag_warn, tag_fail, rule


def read_fasta(path):
    """Read a FASTA file, return [(header, seq), ...]."""
    entries = []
    header, seq_lines = None, []
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.rstrip('\n').rstrip('\r')
            if line.startswith('>'):
                if header is not None:
                    entries.append((header, ''.join(seq_lines)))
                header, seq_lines = line[1:], []
            elif line.strip():
                seq_lines.append(line.strip())
    if header is not None:
        entries.append((header, ''.join(seq_lines)))
    return entries


def clean_seq(value):
    """Strip whitespace/newlines and trailing stops, uppercase."""
    s = str(value).replace(' ', '').replace('\n', '').replace('\r', '')
    s = s.rstrip('*').strip().upper()
    return '' if s in ('', 'NAN', 'NONE') else s


def nmd_label(value):
    """Normalise an NMD column value; nan/empty -> ''."""
    if value is None:
        return ''
    s = str(value).strip()
    return '' if s.lower() in ('', 'nan', 'none') else s


def is_nmd_target(value):
    """True only for NMD_Target (case-insensitive); every other value is False."""
    return nmd_label(value).lower() == 'nmd_target'


def outcome_label(is_nmd, in_uniprot, written):
    """Final disposition of one side, as written to the annotation TSV."""
    if is_nmd:
        return 'No (NMD_Target)'
    if in_uniprot:
        return 'No (in UniProt)'
    return 'Yes' if written else 'No'


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--results-xlsx', required=True,
                    help='BioSpliceView Job_<id>_results.xlsx')
    ap.add_argument('--sheet', default='All_Significant',
                    help='sheet name to read (default: All_Significant)')
    ap.add_argument('--uniprot-fasta', required=True,
                    help='UniProt background proteome FASTA (same species)')
    ap.add_argument('--out-fasta', required=True, help='combined FASTA output')
    ap.add_argument('--out-annotation', required=True,
                    help='per-entry annotation TSV output')
    ap.add_argument('--min-aa', type=int, default=10,
                    help='minimum splice-protein length in aa (default: 10)')
    args = ap.parse_args()

    # ---- 1. background proteome + O(1) sequence index ----
    tag_info("Reading background proteome ...")
    uniprot_entries = read_fasta(args.uniprot_fasta)
    uniprot_seq_set = set(seq for _, seq in uniprot_entries)
    tag_info(f"UniProt entries: {len(uniprot_entries)}, unique sequences: {len(uniprot_seq_set)}")

    # ---- 2. BioSpliceView results ----
    df = pd.read_excel(args.results_xlsx, sheet_name=args.sheet)
    required = ['Event_ID', 'Splice_Type', 'geneSymbol',
                'Ref_Full_Protein', 'Alt_Full_Protein',
                'Ref_Absolute_NMD', 'Alt_Absolute_NMD']
    missing = [c for c in required if c not in df.columns]
    if missing:
        tag_fail(f"{args.results_xlsx} is missing columns: {missing}")
        sys.exit(1)
    tag_info(f"Event table: {df.shape[0]} rows (sheet: {args.sheet})")

    sv_entries, annot_rows, seen_pairs = [], [], set()
    stats = dict(
        rows=len(df), kept_pairs=0, skip_empty=0, skip_short=0,
        skip_identical=0, skip_dup_pair=0,
        written_ref=0, written_alt=0,
        skip_ref_in_uniprot=0, skip_alt_in_uniprot=0,
        skip_ref_nmd=0, skip_alt_nmd=0, skip_row_both_nmd=0,
        rows_all_dropped=0,
    )

    for _, row in df.iterrows():
        event_id = str(row['Event_ID']).strip()
        gene = str(row['geneSymbol']).strip()
        splice = str(row['Splice_Type']).strip()
        ref_seq = clean_seq(row['Ref_Full_Protein'])
        alt_seq = clean_seq(row['Alt_Full_Protein'])

        # --- basic QC ---
        if not ref_seq or not alt_seq:
            stats['skip_empty'] += 1
            continue
        if len(ref_seq) < args.min_aa or len(alt_seq) < args.min_aa:
            stats['skip_short'] += 1
            continue
        if ref_seq == alt_seq:
            stats['skip_identical'] += 1
            continue

        # --- NMD filter: Ref and Alt judged independently ---
        ref_nmd = nmd_label(row['Ref_Absolute_NMD'])
        alt_nmd = nmd_label(row['Alt_Absolute_NMD'])
        ref_is_nmd = is_nmd_target(ref_nmd)
        alt_is_nmd = is_nmd_target(alt_nmd)

        # both sides NMD_Target -> nothing to write; checked before pair
        # dedup so this row does not consume a pair slot
        if ref_is_nmd and alt_is_nmd:
            stats['skip_row_both_nmd'] += 1
            continue

        pair_key = (ref_seq, alt_seq)
        if pair_key in seen_pairs:
            stats['skip_dup_pair'] += 1
            continue
        seen_pairs.add(pair_key)

        gene_clean = re.sub(r'[^A-Za-z0-9_]', '', gene) or 'UNKNOWN'
        base_id = f"{event_id}_{gene}-{splice}"

        ref_in_uniprot = ref_seq in uniprot_seq_set
        alt_in_uniprot = alt_seq in uniprot_seq_set

        ref_header = f"sp|{base_id}_Ref|{gene_clean}"
        alt_header = f"sp|{base_id}_Alt|{gene_clean}"

        ref_written = alt_written = False

        if ref_is_nmd:
            stats['skip_ref_nmd'] += 1
        elif ref_in_uniprot:
            stats['skip_ref_in_uniprot'] += 1
        else:
            sv_entries.append((ref_header, ref_seq))
            stats['written_ref'] += 1
            ref_written = True

        if alt_is_nmd:
            stats['skip_alt_nmd'] += 1
        elif alt_in_uniprot:
            stats['skip_alt_in_uniprot'] += 1
        else:
            sv_entries.append((alt_header, alt_seq))
            stats['written_alt'] += 1
            alt_written = True

        stats['kept_pairs'] += 1
        if not ref_written and not alt_written:
            stats['rows_all_dropped'] += 1

        annot_rows.append({
            'Event_ID': event_id,
            'geneSymbol': gene,
            'Splice_Type': splice,
            'NMD_Status': nmd_label(row.get('NMD_Status', '')),
            'Ref_Absolute_NMD': ref_nmd,
            'Alt_Absolute_NMD': alt_nmd,
            'Match_Status': nmd_label(row.get('Match_Status', '')),
            'FDR': row.get('FDR', ''),
            'Ref_len_aa': len(ref_seq),
            'Alt_len_aa': len(alt_seq),
            'Ref_in_output': outcome_label(ref_is_nmd, ref_in_uniprot, ref_written),
            'Alt_in_output': outcome_label(alt_is_nmd, alt_in_uniprot, alt_written),
            'Ref_header': ref_header if ref_written else '(not written)',
            'Alt_header': alt_header if alt_written else '(not written)',
        })

    # ---- 3. write combined FASTA (atomic: tmp + rename, so an interrupted
    #         run cannot leave a truncated database that a resume would reuse) ----
    tmp_fa = args.out_fasta + '.tmp'
    with open(tmp_fa, 'w', encoding='utf-8', newline='\n') as f:
        for header, seq in uniprot_entries:
            f.write(f">{header}\n{seq}\n")
        for header, seq in sv_entries:
            f.write(f">{header}\n{seq}\n")
    os.replace(tmp_fa, args.out_fasta)

    # ---- 4. annotation TSV (always written: the pipeline's Stage-3 resume
    #         check requires the file to exist; a header-only TSV means no
    #         event survived the filters) ----
    annot_cols = ['Event_ID', 'geneSymbol', 'Splice_Type', 'NMD_Status',
                  'Ref_Absolute_NMD', 'Alt_Absolute_NMD', 'Match_Status',
                  'FDR', 'Ref_len_aa', 'Alt_len_aa', 'Ref_in_output',
                  'Alt_in_output', 'Ref_header', 'Alt_header']
    tmp_ts = args.out_annotation + '.tmp'
    pd.DataFrame(annot_rows, columns=annot_cols).to_csv(tmp_ts, sep='\t', index=False)
    os.replace(tmp_ts, args.out_annotation)

    # ---- 5. report ----
    total = len(uniprot_entries) + len(sv_entries)
    rule()
    print(_c('1;36', 'Search database merged (UniProt first + independent Ref/Alt NMD_Target filter)'))
    print(f"  Excel rows                    : {stats['rows']}")
    print(f"  skip (empty/nan)              : {stats['skip_empty']}")
    print(f"  skip (<{args.min_aa} aa)                 : {stats['skip_short']}")
    print(f"  skip (Ref==Alt)               : {stats['skip_identical']}")
    print(f"  skip (both sides NMD_Target)  : {stats['skip_row_both_nmd']}")
    print(f"  skip (duplicate pair)         : {stats['skip_dup_pair']}")
    print(f"  rows entering write stage     : {stats['kept_pairs']}")
    print(f"  --")
    print(f"  Ref NMD_Target (dropped)      : {stats['skip_ref_nmd']}")
    print(f"  Alt NMD_Target (dropped)      : {stats['skip_alt_nmd']}")
    print(f"  Ref already in UniProt        : {stats['skip_ref_in_uniprot']}")
    print(f"  Alt already in UniProt        : {stats['skip_alt_in_uniprot']}")
    print(f"  splice Ref written            : {stats['written_ref']}")
    print(f"  splice Alt written            : {stats['written_alt']}")
    print(f"  rows with no sequence written : {stats['rows_all_dropped']}")
    print(f"  --")
    print(_c('1;37', f"  Combined entries              : {total} = "
                     f"UniProt {len(uniprot_entries)} + splice {len(sv_entries)}"))
    rule()
    tag_ok(f"FASTA        {args.out_fasta}")
    tag_ok(f"annotation   {args.out_annotation}")


if __name__ == '__main__':
    main()
