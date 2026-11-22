# Test definitions for S3 object storage. Sourced by run.sh.
#
#   layout multi : load spread over BUCKETS buckets  (<BUCKET_PREFIX>-1 .. -N)
#   layout single: all daemons and threads on ONE bucket (<BUCKET_PREFIX>-single)
#   mix tests 05-07: ONE bucket <BUCKET_PREFIX>-mix (elbencho custom tree mode is single-bucket only)
# Every dataset kind lives under its own key prefix, so tests do not disturb each other.
# "IOPS" for S3 = object requests/s (PUT/GET of OBJ_SIZE objects, one request per object).

# Sizes: OBJ_SIZE (4k IOPS tests, 256m throughput / range tests) and DATASET_SIZE; OBJECTS (per thread) and
# MIX_OBJECTS (mixes, in total) are computed by size_dataset in run.sh.
: "${META_FILES:=2000}"       # test 11: objects per thread (S3 has no directories: META_DIRS does not apply)
: "${RANGE_BS:=64k:1,1m:2,8m:1}"  # test 16: size of every ranged GET (footer reads + column chunks)

dataset_bytes() {
  case "$TEST" in
    01|02|08|09|03|04|16) echo $(( OBJECTS * THREADS * PODS * $(to_bytes "$OBJ_SIZE") )) ;;   # the part this run touches
    05|06|07)    echo $(( MIX_OBJECTS * $(mix_avg "$BS_MIX") )) ;;
    10)          echo $(( 1000 * PODS * $(to_bytes "$BS") )) ;;
    *)           echo 0 ;;
  esac
}
dataset_hint() { echo "Raise DATASET_SIZE."; }

if [ "$LAYOUT" = single ]; then BUCKETS_PATH="$BUCKET_PREFIX-single"
else BUCKETS_PATH="$BUCKET_PREFIX-[1-$BUCKETS]"; fi
TIMED=(--timelimit "$DURATION" --infloop)
IOPS_DS=(-n 1 -N "${OBJECTS:-1}" -s "$OBJ_SIZE" -b "$OBJ_SIZE" --s3objprefix iops/)

mkbuckets() {   # always (idempotent, cheap): buckets may have been deleted outside of this suite
  eb mkbuckets 0 ELBENCHO_HOSTS -d -t 1 "$BUCKETS_PATH"
}

# Object names depend only on the global thread number ("rank" 0 .. PODS x THREADS - 1), not on how the
# ranks are split into pods and threads (verified with elbencho 3.3-3, several buckets). So a run with fewer
# pods/threads reads a subset of a larger dataset, and a new prepare is needed only when a run needs MORE
# ranks than exist. Sweeps over THREADS / PODS therefore do not rewrite the dataset at every step.
need_prepare_ranks() {   # need_prepare_ranks <kind> <signature without ranks>
  case "$PREPARE" in always) return 0 ;; never) return 1 ;; esac
  local cur; cur=$(ds_get "$1")
  [ "${cur%,ranks=*}" = "$2" ] && [ "${cur##*,ranks=}" -ge $((PODS * THREADS)) ] 2>/dev/null && return 1
  return 0
}

prepare_iops() {
  local sig="$BUCKETS_PATH,obj=$OBJ_SIZE,n=$OBJECTS"
  if need_prepare_ranks "iops-$LAYOUT" "$sig"; then
    # a THREADS ladder (test 17) names its highest step, so that the small objects are written only once
    local pt=$THREADS; [ "${PREP_MIN_THREADS:-0}" -gt "$pt" ] 2>/dev/null && pt=$PREP_MIN_THREADS
    log "preparing $((OBJECTS*pt*PODS)) objects of $OBJ_SIZE"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$pt" "${IOPS_DS[@]}" "$BUCKETS_PATH"
    ds_set "iops-$LAYOUT" "$sig,ranks=$((PODS * pt))"
  fi
}

prepare_tput() {
  local sig="$BUCKETS_PATH,obj=$OBJ_SIZE,n=$OBJECTS,b=$BS"
  local pt=$THREADS; [ "${PREP_MIN_THREADS:-0}" -gt "$pt" ] 2>/dev/null && pt=$PREP_MIN_THREADS
  if need_prepare_ranks tput "$sig"; then
    log "preparing $((OBJECTS*pt*PODS)) objects of $OBJ_SIZE"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$pt" -n 1 -N "$OBJECTS" -s "$OBJ_SIZE" -b "$BS" --s3objprefix tput/ "$BUCKETS_PATH"
    ds_set tput "$sig,ranks=$((PODS * pt))"
  fi
}

# Mixed object sizes: S3 does not allow --rwmixpct, and --rwmixthr cannot be combined with mixed
# sizes. So readers (READ_PCT % of THREADS) and writers run as two coordinated elbencho runs that
# start at the same second, against two service instances in every daemon pod (ports 1611/1612).
mix_test() {
  # custom tree mode supports a single bucket only -> the mix tests use "<BUCKET_PREFIX>-mix"
  local tree=$REMOTE_DIR/tree.txt prefix="mix-$TEST" maxb
  BUCKETS_PATH="$BUCKET_PREFIX-mix"
  eb mkbucket-mix 0 ELBENCHO_HOSTS -d -t 1 "$BUCKETS_PATH"
  maxb=$(echo "$BS_MIX" | tr ',' '\n' | cut -d: -f1 | awk '
    function b(x){u=tolower(substr(x,length(x)));n=x+0;if(u=="k")n*=1024;else if(u=="m")n*=1048576;else if(u=="g")n*=1073741824;return n}
    {v=b($1); if(v>m)m=v} END{print m}')
  ctl "mkdir -p $REMOTE_DIR && echo '$BS_MIX' | tr ',' '\n' | awk -v n=$MIX_OBJECTS '
    function b(x){u=tolower(substr(x,length(x)));v=x+0;if(u==\"k\")v*=1024;else if(u==\"m\")v*=1048576;return v}
    { split(\$0,a,\":\"); s[NR]=b(a[1]); w[NR]=(a[2]==\"\"?1:a[2]); tw+=w[NR]; k=NR }
    END { srand(42); for(i=0;i<n;i++){ r=rand()*tw; c=0; for(j=1;j<=k;j++){ c+=w[j]; if(r<c) break } printf \"f %d d%d/o%d\\n\", s[j], i%100, i } }' > $tree && wc -l < $tree" >/dev/null
  local sig="$BUCKETS_PATH,mix=$BS_MIX,n=$MIX_OBJECTS,pods=$PODS"
  if need_prepare "$prefix" "$sig"; then
    log "preparing $MIX_OBJECTS objects with sizes $BS_MIX"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$THREADS" --treefile "$tree" -b "$maxb" --s3objprefix "$prefix/r/" "$BUCKETS_PATH"
    ds_set "$prefix" "$sig"
  fi
  local rt=$(( (THREADS * READ_PCT + 50) / 100 )); [ "$rt" -lt 1 ] && rt=1
  local wt=$(( THREADS - rt )); [ "$wt" -lt 1 ] && wt=1
  log "mixed run: $rt reader + $wt writer threads per daemon, object sizes $BS_MIX"
  local rd wr
  rd=$(eb_cmd mix-read 1 ELBENCHO_HOSTS -r --s3fastget -t "$rt" --treefile "$tree" -b "$maxb" --s3objprefix "$prefix/r/" "${TIMED[@]}" --start '$S' "$BUCKETS_PATH")
  wr=$(eb_cmd mix-write 1 ELBENCHO_HOSTS_2 -w -t "$wt" --treefile "$tree" -b "$maxb" --s3objprefix "$prefix/w/" "${TIMED[@]}" --start '$S' "$BUCKETS_PATH")
  eb_pair mix-read "$rd" mix-write "$wr"   # common start after the treefile reached every daemon
}

post_summary() {
  [ -f "$RUN_DIR/mix-read.csv" ] && [ -f "$RUN_DIR/mix-write.csv" ] || return 0
  awk -F, 'FNR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $0~/^[0-9]/{o=$(h["IOPS [first]"]); m=$(h["MiB/s [first]"]); if(FILENAME~/read/){r+=o;rm+=m}else{w+=o;wm+=m}}
    END{t=r+w; printf "COMBINED  ops/s read=%d write=%d total=%d  (read share %.1f%%)  MiB/s read=%d write=%d total=%d\n", r,w,t,(t?100*r/t:0),rm,wm,rm+wm}' \
    "$RUN_DIR/mix-read.csv" "$RUN_DIR/mix-write.csv"
}

run_test() {
  mkbuckets
  case "$TEST" in
    01|09) eb "$TNAME" 1 ELBENCHO_HOSTS -w -t "$THREADS" --iodepth "$IODEPTH" "${IOPS_DS[@]}" "${TIMED[@]}" "$BUCKETS_PATH" ;;
    02|08) prepare_iops
           eb "$TNAME" 1 ELBENCHO_HOSTS -r --s3fastget -t "$THREADS" --iodepth "$IODEPTH" "${IOPS_DS[@]}" "${TIMED[@]}" "$BUCKETS_PATH" ;;
    03)    eb "$TNAME" 1 ELBENCHO_HOSTS -w -t "$THREADS" --iodepth "$IODEPTH" -n 1 -N "$OBJECTS" -s "$OBJ_SIZE" -b "$BS" --s3objprefix tput/ "${TIMED[@]}" "$BUCKETS_PATH" ;;
    04)    prepare_tput
           eb "$TNAME" 1 ELBENCHO_HOSTS -r --s3fastget -t "$THREADS" --iodepth "$IODEPTH" -n 1 -N "$OBJECTS" -s "$OBJ_SIZE" -b "$BS" --s3objprefix tput/ "${TIMED[@]}" "$BUCKETS_PATH" ;;
    05|06|07) mix_test ;;
    10)    local l=(-t 1 -n 1 -N 1000 -s "$BS" -b "$BS" --s3objprefix lat/)
           # The GET phase reads all 1000 objects of every daemon. The timed PUT phase may stop before it has
           # written them all (a slow S3 needs > DURATION for 1000 PUTs), so write them once beforehand.
           local sig="$BUCKETS_PATH,obj=$BS"
           local cur; cur=$(ds_get lat)   # one thread per daemon here, so the marker counts daemons
           if [ "$PREPARE" = always ] || { [ "$PREPARE" != never ] && ! { [ "${cur%,ranks=*}" = "$sig" ] && [ "${cur##*,ranks=}" -ge "$PODS" ] 2>/dev/null; }; }; then
             log "preparing $((1000 * PODS)) objects of $BS for the GET phase"
             eb prepare 0 ELBENCHO_HOSTS -w -t 1 -n 1 -N 1000 -s "$BS" -b "$BS" --s3objprefix lat/ "$BUCKETS_PATH"
             ds_set lat "$sig,ranks=$PODS"
           fi
           eb lat-put 1 ELBENCHO_HOSTS -w "${l[@]}" "${TIMED[@]}" "$BUCKETS_PATH"
           eb lat-get 1 ELBENCHO_HOSTS -r --s3fastget "${l[@]}" "${TIMED[@]}" "$BUCKETS_PATH" ;;
    16)    # random byte-range GETs inside large objects (analytics engines reading Parquet/ORC)
           local r=(-n 1 -N "$OBJECTS" -s "$OBJ_SIZE" --s3objprefix range/)
           local sig="$BUCKETS_PATH,obj=$OBJ_SIZE,n=$OBJECTS"
           local pt=$THREADS; [ "${PREP_MIN_THREADS:-0}" -gt "$pt" ] 2>/dev/null && pt=$PREP_MIN_THREADS
           if need_prepare_ranks range "$sig"; then
             log "preparing $((OBJECTS*pt*PODS)) objects of $OBJ_SIZE"
             eb prepare 0 ELBENCHO_HOSTS -w -t "$pt" "${r[@]}" -b 16m "$BUCKETS_PATH"
             ds_set range "$sig,ranks=$((PODS * pt))"
           fi
           log "random ranged GETs ($RANGE_BS) at random offsets of random objects"
           eb "$TNAME" 1 ELBENCHO_HOSTS -r --s3randobj --s3fastget -t "$THREADS" --iodepth "$IODEPTH" "${r[@]}" -b "$RANGE_BS" \
              --randamount "$(( $(dataset_bytes) * 1000 ))" "${TIMED[@]}" "$BUCKETS_PATH" ;;
    11)    [ -z "${META_DIRS:-}" ] || warn "META_DIRS has no effect on S3 (objects have no directories)"
           local m=(-t "$THREADS" -n 1 -N "$META_FILES" -s 0 --s3objprefix meta/)
           eb meta-create 1 ELBENCHO_HOSTS -w "${m[@]}" "$BUCKETS_PATH"
           eb meta-list   1 ELBENCHO_HOSTS --s3listobjpar "${m[@]}" "$BUCKETS_PATH"
           eb meta-head   1 ELBENCHO_HOSTS --stat "${m[@]}" "$BUCKETS_PATH"
           eb meta-delete 1 ELBENCHO_HOSTS -F "${m[@]}" "$BUCKETS_PATH" ;;
  esac
}
