# ============================================================
# BioSpliceView end-to-end pipeline image
#
#   docker build -t biospliceview-pipeline:1.0 .
#
# In the image: rMATS 4.3.0 + STAR 2.7.10b (bioconda) + BioSpliceView
# (dual-source download). DIA-NN is not baked in: on first run the pipeline
# downloads pinned 2.6.1 in the background to the work volume ref/diann/
# (in parallel with rMATS, reused across jobs); or point diann_bin= at an
# existing binary. All versions pinned; works with the legacy builder.
# ============================================================
FROM mambaorg/micromamba:1.5-jammy

LABEL org.opencontainers.image.title="BioSpliceView end-to-end pipeline" \
      org.opencontainers.image.description="FASTQ/BAM → rMATS 4.3.0 → BioSpliceView → search DB → DIA-NN 2.6.1 → splice-peptide summary" \
      org.opencontainers.image.source="https://github.com/rennmeng/BioSpliceView"

# ---- BioSpliceView source (pinned tag v1.0.1; override BSV_PRIMARY to change) ----
ARG BSV_PRIMARY="https://github.com/rennmeng/BioSpliceView/archive/refs/tags/v1.0.1.tar.gz"
ARG BSV_BACKUP="https://www.spliceview.cn/static/files/main.tar.gz"

# ---- pip index: Tsinghua mirror by default (use --build-arg PIP_INDEX=https://pypi.org/simple for official) ----
ARG PIP_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"

# ---- 1) scientific stack (pinned versions) ----
# rmats 4.3.0 carries a numpy<2.0 constraint; the solver lands on numpy 1.26.x
RUN micromamba install -y -q -n base -c conda-forge -c bioconda \
        python=3.10 "rmats=4.3.0" "star=2.7.10b" \
    && micromamba clean -a -y -q \
    && echo "[ OK ] conda stack ready  · python 3.10 | rMATS 4.3.0 | STAR 2.7.10b"
ENV PATH="/opt/conda/bin:${PATH}"

# ---- 2) system lib: libgomp1 = runtime dependency of the official DIA-NN
#         binary (DIA-NN itself lands on the work volume at first run) ----
USER root
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && echo "[ OK ] system lib ready   · libgomp1"
USER mambauser

# ---- 3) BioSpliceView (dual source: GitHub 2 tries → mirror 3 tries) ----
# This layer only COPYs the fetcher + requirements, so day-to-day pipeline
# edits do not invalidate this network layer's cache. pip uses the mirror
# and falls back to official PyPI; -q keeps per-package spam down.
COPY scripts/fetch_url.sh /opt/pipeline/scripts/fetch_url.sh
COPY requirements.txt /tmp/requirements.txt
RUN bash /opt/pipeline/scripts/fetch_url.sh \
        "$BSV_PRIMARY" "$BSV_BACKUP" /tmp/bsv.tar.gz 2 3 \
    && (pip install -q --no-cache-dir --no-build-isolation \
            --retries 5 --timeout 60 -i "$PIP_INDEX" \
            /tmp/bsv.tar.gz -r /tmp/requirements.txt \
        || pip install -q --no-cache-dir --no-build-isolation \
            --retries 5 --timeout 60 \
            /tmp/bsv.tar.gz -r /tmp/requirements.txt) \
    && echo "[ OK ] BioSpliceView ok   · $(pip show BioSpliceView 2>/dev/null | awk '/^Version/{print $2}')"

# ---- 4) pipeline scripts ----
COPY run_pipeline.sh /opt/pipeline/
COPY scripts/ /opt/pipeline/scripts/

# ---- 5) entrypoint (bash prefix → no exec-bit dependency anywhere) ----
WORKDIR /data
ENTRYPOINT ["bash", "/opt/pipeline/run_pipeline.sh"]
CMD ["/data/pipeline.conf"]
