# BioSpliceView: An End-to-End Pipeline for Splice-Peptide Evidence

BioSpliceView integrates transcriptomic and proteomic analysis into a single,
resumable workflow: alternative splicing events are quantified with rMATS,
annotated at the protein level with BioSpliceView, and the resulting
splice-derived protein sequences are interrogated for peptide evidence by
DIA-NN mass-spectrometry search.

```
FASTQ/BAM → rMATS → BioSpliceView → search DB → DIA-NN → peptide summary
```

## Repository layout

| Path | Purpose |
|---|---|
| `run_pipeline.sh` | Five-stage driver; resumable in place, colored per-stage output (`NO_COLOR=1` disables color) |
| `template/` | Configuration templates: `full.conf` (Stages 1–5) and `splicing.conf` (Stages 1–2 only) |
| `scripts/build_star_index.sh` | STAR genome index construction (~30 GB per organism; invoked automatically when absent) |
| `scripts/merge_db.py` | Merges the background proteome with splice-derived sequences into a combined search database, with per-event annotation |
| `scripts/summarize_splice_peptides.py` | Maps DIA-NN identifications back to their splicing events and performs between-group comparison |
| `scripts/fetch_background_fasta.sh` | Retrieves the background proteome from the project mirror (gzip handled automatically) |
| `scripts/install_diann.sh` | Installs the pinned DIA-NN release (invoked automatically when absent) |
| `environment.yml`, `requirements.txt` | Conda environment and Python dependencies (rMATS via Bioconda) |
| `Dockerfile` | Container image build; DIA-NN is provisioned at runtime rather than baked in |

## Installation

The pipeline requires Bash, conda (or Mamba), and either `curl`, `wget`, or
Python 3 for downloads. All analytical software is pinned to specific
versions to guarantee reproducibility:

```bash
conda env create -f environment.yml
conda activate bsv-pipeline
```

This installs rMATS 4.3.0 (which includes STAR 2.7.10b), BioSpliceView, and
the Python dependencies. DIA-NN 2.6.1, the background proteome, and the STAR
genome index are provisioned automatically on first use and cached in the
work directory.

A Docker image is provided as an alternative:

```bash
docker build -t biospliceview-pipeline:1.0 .
```

## Quick start

Copy the configuration template matching the desired scope, adjust the paths,
and run the pipeline:

```bash
cp template/full.conf pipeline.conf     # splicing-only analysis: template/splicing.conf
bash run_pipeline.sh pipeline.conf
```

The configuration file is read with `source`, i.e. interpreted as Bash:
quote values containing spaces, and keep `job_id` to letters, digits, dot,
dash and underscore (it is used as a path prefix).

Results are written to `<work_dir>/jobs/<job_id>/final/`, with
`<job_id>_peptide_summary.xlsx` as the principal deliverable. Interrupted or
parameter-modified runs resume from the work directory: completed stages are
detected and skipped, so rerunning the same command continues where the
previous run left off.

An equivalent Docker invocation:

```bash
docker run --rm -v /data:/data biospliceview-pipeline:1.0 /data/pipeline.conf
```

## Tool provisioning

Each external tool is resolved in a fixed order: an explicit path in the
configuration takes precedence; otherwise the tool is located in the active
conda environment and on `PATH`; failing that, it is provisioned
automatically.

Tools already installed on the system are declared in the
"already-installed software" section of the configuration - the pipeline
uses those binaries as-is and will not download or install anything for them:

```ini
rmats_py=/home/user/envs/bsv-pipeline/bin/rmats.py
star_bin=/home/user/envs/bsv-pipeline/bin/STAR
diann_bin=/home/user/diann/diann-linux
```

Without a configured path, missing components are fetched and installed
automatically:

| Component | Automatic provisioning |
|---|---|
| DIA-NN 2.6.1 | Downloaded to `<work_dir>/ref/diann/` during Stage 0, after the proteome fetch and in parallel with index construction and alignment; reused by subsequent runs |
| STAR and rMATS | Provided by the conda environment; the STAR version is verified at startup (2.7.10b is fixed internally and is not a user setting) |
| BioSpliceView | Installed with the conda environment |
| Background proteome | Downloaded from the project mirror (mouse: 17,283 reviewed entries; human: 20,431) to `<work_dir>/ref/uniprot_<species>.fasta` |

## Transcriptome sample grouping

Group names serve as filename prefixes within `fastq_dir`. Given
`group1=WT`, `group2=KO`, and `fastq_dir=/data/fastq`, the pipeline scans
`/data/fastq/WT-*` and `/data/fastq/KO-*`:

| Files in `fastq_dir` | Interpretation |
|---|---|
| `WT-01_R1.fq.gz` with `WT-01_R2.fq.gz` | WT replicate 1, paired end |
| `WT-02.R1.fq.gz` with `WT-02.R2.fq.gz` | WT replicate 2 (dot-separated naming is equally accepted) |
| `KO-1_1.fq.gz` with `KO-1_2.fq.gz` | KO replicate 1 (`_1`/`_2` naming is accepted) |
| `sample1_R1.fq.gz` (no group prefix) | Not collected; the prefix must match a group name |

Mate pairing is resolved automatically for the common naming conventions
(`_R1`/`_R2`, `.R1`/`.R2`, `_1.`/`.2.`, and variants). Discovered pairs are
listed at Stage 0 for verification; an unpaired R1 aborts the run.
Alternatively, explicit comma-separated `R1:R2` lists may be supplied via
`group1_samples` / `group2_samples`, which take precedence over prefix
discovery.

## Example data

Publicly available paired-end RNA-seq datasets with two condition groups are
suitable for evaluation; two replicates per group complete within
approximately one hour:

- **SRP111619** — mouse macrophages, IL-10 knockout versus wild type.
  FASTQ files can be obtained with the
  [SRA Toolkit](https://github.com/ncbi/sra-tools)
  (`fasterq-dump --split-files`) and renamed to the `WT-*` / `KO-*` scheme
  described above.
- **GSE133399** — mouse liver RNA-seq with substantial alternative splicing
  (GEO); the same renaming applies.

Stage 4 additionally requires mass-spectrometry acquisitions (Bruker `.d` or
Thermo `.raw`) from matching conditions, placed in the directory given by
`ms_dir`.

## Work directory

All shared resources and per-job products are organized under `work_dir`.
Every run inspects this directory first and reuses whatever is present:

```
work_dir/
├── ref/                          shared cache (reused across jobs)
│   ├── uniprot_mouse.fasta       background proteome (downloaded if absent)
│   ├── diann/                    DIA-NN installation (auto-provisioned)
│   └── star_index/               STAR genome index (~30 GB, built if absent)
├── jobs/
│   └── <job_id>/                 per-job products
│       ├── 01_rmats/ ... 05_summary/
│       └── final/                final deliverables
└── logs/                         run logs (ANSI codes stripped)
```

## Output structure

```
jobs/<job_id>/
├── 01_rmats/                     rMATS event tables and sample lists
├── 02_biospliceview/Job_<id>/    BioSpliceView annotation output
├── 03_search_db/
│   ├── <job_id>_combined_search_db.fasta
│   └── <job_id>_event_annotation.tsv
├── 04_diann/
│   ├── <job_id>_predicted_library.predicted.speclib
│   ├── <job_id>_report.parquet
│   └── <job_id>_report.pr_matrix.tsv
├── 05_summary/
│   └── <job_id>_peptide_summary.xlsx
└── final/                        consolidated deliverables
```

## DIA-NN configuration

Stage 4 executes two DIA-NN commands: spectral-library prediction (4a) and
database search (4b). All tuning options are collected in a single
configuration string that is passed verbatim to both commands; the pipeline
appends the file-managing arguments (`--fasta`, `--lib`, `--f`,
`--out-lib`, `--out`) itself:

```ini
diann_params="--threads 16 --verbose 1 --qvalue 0.01 --semi --rt-profiling --direct-quant --ids-to-names --min-pep-len 7 --max-pep-len 30 --min-pr-mz 300 --max-pr-mz 1800 --min-pr-charge 1 --max-pr-charge 4 --min-fr-mz 200 --max-fr-mz 1800 --cut K*,R* --missed-cleavages 1 --unimod4 --met-excision"
```

For DDA acquisitions, append `--dda`. The search pass additionally
receives `--matrices` (unless already present in the string); without it
DIA-NN does not produce the `report.pr_matrix.tsv` the summary stage
requires. This flag enables the
DDA-identification-aided workflow, in which `--f` inputs are interpreted as
DDA runs; DIA runs would then be supplied via `--f-dia`, and DDA-only
analyses receive a "no DIA data files provided" notice, which is
informational. For quantitative timsTOF data, DIA-NN recommends additionally
`--reanalyse` (match-between-runs) together with fixed mass accuracies of
10–15 ppm (`--mass-acc-ms1`, `--mass-acc`). These search-only options
apply to 4b only; library generation (4a) runs without them. Note that
MBR requires at least two input files - with a single acquisition
DIA-NN reports "MBR turned off".

Each assembled command is echoed as a `cmd:` line before execution, so the
effective DIA-NN invocation is fully transparent. During 4b the live progress
counts two passes per raw file (pre-processing, then analysis), so six files
show as 12 passes.

## Version pinning

| Software | Version |
|---|---|
| rMATS-turbo | 4.3.0 |
| STAR | 2.7.10b |
| DIA-NN | 2.6.1 |
| BioSpliceView | 1.0.1 |

Versions are pinned in `environment.yml` and the `Dockerfile` and should not
be upgraded silently.

## Parameters

All parameters are set in the configuration file; anything not listed falls
back to a built-in default.

| Key | Stage | Description | Default |
|---|---|---|---|
| `mode` | — | `splicing` (Stages 1–2) or `full` (Stages 1–5); the `PIPELINE_MODE` environment variable takes precedence | `splicing` |
| `work_dir` | all | output root; holds `ref/`, `jobs/`, `logs/` | — |
| `gtf` / `genome_fa` | 1–3 | reference annotation and genome; one genome build throughout | — |
| `fastq_dir` | 1 | FASTQ directory; samples are paired by `<group>` prefix | — |
| `group1` / `group2` | 1, 4, 5 | group names, used as sample filename prefixes | — |
| `group1_samples` / `group2_samples` | 1 | explicit `R1:R2` lists; override prefix discovery | auto |
| `threads` / `job_id` | all | worker threads / output prefix (DIA-NN `--threads` follows the same value) | 16 / — |
| `read_type` / `read_length` | 1 | rMATS library type and read length | `paired` / 150 |
| `fdr` / `psi` / `minjc` | 2 | BioSpliceView event filters | 0.05 / 0.05 / 10 |
| `species` | 3 | background proteome species (`mouse` or `human`) | — |
| `uniprot_fasta` | 3 | explicit background FASTA; overrides `species` | — |
| `min_aa` | 3 | minimum splice-protein length in amino acids | 10 |
| `ms_dir` | 4 | directory of MS raw files (`.d` / `.raw`) | — |
| `group1_ms_files` / `group2_ms_files` | 4 | explicit MS file lists; override prefix discovery | auto |
| `diann_bin` | 4 | DIA-NN binary (auto-installed when unset; version pinned internally at 2.6.1) | 2.6.1 |
| `diann_params` | 4 | DIA-NN tuning flags, passed verbatim to both commands | built-in defaults |
| `p_cutoff` | 5 | nominal p-value threshold for the summary | 0.05 |
| `dl_rate_limit` | all | per-transfer download rate cap (internal default: 2 MB/s; override when needed) | `2m` |
| `rmats_py` / `star_bin` | 0 | explicit tool paths; environment and `PATH` fallbacks apply (`diann_bin` likewise in the already-installed section) | auto |
| `star_index` | 0 | existing STAR index to reuse instead of building | auto |
| `status_cols` | all | status-line width cap, for terminals reporting more columns than they render | auto |

## Consistency requirements

1. **A single genome build throughout.** The rMATS GTF, the BioSpliceView
   genome FASTA and GTF, and the background proteome must originate from the
   same species and genome assembly; a mismatched GTF silently degrades
   `Match_Status` toward PARTIAL/ANCHOR_ONLY.
2. **Mass-spectrometry file naming is independent of the transcriptome.**
   With `ms_dir` set, `.d`/`.raw` files are scanned by group prefix
   (case-sensitive). Unprefixed files are assigned to a group only when
   their count exactly matches that group's FASTQ replicate count, and every
   assignment is reported at Stage 0; ambiguous cases abort the run rather
   than being guessed. `report.pr_matrix.tsv` columns carry the original file
   names and are matched automatically at Stage 5.

## Statistical notes

The summary stage applies nominal (uncorrected) two-sided Welch t-tests with
pairwise exclusion of missing values. A single-group detection (all
replicates of one group, none of the other) is flagged with a placeholder
p-value of 1e-10 and infinite log2 fold change
(`Detection_Pattern=Single_group_all`). The resulting
`*_peptide_summary.xlsx` is intended as an exploratory candidate screen;
candidate splice peptides warrant targeted mass spectrometry or synthetic
peptide validation.

## License

The DIA-NN release package is distributed under an academic license; consult
dia-nn.com regarding commercial use. The pipeline code is provided under the
repository license.
