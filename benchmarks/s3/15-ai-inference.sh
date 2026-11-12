#!/usr/bin/env bash
# S3 test 15: AI inference: model load at cold start (every replica reads the full model at once), lookups
#   (small random reads at queue depth 1, latency) and KV-cache offload (50/50 large blocks).
#
# usage: ./15-ai-inference.sh [KEY=VALUE ...]      e.g.  ./15-ai-inference.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     INF_PHASES("load lookup kvcache") MODEL_SIZE MODEL_SHARDS LOAD_THREADS LOAD_BS LOAD_DIRECT INDEX_SIZE
#                    LOOKUP_BS_MIX LOOKUP_OBJ_SIZE LOOKUP_OBJECTS LOOKUP_THREADS KV_SIZE KV_BS KV_OBJECTS KV_THREADS KV_IODEPTH DURATION PODS
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 15 "$@"
