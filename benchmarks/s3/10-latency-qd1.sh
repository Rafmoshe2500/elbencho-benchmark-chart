#!/usr/bin/env bash
# S3 test 10: Latency at queue depth 1 (1 thread, iodepth 1): random read + random write, p99/p99.9/p99.99.
#
# usage: ./10-latency-qd1.sh [KEY=VALUE ...]      e.g.  ./10-latency-qd1.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     PODS BS DURATION LAT_THREADS LAT_IODEPTH (both default 1 = QD1)
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 10 "$@"
