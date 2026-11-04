#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
summarize_splice_peptides.py — extract splice-event-derived peptides from a
DIA-NN report.pr_matrix.tsv, map them back to their defining splicing events,
and run an exploratory between-group comparison.

Selection rule for splice-derived rows (reference workflow),
applied to the Protein.Ids column (DIA-NN run with --ids-to-names):
  - a single protein group containing a _Ref/_Alt marker        -> keep
  - all semicolon-separated members are _Alt splice entries     -> keep
  - exactly one member being a _Ref/_Alt splice entry           -> keep
  - everything else (e.g. mixed Ref;Alt canonical groups)       -> drop

Statistics are exploratory: nominal two-sided Welch t-tests (values missing
in either group are excluded pairwise); a single-group detection (all
replicates of one group, none of the other) is flagged with a placeholder
p-value (1e-10) and +/-inf log2FC.

Usage:
  python summarize_splice_peptides.py --pr-matrix report.pr_matrix.tsv \
      --annotation event_annotation.tsv \
      --group1-name WT  --group1-files WT-1.d,WT-2.d,WT-3.d \
      --group2-name KO --group2-files KO-1.d,KO-2.d,KO-3.d \
      --out peptide_summary.xlsx
"""
import argparse
import os
import re
import sys

import numpy as np
import pandas as pd
from scipy import stats

PLACEHOLDER_P = 1e-10  # group-restricted detection (3 vs 0)

# ---------------- terminal styles ----------------
_TTY = sys.stdout.isatty() and not os.environ.get('NO_COLOR')


def _c(code, s):
    return f"\033[{code}m{s}\033[0m" if _TTY else str(s)


def tag_ok(msg):   print(f"{_c('1;32', '[ OK ]')} {msg}")
def tag_info(msg): print(f"{_c('1;36', 'INFO ')} {msg}")
def tag_warn(msg): print(f"{_c('1;33', 'WARN ')} {msg}")
def tag_fail(msg): print(f"{_c('1;31', '[FAIL]')} {msg}")
def rule():        print(_c('2', '─' * 62))


def keep_row(val):
    """Decide whether a Protein.Ids value represents a splice-derived entry."""
    if pd.isna(val):
        return False
    s = str(val).strip()

    if ";" not in s:
        sl = s.lower()
        return "_ref" in sl or "_alt" in sl

    parts = [p.strip() for p in s.split(";") if p.strip() != ""]
    if len(parts) == 0:
        return False

    # with --ids-to-names a splice header renders as "sp <EVENT>_..._Ref <GENE>",
    # so the marker may sit mid-token rather than at the end
    def is_alt(p):
        pl = p.lower()
        return (pl == "alt" or pl.endswith("_alt")
                or re.search(r"_alt( |$)", pl) is not None)

    def is_ref(p):
        pl = p.lower()
        return (pl == "ref" or pl.endswith("_ref")
                or re.search(r"_ref( |$)", pl) is not None)

    if all(is_alt(p) for p in parts):
        return True
    if len(parts) == 1 and (is_alt(parts[0]) or is_ref(parts[0])):
        return True
    return False


def regulation(log2fc):
    if pd.isna(log2fc):
        return "Unknown"
    if log2fc == np.inf:
        return "Up"
    if log2fc == -np.inf:
        return "Down"
    return "Up" if log2fc >= 0 else "Down"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--pr-matrix', required=True,
                    help='DIA-NN report.pr_matrix.tsv')
    ap.add_argument('--annotation', default=None,
                    help='BioSpliceView event annotation TSV (merge_db.py output); '
                         'used to attach event/NMD columns')
    ap.add_argument('--group1-name', required=True, help='control group label')
    ap.add_argument('--group1-files', required=True,
                    help='comma-separated MS file names for group 1; must match '
                         'the column names of the pr_matrix')
    ap.add_argument('--group2-name', required=True, help='treatment group label')
    ap.add_argument('--group2-files', required=True,
                    help='comma-separated MS file names for group 2')
    ap.add_argument('--p-cutoff', type=float, default=0.05)
    ap.add_argument('--out', required=True, help='output xlsx')
    args = ap.parse_args()

    # ========== 1. read ==========
    tag_info(f"Reading {args.pr_matrix} ...")
    df = pd.read_csv(args.pr_matrix, sep="\t")
    tag_info(f"Raw table: {df.shape[0]} rows x {df.shape[1]} columns")

    # column resolution: pr_matrix columns may be file names or full paths;
    # exact match first, then substring match
    def resolve_col(name):
        cols = list(df.columns)
        if name in cols:
            return name
        hits = [c for c in cols if name in c]
        if len(hits) == 1:
            tag_info(f"Column '{name}' resolved to '{hits[0]}'")
            return hits[0]
        if len(hits) > 1:
            tag_warn(f"Column '{name}' has {len(hits)} candidates, using the first: {hits[0]}")
            return hits[0]
        return None

    g1_names = [n.strip() for n in args.group1_files.split(',') if n.strip()]
    g2_names = [n.strip() for n in args.group2_files.split(',') if n.strip()]
    col_of = {n: resolve_col(n) for n in g1_names + g2_names}
    unresolved = [n for n, c in col_of.items() if c is None]
    if unresolved:
        tag_fail(f"Could not resolve pr_matrix columns for: {', '.join(unresolved)}")
        tag_info(f"Available columns: {', '.join(map(str, df.columns))}")
        sys.exit(1)
    g1_cols = [col_of[n] for n in g1_names]
    g2_cols = [col_of[n] for n in g2_names]
    needed = g1_cols + g2_cols
    if not g1_cols or not g2_cols:
        tag_fail("Failed to resolve group columns; check --group1-files/--group2-files "
                 "against the pr_matrix column names")
        sys.exit(1)
    if len(set(needed)) != len(needed):
        tag_fail("Two or more samples resolved to the same pr_matrix column; "
                 "check the file names")
        sys.exit(1)

    # ========== 2. keep splice-derived rows ==========
    if "Protein.Ids" in df.columns:
        id_col = "Protein.Ids"
    else:
        id_col = df.columns[1]
    tag_info(f"Protein id column: '{id_col}'")
    mask_keep = df[id_col].apply(keep_row)
    df_f = df[mask_keep].copy()
    tag_info(f"Splice-derived rows kept: {df_f.shape[0]}")

    for c in needed:
        if c in df_f.columns:
            df_f[c] = pd.to_numeric(df_f[c], errors="coerce")
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    # ========== 3. Welch t-tests (pairwise NaN exclusion) ==========
    n1_full, n2_full = len(g1_cols), len(g2_cols)

    def compute_stats(input_df):
        p_values, fc_values = [], []
        g1_means, g2_means = [], []
        n_g1_list, n_g2_list, patterns = [], [], []

        for _, row in input_df.iterrows():
            g1_vals = [row[c] for c in g1_cols if c in input_df.columns]
            g2_vals = [row[c] for c in g2_cols if c in input_df.columns]
            g1_clean = [v for v in g1_vals if pd.notna(v)]
            g2_clean = [v for v in g2_vals if pd.notna(v)]
            n_g1, n_g2 = len(g1_clean), len(g2_clean)
            n_g1_list.append(n_g1)
            n_g2_list.append(n_g2)
            g1_mean = np.mean(g1_clean) if n_g1 > 0 else np.nan
            g2_mean = np.mean(g2_clean) if n_g2 > 0 else np.nan
            g1_means.append(g1_mean)
            g2_means.append(g2_mean)

            p_val, pattern = np.nan, "Other"
            if n_g1 >= 2 and n_g2 >= 2:
                try:
                    _, p_val = stats.ttest_ind(g1_clean, g2_clean, equal_var=False)
                    pattern = "Both_detected"
                except Exception:
                    p_val, pattern = np.nan, "Ttest_error"
            elif (n_g1 == n1_full and n_g2 == 0) or (n_g1 == 0 and n_g2 == n2_full):
                p_val = PLACEHOLDER_P
                pattern = "Single_group_all"
            p_values.append(p_val)
            patterns.append(pattern)

            if (not np.isnan(g1_mean) and not np.isnan(g2_mean)
                    and g1_mean > 0 and g2_mean > 0):
                fc_values.append(np.log2(g1_mean / g2_mean))
            else:
                if n_g1 == n1_full and n_g2 == 0:
                    fc_values.append(np.inf)
                elif n_g1 == 0 and n_g2 == n2_full:
                    fc_values.append(-np.inf)
                else:
                    fc_values.append(np.nan)

        out = input_df.copy()
        out[f"n_{args.group1_name}"] = n_g1_list
        out[f"n_{args.group2_name}"] = n_g2_list
        out[f"{args.group1_name}_mean"] = g1_means
        out[f"{args.group2_name}_mean"] = g2_means
        out[f"log2FC({args.group2_name}/{args.group1_name})"] = fc_values
        out["p_value"] = p_values
        out["Detection_Pattern"] = patterns
        return out

    tag_info(f"Welch t-test ({args.group2_name} vs {args.group1_name}) ...")
    df_f = compute_stats(df_f)
    df_sig = df_f[df_f["p_value"] < args.p_cutoff].copy()
    fc_col = f"log2FC({args.group2_name}/{args.group1_name})"
    df_sig["Regulation"] = df_sig[fc_col].apply(regulation)
    tag_info(f"p < {args.p_cutoff}: {df_sig.shape[0]} entries")

    # ========== 4. map significant groups back to the full table ==========
    def split_parts(val):
        if pd.isna(val):
            return []
        s = str(val).strip()
        if s == "":
            return []
        return [p.strip() for p in s.split(";") if p.strip() != ""]

    sig_parts = set()
    for v in df_sig[id_col].dropna().unique().tolist():
        sig_parts.update(split_parts(v))
    tag_info(f"Significant protein-name fragments: {len(sig_parts)}")

    def has_matching_part(val):
        return any(p in sig_parts for p in split_parts(val))

    df_matched = df[df[id_col].apply(has_matching_part)].copy()
    tag_info(f"Rows in the full table matching any significant fragment: {df_matched.shape[0]}")
    df_matched = compute_stats(df_matched)
    df_matched["Regulation"] = df_matched[fc_col].apply(regulation)
    df_matched_sig = df_matched[df_matched["p_value"] < args.p_cutoff].copy()

    # ========== 5. attach event annotation ==========
    event_cols = ['Protein.Ids', 'Event_ID', 'geneSymbol', 'Splice_Type',
                  'NMD_Status', 'Ref_Absolute_NMD', 'Alt_Absolute_NMD',
                  'Match_Status', 'FDR']
    if args.annotation:
        try:
            annot = pd.read_csv(args.annotation, sep="\t")
            ref_map = annot.set_index('Ref_header')
            alt_map = annot.set_index('Alt_header')

            def lookup(header_val):
                """Map a splice protein name back to its defining event.

                Annotation headers look like  sp|EVENT_GENE-SE_Ref|GENE.
                With --ids-to-names DIA-NN replaces '|' with spaces in
                Protein.Ids, so try the parts verbatim first, then a
                space->'|' restoration of the sp|...|NAME pattern."""
                for part in split_parts(header_val):
                    cands = [part]
                    if part.startswith("sp ") and part.count(" ") >= 2:
                        head, _, tail = part.partition(" ")
                        mid, _, name = tail.rpartition(" ")
                        cands.append(f"{head}|{mid}|{name}")
                    for cand in cands:
                        for m in (ref_map, alt_map):
                            if cand in m.index:
                                row = m.loc[cand]
                                if isinstance(row, pd.DataFrame):
                                    row = row.iloc[0]
                                return row
                return None

            for target in (df_f, df_sig, df_matched, df_matched_sig):
                # plain list comprehension: Series.apply expands into a
                # DataFrame when every result is a Series and crashes on a
                # Series/None mix
                rows = [lookup(v) for v in target[id_col]]
                for col in event_cols[1:]:
                    target[f"Event_{col}"] = [
                        r[col] if r is not None else None for r in rows]
                joined = sum(r is not None for r in rows)
                tag_info(f"Event annotation joined: {joined}/{len(target)} rows")
        except FileNotFoundError:
            tag_warn(f"Annotation file not found: {args.annotation} - "
                     f"peptide-to-event mapping will be skipped")

    # ========== 6. write ==========
    from openpyxl.styles import Alignment
    with pd.ExcelWriter(args.out, engine="openpyxl") as writer:
        for sheet, frame in ((f"Splice_sig_p{args.p_cutoff}", df_sig),
                             ("Splice_all", df_f),
                             ("Orig_Matched_All", df_matched),
                             ("Orig_Matched_Sig", df_matched_sig)):
            frame.to_excel(writer, sheet_name=sheet, index=False)
            ws = writer.sheets[sheet]
            left = Alignment(horizontal="left")
            for row in ws.iter_rows():
                for cell in row:
                    cell.alignment = left
            # practical column widths: longest value per column, capped
            for j, col in enumerate(frame.columns, start=1):
                width = max([len(str(col))] + [len(str(v)) for v in frame[col].head(200)])
                ws.column_dimensions[ws.cell(row=1, column=j).column_letter].width = min(width + 2, 60)

    rule()
    tag_ok(f"Output {args.out}")
    print(f"       Splice_sig: {df_sig.shape[0]} significant splice peptides")
    print(f"       Splice_all: {df_f.shape[0]} splice peptides")
    print(f"       Orig_Matched_All: {df_matched.shape[0]} rows")
    print(f"       Orig_Matched_Sig: {df_matched_sig.shape[0]} rows")


if __name__ == '__main__':
    main()
