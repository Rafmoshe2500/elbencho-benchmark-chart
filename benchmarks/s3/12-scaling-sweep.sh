#!/usr/bin/env bash
# S3 test 12: Sweep: runs another test for several values of PODS, THREADS, IODEPTH, NCONNECT (nfs) or DATASET_SIZE
#   and prints a table with a latency verdict per step.
#
# usage: ./12-scaling-sweep.sh [KEY=VALUE ...]      e.g.  ./12-scaling-sweep.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     SWEEP_TEST SWEEP_PODS SWEEP_THREADS SWEEP_IODEPTH SWEEP_NCONNECT SWEEP_DATASET_SIZE (see README, "Sweeps")
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE DATASET_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 12 "$@"
