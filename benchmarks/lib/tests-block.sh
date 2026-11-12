# Test definitions for raw block devices (volumeMode: Block, no filesystem). Sourced by run.sh.
#
# The device is /dev/elbencho in every daemon. Without DEV_SIZE the whole device is used.
#   layout multi : every daemon has its own device -> --nosvcshare (each daemon covers its full device)
#   layout single: all daemons (same node) share ONE device; the device range is split between them.
# WARNING: these tests overwrite the whole device.

: "${DEV_SIZE:=}"           # optional: limit the tested range, e.g. 100g
: "${PREP_THREADS:=8}"

DEV=/dev/elbencho

dataset_bytes() {   # the tested range of every device
  local one; one=$(to_bytes "${DEV_SIZE:-$PVC_SIZE}")
  if [ "$LAYOUT" = multi ]; then echo $(( PODS * one )); else echo "$one"; fi
}
dataset_hint() { echo "Raise PVC_SIZE (or DEV_SIZE)$( [ "$LAYOUT" = multi ] && echo ' / PODS')."; }
SHARE=""; [ "$LAYOUT" = multi ] && SHARE="--nosvcshare"
SIZE=(); [ -n "$DEV_SIZE" ] && SIZE=(-s "$DEV_SIZE")
TIMED=(--timelimit "$DURATION" --infloop)

prepare() {
  # Fill the device once: reads from never-written (thin) blocks are unrealistically fast.
  local sig="dev=${DEV_SIZE:-full},pods=$PODS"
  if need_prepare dataset "$sig"; then
    log "preconditioning: sequential write of the ${DEV_SIZE:-whole} device on every daemon"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$PREP_THREADS" -b 1m --direct "${SIZE[@]}" $SHARE "$DEV"
    ds_set dataset "$sig"
  else
    log "device already preconditioned ($sig) - skipping (PREPARE=always to force)"
  fi
}

run_test() {
  local io=(-t "$THREADS" --iodepth "$IODEPTH" --direct "${SIZE[@]}" $SHARE)
  case "$TEST" in
    01|09) prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -w --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$DEV" ;;
    02|08) prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -r --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$DEV" ;;
    03)             eb "$TNAME" 1 ELBENCHO_HOSTS -w -b "$BS" "${io[@]}" "${TIMED[@]}" "$DEV" ;;
    04)    prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -r -b "$BS" "${io[@]}" "${TIMED[@]}" "$DEV" ;;
    05|06|07)
           prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -w --rwmixpct "$READ_PCT" --rand -b "$BS_MIX" "${io[@]}" "${TIMED[@]}" "$DEV" ;;
    10)    prepare
           eb lat-randread  1 ELBENCHO_HOSTS -r --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$DEV"
           eb lat-randwrite 1 ELBENCHO_HOSTS -w --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$DEV" ;;
    11)    die "test 11 (metadata) needs a filesystem - not applicable to raw block devices" ;;
  esac
}
