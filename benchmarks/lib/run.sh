#!/usr/bin/env bash
# elbencho benchmark runner.
#   usage: run.sh <protocol> <test-id> [KEY=VALUE ...]
#   protocol: nfs | xfs | raw-block | s3
#   test-id:  01..16 (see benchmarks/README.md)
# All tunables can be given as KEY=VALUE arguments or as environment variables.
set -euo pipefail

BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(cd "$BENCH_DIR/.." && pwd)

log()  { printf '\033[1;34m[bench]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[bench] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bench] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# sizes: 4k / 16m / 2g / 1t / 50Gi / 1TiB / plain bytes -> bytes ; bytes -> "1.5 GiB"
to_bytes() {
  local v; v=$(printf "%s" "$1" | tr "A-Z" "a-z"); v=${v%b}; v=${v%i}
  awk -v v="$v" 'BEGIN{ n=v+0; u=substr(v,length(v)); m=1
    if(u=="k")m=1024; else if(u=="m")m=1048576; else if(u=="g")m=1073741824; else if(u=="t")m=1099511627776
    printf "%.0f\n", n*m }'
}
hr() { awk -v b="$1" 'BEGIN{ split("B KiB MiB GiB TiB PiB",u," "); i=1; while (b>=1024 && i<6) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'; }
# average size of a weighted mix "32k:1,64k:2" (or a single size) in bytes
mix_avg() { local tot=0 w=0 e s n; for e in ${1//,/ }; do s=$(to_bytes "${e%%:*}"); n=${e#*:}; [ "$n" = "$e" ] && n=1; tot=$((tot + s*n)); w=$((w + n)); done; echo $((tot / w)); }

[ $# -ge 2 ] || die "usage: run.sh <nfs|xfs|raw-block|s3> <test-id> [KEY=VALUE ...]"
PROTO=$1; TEST=$2; shift 2
for kv in "$@"; do
  [[ $kv == *=* ]] || die "arguments must be KEY=VALUE, got '$kv'"
  export "${kv?}"
done
[ -f "$BENCH_DIR/$PROTO/profile.env" ] || die "unknown protocol '$PROTO'"
USER_THREADS=${THREADS:-}; USER_BS=${BS:-}; USER_IODEPTH=${IODEPTH:-}; USER_DURATION=${DURATION:-}
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm >/dev/null || die "helm not found"

# ---------------------------------------------------------------- defaults ---
# Global defaults (protocol profile and per-test defaults come on top; KEY=VALUE always wins).
: "${NAMESPACE:=elbencho-bench}"
: "${RELEASE_PREFIX:=eb}"
: "${CHART:=$REPO_DIR/charts/elbencho}"
: "${IMAGE_REPO:=}"            # default: chart default (breuner/elbencho)
: "${IMAGE_TAG:=}"             # default: chart default (v<appVersion>)
: "${PODS:=2}"                 # number of elbencho daemons (load generators)
: "${SPREAD:=preferred}"       # spread daemons over nodes: preferred | required | none
: "${NODE_SELECTOR:=}"         # e.g. "node-role/bench=true" (key=value)
: "${CPU:=}"                   # cpu request+limit per daemon, e.g. "8"
: "${MEMORY:=}"                # memory request+limit per daemon, e.g. "16Gi"
: "${PREPARE:=auto}"           # dataset creation before read/mixed tests: auto | always | never
: "${KEEP:=1}"                 # 1 = keep the deployment for the next test (see cleanup.sh)
: "${LIVE:=1}"                 # 1 = live progress lines during the run
: "${LAT:=1}"                  # 1 = latency + percentiles (p99, p99.9, p99.99)
: "${EXTRA_ARGS:=}"            # extra elbencho args for the measured phases
: "${HELM_ARGS:=}"             # extra helm args, e.g. "--set tolerations[0].operator=Exists"
: "${RESULTS_DIR:=$BENCH_DIR/results}"
: "${WAIT_TIMEOUT:=10m}"
: "${STORAGE_CACHE:=}"         # cache of the storage system (controllers DRAM/NVRAM + SSD cache), e.g. 512g
: "${CACHE_FACTOR:=2}"         # the dataset should be at least CACHE_FACTOR x STORAGE_CACHE
: "${CACHE_CHECK:=warn}"       # warn | fail | off
: "${BLOCKVARPCT:=}"           # % of every written block refilled with random data (elbencho default 100 =
                               # incompressible). Lower = compressible/dedupable data, e.g. 50
: "${DETACH:=1}"               # 1 = benchmarks run detached in the controller pod and survive a lost
                               #     kubectl connection (VPN/SSH drop); output is polled every POLL s
: "${POLL:=5}"
: "${RECONNECT_TIMEOUT:=3600}" # give up after this many seconds without a working connection

# shellcheck disable=SC1090
source "$BENCH_DIR/$PROTO/profile.env"

case "$PROTO" in
  nfs|xfs) FAMILY=file ;;
  raw-block) FAMILY=block ;;
  s3) FAMILY=s3 ;;
esac

# ------------------------------------------------------------ test catalog ---
# name | layout (multi = every daemon on its own volume/buckets, single = one shared PVC/bucket)
case "$TEST" in
  01) TNAME=write-iops ;;          02) TNAME=read-iops ;;
  03) TNAME=write-throughput ;;    04) TNAME=read-throughput ;;
  05) TNAME=mix70-32k-128k ;;      06) TNAME=mix70-4k ;;
  07) TNAME=mix70-256k-1m ;;
  08) TNAME=single-target-read-iops ;;  09) TNAME=single-target-write-iops ;;
  10) TNAME=latency-qd1 ;;         11) TNAME=metadata ;;
  12) TNAME=scaling-sweep ;;       13) TNAME=iodepth-sweep ;;
  14) TNAME=ai-training ;;         15) TNAME=ai-inference ;;
  16) TNAME=range-read ;;
  *) die "unknown test id '$TEST'" ;;
esac
case "$TEST" in
  11) [ "$FAMILY" != block ] || die "test 11 (metadata) needs a filesystem - not available for raw-block" ;;
  13) [ "$FAMILY" != s3 ] || die "test 13 (iodepth sweep) is for nfs / xfs / raw-block" ;;
  14|15) [ "$PROTO" = nfs ] || [ "$PROTO" = s3 ] || die "tests 14/15 (AI) are for nfs and s3 (shared datasets)" ;;
  16) [ "$FAMILY" = s3 ] || die "test 16 (range reads in large objects) is for s3" ;;
esac
# AI tests: one dataset shared by all pods (like a real training cluster / inference fleet)
LAYOUT=multi; [[ $TEST == 08 || $TEST == 09 || $TEST == 14 || $TEST == 15 ]] && LAYOUT=single

# Per-test defaults
case "$TEST" in
  01|02|08|09) : "${BS:=4k}"; : "${THREADS:=16}"; : "${IODEPTH:=16}" ;;
  03|04)       : "${BS:=1m}"; : "${THREADS:=8}";  : "${IODEPTH:=4}" ;;
  05)          : "${BS_MIX:=32k:1,64k:1,128k:1}";  : "${THREADS:=16}"; : "${IODEPTH:=8}" ;;
  06)          : "${BS_MIX:=$MIX_SMALL_DEFAULT}";  : "${THREADS:=16}"; : "${IODEPTH:=16}" ;;
  07)          : "${BS_MIX:=256k:1,512k:1,1m:1}";  : "${THREADS:=8}";  : "${IODEPTH:=4}" ;;
  10)          : "${BS:=4k}"; THREADS=${LAT_THREADS:-1}; IODEPTH=${LAT_IODEPTH:-1}; : "${DURATION:=30}" ;;  # always QD1 unless LAT_*
  11)          : "${THREADS:=16}"; : "${IODEPTH:=1}" ;;
esac
: "${READ_PCT:=70}"
# S3: concurrency comes from threads (one request in flight per thread by default) and the
# "block" of the IOPS tests is the object size; throughput tests use 16 MiB multipart parts.
if [ "$FAMILY" = s3 ]; then
  case "$TEST" in
    01|02|08|09) THREADS=${USER_THREADS:-32}; IODEPTH=${USER_IODEPTH:-1}; BS=${USER_BS:-$OBJ_SIZE} ;;
    03|04)       THREADS=${USER_THREADS:-16}; IODEPTH=${USER_IODEPTH:-1}; BS=${USER_BS:-16m} ;;
    05|06|07)    THREADS=${USER_THREADS:-20} ;;
    16)          THREADS=${USER_THREADS:-16}; IODEPTH=${USER_IODEPTH:-1} ;;
  esac
fi
: "${DURATION:=60}"            # seconds per timed phase

# ------------------------------------------------------- sweeps (12, 13) ---
# 12: pods (and NCONNECT / IODEPTH) sweep, 13: iodepth sweep at a fixed pod count.
if [ "$TEST" = 12 ] || [ "$TEST" = 13 ]; then
  if [ "$TEST" = 13 ]; then
    : "${SWEEP_TEST:=02}"; : "${SWEEP_PODS:=$PODS}"; : "${SWEEP_IODEPTH:=1 2 4 8 16 32 64 128}"
  else
    : "${SWEEP_TEST:=02}"; : "${SWEEP_PODS:=1 2 4 8}"; : "${SWEEP_IODEPTH:=}"
  fi
  : "${SWEEP_NCONNECT:=}"        # nfs only, e.g. "1 4 8 16"
  # dataset size (find where the storage cache ends): FILE_SIZE (nfs/xfs), DEV_SIZE (raw-block), OBJECTS (s3)
  SWEEP_SIZE_VAR=""; SWEEP_SIZES=""
  for v in FILE_SIZE DEV_SIZE OBJECTS; do
    sv="SWEEP_$v"; if [ -n "${!sv:-}" ]; then SWEEP_SIZE_VAR=$v; SWEEP_SIZES=${!sv}; fi
  done
  case "$SWEEP_TEST" in 12|13|14|15) die "SWEEP_TEST must be one of 01..11" ;; esac
  [ -z "$SWEEP_IODEPTH" ] || [ "$SWEEP_TEST" != 10 ] || die "test 10 is fixed at QD1 - sweep another test"
  SWEEP_ID=sweep-$(date +%Y%m%d-%H%M%S)
  for p in $SWEEP_PODS; do
    for n in ${SWEEP_NCONNECT:-_}; do
      for q in ${SWEEP_IODEPTH:-_}; do
        for z in ${SWEEP_SIZES:-_}; do
          extra=(PODS="$p" SWEEP_ID="$SWEEP_ID")
          [ "$n" != _ ] && extra+=(NCONNECT="$n")
          [ "$q" != _ ] && extra+=(IODEPTH="$q")
          [ "$z" != _ ] && extra+=("$SWEEP_SIZE_VAR=$z" CACHE_CHECK=warn)
          log "sweep: test $SWEEP_TEST with ${extra[*]}"
          "$0" "$PROTO" "$SWEEP_TEST" "${extra[@]}" || warn "sweep step failed: ${extra[*]}"
        done
      done
    done
  done
  log "sweep results ($SWEEP_ID):"
  awk -F, -v id="$SWEEP_ID" '
    NR==1 { for (i=1;i<=NF;i++) h[$i]=i
            printf "%-5s %-8s %-7s %-7s %-7s %-10s %-11s %12s %10s %10s %10s %10s\n","pods","nconnect","threads","iodepth","block","dataset","operation","total_iops","MiB/s","rdMiB/s","lat_avg_us","p99_us"; next }
    $(h["sweep_id"])==id && $(h["phase"]) !~ /^(prepare|mkbucket)/ {
      ds=$(h["dataset_gib"]); printf "%-5s %-8s %-7s %-7s %-7s %-10s %-11s %12s %10s %10s %10s %10s\n", $(h["pods"]), $(h["nconnect"]), $(h["threads"]), $(h["iodepth"]), $(h["block"]), (ds==""?"-":ds"G"), $(h["operation"]), $(h["total_iops"]), $(h["mib_s"]), $(h["read_mib_s"]), $(h["lat_avg_us"]), $(h["p99_us"]) }' "$RESULTS_DIR/summary.csv"
  exit 0
fi

# --------------------------------------------------------------- run setup ---
case "$PROTO" in raw-block) PSHORT=blk ;; *) PSHORT=$PROTO ;; esac
REL="$RELEASE_PREFIX-$PSHORT"
[ "$FAMILY" != s3 ] && [ "$LAYOUT" = single ] && REL="$REL-single"
FULL="$REL-elbencho"                     # chart fullname
CTL="deploy/$FULL-ctl"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RESULTS_DIR/$PROTO/$TEST-$TNAME/$RUN_ID"
REMOTE_DIR="/tmp/eb/$RUN_ID"
mkdir -p "$RUN_DIR"
: > "$RUN_DIR/console.log"
K="kubectl -n $NAMESPACE"

# Record all parameters of this run
{
  echo "# $PROTO $TEST-$TNAME  ($RUN_ID)"
  for v in PROTO TEST TNAME LAYOUT NAMESPACE REL PODS THREADS IODEPTH BS BS_MIX READ_PCT DURATION \
           FILES FILE_SIZE PVC_SIZE STORAGE_CLASS NFS_SERVER NFS_PATH NFS_STORAGE_CLASS NFS_VERS NCONNECT \
           RSIZE WSIZE NFS_EXTRA_OPTS S3_ENDPOINT S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS \
           TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS META_DIRS META_FILES EXTRA_ARGS SPREAD CPU MEMORY \
           DEV_SIZE STORAGE_CACHE CACHE_FACTOR BLOCKVARPCT DETACH RANGE_OBJ_SIZE RANGE_OBJECTS RANGE_BS; do
    [ -n "${!v:-}" ] && printf '%s=%q\n' "$v" "${!v}"
  done
} > "$RUN_DIR/params.env"

# ------------------------------------------------------------ helm values ----
VALUES="$RUN_DIR/values.yaml"
render_values() {
  {
    echo "mode: service"
    echo "replicaCount: $PODS"
    echo "terminationGracePeriodSeconds: 5"
    [ -n "$IMAGE_REPO$IMAGE_TAG" ] && { echo "image:"; [ -n "$IMAGE_REPO" ] && echo "  repository: $IMAGE_REPO"; [ -n "$IMAGE_TAG" ] && echo "  tag: \"$IMAGE_TAG\""; }
    echo "serviceMode:"
    # 2 service instances: S3 mixes and async checkpoints run two coordinated elbencho runs at once
    echo "  instancesPerPod: $([ "$FAMILY" = s3 ] || [ "$PROTO" = nfs ] && echo 2 || echo 1)"
    echo "  controller: {enabled: true}"
    if [ -n "$CPU$MEMORY" ]; then
      echo "resources:"
      for k in requests limits; do
        echo "  $k:"; [ -n "$CPU" ] && echo "    cpu: \"$CPU\""; [ -n "$MEMORY" ] && echo "    memory: \"$MEMORY\""
      done
    fi
    [ -n "$NODE_SELECTOR" ] && { echo "nodeSelector:"; echo "  \"${NODE_SELECTOR%%=*}\": \"${NODE_SELECTOR#*=}\""; }
    local sel="{matchLabels: {app.kubernetes.io/name: elbencho, app.kubernetes.io/instance: $REL}}"
    echo "affinity:"
    if [ "$FAMILY" != s3 ] && [ "$LAYOUT" = single ] && [ "${ACCESS_MODE:-ReadWriteOnce}" = ReadWriteOnce ] && [ "$PROTO" != nfs ]; then
      # one RWO volume shared by all daemons -> they must run on the same node
      echo "  podAffinity:"
      echo "    requiredDuringSchedulingIgnoredDuringExecution:"
      echo "      - {topologyKey: kubernetes.io/hostname, labelSelector: $sel}"
    elif [ "$SPREAD" = preferred ]; then
      echo "  podAntiAffinity:"
      echo "    preferredDuringSchedulingIgnoredDuringExecution:"
      echo "      - weight: 100"
      echo "        podAffinityTerm: {topologyKey: kubernetes.io/hostname, labelSelector: $sel}"
    elif [ "$SPREAD" = required ]; then
      echo "  podAntiAffinity:"
      echo "    requiredDuringSchedulingIgnoredDuringExecution:"
      echo "      - {topologyKey: kubernetes.io/hostname, labelSelector: $sel}"
    else
      echo "  {}"
    fi
    profile_values      # protocol specific part (profile.env)
  } > "$VALUES"
}

# ------------------------------------------------------------- deployment ---
deploy() {
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
  if declare -F profile_predeploy >/dev/null; then profile_predeploy; fi
  render_values
  log "deploying $REL ($PODS daemons, layout=$LAYOUT) in namespace $NAMESPACE"
  # shellcheck disable=SC2086
  helm upgrade --install "$REL" "$CHART" -n "$NAMESPACE" --create-namespace -f "$VALUES" \
       --wait --timeout "$WAIT_TIMEOUT" $HELM_ARGS >> "$RUN_DIR/console.log" 2>&1 \
    || { tail -5 "$RUN_DIR/console.log" >&2; $K get pods,pvc -l app.kubernetes.io/instance="$REL" >&2
         echo "--- latest warning events of $REL:" >&2
         $K get events --field-selector type=Warning --sort-by=.lastTimestamp -o go-template='{{range .items}}{{.involvedObject.kind}}/{{.involvedObject.name}} {{.reason}}: {{.message}}{{"\n"}}{{end}}' 2>/dev/null \
           | grep -F "$FULL" | tail -4 >&2
         die "helm deploy failed (see above)"; }
  $K rollout status "statefulset/$FULL" --timeout "$WAIT_TIMEOUT" >/dev/null
  $K rollout status "$CTL" --timeout "$WAIT_TIMEOUT" >/dev/null
  if [ "$FAMILY" = file ] && [ -n "${EXPECT_FS:-}" ]; then
    local fs; fs=$($K exec "$FULL-0" -c elbencho -- stat -f -c %T /data 2>/dev/null || true)
    [ "$fs" = "$EXPECT_FS" ] || warn "/data in the pods is '$fs', expected '$EXPECT_FS' - check the StorageClass!"
    log "filesystem under test: $fs"
  fi
  $K get pods -l "app.kubernetes.io/instance=$REL" -o wide >> "$RUN_DIR/console.log"
}

# ------------------------------------------------------- remote execution ---
ctl() { $K exec -i "$CTL" -- bash -c "$1"; }

S3_AUTH=""
if [ "$FAMILY" = s3 ]; then
  S3_AUTH='--s3endpoints "$AWS_ENDPOINT_URL" --s3key "$AWS_ACCESS_KEY_ID" --s3secret "$AWS_SECRET_ACCESS_KEY"'
  [ -n "${S3_REGION:-}" ] && S3_AUTH="$S3_AUTH --s3region \"\$AWS_REGION\""
fi
LIVE_FLAGS="--nolive"; [ "$LIVE" = 1 ] && LIVE_FLAGS="--live1n --liveint 5000"
LAT_FLAGS=""; [ "$LAT" = 1 ] && LAT_FLAGS="--lat --latpercent --latpercent9s 2"

# eb <phase-name> <measured:0|1> <hosts-var> <elbencho args...>
eb_cmd() {
  local name=$1 measured=$2 hv=$3; shift 3
  local extra=""; [ "$measured" = 1 ] && extra="$LAT_FLAGS $EXTRA_ARGS"
  # data content of every write (prepare included): compressible/dedupable when BLOCKVARPCT < 100
  if [ -n "$BLOCKVARPCT" ] && [[ " $* " == *" -w "* ]]; then extra="$extra --blockvarpct $BLOCKVARPCT"; fi
  printf 'elbencho %s --hosts "$%s" %s --label %q --csvfile %s/%s.csv --resfile %s/%s.txt %s %s' \
    "$S3_AUTH" "$hv" "$LIVE_FLAGS" "$PROTO/$TEST-$TNAME/$name" "$REMOTE_DIR" "$name" "$REMOTE_DIR" "$name" \
    "$extra" "$(printf '%q ' "$@")"
}
eb() {
  local name=$1
  log "phase '$name': elbencho ${*:4}"
  ctl_run "$(eb_cmd "$@")" 2>&1 | tee -a "$RUN_DIR/console.log"
}

# Run a shell script in the controller pod and stream its output; returns its exit code.
# DETACH=1: the script runs detached (setsid/nohup) and its output is polled, so a dropped
# kubectl connection (VPN, SSH, laptop sleep) does not stop the benchmark - we just reconnect.
ctl_run() {
  if [ "$DETACH" != 1 ]; then ctl "mkdir -p $REMOTE_DIR && $1"; return; fi
  # unique id per call (ctl_run usually runs in a "| tee" subshell, so no shared counter)
  local d=$REMOTE_DIR id="job-$(date +%s)-$RANDOM$RANDOM" off=0 size rc meta down=0 lost=0
  # (only the nohup part goes to the background: a backgrounded "cat" would read /dev/null)
  printf '%s\n' "$1" | $K exec -i "$CTL" -- bash -c "mkdir -p $d && cat > $d/$id.sh && \
    { nohup setsid bash -c 'echo \$\$ > $d/$id.pid; bash $d/$id.sh > $d/$id.out 2>&1; echo \$? > $d/$id.rc' >/dev/null 2>&1 < /dev/null & }" \
    || die "could not start the benchmark in the controller pod"
  [ "$($K exec "$CTL" -- bash -c "wc -c < $d/$id.sh" 2>/dev/null)" -gt 1 ] 2>/dev/null || die "the benchmark script did not reach the controller pod"
  # Ctrl+C here stops the benchmark in the cluster as well (elbencho interrupts its services)
  trap "$K exec $CTL -- bash -c 'kill -INT -- -\$(cat $d/$id.pid) 2>/dev/null' >/dev/null 2>&1; exit 130" INT TERM
  while :; do
    if meta=$($K exec "$CTL" -- bash -c "echo \$(stat -c %s $d/$id.out 2>/dev/null || echo 0) \$(cat $d/$id.rc 2>/dev/null || echo -)" 2>/dev/null); then
      [ $lost = 1 ] && log "connection restored - the benchmark kept running in the cluster"
      lost=0; down=0
      size=${meta% *}; rc=${meta#* }
      if [ "$size" -gt "$off" ]; then
        $K exec "$CTL" -- bash -c "tail -c +$((off + 1)) $d/$id.out | head -c $((size - off))" 2>/dev/null && off=$size
      fi
      if [ "$rc" != "-" ] && [ "$off" -ge "$size" ]; then trap - INT TERM; return "$rc"; fi
    else
      [ $lost = 0 ] && warn "lost the connection to the cluster - the benchmark keeps running there; retrying every ${POLL}s"
      lost=1; down=$((down + POLL))
      [ $down -lt "$RECONNECT_TIMEOUT" ] || die "no connection for ${RECONNECT_TIMEOUT}s - results stay in $CTL:$d"
    fi
    sleep "$POLL"
  done
}
fetch() { # copy result files of this run from the controller
  local f
  for f in $(ctl "ls -tr $REMOTE_DIR 2>/dev/null" || true); do   # oldest first -> phase order kept
    ctl "cat $REMOTE_DIR/$f" > "$RUN_DIR/$f"; sleep 0.01
  done
}

# ------------------------------------------------------- dataset markers ----
ds_get() { $K get "statefulset/$FULL" -o go-template="{{index .metadata.annotations \"elbencho-bench/$1\"}}" 2>/dev/null | sed 's/<no value>//'; }
ds_set() { $K annotate --overwrite "statefulset/$FULL" "elbencho-bench/$1=$2" >/dev/null; }
need_prepare() { # kind signature
  case "$PREPARE" in always) return 0 ;; never) return 1 ;; esac
  [ "$(ds_get "$1")" != "$2" ]
}

# ---------------------------------------------------------------- summary ---
summarize() {
  local f out="$RUN_DIR/summary.txt"
  local hdr="date,protocol,test,layout,pods,nconnect,threads,iodepth,block,phase,operation,iops,read_iops,total_iops,mib_s,read_mib_s,lat_avg_us,read_lat_avg_us,p99_us,read_p99_us,elapsed_ms_last,dataset_gib,run_dir,sweep_id"
  if [ -f "$RESULTS_DIR/summary.csv" ] && [ "$(head -1 "$RESULTS_DIR/summary.csv")" != "$hdr" ]; then
    mv "$RESULTS_DIR/summary.csv" "$RESULTS_DIR/summary-old-$RUN_ID.csv"   # older column layout
  fi
  [ -f "$RESULTS_DIR/summary.csv" ] || echo "$hdr" > "$RESULTS_DIR/summary.csv"
  {
    printf '%-14s %-10s %12s %12s %12s %10s %10s %11s %11s\n' PHASE OP IOPS RD-IOPS TOTAL-IOPS MiB/s RD-MiB/s LAT-us RD-LAT-us
    for f in $(ls -tr "$RUN_DIR"/*.csv 2>/dev/null); do
      [ -e "$f" ] || continue
      # p99 per operation from the human readable result file: "OP w_p99 r_p99"
      local p99s
      p99s=$(awk '/^[A-Z]/{op=$1}
        /IO (wr )?lat % us/ { if (match($0, / 99%<=[0-9]+/)) w[op]=substr($0,RSTART+6,RLENGTH-6) }
        /IO rd lat % us/    { if (match($0, / 99%<=[0-9]+/)) r[op]=substr($0,RSTART+6,RLENGTH-6) }
        END { for (o in w) printf "%s=%s:%s;", o, w[o], r[o] }' "${f%.csv}.txt" 2>/dev/null || true)
      awk -F, -v phase="$(basename "$f" .csv)" -v sum="$RESULTS_DIR/summary.csv" -v meta="$RUN_ID,$PROTO,$TEST-$TNAME,$LAYOUT,$PODS,${NCONNECT:-}" -v dir="$RUN_DIR" -v sw="${SWEEP_ID:-}" -v p99s="$p99s" -v dsg="$(awk -v b="${DATASET_BYTES:-0}" 'BEGIN{ if (b>0) printf "%.1f", b/1073741824 }')" '
        BEGIN { n=split(p99s, a, ";"); for (i=1;i<=n;i++) if (split(a[i], kv, "=")==2) { split(kv[2], wr, ":"); pw[kv[1]]=wr[1]; pr[kv[1]]=wr[2] } }
        NR==1 { for (i=1;i<=NF;i++) h[$i]=i; next }
        # [first] = all workers still running (stonewall). If that phase was too short to measure
        # (0 ms, elbencho prints a 1234567 placeholder) fall back to the [last] values.
        function g(k,  kk) { kk=k; if (fb && kk ~ /\[first\]$/) sub(/\[first\]$/,"[last]",kk); return (kk in h) ? $(h[kk]) : "" }
        $0 ~ /^[0-9]/ {
          fb=0; if ($(h["time ms [first]"])+0 == 0) fb=1
          op=g("operation"); iops=g("IOPS [first]"); if (iops=="") iops=g("entries/s [first]")
          if (op ~ /MKDIRS|DELDIRS|STAT|DELFILES|LISTOBJ|MKBUCKETS/ || iops=="0") iops=g("entries/s [first]")
          r=g("rwmix read IOPS [first]"); if (r=="") r=g("rwmix read entries/s [first]")
          tot=iops+r
          printf "%-14s %-10s %12s %12s %12s %10s %10s %11s %11s\n", phase, op, iops, (r==""?"-":r), tot, g("MiB/s [first]"), (r==""?"-":g("rwmix read MiB/s [first]")), g("IO lat us [avg]"), g("rwmix read IO lat us [avg]")
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", meta, g("threads"), g("IO depth"), g("block size"), phase, op, iops, r, tot, g("MiB/s [first]"), g("rwmix read MiB/s [first]"), g("IO lat us [avg]"), g("rwmix read IO lat us [avg]"), pw[op], pr[op], $(h["time ms [last]"]), dsg, dir, sw >> sum
        }' "$f"
    done
  } | tee "$out"
  local f2 pct=""
  for f2 in "$RUN_DIR"/*.txt; do
    [ -e "$f2" ] || continue
    pct+=$(awk -v p="$(basename "$f2" .txt)" '/^[A-Z]/{op=$1} /IO (rd |wr )?lat % us/{sub(/^ +/,""); printf "%-14s %-8s %s\n", p, op, $0}' "$f2")$'\n'
  done
  [ -n "${pct//[$'\n']/}" ] && { echo "--- IO latency percentiles (us) ---"; printf '%s' "$pct" | grep -v '^$'; } | tee -a "$out"
  return 0
}

finish() {
  fetch
  echo
  log "RESULTS  $PROTO / $TEST-$TNAME  (pods=$PODS layout=$LAYOUT)"
  summarize
  if declare -F post_summary >/dev/null; then post_summary | tee -a "$RUN_DIR/summary.txt"; fi
  log "saved to: $RUN_DIR"
  if [ "$KEEP" != 1 ]; then
    log "KEEP=0: removing deployment $REL"
    "$BENCH_DIR/cleanup.sh" "$PROTO" "RELEASES=$REL" >/dev/null
  fi
}

# ------------------------------------------------------- protocol tests -----
# shellcheck disable=SC1090
source "$BENCH_DIR/lib/tests-$FAMILY.sh"
# shellcheck disable=SC1090
case "$TEST" in 14|15) source "$BENCH_DIR/lib/tests-ai.sh" ;; esac   # overrides run_test

# ------------------------------------------------- dataset vs storage cache ---
# dataset_bytes (defined by the tests-*.sh file): bytes the measured phase works on, 0 = not relevant
cache_check() {
  DATASET_BYTES=$(dataset_bytes 2>/dev/null || echo 0)
  [ "${DATASET_BYTES:-0}" -gt 0 ] || return 0
  if [ -z "$STORAGE_CACHE" ] || [ "$CACHE_CHECK" = off ]; then
    log "dataset of this test: $(hr "$DATASET_BYTES") (set STORAGE_CACHE=<size> to check it against the storage cache)"
    return 0
  fi
  local cache ratio; cache=$(to_bytes "$STORAGE_CACHE")
  ratio=$(awk -v d="$DATASET_BYTES" -v c="$cache" 'BEGIN{ printf "%.1f", d/c }')
  if awk -v r="$ratio" -v f="$CACHE_FACTOR" 'BEGIN{ exit !(r < f) }'; then
    local msg="dataset $(hr "$DATASET_BYTES") is only ${ratio}x the storage cache ($STORAGE_CACHE), wanted >= ${CACHE_FACTOR}x: results will largely come from cache. $(dataset_hint)"
    [ "$CACHE_CHECK" = fail ] && die "$msg (CACHE_CHECK=warn to run anyway)"
    warn "$msg"
  else
    log "dataset $(hr "$DATASET_BYTES") = ${ratio}x the storage cache ($STORAGE_CACHE) - measures the media, not the cache"
  fi
}
cache_check
echo "DATASET_BYTES=$DATASET_BYTES" >> "$RUN_DIR/params.env"

deploy
run_test
finish
