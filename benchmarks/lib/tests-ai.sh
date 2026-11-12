# AI workload simulations for shared storage (NFS, S3). Sourced by run.sh after tests-<family>.sh.
#
# 14 ai-training  (MLPerf Storage / DLIO style)
#    dataset of sample files -> per epoch: all pods read the WHOLE dataset in random order, split
#    between them (data parallel) -> checkpoint: every pod writes its shard (sync or async to the
#    next epoch's reads) -> restore: all pods read the last checkpoint back.
# 15 ai-inference
#    model load (cold start): every replica reads the FULL model at the same time
#    -> lookups: small random reads at low queue depth (RAG / embeddings / index), latency percentiles
#    -> KV-cache offload: 50/50 read/write of large blocks.
# Everything lives on one shared target: the NFS export / the bucket <BUCKET_PREFIX>-ai.

S3=0; [ "$FAMILY" = s3 ] && S3=1
if [ $S3 = 1 ]; then AI_BUCKET="$BUCKET_PREFIX-ai"; BASE="$AI_BUCKET"; else BASE=/data; fi

# Create directories on the shared volume (any daemon pod sees the same volume)
pod_mkdir() { [ $S3 = 1 ] || $K exec "$FULL-0" -c elbencho -- mkdir -p "$@"; }

# Run two elbencho commands (built with eb_cmd ... --start '$S') so that they start in the same second
eb_concurrent() {
  local a=${1//\\\$S/\$S} b=${2//\\\$S/\$S}
  ctl_run "S=\$((\$(date +%s)+5)); ($a) > $REMOTE_DIR/c1.log 2>&1 & ($b) > $REMOTE_DIR/c2.log 2>&1 &
       st=0; for j in \$(jobs -p); do wait \$j || st=1; done; cat $REMOTE_DIR/c1.log $REMOTE_DIR/c2.log; rm -f $REMOTE_DIR/c?.log; exit \$st" \
    2>&1 | tee -a "$RUN_DIR/console.log"
}

ai_mkbucket() { [ $S3 = 1 ] || return 0; eb mkbucket 0 ELBENCHO_HOSTS -d -t 1 "$AI_BUCKET"; }   # idempotent

# ============================================================== training ====
: "${TRAIN_PRESET:=resnet50}"
case "$TRAIN_PRESET" in                         # average sample sizes used by MLPerf Storage
  resnet50)  : "${TRAIN_SAMPLE_SIZE:=115k}"; : "${TRAIN_SAMPLES:=100000}" ;;
  cosmoflow) : "${TRAIN_SAMPLE_SIZE:=2867k}"; : "${TRAIN_SAMPLES:=4000}" ;;
  unet3d)    : "${TRAIN_SAMPLE_SIZE:=147m}"; : "${TRAIN_SAMPLES:=80}" ;;
  custom)    : "${TRAIN_SAMPLE_SIZE:=1m}"; : "${TRAIN_SAMPLES:=10000}" ;;
  *) die "TRAIN_PRESET must be resnet50 | cosmoflow | unet3d | custom" ;;
esac
: "${TRAIN_SIZE_MIX:=}"              # optional weighted sample sizes, e.g. "64k:1,128k:2,256k:1"
: "${MODEL_SIZE:=16g}"               # (inference) e.g. 8B parameters in bf16 ~ 16 GB

# training: the sample dataset (re-read every epoch); inference: the model (read by every replica)
dataset_bytes() {
  case "$TEST" in
    14) echo $(( TRAIN_SAMPLES * $(mix_avg "${TRAIN_SIZE_MIX:-$TRAIN_SAMPLE_SIZE}") )) ;;
    15) to_bytes "$MODEL_SIZE" ;;
  esac
}
dataset_hint() { if [ "$TEST" = 14 ]; then echo "Raise TRAIN_SAMPLES (MLPerf uses datasets far larger than any cache)."; else echo "For inference a cached model is realistic for repeated loads - CACHE_CHECK=off silences this."; fi; }

train_test() {
  : "${EPOCHS:=3}"
  : "${TRAIN_THREADS:=8}"            # data loader workers per pod
  : "${TRAIN_BS:=$([ $S3 = 1 ] && echo 16m || echo 1m)}"
  : "${TRAIN_DIRECT:=1}"             # bypass the client page cache (dataset may fit in RAM otherwise)
  : "${TRAIN_REQUIRED_MIBS:=}"       # emulate accelerators: MiB/s one pod consumes -> keep-up %
  : "${CKPT_SIZE:=8g}"               # checkpoint shard written by every pod
  : "${CKPT_THREADS:=8}"
  : "${CKPT_BS:=$([ $S3 = 1 ] && echo 16m || echo 4m)}"
  : "${CKPT_EVERY:=1}"               # checkpoint after every N epochs (0 = never)
  : "${CKPT_MODE:=sync}"             # sync: training waits | async: next epoch reads during the write
  : "${RESTORE:=1}"                  # read the last checkpoint back at the end (resume after failure)
  local sz; sz=$(to_bytes "$TRAIN_SAMPLE_SIZE")
  local tree=$REMOTE_DIR/train-tree.txt mix=${TRAIN_SIZE_MIX:-$sz:1}
  local ddir=$((TRAIN_SAMPLES / 1000 + 1))
  # treefile: optional dir lines (filesystems) + one line per sample with a size drawn from the mix
  ctl "mkdir -p $REMOTE_DIR && echo '$mix' | tr ',' '\n' | awk -v n=$TRAIN_SAMPLES -v nd=$ddir -v s3=$S3 '
    function b(x){u=tolower(substr(x,length(x)));v=x+0;if(u==\"k\")v*=1024;else if(u==\"m\")v*=1048576;else if(u==\"g\")v*=1073741824;return int(v)}
    { split(\$0,a,\":\"); s[NR]=b(a[1]); w[NR]=(a[2]==\"\"?1:a[2]); tw+=w[NR]; k=NR }
    END { srand(7); if (!s3) { print \"d ai\"; print \"d ai/train\"; for(d=0;d<nd;d++) printf \"d ai/train/d%d\\n\", d }
          for(i=0;i<n;i++){ r=rand()*tw; c=0; for(j=1;j<=k;j++){ c+=w[j]; if(r<c) break }
            printf \"f %d %s/d%d/s%d\\n\", s[j], (s3?\"train\":\"ai/train\"), i%nd, i } }' > $tree"
  local common=(--treefile "$tree")
  [ $S3 = 0 ] && [ "$TRAIN_DIRECT" = 1 ] && common+=(--direct --treeroundup 4096)
  local total; total=$(ctl "awk '\$1==\"f\"{s+=\$2} END{print s}' $tree")
  log "training dataset: $TRAIN_SAMPLES samples ($TRAIN_PRESET, ${TRAIN_SIZE_MIX:-$TRAIN_SAMPLE_SIZE}), $(hr "$total") total"

  ai_mkbucket
  local sig="tree=$TRAIN_PRESET,$mix,n=$TRAIN_SAMPLES,direct=$TRAIN_DIRECT"
  if need_prepare ai-train "$sig"; then
    log "writing the training dataset"
    eb prepare 0 ELBENCHO_HOSTS -d -w -t "${PREP_THREADS:-16}" "${common[@]}" -b "$([ $S3 = 1 ] && echo 16m || echo 1m)" "$BASE"
    ds_set ai-train "$sig"
  fi

  local rd=(-r --treerand -t "$TRAIN_THREADS" -b "$TRAIN_BS" "${common[@]}")
  [ $S3 = 1 ] && rd+=(--s3fastget)
  if [ -n "$TRAIN_REQUIRED_MIBS" ]; then   # per-thread rate limit = what the accelerators can consume
    rd+=(--limitread $(( TRAIN_REQUIRED_MIBS * 1048576 / TRAIN_THREADS )))
    log "emulating accelerators: $TRAIN_REQUIRED_MIBS MiB/s per pod"
  fi
  local per=$(( $(to_bytes "$CKPT_SIZE") / CKPT_THREADS / 1048576 * 1048576 ))
  ck_args() { # epoch
    if [ $S3 = 1 ]; then echo -w -t "$CKPT_THREADS" -n 1 -N 1 -s "$per" -b "$CKPT_BS" --s3objprefix "ckpt/e$1/" "$AI_BUCKET"
    else echo -d -w -t "$CKPT_THREADS" -n 1 -N 1 -s "$per" -b "$CKPT_BS" --direct "/data/ai-ckpt/e$1"; fi
  }
  local e last=0
  for e in $(seq 1 "$EPOCHS"); do
    local do_ck=0; [ "$CKPT_EVERY" -gt 0 ] && [ $((e % CKPT_EVERY)) = 0 ] && do_ck=1
    [ $do_ck = 1 ] && pod_mkdir "/data/ai-ckpt/e$e"
    # shellcheck disable=SC2046
    if [ $do_ck = 1 ] && [ "$CKPT_MODE" = async ]; then
      log "epoch $e: reading the dataset while checkpoint e$e is written in the background"
      eb_concurrent "$(eb_cmd "train-e$e" 1 ELBENCHO_HOSTS "${rd[@]}" --start '$S' "$BASE")" \
                    "$(eb_cmd "ckpt-e$e" 1 ELBENCHO_HOSTS_2 $(ck_args "$e") --start '$S')"
    else
      log "epoch $e: reading the dataset"
      eb "train-e$e" 1 ELBENCHO_HOSTS "${rd[@]}" "$BASE"
      if [ $do_ck = 1 ]; then log "epoch $e: checkpoint ($CKPT_SIZE per pod)"; eb "ckpt-e$e" 1 ELBENCHO_HOSTS $(ck_args "$e"); fi
    fi
    [ $do_ck = 1 ] && last=$e
  done
  if [ "$RESTORE" = 1 ] && [ $last -gt 0 ]; then
    log "restore: all pods read checkpoint e$last"
    # shellcheck disable=SC2046
    eb restore 1 ELBENCHO_HOSTS $(ck_args "$last" | sed 's/^-d -w /-r /; s/^-w /-r /')
  fi
}

# ============================================================= inference ====
inference_test() {
  : "${INF_PHASES:=load lookup kvcache}"
  : "${MODEL_SHARDS:=4}"             # safetensors shards
  : "${LOAD_THREADS:=16}"            # parallel readers per replica (model streamers use 16+)
  : "${LOAD_BS:=$([ $S3 = 1 ] && echo 16m || echo 4m)}"
  : "${LOAD_DIRECT:=1}"              # cold start = nothing in the page cache
  : "${INDEX_SIZE:=8g}"              # lookups: size of the shared index (files)
  : "${LOOKUP_BS_MIX:=4k:1,16k:1,64k:1}"
  : "${LOOKUP_OBJ_SIZE:=64k}"        # lookups on S3: object size
  : "${LOOKUP_OBJECTS:=2000}"        # lookups on S3: objects per thread
  : "${LOOKUP_THREADS:=8}"
  : "${KV_SIZE:=16g}"                # KV-cache offload area (files)
  : "${KV_BS:=2m}"                   # KV chunk size
  : "${KV_OBJECTS:=200}"             # KV on S3: objects per thread
  : "${KV_THREADS:=8}"
  : "${KV_IODEPTH:=4}"
  ai_mkbucket
  local shard=$(( $(to_bytes "$MODEL_SIZE") / MODEL_SHARDS / 1048576 * 1048576 ))
  local p
  for p in $INF_PHASES; do
    case "$p" in
    load)
      local model
      if [ $S3 = 1 ]; then model="$AI_BUCKET/model/shard[1-$MODEL_SHARDS]"; else model="/data/ai-model/shard[1-$MODEL_SHARDS]"; pod_mkdir /data/ai-model; fi
      local d=(); [ $S3 = 0 ] && [ "$LOAD_DIRECT" = 1 ] && d=(--direct)
      if need_prepare ai-model "$MODEL_SIZE/$MODEL_SHARDS"; then
        log "writing the model once ($MODEL_SIZE in $MODEL_SHARDS shards)"
        eb prepare-model 0 ELBENCHO_HOSTS --numhosts 1 -w -t "$LOAD_THREADS" -s "$shard" -b 16m "${d[@]}" "$model"
        ds_set ai-model "$MODEL_SIZE/$MODEL_SHARDS"
      fi
      log "model load: $PODS replicas read the full model ($MODEL_SIZE) at the same time"
      local x=(); [ $S3 = 1 ] && x=(--s3fastget)
      eb model-load 1 ELBENCHO_HOSTS --nosvcshare -r -t "$LOAD_THREADS" -s "$shard" -b "$LOAD_BS" "${d[@]}" "${x[@]}" "$model" ;;
    lookup)
      if [ $S3 = 1 ]; then
        local l=(-n 1 -N "$LOOKUP_OBJECTS" -s "$LOOKUP_OBJ_SIZE" -b "$LOOKUP_OBJ_SIZE" -t "$LOOKUP_THREADS" --s3objprefix index/)
        if need_prepare ai-index "s3,$LOOKUP_OBJ_SIZE,$LOOKUP_OBJECTS,$LOOKUP_THREADS"; then
          eb prepare-index 0 ELBENCHO_HOSTS --numhosts 1 -w "${l[@]}" "$AI_BUCKET"; ds_set ai-index "s3,$LOOKUP_OBJ_SIZE,$LOOKUP_OBJECTS,$LOOKUP_THREADS"
        fi
        log "lookups: every replica GETs $LOOKUP_OBJ_SIZE objects of the shared index"
        eb lookup 1 ELBENCHO_HOSTS --nosvcshare -r --s3fastget "${l[@]}" --timelimit "$DURATION" --infloop "$AI_BUCKET"
      else
        pod_mkdir /data/ai-index
        local isz=$(( $(to_bytes "$INDEX_SIZE") / 4 / 1048576 * 1048576 ))
        if need_prepare ai-index "file,$INDEX_SIZE"; then
          eb prepare-index 0 ELBENCHO_HOSTS --numhosts 1 -w -t 8 -s "$isz" -b 1m --direct "/data/ai-index/idx[1-4]"; ds_set ai-index "file,$INDEX_SIZE"
        fi
        log "lookups: every replica does random reads ($LOOKUP_BS_MIX) in the shared index, queue depth 1"
        eb lookup 1 ELBENCHO_HOSTS --nosvcshare -r --rand -b "$LOOKUP_BS_MIX" -t "$LOOKUP_THREADS" --iodepth 1 -s "$isz" --direct \
           --timelimit "$DURATION" --infloop "/data/ai-index/idx[1-4]"
      fi ;;
    kvcache)
      if [ $S3 = 1 ]; then
        local k=(-n 1 -N "$KV_OBJECTS" -s "$KV_BS" -b "$KV_BS" -t "$KV_THREADS" --s3objprefix kv/)
        if need_prepare ai-kv "s3,$KV_BS,$KV_OBJECTS,$KV_THREADS,pods=$PODS"; then
          eb prepare-kv 0 ELBENCHO_HOSTS -w "${k[@]}" "$AI_BUCKET"; ds_set ai-kv "s3,$KV_BS,$KV_OBJECTS,$KV_THREADS,pods=$PODS"
        fi
        log "KV-cache offload: 50/50 GET/PUT of $KV_BS objects"
        eb kvcache 1 ELBENCHO_HOSTS -w --rwmixthr $(( KV_THREADS / 2 > 0 ? KV_THREADS / 2 : 1 )) --rwmixthrpct 50 "${k[@]}" \
           --timelimit "$DURATION" --infloop "$AI_BUCKET"
      else
        pod_mkdir /data/ai-kv
        local ksz=$(( $(to_bytes "$KV_SIZE") / 8 / 1048576 * 1048576 ))
        if need_prepare ai-kv "file,$KV_SIZE"; then
          eb prepare-kv 0 ELBENCHO_HOSTS -w -t 8 -s "$ksz" -b 1m --direct "/data/ai-kv/kv[1-8]"; ds_set ai-kv "file,$KV_SIZE"
        fi
        log "KV-cache offload: 50/50 random read/write of $KV_BS blocks"
        eb kvcache 1 ELBENCHO_HOSTS -w --rwmixpct 50 --rand -b "$KV_BS" -t "$KV_THREADS" --iodepth "$KV_IODEPTH" -s "$ksz" --direct \
           --timelimit "$DURATION" --infloop "/data/ai-kv/kv[1-8]"
      fi ;;
    *) die "unknown INF_PHASES entry '$p' (load lookup kvcache)" ;;
    esac
  done
}

# ============================================================== summary =====
post_summary() {
  echo "--- AI workload view ---"
  local f
  for f in $(ls -tr "$RUN_DIR"/*.csv 2>/dev/null); do
    awk -F, -v ph="$(basename "$f" .csv)" -v pods="$PODS" -v req="${TRAIN_REQUIRED_MIBS:-}" -v msize="$(to_bytes "${MODEL_SIZE:-0}")" '
      NR==1 { for (i=1;i<=NF;i++) h[$i]=i; next }
      $0 !~ /^[0-9]/ || ph ~ /^(prepare|mkbucket)/ || $(h["operation"]) ~ /DIRS|BUCKETS/ { next }
      { t=$(h["time ms [last]"])/1000; mib=$(h["MiB [last]"]); rate=$(h["MiB/s [last]"]); ent=$(h["entries [last]"]); eps=$(h["entries/s [last]"]) }
      ph ~ /^train-e/ { au=""; if (req!="") { k=100*rate/pods/req; au=sprintf("  keep-up %.0f%% of %s MiB/s per pod %s", k, req, (k>=97?"(storage keeps up)":"(STORAGE IS THE BOTTLENECK)")) }
                        printf "%-10s epoch time %8.1f s   %10s samples/s   %8s MiB/s%s\n", ph, t, eps, rate, au }
      ph ~ /^(ckpt-e|restore)/ { printf "%-10s %8.1f GiB in %8.1f s  = %8.2f GiB/s (all pods)\n", ph, mib/1024, t, (t>0?mib/1024/t:0) }
      ph == "model-load" { printf "%-10s slowest replica %.1f s for %.1f GiB  -> %.0f MiB/s per replica, %s MiB/s aggregate\n", ph, t, msize/1073741824, (t>0?msize/1048576/t:0), rate }
      ph ~ /^(lookup|kvcache)$/ { r=$(h["rwmix read IOPS [last]"]); printf "%-10s %s ops/s%s  avg latency %s us (see percentiles above)\n", ph, $(h["IOPS [last]"])+r, (r!=""?" (incl. "r" reads)":""), $(h["IO lat us [avg]"]) }
    ' "$f"
  done
}

run_test() {
  case "$TEST" in
    14) train_test ;;
    15) inference_test ;;
  esac
}
