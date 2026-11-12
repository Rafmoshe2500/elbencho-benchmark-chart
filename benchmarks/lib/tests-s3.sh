# Test definitions for S3 object storage. Sourced by run.sh.
#
#   layout multi : load spread over BUCKETS buckets  (<BUCKET_PREFIX>-1 .. -N)
#   layout single: all daemons and threads on ONE bucket (<BUCKET_PREFIX>-single)
#   mix tests 05-07: ONE bucket <BUCKET_PREFIX>-mix (elbencho custom tree mode is single-bucket only)
# Every dataset kind lives under its own key prefix, so tests do not disturb each other.
# "IOPS" for S3 = object requests/s (PUT/GET of OBJ_SIZE objects, one request per object).

: "${OBJECTS:=1000}"          # IOPS tests: objects per thread
: "${TPUT_OBJ_SIZE:=256m}"    # throughput tests: object size (multipart, part = BS)
: "${TPUT_OBJECTS:=4}"        # throughput tests: objects per thread
: "${MIX_OBJECTS:=20000}"     # mix tests: objects in the mixed-size dataset (all daemons)
: "${META_FILES:=2000}"       # test 11: objects per thread
: "${RANGE_OBJ_SIZE:=256m}"   # test 16: size of the large objects (e.g. Parquet/ORC files)
: "${RANGE_OBJECTS:=4}"       # test 16: large objects per thread
: "${RANGE_BS:=64k:1,1m:2,8m:1}"  # test 16: size of every ranged GET (footer reads + column chunks)

dataset_bytes() {
  case "$TEST" in
    01|02|08|09) echo $(( OBJECTS * THREADS * PODS * $(to_bytes "$OBJ_SIZE") )) ;;
    03|04)       echo $(( TPUT_OBJECTS * THREADS * PODS * $(to_bytes "$TPUT_OBJ_SIZE") )) ;;
    05|06|07)    echo $(( MIX_OBJECTS * $(mix_avg "$BS_MIX") )) ;;
    10)          echo $(( 1000 * PODS * $(to_bytes "$BS") )) ;;
    16)          echo $(( RANGE_OBJECTS * THREADS * PODS * $(to_bytes "$RANGE_OBJ_SIZE") )) ;;
    *)           echo 0 ;;
  esac
}
dataset_hint() {
  case "$TEST" in
    01|02|08|09) echo "Raise OBJECTS (objects per thread) or OBJ_SIZE." ;;
    03|04)       echo "Raise TPUT_OBJECTS or TPUT_OBJ_SIZE." ;;
    05|06|07)    echo "Raise MIX_OBJECTS." ;;
    16)          echo "Raise RANGE_OBJECTS or RANGE_OBJ_SIZE." ;;
    *)           echo "Make the dataset larger." ;;
  esac
}

if [ "$LAYOUT" = single ]; then BUCKETS_PATH="$BUCKET_PREFIX-single"
else BUCKETS_PATH="$BUCKET_PREFIX-[1-$BUCKETS]"; fi
TIMED=(--timelimit "$DURATION" --infloop)
IOPS_DS=(-n 1 -N "$OBJECTS" -s "$OBJ_SIZE" -b "$OBJ_SIZE" --s3objprefix iops/)

mkbuckets() {   # always (idempotent, cheap): buckets may have been deleted outside of this suite
  eb mkbuckets 0 ELBENCHO_HOSTS -d -t 1 "$BUCKETS_PATH"
}

prepare_iops() {
  local sig="$BUCKETS_PATH,obj=$OBJ_SIZE,n=$OBJECTS,t=$THREADS,pods=$PODS"
  if need_prepare "iops-$LAYOUT" "$sig"; then
    log "preparing $((OBJECTS*THREADS*PODS)) objects of $OBJ_SIZE"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$THREADS" "${IOPS_DS[@]}" "$BUCKETS_PATH"
    ds_set "iops-$LAYOUT" "$sig"
  fi
}

prepare_tput() {
  local sig="$BUCKETS_PATH,obj=$TPUT_OBJ_SIZE,n=$TPUT_OBJECTS,b=$BS,t=$THREADS,pods=$PODS"
  if need_prepare tput "$sig"; then
    log "preparing $((TPUT_OBJECTS*THREADS*PODS)) objects of $TPUT_OBJ_SIZE"
    eb prepare 0 ELBENCHO_HOSTS -w -t "$THREADS" -n 1 -N "$TPUT_OBJECTS" -s "$TPUT_OBJ_SIZE" -b "$BS" --s3objprefix tput/ "$BUCKETS_PATH"
    ds_set tput "$sig"
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
  rd=${rd//\\\$S/\$S}; wr=${wr//\\\$S/\$S}   # let the remote shell expand the common start time
  ctl_run "S=\$((\$(date +%s)+5)); ($rd) > $REMOTE_DIR/mix-read.log 2>&1 & ($wr) > $REMOTE_DIR/mix-write.log 2>&1 &
       st=0; for j in \$(jobs -p); do wait \$j || st=1; done; cat $REMOTE_DIR/mix-read.log $REMOTE_DIR/mix-write.log; exit \$st" \
    2>&1 | tee -a "$RUN_DIR/console.log"
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
    03)    eb "$TNAME" 1 ELBENCHO_HOSTS -w -t "$THREADS" --iodepth "$IODEPTH" -n 1 -N "$TPUT_OBJECTS" -s "$TPUT_OBJ_SIZE" -b "$BS" --s3objprefix tput/ "${TIMED[@]}" "$BUCKETS_PATH" ;;
    04)    prepare_tput
           eb "$TNAME" 1 ELBENCHO_HOSTS -r --s3fastget -t "$THREADS" --iodepth "$IODEPTH" -n 1 -N "$TPUT_OBJECTS" -s "$TPUT_OBJ_SIZE" -b "$BS" --s3objprefix tput/ "${TIMED[@]}" "$BUCKETS_PATH" ;;
    05|06|07) mix_test ;;
    10)    local l=(-t 1 -n 1 -N 1000 -s "$BS" -b "$BS" --s3objprefix lat/)
           eb lat-put 1 ELBENCHO_HOSTS -w "${l[@]}" "${TIMED[@]}" "$BUCKETS_PATH"
           eb lat-get 1 ELBENCHO_HOSTS -r --s3fastget "${l[@]}" "${TIMED[@]}" "$BUCKETS_PATH" ;;
    16)    # random byte-range GETs inside large objects (analytics engines reading Parquet/ORC)
           local r=(-n 1 -N "$RANGE_OBJECTS" -s "$RANGE_OBJ_SIZE" --s3objprefix range/)
           local sig="$BUCKETS_PATH,obj=$RANGE_OBJ_SIZE,n=$RANGE_OBJECTS,t=$THREADS,pods=$PODS"
           if need_prepare range "$sig"; then
             log "preparing $((RANGE_OBJECTS*THREADS*PODS)) objects of $RANGE_OBJ_SIZE"
             eb prepare 0 ELBENCHO_HOSTS -w -t "$THREADS" "${r[@]}" -b 16m "$BUCKETS_PATH"
             ds_set range "$sig"
           fi
           log "random ranged GETs ($RANGE_BS) at random offsets of random objects"
           eb "$TNAME" 1 ELBENCHO_HOSTS -r --s3randobj --s3fastget -t "$THREADS" --iodepth "$IODEPTH" "${r[@]}" -b "$RANGE_BS" \
              --randamount "$(( $(dataset_bytes) * 1000 ))" "${TIMED[@]}" "$BUCKETS_PATH" ;;
    11)    local m=(-t "$THREADS" -n 1 -N "$META_FILES" -s 0 --s3objprefix meta/)
           eb meta-create 1 ELBENCHO_HOSTS -w "${m[@]}" "$BUCKETS_PATH"
           eb meta-list   1 ELBENCHO_HOSTS --s3listobjpar "${m[@]}" "$BUCKETS_PATH"
           eb meta-head   1 ELBENCHO_HOSTS --stat "${m[@]}" "$BUCKETS_PATH"
           eb meta-delete 1 ELBENCHO_HOSTS -F "${m[@]}" "$BUCKETS_PATH" ;;
  esac
}
