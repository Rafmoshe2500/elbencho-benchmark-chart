# Test definitions for filesystem targets (NFS, XFS). Sourced by run.sh.
#
# Dataset: FILES files of FILE_SIZE at /data/f1../data/fN.
#   layout multi : every daemon has its own volume (XFS: own PVC, NFS: own sub dir) -> --nosvcshare,
#                  every daemon works on its full own dataset.
#   layout single: all daemons share ONE volume / directory; the dataset is split between them.

# FILES and FILE_SIZE are set by size_dataset (run.sh) from DATASET_SIZE
: "${PREP_THREADS:=8}"
: "${META_DIRS:=10}"        # test 11: dirs per thread
: "${META_FILES:=1000}"     # test 11: files per dir

if [ "$FILES" = 1 ]; then PATHS=/data/f1; else PATHS="/data/f[1-$FILES]"; fi

dataset_bytes() {   # what the measured phase works on (metadata test: not relevant)
  [ "$TEST" = 11 ] && { echo 0; return; }
  local one=$(( FILES * $(to_bytes "$FILE_SIZE") ))
  if [ "$LAYOUT" = multi ]; then echo $(( PODS * one )); else echo "$one"; fi
}
dataset_hint() { echo "Raise DATASET_SIZE."; }
SHARE=""; [ "$LAYOUT" = multi ] && SHARE="--nosvcshare"
TIMED=(--timelimit "$DURATION" --infloop)

prepare() {
  # multi: every daemon has its own files, so the marker records how many daemons have them; fewer daemons
  # later find their files, more daemons need a new prepare. single: one shared set, the pod count is irrelevant.
  local sig="files=$FILES,size=$FILE_SIZE"
  if need_prepare_pods dataset "$sig"; then
    log "preparing dataset: $FILES x $FILE_SIZE per $([ "$LAYOUT" = multi ] && echo daemon || echo 'shared volume')"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$PREP_THREADS" -s "$FILE_SIZE" -b 1m --direct $SHARE "$PATHS"
    ds_set dataset "$sig,pods=$([ "$LAYOUT" = multi ] && echo "$PODS" || echo 0)"
  else
    log "dataset already prepared ($sig) - skipping (PREPARE=always to force)"
  fi
}

run_test() {
  local io=(-t "$THREADS" --iodepth "$IODEPTH" -s "$FILE_SIZE" --direct $SHARE)
  case "$TEST" in
    01|09) prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -w --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$PATHS" ;;
    02|08) prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -r --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$PATHS" ;;
    03)             eb "$TNAME" 1 ELBENCHO_HOSTS -w -b "$BS" "${io[@]}" "${TIMED[@]}" "$PATHS" ;;
    04)    prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -r -b "$BS" "${io[@]}" "${TIMED[@]}" "$PATHS" ;;
    05|06|07)
           prepare; eb "$TNAME" 1 ELBENCHO_HOSTS -w --rwmixpct "$READ_PCT" --rand -b "$BS_MIX" "${io[@]}" "${TIMED[@]}" "$PATHS" ;;
    10)    prepare
           eb lat-randread  1 ELBENCHO_HOSTS -r --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$PATHS"
           eb lat-randwrite 1 ELBENCHO_HOSTS -w --rand -b "$BS" "${io[@]}" "${TIMED[@]}" "$PATHS" ;;
    11)    local m=(-t "$THREADS" -n "$META_DIRS" -N "$META_FILES" -s 0 /data)
           eb meta-create 1 ELBENCHO_HOSTS -d -w "${m[@]}"
           eb meta-stat   1 ELBENCHO_HOSTS --stat "${m[@]}"
           eb meta-delete 1 ELBENCHO_HOSTS -F -D "${m[@]}" ;;
  esac
}
