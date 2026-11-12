#!/usr/bin/env bash
# S3 test 14: AI training (MLPerf Storage style): every epoch all pods read the whole sample dataset in random
#   order (data parallel), then each pod writes its checkpoint shard (sync or async); finally the last
#   checkpoint is restored. Presets: resnet50 (115k samples), cosmoflow (2.8m), unet3d (147m).
#
# usage: ./14-ai-training.sh [KEY=VALUE ...]      e.g.  ./14-ai-training.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     TRAIN_PRESET TRAIN_SAMPLES TRAIN_SAMPLE_SIZE TRAIN_SIZE_MIX EPOCHS TRAIN_THREADS TRAIN_BS TRAIN_DIRECT
#                    TRAIN_REQUIRED_MIBS CKPT_SIZE CKPT_THREADS CKPT_BS CKPT_EVERY CKPT_MODE(sync|async) RESTORE PODS
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 14 "$@"
