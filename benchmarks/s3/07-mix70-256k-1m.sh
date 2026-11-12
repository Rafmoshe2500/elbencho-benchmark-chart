#!/usr/bin/env bash
# S3 test 07: 70/30 read/write mix, object sizes 256k/512k/1m (equal weights).
#
# usage: ./07-mix70-256k-1m.sh [KEY=VALUE ...]      e.g.  ./07-mix70-256k-1m.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 07 "$@"
