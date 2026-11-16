#!/usr/bin/env bash
# S3 test 17: Find the maximum: runs SWEEP_TEST (default 02 = read IOPS; 01 write IOPS, 03/04 write/read throughput)
#   with growing load (THREADS per daemon: 8 16 32 ... 256) on PODS daemons (default: auto = every node) and stops when the latency
#   target is missed (LAT_AVG_MAX / LAT_P99_MAX, ms), when the result stops growing, or when the daemons themselves
#   are out of CPU. Prints every step and the best step within the target.
#
# usage: ./17-find-max.sh [KEY=VALUE ...]      e.g.  ./17-find-max.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds SWEEP_TEST=01
# test tunables:     SWEEP_TEST SWEEP_THREADS SWEEP_IODEPTH LAT_AVG_MAX LAT_P99_MAX MIN_GAIN FIND_STOP CLIENT_CPU_MAX
#                    PODS (auto) PODS_PER_NODE CPU (auto) CPU_SHARE (+ all tunables of the swept test)
# general:           NAMESPACE MEMORY NODE_SELECTOR TOLERATE_ALL PREPARE KEEP EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 17 "$@"
