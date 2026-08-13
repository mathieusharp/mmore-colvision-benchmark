#!/usr/bin/env bash
# Push the working tree's version of the benchmark files to the cluster repo
# without a git push: they are tarred, base64-encoded and unpacked by a short
# RunAI job. Run from the repo root, after "source .rcp-env".
#
# The archive is built from the files listed in FILES below, read at run time,
# so this script can never ship a stale hard-coded blob. When the venv itself
# needs to change (a new pin in pyproject.toml or uv.lock), re-bootstrap it
# afterwards: FORCE_BOOTSTRAP=1 ./scripts/rcp/bootstrap-venv.sh --wait
set -euo pipefail

[ -f .rcp-env ] || { echo "Run from the repo root (where .rcp-env lives)." >&2; exit 1; }
source .rcp-env

FILES=(
    pyproject.toml
    uv.lock
    src/benchmark_colvision/runners/mmore_wrapper.py
    src/benchmark_colvision/runners/orchestrate.py
    src/benchmark_colvision/runners/run_track_a.py
    src/benchmark_colvision/runners/text_baseline.py
    src/benchmark_colvision/runners/mmore_text_baseline.py
    src/benchmark_colvision/clients/vllm_client.py
    src/benchmark_colvision/queries/inverse_query_gen.py
    src/benchmark_colvision/queries/cli.py
    src/benchmark_colvision/queries/pdf_pages.py
    src/benchmark_colvision/queries/schema.py
    src/benchmark_colvision/corpus/cli.py
    src/benchmark_colvision/corpus/corpus_manifest.py
    src/benchmark_colvision/corpus/vidore_v2.py
    src/benchmark_colvision/corpus/ocr_pages.py
    src/benchmark_colvision/runners/run_track_b_vidore.py
    src/benchmark_colvision/runners/cli.py
    scripts/rcp/submit.sh
    scripts/rcp/materialize_tb_lang.py
    src/benchmark_colvision/corpus/hal_downloader.py
    src/benchmark_colvision/corpus/pmc_zh_sampler.py
    configs/models.yaml
    configs/track_a.yaml
    configs/track_b_en.yaml
    configs/track_b_fr.yaml
    configs/track_b_zh.yaml
    configs/track_b_de.yaml
    configs/track_b_es.yaml
)

for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "[patch][ERROR] missing file: $f" >&2; exit 1; }
done

# Deterministic archive, base64 on a single line.
TMP_TGZ=$(mktemp /tmp/bcv-patch.XXXXXX.tar.gz)
trap 'rm -f "${TMP_TGZ}"' EXIT
tar -czf "${TMP_TGZ}" "${FILES[@]}"
B64=$(base64 -w0 "${TMP_TGZ}")
NBYTES=$(wc -c < "${TMP_TGZ}")
echo "[patch] archive ${NBYTES} bytes → ${#B64} chars b64"

# Split into 2700-char chunks, under the size limit of one k8s env var.
CHUNK=2700
ENV_ARGS=()
CAT_CMD=""
i=0
off=0
while [ "${off}" -lt "${#B64}" ]; do
    i=$((i + 1))
    part="${B64:${off}:${CHUNK}}"
    ENV_ARGS+=(-e "P${i}=${part}")
    if [ "${i}" -eq 1 ]; then
        CAT_CMD="printf \"%s\" \"\${P${i}}\" > /tmp/p.b64"
    else
        CAT_CMD="${CAT_CMD} && printf \"%s\" \"\${P${i}}\" >> /tmp/p.b64"
    fi
    off=$((off + CHUNK))
done
echo "[patch] ${i} chunks"

REMOTE_CMD="${CAT_CMD} && base64 -d /tmp/p.b64 > /tmp/patch.tar.gz && tar -xzf /tmp/patch.tar.gz -C /mloscratch/users/mbonnet/bcv-dev && echo PATCH_OK"

NAME="bcv-patch-$(date +%H%M%S)"
echo "[patch] submitting ${NAME} — ${#FILES[@]} files, ${i} b64 chunks"
runai submit "${NAME}" \
  --image "${IMAGE}" \
  --gpu 0 \
  --existing-pvc "claimname=${PVC_SCRATCH},path=/mloscratch" \
  -e PROJECT_ROOT_AT=/mloscratch/users/mbonnet/bcv-dev \
  -e PACKAGE_NAME=benchmark_colvision \
  -e BCV_VENV=/mloscratch/users/mbonnet/bcv-venv \
  -p light-mbonnet \
  --suppress-deprecation-message \
  "${ENV_ARGS[@]}" \
  -- bash -c "${REMOTE_CMD}"
echo "[patch] submitted — check with: runai logs ${NAME} -p light-mbonnet --suppress-deprecation-message"
