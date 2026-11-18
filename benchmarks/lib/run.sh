#!/usr/bin/env bash
# elbencho benchmark runner.
#   usage: run.sh <protocol> <test-id> [KEY=VALUE ...]
#   protocol: nfs | xfs | raw-block | s3
#   test-id:  01..17 (see benchmarks/README.md)
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

# CPU quantity ("8", "1.5", "500m") -> millicores
to_milli() { awk -v v="$1" 'BEGIN{ if (v ~ /m$/) printf "%d\n", v+0; else printf "%d\n", v*1000 }'; }

# Result groups of one run from summary.csv, one line per group (tab separated, "-" = no value):
#   1 group  2 ops/s  3 MiB/s  4 wr_avg_ms  5 wr_p99_ms  6 rd_avg_ms  7 rd_p99_ms  8 client_cpu_pct
#   9 pods  10 threads  11 iodepth  12 block  13 nconnect  14 dataset
# A group is a measured phase; the two halves of an S3 mix (mix-read + mix-write) are one group "mix".
# Reads and writes keep separate latencies, because they have separate targets.
run_rows() {
  [ -f "$RESULTS_DIR/summary.csv" ] || return 0
  awk -F, -v dir="$1" '
    function mx(a, k, v) { if (v != "" && (!(k in a) || v+0 > a[k]+0)) a[k]=v+0 }
    function ms(a, k) { return (k in a) ? sprintf("%.2f", a[k]/1000) : "-" }
    NR==1 { for (i=1;i<=NF;i++) h[$i]=i; next }
    $(h["run_dir"])==dir && $(h["phase"]) !~ /^(prepare|mkbucket)/ {
      g=$(h["phase"]); mix=(g ~ /^mix-(read|write)$/); if (mix) g="mix"
      if (!(g in ops)) { order[++n]=g; thr[g]=0 }
      ops[g]+=$(h["total_iops"]); mib[g]+=$(h["mib_s"])+$(h["read_mib_s"])
      op=$(h["operation"])
      if (op ~ /^(READ|STAT|LISTOBJ)/) { mx(ra, g, $(h["lat_avg_us"])); mx(rp, g, $(h["p99_us"])) }
      else { mx(wa, g, $(h["lat_avg_us"])); mx(wp, g, $(h["p99_us"]))
             mx(ra, g, $(h["read_lat_avg_us"])); mx(rp, g, $(h["read_p99_us"])) }   # rwmix: read half
      c=$(h["client_cpu_pct"]); if (c!="" && c+0>=cpu[g]+0) cpu[g]=c
      thr[g]=(mix ? thr[g]+$(h["threads"]) : $(h["threads"])); qd[g]=$(h["iodepth"]); bs[g]=$(h["block"])
      pods[g]=$(h["pods"]); nc[g]=$(h["nconnect"]); ds[g]=$(h["dataset_gib"])
    }
    END { for (i=1;i<=n;i++) { g=order[i]
      printf "%s\t%.0f\t%.0f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", g, ops[g], mib[g], ms(wa,g), ms(wp,g), ms(ra,g), ms(rp,g),
        (cpu[g]==""?"-":cpu[g]), pods[g], thr[g], qd[g], bs[g], (nc[g]==""?"-":nc[g]), (ds[g]==""?"-":ds[g]"G") } }' "$RESULTS_DIR/summary.csv"
}
# Latency targets of a test in ms: "rd_avg rd_p99 wr_avg wr_p99" ("-" = none), from LAT_READ / LAT_WRITE
# ("avg/p99", e.g. 2/5; "-/5" = only p99, "2" = only avg, empty = no target). Large-block tests (throughput 03/04
# and the 256k-1m mix 07) get TPUT_LAT_FACTOR x the targets: one 1 MiB IO takes longer than a 4k IO.
targets() {
  local f=1; case "$1" in 03|04|07) f=${TPUT_LAT_FACTOR:-1} ;; esac
  awk -v f="$f" -v r="${LAT_READ:-}" -v w="${LAT_WRITE:-}" '
    function t(v) { return (v=="" || v=="-") ? "-" : v*f }
    BEGIN { split(r, a, "/"); split(w, b, "/"); print t(a[1]), t(a[2]), t(b[1]), t(b[2]) }'
}
has_targets() { [ -n "${LAT_READ:-}${LAT_WRITE:-}" ]; }
# verdict <test> <wr_avg> <wr_p99> <rd_avg> <rd_p99> <client_cpu_pct>
#   client = the load generators were the limit, slo = a latency target was missed, ok
verdict() {
  # shellcheck disable=SC2046
  awk -v wa="$2" -v wp="$3" -v ra="$4" -v rp="$5" -v c="$6" -v cm="${CLIENT_CPU_MAX:-80}" -v t="$(targets "$1")" '
    function over(v, lim) { return (v!="-" && v!="" && lim!="-" && v+0 > lim+0) }
    BEGIN { split(t, m, " ")
    if (c!="-" && c!="" && c+0>=cm+0) print "client"
    else if (over(ra,m[1]) || over(rp,m[2]) || over(wa,m[3]) || over(wp,m[4])) print "slo"
    else print "ok" }'
}
slo_text() {   # slo_text <test>
  has_targets || { echo "no latency target set (LAT_READ / LAT_WRITE = avg/p99 in ms)"; return; }
  # shellcheck disable=SC2046
  set -- $(targets "$1") "$1"
  local r="" w=""
  [ "$1" != - ] && r="avg <= $1"; [ "$2" != - ] && r="${r:+$r, }p99 <= $2"
  [ "$3" != - ] && w="avg <= $3"; [ "$4" != - ] && w="${w:+$w, }p99 <= $4"
  echo "read ${r:-no target}; write ${w:-no target} (ms)"
}

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
: "${IMAGE_REPO:=}"            # default: chart default (rafmoshe2500/elbencho, see ../Dockerfile)
: "${IMAGE_TAG:=}"             # default: chart default (v<appVersion>)
[ "$TEST" = 17 ] && : "${PODS:=auto}"   # find-max: load generators on every node unless told otherwise
: "${PODS:=2}"                 # number of elbencho daemons (load generators); auto = PODS_PER_NODE on every node
: "${PODS_PER_NODE:=1}"        # PODS=auto: daemons per node
: "${TOLERATE_ALL:=}"          # 1 = tolerate every node taint (control plane...). Default: 1 with PODS=auto, else 0
: "${SPREAD:=preferred}"       # spread daemons over nodes: preferred | required | even | none
: "${NODE_SELECTOR:=}"         # e.g. "node-role/bench=true" (key=value)
: "${CPU:=}"                   # cpu request per daemon pod, e.g. "8"; auto = CPU_SHARE % of the free CPU of the
                               # weakest node, divided between its daemons; none = no request (default with PODS=auto: auto)
: "${CPU_SHARE:=80}"           # CPU=auto: percent of a node's free CPU given to its daemons
: "${CPU_LIMIT:=0}"            # 1 = cpu limit = request (Guaranteed QoS / static CPU manager). 0 = request only:
                               #     no CFS throttling, which would show up as storage latency
: "${MEMORY:=}"                # memory request+limit per daemon, e.g. "16Gi"
: "${CLIENT_CPU:=1}"           # 1 = measure the CPU the daemons used in every measured phase (cgroup counters)
: "${CLIENT_CPU_MAX:=80}"      # busiest daemon above this % of its CPU -> the result is client-limited
# Latency targets in ms, "avg/p99", for the verdict of every run and where test 17 stops:
#   LAT_READ  LAT_WRITE   (defaults per protocol in profile.env; TPUT_LAT_FACTOR multiplies them for 03 04 07)
# Dataset (all protocols): DATASET_SIZE = total size of all pods together. The number of files / objects per
#   thread follows from it and the file / object size (FILE_SIZE, OBJ_SIZE). Defaults in profile.env / below.
: "${IOPS_COVER_MIN:=20}"      # IOPS tests: warn when the random IO goes through the dataset faster than this (min)
: "${DATASET_SIZE:=}"          # total dataset; default: nfs/xfs/raw-block 4t, S3 16g (IOPS, mixes) / 4t (throughput)
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
: "${AIO:=auto}"              # async IO (libaio, used when IODEPTH > 1) on nfs/xfs/raw-block:
                               #   auto   = check once in a pod; if the cluster blocks it (seccomp), emulate it
                               #   emulate= never use libaio: THREADS x IODEPTH threads with IODEPTH=1
                               #   native = no check, no fallback (fails if libaio is blocked)
: "${AIO_MAX_THREADS:=1024}"   # cap for the emulated thread count
: "${RECONNECT_TIMEOUT:=3600}" # give up after this many seconds without a working connection

# shellcheck disable=SC1090
source "$BENCH_DIR/$PROTO/profile.env"
for v in LAT_AVG_MAX LAT_P99_MAX LAT_READ_AVG_MAX LAT_READ_P99_MAX LAT_WRITE_AVG_MAX LAT_WRITE_P99_MAX \
         TPUT_DATASET EXPECTED_IOPS TPUT_OBJ_SIZE TPUT_OBJECTS RANGE_OBJ_SIZE RANGE_OBJECTS OBJECTS MIX_OBJECTS \
         SWEEP_FILE_SIZE SWEEP_DEV_SIZE SWEEP_OBJECTS; do
  [ -z "${!v+x}" ] || die "$v was replaced: latency targets are LAT_READ=avg/p99 and LAT_WRITE=avg/p99 (e.g. LAT_WRITE=2/10); datasets are DATASET_SIZE (+ FILE_SIZE / OBJ_SIZE), sweeps SWEEP_DATASET_SIZE. See benchmarks/README.md"
done
: "${LAT_READ=}"; : "${LAT_WRITE=}"
for v in LAT_READ LAT_WRITE; do
  [[ ${!v} =~ ^(([0-9.]+|-)(/([0-9.]+|-))?)?$ ]] || die "$v must be avg/p99 in ms, e.g. 2/5 (or -/5 for p99 only), got '${!v}'"
done
: "${TPUT_LAT_FACTOR:=10}"

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
  13) die "test 13 is now part of test 12: ./12-scaling-sweep.sh SWEEP_PODS=<pods> SWEEP_IODEPTH=\"1 2 4 8 16 32 64 128\"" ;;
  14) TNAME=ai-training ;;         15) TNAME=ai-inference ;;
  16) TNAME=range-read ;;
  17) TNAME=find-max ;;
  deploy) TNAME=deploy ;;           # only deploy the daemons + controller, for elbencho runs by hand
  *) die "unknown test id '$TEST'" ;;
esac
case "$TEST" in
  11) [ "$FAMILY" != block ] || die "test 11 (metadata) needs a filesystem - not available for raw-block" ;;
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
  10)          : "${BS:=4k}"; THREADS=${LAT_THREADS:-1}; IODEPTH=${LAT_IODEPTH:-1} ;;  # always QD1 unless LAT_*
  11)          : "${THREADS:=16}"; : "${IODEPTH:=1}" ;;
esac
: "${READ_PCT:=70}"
# S3: concurrency comes from threads (one request in flight per thread by default) and the
# "block" of the IOPS tests is the object size; throughput tests use 16 MiB multipart parts.
if [ "$FAMILY" = s3 ]; then
  case "$TEST" in
    01|02|08|09) THREADS=${USER_THREADS:-32}; IODEPTH=1; OBJ_SIZE=${USER_BS:-${OBJ_SIZE:-4k}}; BS=$OBJ_SIZE   # BS = OBJ_SIZE here
                 # verified with elbencho 3.3-3: one PUT/GET per object is always synchronous, --iodepth changes nothing
                 [ "${USER_IODEPTH:-1}" = 1 ] || warn "IODEPTH has no effect on S3 whole-object requests (concurrency = PODS x THREADS) - using IODEPTH=1; raise THREADS instead" ;;
    03|04)       THREADS=${USER_THREADS:-16}; IODEPTH=${USER_IODEPTH:-1}; BS=${USER_BS:-16m}; : "${OBJ_SIZE:=256m}" ;;
    05|06|07)    THREADS=${USER_THREADS:-20} ;;
    16)          THREADS=${USER_THREADS:-16}; IODEPTH=${USER_IODEPTH:-1}; : "${OBJ_SIZE:=256m}" ;;
  esac
fi
: "${DURATION:=300}"           # seconds per timed phase (5 min: past write caches, steadier numbers)

# ------------------------------------------------------- sweeps (12, 17) ---
# 12: sweep over pods / threads / iodepth / nconnect / dataset size (any combination, every step runs),
# 17: find-max = load ladder (S3: THREADS, files/block: IODEPTH) that stops at the latency target,
#     when the result stops growing, or when the load generators themselves are the limit.
if [ "$TEST" = 12 ] || [ "$TEST" = 17 ]; then
  : "${SWEEP_TEST:=02}"; : "${SWEEP_THREADS:=}"
  case "$TEST" in
    12) : "${SWEEP_PODS:=1 2 4 8}"; : "${SWEEP_IODEPTH:=}" ;;
    17) : "${SWEEP_PODS:=$PODS}"; : "${FIND_STOP:=1}"
        if [ -z "$SWEEP_THREADS${SWEEP_IODEPTH:-}" ]; then
          if [ "$FAMILY" = s3 ]; then
            case "$SWEEP_TEST" in 03|04|16) SWEEP_THREADS="2 4 8 16 32 64" ;; *) SWEEP_THREADS="8 16 32 64 128 256" ;; esac
          else
            case "$SWEEP_TEST" in 03|04|07) SWEEP_IODEPTH="1 2 4 8 16 32" ;; *) SWEEP_IODEPTH="1 2 4 8 16 32 64 128" ;; esac
          fi
        fi
        : "${SWEEP_IODEPTH:=}" ;;
  esac
  : "${FIND_STOP:=0}"            # 1 = stop a ladder at the first step that misses the target / is client-limited / is flat
  : "${MIN_GAIN:=3}"             # a step that gains less than this % over the best so far counts as flat
  : "${SWEEP_NCONNECT:=}"        # nfs only, e.g. "1 4 8 16"
  case "$SWEEP_TEST" in 03|04) : "${SWEEP_METRIC:=mibs}" ;; *) : "${SWEEP_METRIC:=ops}" ;; esac
  : "${SWEEP_DATASET_SIZE:=}"    # total dataset sizes, e.g. "100g 400g 1600g": where the storage cache ends
  case "$SWEEP_TEST" in 12|13|14|15|17) die "SWEEP_TEST must be one of 01..11, 16" ;; esac
  [ -z "$SWEEP_IODEPTH" ] || [ "$SWEEP_TEST" != 10 ] || die "test 10 is fixed at QD1 - sweep another test"
  SWEEP_ID=sweep-$(date +%Y%m%d-%H%M%S)${SWEEP_TAG:+-$SWEEP_TAG}
  # one dataset for all steps: sized for the largest pod count (fewer pods use a part of it), so that a pod
  # sweep does not prepare (and for xfs / raw-block: create volumes) again at every step
  if [ "$FAMILY" != s3 ] && [ -z "${DATASET_PODS:-}" ]; then
    DATASET_PODS=$(printf '%s\n' $SWEEP_PODS | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
    [ -n "$DATASET_PODS" ] && [ "$(printf '%s\n' $SWEEP_PODS | sort -u | wc -l)" -gt 1 ] && export DATASET_PODS || DATASET_PODS=""
  fi
  # S3 read tests: prepare once, for the highest thread count of the ladder (fewer threads read a part of it)
  if [ "$FAMILY" = s3 ] && [ -n "$SWEEP_THREADS" ] && [[ $SWEEP_TEST =~ ^(02|04|08|16)$ ]]; then
    PREP_MIN_THREADS=$(printf '%s\n' $SWEEP_THREADS | sort -n | tail -1); export PREP_MIN_THREADS
  fi
  mkdir -p "$RESULTS_DIR"
  STEPS="$RESULTS_DIR/$SWEEP_ID.tsv"; : > "$STEPS"
  last_dir() { [ -f "$RESULTS_DIR/summary.csv" ] && awk -F, -v id="$SWEEP_ID" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $(h["sweep_id"])==id{d=$(h["run_dir"])} END{print d}' "$RESULTS_DIR/summary.csv"; }
  prev_dir=""; why=""
  for p in $SWEEP_PODS; do
    for n in ${SWEEP_NCONNECT:-_}; do
      for z in ${SWEEP_DATASET_SIZE:-_}; do
        best=0; flat=0
        for t in ${SWEEP_THREADS:-_}; do
          for q in ${SWEEP_IODEPTH:-_}; do
            extra=(PODS="$p" SWEEP_ID="$SWEEP_ID")
            [ "$n" != _ ] && extra+=(NCONNECT="$n")
            [ "$t" != _ ] && extra+=(THREADS="$t")
            [ "$q" != _ ] && extra+=(IODEPTH="$q")
            [ "$z" != _ ] && extra+=("DATASET_SIZE=$z" CACHE_CHECK=warn)
            log "sweep: test $SWEEP_TEST with ${extra[*]}"
            rc=0; "$0" "$PROTO" "$SWEEP_TEST" "${extra[@]}" || rc=$?
            dir=$(last_dir || true)
            if [ $rc != 0 ] || [ -z "$dir" ] || [ "$dir" = "$prev_dir" ]; then
              warn "sweep step failed: ${extra[*]}"
              printf 'failed\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\t%s\t-\t%s\t-\tfailed\t0\n' "$p" "${t/_/-}" "${q/_/-}" "${n/_/-}" >> "$STEPS"
              [ "$FIND_STOP" = 1 ] && { why="a step failed"; break 2; }
              continue
            fi
            prev_dir=$dir
            rows=$(run_rows "$dir")
            IFS=$'\t' read -r _g ops mibs wa wp ra rp cpu _rest <<< "$rows"     # first group decides
            v=$(verdict "$SWEEP_TEST" "$wa" "$wp" "$ra" "$rp" "$cpu")
            m=$ops; [ "$SWEEP_METRIC" = mibs ] && m=$mibs
            if [ "$v" = ok ]; then
              if awk -v m="$m" -v b="$best" -v g="$MIN_GAIN" 'BEGIN{ exit !(m > b*(1+g/100)) }'; then flat=0; else flat=$((flat+1)); v=flat; fi
              awk -v m="$m" -v b="$best" 'BEGIN{ exit !(m > b) }' && best=$m
            fi
            first=1
            while IFS= read -r row; do [ -n "$row" ] && printf '%s\t%s\t%s\n' "$row" "$v" "$first" >> "$STEPS"; first=0; done <<< "$rows"
            if [ "$FIND_STOP" = 1 ]; then
              case "$v" in
                slo)    why="the latency target was missed ($(slo_text "$SWEEP_TEST"))"; break 2 ;;
                client) why="the load generators were the limit (a daemon used >= ${CLIENT_CPU_MAX}% of its CPU): add PODS / CPU, not threads"; break 2 ;;
                flat)   [ "$flat" -ge 2 ] && { why="no gain of more than ${MIN_GAIN}% in the last 2 steps (saturated)"; break 2; } ;;
              esac
            fi
          done
        done
      done
    done
  done
  unit="ops/s"; [ "$SWEEP_METRIC" = mibs ] && unit="MiB/s"
  log "sweep results ($SWEEP_ID), test $SWEEP_TEST. Target: $(slo_text "$SWEEP_TEST")"
  {
    awk -F'\t' 'BEGIN { printf "%-5s %-8s %-7s %-7s %-7s %-9s %-14s %11s %9s %8s %8s %8s %8s %6s  %s\n","pods","nconnect","threads","iodepth","block","dataset","phase","ops/s","MiB/s","rd_avg","rd_p99","wr_avg","wr_p99","cpu%","verdict" }
      { v=$15; if (v=="slo") v="over target"; else if (v=="client") v="CLIENT-LIMITED"; else if (v=="flat") v="ok (no gain)"
        printf "%-5s %-8s %-7s %-7s %-7s %-9s %-14s %11s %9s %8s %8s %8s %8s %6s  %s\n", $9,$13,$10,$11,$12,$14,$1,$2,$3,$6,$7,$4,$5,$8,v }' "$STEPS"
    echo "(latencies in ms)"
    [ -n "$why" ] && echo "stopped: $why"
    awk -F'\t' -v col="$([ "$SWEEP_METRIC" = mibs ] && echo 3 || echo 2)" -v slo="$(has_targets && echo " within target ($(slo_text "$SWEEP_TEST"))")" '
      function lat(a, p) { return (a=="-" && p=="-") ? "" : sprintf(" avg %s / p99 %s ms", a, p) }
      $16==1 && ($15=="ok" || $15=="flat") && $col+0 > best { best=$col+0; l=$0 }
      END { if (l=="") { print "BEST: no step met the target and was not client-limited"; exit }
            split(l, f, "\t"); r=lat(f[6], f[7]); w=lat(f[4], f[5])
            printf "BEST%s: %s ops/s, %s MiB/s%s%s  ->  PODS=%s THREADS=%s IODEPTH=%s%s (daemon cpu %s%%)\n", slo, f[2], f[3],
              (r==""?"":", read"r), (w==""?"":", write"w), f[9], f[10], f[11], (f[13]=="-"?"":" NCONNECT="f[13]), f[8] }' "$STEPS"
  } | tee "$RESULTS_DIR/$SWEEP_ID.txt"
  log "saved to: $RESULTS_DIR/$SWEEP_ID.txt"
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
INSTANCES=1; { [ "$FAMILY" = s3 ] || [ "$PROTO" = nfs ]; } && INSTANCES=2
# tests that load both service instances of a pod at the same time (S3 mixes, async checkpoints)
BOTH_ACTIVE=0
[ "$FAMILY" = s3 ] && [[ $TEST == 05 || $TEST == 06 || $TEST == 07 ]] && BOTH_ACTIVE=1
[ "$TEST" = 14 ] && [ "${CKPT_MODE:-sync}" = async ] && BOTH_ACTIVE=1

# ------------------------------------------- PODS=auto / CPU=auto (per node) ---
# PODS=auto: PODS_PER_NODE daemons on every Ready, schedulable node (NODE_SELECTOR narrows the set).
# CPU=auto : CPU_SHARE % of the free CPU (allocatable - requests of the other pods) of the weakest of
#            these nodes, divided between the daemons of a node, in whole cores.
ONE_NODE=0   # all daemons share one RWO volume -> one node
[ "$FAMILY" != s3 ] && [ "$LAYOUT" = single ] && [ "${ACCESS_MODE:-ReadWriteOnce}" = ReadWriteOnce ] && [ "$PROTO" != nfs ] && ONE_NODE=1
resolve_auto() {
  [ -n "$TOLERATE_ALL" ] || { [ "$PODS" = auto ] && TOLERATE_ALL=1 || TOLERATE_ALL=0; }
  [ "$PODS" = auto ] && [ -z "$CPU" ] && CPU=auto
  [ "$CPU" = none ] && CPU=""
  if [ "$PODS" != auto ] && [ "$CPU" != auto ]; then
    [ "$PODS" -ge 1 ] 2>/dev/null || die "PODS must be a number or 'auto', got '$PODS'"
    return 0
  fi
  local sel=() nodes count
  [ -n "$NODE_SELECTOR" ] && sel=(-l "$NODE_SELECTOR")
  # name, unschedulable, taint effects, allocatable cpu, Ready
  nodes=$(kubectl get nodes ${sel[@]+"${sel[@]}"} --no-headers -o 'custom-columns=N:.metadata.name,U:.spec.unschedulable,T:.spec.taints[*].effect,C:.status.allocatable.cpu,R:.status.conditions[?(@.type=="Ready")].status') \
    || die "PODS=auto / CPU=auto need permission to list nodes (kubectl get nodes) - set PODS and CPU by hand"
  nodes=$(printf '%s\n' "$nodes" | awk -v tol="$TOLERATE_ALL" '$2!="true" && $5=="True" && (tol==1 || $3 !~ /NoSchedule|NoExecute/) { print $1, $4 }')
  count=$(printf '%s\n' "$nodes" | grep -c . || true)
  [ "$count" -ge 1 ] || die "no Ready, schedulable node found${NODE_SELECTOR:+ for NODE_SELECTOR=$NODE_SELECTOR}$([ "$TOLERATE_ALL" = 1 ] || echo ' (tainted nodes are skipped: TOLERATE_ALL=1 includes them)')"
  local per_node=$PODS_PER_NODE
  if [ "$PODS" = auto ]; then
    if [ "$ONE_NODE" = 1 ]; then
      PODS=2; per_node=2
      warn "PODS=auto: test $TEST shares one ReadWriteOnce volume, so all daemons run on ONE node - using PODS=2"
    else
      PODS=$(( count * PODS_PER_NODE ))
      if [ "$PODS_PER_NODE" = 1 ]; then SPREAD=required; else SPREAD=even; fi
      log "PODS=auto: $count nodes x $PODS_PER_NODE = $PODS daemons (spread: $SPREAD$([ "$TOLERATE_ALL" = 1 ] && echo ', all taints tolerated'))"
    fi
  else
    [ "$PODS" -ge 1 ] 2>/dev/null || die "PODS must be a number or 'auto', got '$PODS'"
    if [ "$ONE_NODE" = 1 ]; then per_node=$PODS; else per_node=$(( (PODS + count - 1) / count )); fi
  fi
  if [ "$CPU" = auto ]; then
    local used milli
    # node, namespace, release, cpu requests of the containers; finished pods do not count
    used=$(kubectl get pods -A --no-headers --field-selector=status.phase!=Succeeded,status.phase!=Failed \
             -o 'custom-columns=N:.spec.nodeName,NS:.metadata.namespace,I:.metadata.labels.app\.kubernetes\.io/instance,C:.spec.containers[*].resources.requests.cpu' 2>/dev/null) \
      || { used=""; warn "CPU=auto: cannot list the pods of all namespaces - using the allocatable CPU of the nodes (other workloads are not subtracted)"; }
    milli=$(printf '%s\n' "$used" | awk -v nodes="$nodes" -v ns="$NAMESPACE" -v rel="$REL" -v share="$CPU_SHARE" -v ppn="$per_node" '
      function m(v) { if (v=="" || v ~ /none/) return 0; return (v ~ /m$/) ? v+0 : v*1000 }
      BEGIN { n=split(nodes, l, "\n"); for (i=1;i<=n;i++) { split(l[i], f, " "); if (f[1]!="") free[f[1]]=m(f[2]) } }
      ($1 in free) && !($2==ns && $3==rel) { k=split($4, c, ","); for (i=1;i<=k;i++) free[$1]-=m(c[i]) }
      END { min=-1; for (x in free) if (min<0 || free[x]<min) min=free[x]; if (min<0) min=0
            printf "%d\n", min*share/100/ppn }')
    if [ "$milli" -ge 1000 ]; then CPU=$(( milli / 1000 ))
    elif [ "$milli" -ge 100 ]; then CPU="${milli}m"
    else die "CPU=auto: the weakest node has no free CPU for $per_node daemon(s) - free some CPU, use NODE_SELECTOR, or set CPU by hand"; fi
    log "CPU=auto: $CPU per daemon (${CPU_SHARE}% of the free CPU of the weakest node, $per_node daemon(s) per node)"
  fi
}
resolve_auto

# ------------------------------------------------------------ dataset size ---
# DATASET_SIZE is the total of all daemons. The runner derives everything else:
#   nfs / xfs : FILES = size per daemon / FILE_SIZE (default 64g; smaller datasets get one smaller file)
#   raw block : DEV_SIZE = size per daemon (the tested range of every device)
#   s3        : objects per thread = DATASET_SIZE / (OBJ_SIZE x daemons x threads); mixes: DATASET_SIZE / avg size
# nfs/xfs/raw-block keep ONE dataset per deployment for all tests, so switching tests does not prepare again.
# Layout multi splits it over the daemons (DATASET_PODS = the largest pod count of a sweep), layout single is one
# shared set. xfs / raw-block volumes (PVC_SIZE) are sized to hold it, unless PVC_SIZE is given.
size_dataset() {
  local units=1 total pu cap gib=1073741824 mib=1048576
  if [ "$FAMILY" = s3 ]; then
    local pt=${THREADS:-1} ob
    [ "${PREP_MIN_THREADS:-0}" -gt "$pt" ] 2>/dev/null && pt=$PREP_MIN_THREADS
    case "$TEST" in
      01|02|08|09|05|06|07) : "${DATASET_SIZE:=16g}" ;;
      03|04|16)             : "${DATASET_SIZE:=4t}" ;;
      *) return 0 ;;
    esac
    total=$(to_bytes "$DATASET_SIZE")
    if [[ $TEST =~ ^0[5-7]$ ]]; then
      MIX_OBJECTS=$(( total / $(mix_avg "$BS_MIX") )); [ "$MIX_OBJECTS" -ge 100 ] || MIX_OBJECTS=100
      log "dataset: $(hr "$total") = $MIX_OBJECTS objects of $BS_MIX"
    else
      ob=$(to_bytes "$OBJ_SIZE"); OBJECTS=$(( total / ob / (PODS * pt) )); [ "$OBJECTS" -ge 1 ] || OBJECTS=1
      log "dataset: $(hr "$total") = $OBJECTS objects of $OBJ_SIZE per thread x $((PODS * pt)) threads$([ "$pt" != "$THREADS" ] && echo " (prepared for the largest step, THREADS=$pt)")"
    fi
    return 0
  fi
  : "${DATASET_SIZE:=4t}"
  [ "$LAYOUT" = multi ] && units=${DATASET_PODS:-$PODS}
  total=$(to_bytes "$DATASET_SIZE")
  pu=$(( total / units / mib * mib ))
  if [ "$FAMILY" = file ]; then
    if [ "$PROTO" = xfs ] && [ -n "${PVC_SIZE:-}" ]; then
      cap=$(( $(to_bytes "$PVC_SIZE") * 90 / 100 / mib * mib ))
      [ "$pu" -gt "$cap" ] && { warn "PVC_SIZE=$PVC_SIZE holds only $(hr "$cap") per daemon - the dataset is smaller than wanted ($(hr "$pu"))"; pu=$cap; }
    fi
    : "${FILE_SIZE:=64g}"
    if [ -z "${FILES:-}" ]; then FILES=$(( pu / $(to_bytes "$FILE_SIZE") )); [ "$FILES" -ge 1 ] || FILES=1; fi
    FILE_SIZE="$(( pu / FILES / mib ))m"          # the files together give exactly the dataset
    if [ "$PROTO" = xfs ] && [ -z "${PVC_SIZE:-}" ]; then   # + 5% and 10 GiB for the filesystem
      PVC_SIZE="$(( (FILES * $(to_bytes "$FILE_SIZE") * 105 / 100 + gib - 1) / gib + 10 ))Gi"
    fi
  else
    if [ -n "${PVC_SIZE:-}" ]; then
      cap=$(( $(to_bytes "$PVC_SIZE") / mib * mib ))
      [ "$pu" -gt "$cap" ] && { warn "PVC_SIZE=$PVC_SIZE is smaller than the wanted $(hr "$pu") per daemon - testing the whole device"; pu=$cap; }
    fi
    DEV_SIZE="$(( pu / mib ))m"
    [ -n "${PVC_SIZE:-}" ] || PVC_SIZE="$(( ($(to_bytes "$DEV_SIZE") + gib - 1) / gib ))Gi"
  fi
  local per; per=$([ "$FAMILY" = file ] && echo "$FILES file(s) of $FILE_SIZE" || echo "$DEV_SIZE")
  log "dataset: $(hr "$total") = $per per $([ "$LAYOUT" = multi ] && echo "daemon x $units" || echo "shared target")$([ "$PROTO" = nfs ] || echo ", volumes of $PVC_SIZE")"
}
size_dataset

# IOPS tests: how long the measured IO needs to go once through the dataset (IOPS_COVER_MIN wanted)
cover_check() {
  case "$TEST" in 01|02|05|06|08|09) ;; *) return 0 ;; esac
  [ "${DATASET_BYTES:-0}" -gt 0 ] || return 0
  local row; row=$(run_rows "$RUN_DIR" | head -1)
  [ -n "$row" ] || return 0
  awk -F'\t' -v d="$DATASET_BYTES" -v c="$IOPS_COVER_MIN" '{ b=$3*1048576; if (b<=0) exit
    min=d/b/60; need=b*60*c
    printf "DATASET  %.0f GiB are gone through once every %.1f min at %d MiB/s (wanted >= %s min)\n", d/1073741824, min, $3, c
    if (min < c) printf "WARNING: the same data is hit again after %.1f min. For %s min at this rate: DATASET_SIZE=%dg\n", min, c, need/1073741824+1 }'  <<< "$row"
}
case "$SPREAD" in preferred|required|even|none) ;; *) die "SPREAD must be preferred | required | even | none" ;; esac

# Record all parameters of this run
{
  echo "# $PROTO $TEST-$TNAME  ($RUN_ID)"
  for v in PROTO TEST TNAME LAYOUT NAMESPACE REL PODS THREADS IODEPTH BS BS_MIX READ_PCT DURATION \
           FILES FILE_SIZE PVC_SIZE STORAGE_CLASS NFS_SERVER NFS_PATH NFS_STORAGE_CLASS NFS_VERS NCONNECT \
           RSIZE WSIZE NFS_EXTRA_OPTS S3_ENDPOINT S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS \
           MIX_OBJECTS META_DIRS META_FILES EXTRA_ARGS SPREAD CPU CPU_LIMIT MEMORY \
           PODS_PER_NODE TOLERATE_ALL NODE_SELECTOR LAT_READ LAT_WRITE TPUT_LAT_FACTOR DATASET_SIZE IOPS_COVER_MIN \
           DATASET_PODS DEV_SIZE STORAGE_CACHE CACHE_FACTOR BLOCKVARPCT DETACH AIO RANGE_BS; do
    [ -n "${!v:-}" ] && printf '%s=%q\n' "$v" "${!v}"
  done
} > "$RUN_DIR/params.env"

# ------------------------------------------------------------ helm values ----
VALUES="$RUN_DIR/values.yaml"
res_yaml() {   # res_yaml <indent> <cpu> <memory>: cpu limit only with CPU_LIMIT=1, memory always request = limit
  local in=$1 c=$2 m=$3
  [ -n "$c$m" ] || { echo "$in{}"; return; }
  echo "${in}requests:"; [ -n "$c" ] && echo "$in  cpu: \"$c\""; [ -n "$m" ] && echo "$in  memory: \"$m\""
  if [ -n "$m" ] || { [ "$CPU_LIMIT" = 1 ] && [ -n "$c" ]; }; then
    echo "${in}limits:"; [ "$CPU_LIMIT" = 1 ] && [ -n "$c" ] && echo "$in  cpu: \"$c\""; [ -n "$m" ] && echo "$in  memory: \"$m\""
  fi
  return 0
}
render_values() {
  {
    echo "mode: service"
    echo "replicaCount: $PODS"
    echo "terminationGracePeriodSeconds: 5"
    [ -n "$IMAGE_REPO$IMAGE_TAG" ] && { echo "image:"; [ -n "$IMAGE_REPO" ] && echo "  repository: $IMAGE_REPO"; [ -n "$IMAGE_TAG" ] && echo "  tag: \"$IMAGE_TAG\""; }
    echo "serviceMode:"
    # 2 service instances: S3 mixes and async checkpoints run two coordinated elbencho runs at once
    echo "  instancesPerPod: $INSTANCES"
    echo "  controller: {enabled: true}"
    if [ -n "$CPU$MEMORY" ]; then
      # CPU is the request of the whole pod. The 2nd service instance is idle in most tests and then gets
      # nothing; in tests that load both instances the CPU is split between them.
      local c1=$CPU c2=""
      if [ "$INSTANCES" = 2 ]; then
        if [ "$BOTH_ACTIVE" = 1 ] && [ -n "$CPU" ]; then c1="$(( $(to_milli "$CPU") / 2 ))m"; c2=$c1
        elif [ "$CPU_LIMIT" = 1 ] && [ -n "$CPU" ]; then c2=100m; fi   # a Guaranteed pod needs limits on every container
        echo "  extraInstanceResources:"
        if [ -n "$c2" ] || [ "$BOTH_ACTIVE" = 1 ]; then res_yaml "    " "$c2" "$MEMORY"; else echo "    {}"; fi
      fi
      echo "resources:"
      res_yaml "  " "$c1" "$MEMORY"
    fi
    [ "$TOLERATE_ALL" = 1 ] && echo "tolerations: [{operator: Exists}]"
    [ -n "$NODE_SELECTOR" ] && { echo "nodeSelector:"; echo "  \"${NODE_SELECTOR%%=*}\": \"${NODE_SELECTOR#*=}\""; }
    local sel="{matchLabels: {app.kubernetes.io/name: elbencho, app.kubernetes.io/instance: $REL}}"
    if [ "$SPREAD" = even ] && [ "$ONE_NODE" != 1 ]; then
      # the same number of daemons on every node (taints are honored unless all are tolerated anyway)
      echo "topologySpreadConstraints:"
      echo "  - maxSkew: 1"
      echo "    topologyKey: kubernetes.io/hostname"
      echo "    whenUnsatisfiable: DoNotSchedule"
      [ "$TOLERATE_ALL" = 1 ] || echo "    nodeTaintsPolicy: Honor"
      echo "    labelSelector: $sel"
    fi
    echo "affinity:"
    if [ "$ONE_NODE" = 1 ]; then
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
# Why pods do not come up: pod states and the latest warning events (SCC/PodSecurity "forbidden" errors are
# events of the StatefulSet, scheduling and image problems are events of the pods).
deploy_diag() {
  echo "--- pods of $REL:" >&2
  $K get pods -l app.kubernetes.io/instance="$REL" >&2 || true
  echo "--- latest warning events of $REL:" >&2
  $K get events --field-selector type=Warning --sort-by=.lastTimestamp -o go-template='{{range .items}}{{.involvedObject.kind}}/{{.involvedObject.name}} {{.reason}}: {{.message}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -F "$FULL" | tail -6 >&2 || true
}

# A StatefulSet replaces its pods ONE AT A TIME after a pod-template change (new HELM_ARGS, CPU, NCONNECT...),
# even with podManagementPolicy Parallel, and stops at the first pod that does not become ready. Here all daemons
# are restarted at once instead (they hold no state), so a change costs seconds, not minutes.
restart_daemons_at_once() {
  local i gen obs cur upd
  for i in $(seq 1 30); do   # wait until the controller has seen the new spec
    gen=$($K get "statefulset/$FULL" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    obs=$($K get "statefulset/$FULL" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
    [ -n "$gen" ] && [ "$gen" = "$obs" ] && break; sleep 1
  done
  cur=$($K get "statefulset/$FULL" -o jsonpath='{.status.currentRevision}' 2>/dev/null || true)
  upd=$($K get "statefulset/$FULL" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)
  if [ -n "$cur" ] && [ "$cur" != "$upd" ]; then
    log "pod settings changed: restarting all $PODS daemons at once"
    $K delete pod -l "app.kubernetes.io/name=elbencho,app.kubernetes.io/instance=$REL" --wait=false >/dev/null
  fi
}

# xfs / raw-block: the volume size of a StatefulSet (volumeClaimTemplates) and of a PVC cannot shrink and in most
# cases not grow in place. Existing volumes of the same StorageClass that are large enough are reused as they are;
# otherwise the release and its volumes are removed and created again (the dataset is then prepared again).
pvc_reconcile() {
  [ "$FAMILY" != s3 ] && [ "$PROTO" != nfs ] || return 0
  local cur sc
  if [ "$LAYOUT" = multi ]; then
    cur=$($K get "statefulset/$FULL" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null || true)
    sc=$($K get "statefulset/$FULL" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}' 2>/dev/null || true)
  else
    cur=$($K get "pvc/$FULL" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
    sc=$($K get "pvc/$FULL" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
  fi
  [ -n "$cur" ] || return 0
  if [ "$sc" = "$STORAGE_CLASS" ] && [ "$(to_bytes "$cur")" -ge "$(to_bytes "$PVC_SIZE")" ]; then
    [ "$(to_bytes "$cur")" = "$(to_bytes "$PVC_SIZE")" ] || log "reusing the existing volumes of $cur (>= $PVC_SIZE)"
    PVC_SIZE=$cur; return 0
  fi
  warn "the volumes change ($cur on '$sc' -> $PVC_SIZE on '$STORAGE_CLASS'): removing $REL and its volumes; the dataset is prepared again"
  "$BENCH_DIR/cleanup.sh" "$PROTO" "RELEASES=$REL" "NAMESPACE=$NAMESPACE" >/dev/null
}

deploy() {
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
  pvc_reconcile
  if declare -F profile_predeploy >/dev/null; then profile_predeploy; fi
  render_values
  log "deploying $REL ($PODS daemons, layout=$LAYOUT) in namespace $NAMESPACE"
  # no --wait: the readiness wait is done below, after the daemons have been restarted at once
  # shellcheck disable=SC2086
  helm upgrade --install "$REL" "$CHART" -n "$NAMESPACE" --create-namespace -f "$VALUES" \
       --timeout "$WAIT_TIMEOUT" $HELM_ARGS >> "$RUN_DIR/console.log" 2>&1 \
    || { tail -5 "$RUN_DIR/console.log" >&2; deploy_diag; die "helm deploy failed (see above)"; }
  restart_daemons_at_once
  $K rollout status "statefulset/$FULL" --timeout "$WAIT_TIMEOUT" >/dev/null 2>&1 \
    || { deploy_diag; die "the $PODS daemons did not become ready within $WAIT_TIMEOUT (see above)"; }
  $K rollout status "$CTL" --timeout "$WAIT_TIMEOUT" >/dev/null 2>&1 \
    || { deploy_diag; die "the controller pod did not become ready within $WAIT_TIMEOUT (see above)"; }
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
  local name=$1 rc=0
  log "phase '$name': elbencho ${*:4}"
  [ "$2" = 1 ] && cpu_begin elbencho
  ctl_run "$(eb_cmd "$@")" 2>&1 | tee -a "$RUN_DIR/console.log" || rc=$?
  [ "$2" = 1 ] && cpu_end "$name"
  return $rc
}

# ------------------------------------------------ CPU used by the daemons ----
# A saturated load generator looks exactly like slow storage: the result stops growing and the measured
# latency rises. So the CPU time every daemon container used during a measured phase is read from its cgroup
# counters (v2: cpu.stat, v1: cpuacct.usage) and compared with what the pod may use (CPU request, else the
# cores of its node). Output per sample: usage_usec throttled_usec now_ns cores
CPU_PROBE='u=; t=0; s=/sys/fs/cgroup/cpu.stat
if grep -q usage_usec $s 2>/dev/null; then u=$(awk "/^usage_usec/{print \$2}" $s); t=$(awk "/^throttled_usec/{print \$2}" $s)
else for f in /sys/fs/cgroup/cpuacct/cpuacct.usage /sys/fs/cgroup/cpu,cpuacct/cpuacct.usage; do [ -r $f ] && { u=$(($(cat $f)/1000)); break; }; done; fi
[ -n "$u" ] && echo "$u ${t:-0} $(date +%s%N) $(nproc)"'
cpu_sample() {   # cpu_sample <outfile> <container>...
  local out=$1 i c n=0; shift
  : > "$out"
  for i in $(seq 0 $((PODS - 1))); do
    for c in "$@"; do
      { r=$($K exec "$FULL-$i" -c "$c" -- sh -c "$CPU_PROBE" 2>/dev/null) && [ -n "$r" ] && echo "$i $c $r" >> "$out"; } &
      n=$((n + 1)); [ $((n % 16)) = 0 ] && wait
    done
  done
  wait
  return 0
}
CPU_CONTAINERS=""
cpu_begin() {   # cpu_begin <container>...
  [ "$CLIENT_CPU" = 1 ] || return 0
  CPU_CONTAINERS="$*"
  # shellcheck disable=SC2086
  cpu_sample "$RUN_DIR/.cpu0" $CPU_CONTAINERS
}
cpu_end() {     # cpu_end <phase>...  -> <phase>.cpu: "avg_cores busiest_cores busiest_pct throttled_pct available_cores"
  [ "$CLIENT_CPU" = 1 ] && [ -s "$RUN_DIR/.cpu0" ] || return 0
  # shellcheck disable=SC2086
  cpu_sample "$RUN_DIR/.cpu1" $CPU_CONTAINERS
  local st ph
  st=$(awk -v req="$([ -n "$CPU" ] && to_milli "$CPU" || echo 0)" '
    FNR==NR { u[$1" "$2]=$3; t[$1" "$2]=$4; ns[$1" "$2]=$5; next }
    ($1" "$2) in u { k=$1" "$2; dt=($5-ns[k])/1e9; if (dt<=0) next
      cores[$1]+=($3-u[k])/1e6/dt; thr+=($4-t[k])/1e6; wall+=dt; np[$1]=$6; seen=1 }
    END { if (!seen) exit
      for (p in cores) { n++; sum+=cores[p]; if (cores[p]>=max) { max=cores[p]; av=(req>0 ? req/1000 : np[p]) } }
      printf "%.1f %.1f %.0f %.0f %.1f\n", sum/n, max, (av>0 ? 100*max/av : 0), (wall>0 ? 100*thr/wall : 0), av }' "$RUN_DIR/.cpu0" "$RUN_DIR/.cpu1")
  rm -f "$RUN_DIR/.cpu0" "$RUN_DIR/.cpu1"
  [ -n "$st" ] || return 0
  for ph in "$@"; do echo "$st" > "$RUN_DIR/$ph.cpu"; done
  # shellcheck disable=SC2086
  set -- $st
  log "daemon CPU: average $1 cores per pod, busiest pod $2 of $5 cores ($3%)$([ "$4" -gt 0 ] && echo ", throttled $4% of the time")"
  if [ "$3" -ge "$CLIENT_CPU_MAX" ]; then
    warn "CLIENT-LIMITED: the busiest daemon used $3% of its CPU. This result measures the load generators, not the storage - add PODS or CPU instead of threads"
  elif [ "$4" -ge 5 ]; then
    warn "the daemons were CPU-throttled $4% of the time (cpu limit): latencies are inflated - raise CPU or run with CPU_LIMIT=0"
  fi
  return 0
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
need_prepare_pods() { # kind signature-without-pods: the marker is "<signature>,pods=N" (N daemons have the data)
  case "$PREPARE" in always) return 0 ;; never) return 1 ;; esac
  local cur; cur=$(ds_get "$1")
  [ "${cur%,pods=*}" = "$2" ] || return 0
  [ "$LAYOUT" = single ] && return 1
  [ "${cur##*,pods=}" -ge "$PODS" ] 2>/dev/null && return 1
  return 0
}

# ---------------------------------------------------------------- summary ---
summarize() {
  local f out="$RUN_DIR/summary.txt"
  local hdr="date,protocol,test,layout,pods,nconnect,threads,iodepth,block,phase,operation,iops,read_iops,total_iops,mib_s,read_mib_s,lat_avg_us,read_lat_avg_us,p99_us,read_p99_us,elapsed_ms_last,dataset_gib,run_dir,sweep_id,client_cpu_pct"
  if [ -f "$RESULTS_DIR/summary.csv" ] && [ "$(head -1 "$RESULTS_DIR/summary.csv")" != "$hdr" ]; then
    mv "$RESULTS_DIR/summary.csv" "$RESULTS_DIR/summary-old-$RUN_ID.csv"   # older column layout
  fi
  [ -f "$RESULTS_DIR/summary.csv" ] || echo "$hdr" > "$RESULTS_DIR/summary.csv"
  {
    printf '%-14s %-10s %12s %12s %12s %10s %10s %11s %11s %5s\n' PHASE OP IOPS RD-IOPS TOTAL-IOPS MiB/s RD-MiB/s LAT-us RD-LAT-us CPU%
    for f in $(ls -tr "$RUN_DIR"/*.csv 2>/dev/null); do
      [ -e "$f" ] || continue
      # p99 per operation from the human readable result file: "OP w_p99 r_p99"
      local p99s
      p99s=$(awk '/^[A-Z]/{op=$1}
        /IO (wr )?lat % us/ { if (match($0, / 99%<=[0-9]+/)) w[op]=substr($0,RSTART+6,RLENGTH-6) }
        /IO rd lat % us/    { if (match($0, / 99%<=[0-9]+/)) r[op]=substr($0,RSTART+6,RLENGTH-6) }
        END { for (o in w) printf "%s=%s:%s;", o, w[o], r[o] }' "${f%.csv}.txt" 2>/dev/null || true)
      awk -F, -v phase="$(basename "$f" .csv)" -v sum="$RESULTS_DIR/summary.csv" -v meta="$RUN_ID,$PROTO,$TEST-$TNAME,$LAYOUT,$PODS,${NCONNECT:-}" -v dir="$RUN_DIR" -v sw="${SWEEP_ID:-}" -v p99s="$p99s" -v cpu="$(cut -d' ' -f3 "${f%.csv}.cpu" 2>/dev/null || true)" -v dsg="$(awk -v b="${DATASET_BYTES:-0}" 'BEGIN{ if (b>0) printf "%.1f", b/1073741824 }')" '
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
          printf "%-14s %-10s %12s %12s %12s %10s %10s %11s %11s %5s\n", phase, op, iops, (r==""?"-":r), tot, g("MiB/s [first]"), (r==""?"-":g("rwmix read MiB/s [first]")), g("IO lat us [avg]"), g("rwmix read IO lat us [avg]"), (cpu==""?"-":cpu)
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", meta, g("threads"), g("IO depth"), g("block size"), phase, op, iops, r, tot, g("MiB/s [first]"), g("rwmix read MiB/s [first]"), g("IO lat us [avg]"), g("rwmix read IO lat us [avg]"), pw[op], pr[op], $(h["time ms [last]"]), dsg, dir, sw, cpu >> sum
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
  if has_targets && [ "$LAT" = 1 ]; then
    local g ops mibs wa wp ra rp cpu rest v
    while IFS=$'\t' read -r g ops mibs wa wp ra rp cpu rest; do
      [ -n "$g" ] || continue
      case "$(verdict "$TEST" "$wa" "$wp" "$ra" "$rp" "$cpu")" in
        ok)     v="within the target" ;;
        slo)    v="OVER the target" ;;
        client) v="CLIENT-LIMITED (daemon CPU ${cpu}%): not a storage result" ;;
      esac
      printf 'TARGET %-14s read avg %s / p99 %s ms, write avg %s / p99 %s ms  ->  %s  (%s)\n' "$g" "$ra" "$rp" "$wa" "$wp" "$v" "$(slo_text "$TEST")"
    done <<< "$(run_rows "$RUN_DIR")" | tee -a "$RUN_DIR/summary.txt"
  fi
  if declare -F cover_check >/dev/null; then cover_check | tee -a "$RUN_DIR/summary.txt"; fi
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

# ------------------------------------------------------- async IO preflight ---
# elbencho uses Linux libaio for --iodepth > 1. Container runtimes can block its syscalls with a
# seccomp profile (error "Getting async IO events (io_getevents) failed ... Operation not permitted").
# Sync IO (--iodepth 1) is not affected, and N threads x iodepth 1 gives the same concurrency.
aio_emulate() {   # aio_emulate <threads-var> <iodepth-var>: iodepth N -> N x threads at iodepth 1
  local t=${!1} q=${!2}
  [ "$q" -gt 1 ] 2>/dev/null || return 0
  local n=$(( t * q )); [ "$n" -le "$AIO_MAX_THREADS" ] || n=$AIO_MAX_THREADS
  printf -v "$1" '%s' "$n"; printf -v "$2" '%s' 1
}
AIO_EMULATE=0
aio_preflight() {
  [ "$FAMILY" != s3 ] || return 0
  case "$AIO" in native) return 0 ;; emulate) AIO_EMULATE=1 ;; auto) ;; *) die "AIO must be auto | emulate | native" ;; esac
  if [ "$AIO" = auto ]; then
    # only when this run uses libaio: IODEPTH > 1 (test 15 has its own KV_IODEPTH)
    [ "${IODEPTH:-1}" -gt 1 ] 2>/dev/null || [ "$TEST" = 15 ] || return 0
    local script out rc
    if [ "$FAMILY" = block ]; then
      script='elbencho -r --direct --iodepth 2 -s 64k -b 4k --nolive /dev/elbencho 2>&1'
    else
      script='f=/data/.aio-check-$$; elbencho -w -s 64k -b 4k --nolive $f >/dev/null 2>&1 && elbencho -r --direct --iodepth 2 -s 64k -b 4k --nolive $f 2>&1; rc=$?; rm -f $f; exit $rc'
    fi
    out=$($K exec "$FULL-0" -c elbencho -- sh -c "$script" 2>&1) && rc=0 || rc=$?
    if [ "$rc" = 0 ]; then
      log "async IO (libaio) works in the pods"
      return 0
    elif printf '%s' "$out" | grep -qi "async io"; then
      AIO_EMULATE=1
      warn "async IO (libaio) is blocked in the pods (usually a seccomp profile): $(printf '%s' "$out" | grep -i 'async io' | head -1 | cut -c1-200)"
    else
      warn "async IO check was inconclusive (exit $rc): $(printf '%s' "$out" | tail -1 | cut -c1-200) - continuing with native async IO"
      return 0
    fi
  fi
  if [ "$AIO_EMULATE" = 1 ]; then
    # test 15 has no THREADS/IODEPTH of its own (it emulates KV_IODEPTH inside the test)
    if [ -n "${THREADS:-}" ] && [ -n "${IODEPTH:-}" ]; then
      local t0=$THREADS q0=$IODEPTH
      aio_emulate THREADS IODEPTH
      [ "$q0" -gt 1 ] 2>/dev/null && log "emulating async IO: THREADS=$t0 x IODEPTH=$q0 -> THREADS=$THREADS IODEPTH=1 (same concurrency per pod; AIO=native to disable)"
    fi
    echo "AIO_EMULATED=1" >> "$RUN_DIR/params.env"
    warn "permanent fix: run the pods without a seccomp filter (see benchmarks/README.md, 'async IO blocked')"
  fi
}

deploy
if [ "$TEST" = deploy ]; then
  case "$FAMILY" in
    s3)    tgt="$BUCKET_PREFIX-1"; s3='$ELBENCHO_S3 '; ex="-d -w -t 8 -n 1 -N 1000 -s 4k -b 4k $tgt" ;;
    block) tgt=/dev/elbencho; s3=""; ex="-w --direct --rand -t 8 --iodepth 16 -b 4k -s ${DEV_SIZE:-10g} $SHARE --timelimit 60 $tgt" ;;
    *)     tgt="/data/f[1-$FILES]"; s3=""; ex="-r --direct --rand -t 8 --iodepth 16 -b 4k -s $FILE_SIZE $SHARE --timelimit 60 '$tgt'" ;;
  esac
  cat <<EOT

$PODS elbencho daemons are up ($REL). Run elbencho by hand from the controller pod, which knows all daemons:

  kubectl -n $NAMESPACE exec -it $CTL -- bash
  elbencho ${s3}--hosts "\$ELBENCHO_HOSTS" $ex

  ELBENCHO_HOSTS   all daemons (port 1611)$([ "$INSTANCES" = 2 ] && printf '\n  ELBENCHO_HOSTS_2 second service instance of every daemon (port 1612), for a second run at the same time')
  target           $tgt$([ "$FAMILY" = s3 ] && printf '  (ELBENCHO_S3 = --s3endpoints/--s3key/--s3secret)')
$([ "$FAMILY" != s3 ] && echo "  dataset          prepared by the suite: $([ "$FAMILY" = file ] && echo "/data/f1..f$FILES of $FILE_SIZE" || echo "the first $DEV_SIZE of /dev/elbencho") per daemon (if a test ran before)")
$([ "$LAYOUT" = multi ] && [ "$FAMILY" != s3 ] && echo "  --nosvcshare     every daemon has its own volume / directory: each one works on the full path")

Or a single daemon on its own:  kubectl -n $NAMESPACE exec -it $FULL-0 -c elbencho -- bash
Remove everything:              ./benchmarks/cleanup.sh $PROTO
EOT
  exit 0
fi
aio_preflight
run_test
finish
