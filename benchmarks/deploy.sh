#!/usr/bin/env bash
# Deploys the elbencho daemons (and the controller pod) of a protocol WITHOUT running a test, and prints how to
# run elbencho by hand. Uses the same settings as the tests (PODS=auto, CPU, volumes, dataset size ...).
#   usage: ./deploy.sh <nfs|xfs|raw-block|s3> [KEY=VALUE ...]
#   e.g.   ./deploy.sh raw-block STORAGE_CLASS=array-a PODS=auto
#          ./deploy.sh s3 S3_ENDPOINT=http://minio:9000 S3_SECRET_NAME=s3-creds PODS=4
# An existing deployment of the suite (KEEP=1, the default) is reused as it is.
exec "$(dirname "$0")/lib/run.sh" "${1:?usage: deploy.sh <nfs|xfs|raw-block|s3> [KEY=VALUE ...]}" deploy "${@:2}"
