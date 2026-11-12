#!/usr/bin/env bash
# S3 test 05: 70/30 read/write mix, object sizes 32k/64k/128k (equal weights).
#
# usage: ./05-mix70-32k-128k.sh [KEY=VALUE ...]      e.g.  ./05-mix70-32k-128k.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 05 "$@"
