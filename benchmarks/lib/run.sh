#!/usr/bin/env bash
# elbencho benchmark runner.
#   usage: run.sh <protocol> <test-id> [KEY=VALUE ...]
#   protocol: nfs | xfs | raw-block | s3
#   test-id:  01..12 (see benchmarks/README.md)
# All tunables can be given as KEY=VALUE arguments or as environment variables.
set -euo pipefail

BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(cd "$BENCH_DIR/.." && pwd)

log()  { printf '\033[1;34m[bench]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[bench] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bench] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

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
  12) TNAME=scaling-sweep ;;
  *) die "unknown test id '$TEST'" ;;
esac
LAYOUT=multi; [[ $TEST == 08 || $TEST == 09 ]] && LAYOUT=single

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
  esac
fi
: "${DURATION:=60}"            # seconds per timed phase

# --------------------------------------------------------------- sweep (12) --
if [ "$TEST" = 12 ]; then
  : "${SWEEP_TEST:=02}"
  : "${SWEEP_PODS:=1 2 4 8}"
  : "${SWEEP_NCONNECT:=}"        # nfs only, e.g. "1 4 8 16"
  [ "$SWEEP_TEST" != 12 ] || die "SWEEP_TEST cannot be 12"
  SWEEP_ID=sweep-$(date +%Y%m%d-%H%M%S)
  for p in $SWEEP_PODS; do
    for n in ${SWEEP_NCONNECT:-_}; do
      extra=(PODS="$p" SWEEP_ID="$SWEEP_ID")
      [ "$n" != _ ] && extra+=(NCONNECT="$n")
      log "sweep: test $SWEEP_TEST with ${extra[*]}"
      "$0" "$PROTO" "$SWEEP_TEST" "${extra[@]}"
    done
  done
  log "sweep results ($SWEEP_ID):"
  awk -F, -v id="$SWEEP_ID" 'NR==1 || ($NF==id && $9 !~ /^(prepare|mkbucket)/) { printf "%-6s %-5s %-8s %-8s %-6s %-26s %-10s %12s %12s %12s %10s %10s %10s\n", $5,$6,$7,$8,$4,$9,$10,$11,$12,$13,$14,$15,$16 }' "$RESULTS_DIR/summary.csv"
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
           TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS META_DIRS META_FILES EXTRA_ARGS SPREAD CPU MEMORY; do
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
    echo "  instancesPerPod: $([ "$FAMILY" = s3 ] && echo 2 || echo 1)"
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
  printf 'elbencho %s --hosts "$%s" %s --label %q --csvfile %s/%s.csv --resfile %s/%s.txt %s %s' \
    "$S3_AUTH" "$hv" "$LIVE_FLAGS" "$PROTO/$TEST-$TNAME/$name" "$REMOTE_DIR" "$name" "$REMOTE_DIR" "$name" \
    "$extra" "$(printf '%q ' "$@")"
}
eb() {
  local name=$1
  log "phase '$name': elbencho ${*:4}"
  ctl "mkdir -p $REMOTE_DIR && $(eb_cmd "$@")" 2>&1 | tee -a "$RUN_DIR/console.log"
}
fetch() { # copy result files of this run from the controller
  local f
  for f in $(ctl "ls $REMOTE_DIR 2>/dev/null" || true); do
    ctl "cat $REMOTE_DIR/$f" > "$RUN_DIR/$f"
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
  [ -f "$RESULTS_DIR/summary.csv" ] || echo "date,protocol,test,layout,pods,threads,iodepth,block,phase,operation,iops,read_iops,total_iops,mib_s,read_mib_s,lat_avg_us,read_lat_avg_us,run_dir,sweep_id" > "$RESULTS_DIR/summary.csv"
  {
    printf '%-14s %-10s %12s %12s %12s %10s %10s %11s %11s\n' PHASE OP IOPS RD-IOPS TOTAL-IOPS MiB/s RD-MiB/s LAT-us RD-LAT-us
    for f in $(ls -tr "$RUN_DIR"/*.csv 2>/dev/null); do
      [ -e "$f" ] || continue
      awk -F, -v phase="$(basename "$f" .csv)" -v sum="$RESULTS_DIR/summary.csv" -v meta="$RUN_ID,$PROTO,$TEST-$TNAME,$LAYOUT,$PODS" -v dir="$RUN_DIR" -v sw="${SWEEP_ID:-}" '
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
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", meta, g("threads"), g("IO depth"), g("block size"), phase, op, iops, r, tot, g("MiB/s [first]"), g("rwmix read MiB/s [first]"), g("IO lat us [avg]"), g("rwmix read IO lat us [avg]"), dir, sw >> sum
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

deploy
run_test
finish
