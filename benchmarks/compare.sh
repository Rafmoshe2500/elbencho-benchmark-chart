#!/usr/bin/env bash
# Compares two (or more) storage systems with the same tests, the same load generators and the same dataset,
# one system after the other, and prints the results side by side.
#
#   usage: ./compare.sh <raw-block|xfs|nfs|s3> TARGETS="<label>=<value> <label>=<value>" [ITEMS="..."] [KEY=VALUE ...]
#
#   TARGETS     one entry per system: a label (letters/digits) and the value of COMPARE_VAR for it
#   COMPARE_VAR what differs between the systems. Default: STORAGE_CLASS (raw-block, xfs), NFS_SERVER (nfs),
#               S3_ENDPOINT (s3)
#   ARGS_<label> extra KEY=VALUE settings for one system only, e.g. ARGS_b="NFS_PATH=/vol2 NCONNECT=16"
#   ITEMS       what to run on every system (default "max:01 max:02 max:03 max:04"):
#                 max:NN = 17-find-max on test NN (the most within the latency target)
#                 NN     = one run of test NN with the given settings
#   Everything else (PODS, CPU, DATASET_SIZE, LAT_*, DURATION ...) is passed to every run unchanged.
#   Default PODS=auto: a load generator on every node, the same nodes for every system.
#
# Each system gets its own releases (cmp-<label>-...) and its own volumes/dataset. Before a system runs, the
# daemons of the other systems are scaled to 0, so that they do not take CPU from it. Volumes are kept
# (a second compare run reuses the datasets); remove them with: ./cleanup.sh <protocol> RELEASE_PREFIX=cmp-<label>
#
# example: two distributed block arrays, everything else at the defaults
#   ./compare.sh raw-block TARGETS="arrayA=sc-array-a arrayB=sc-array-b"
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
P=${1:?usage: compare.sh <raw-block|xfs|nfs|s3> TARGETS=\"a=<value> b=<value>\" [ITEMS=...] [KEY=VALUE ...]}; shift
[ -f "$D/$P/profile.env" ] || { echo "unknown protocol '$P'" >&2; exit 1; }
TARGETS=""; ITEMS="max:01 max:02 max:03 max:04"; COMPARE_VAR=""; args=(); declare -A EXTRA
for kv in "$@"; do
  case $kv in
    TARGETS=*) TARGETS=${kv#*=} ;;
    ITEMS=*) ITEMS=${kv#*=} ;;
    COMPARE_VAR=*) COMPARE_VAR=${kv#*=} ;;
    ARGS_*=*) k=${kv%%=*}; EXTRA[${k#ARGS_}]=${kv#*=} ;;
    *=*) args+=("$kv") ;;
    *) echo "arguments must be KEY=VALUE, got '$kv'" >&2; exit 1 ;;
  esac
done
[ -n "$COMPARE_VAR" ] || case $P in raw-block|xfs) COMPARE_VAR=STORAGE_CLASS ;; nfs) COMPARE_VAR=NFS_SERVER ;; s3) COMPARE_VAR=S3_ENDPOINT ;; esac
[ -n "$TARGETS" ] || { echo "set TARGETS=\"<label>=<$COMPARE_VAR> <label>=<$COMPARE_VAR>\"" >&2; exit 1; }
for kv in "${args[@]}"; do [[ $kv == PODS=* ]] && HAVE_PODS=1; done
[ -n "${HAVE_PODS:-}" ] || args+=(PODS=auto)
: "${NAMESPACE:=elbencho-bench}"; : "${RESULTS_DIR:=$D/results}"
for kv in "${args[@]}"; do case $kv in NAMESPACE=*) NAMESPACE=${kv#*=} ;; RESULTS_DIR=*) RESULTS_DIR=${kv#*=} ;; esac; done
case $P in raw-block) PS=blk ;; *) PS=$P ;; esac
labels=(); for t in $TARGETS; do
  l=${t%%=*}; [[ $l =~ ^[A-Za-z0-9]+$ ]] && [ "$t" != "$l" ] || { echo "bad TARGETS entry '$t' (want <label>=<value>)" >&2; exit 1; }
  labels+=("$l")
done
rel_of() { local r; r=$(printf 'cmp-%s' "$1" | tr 'A-Z' 'a-z'); echo "$r-$PS $r-$PS-single"; }
scale_down() {   # all compare releases except the one of label $1
  local l r
  for l in "${labels[@]}"; do
    [ "$l" = "${1:-}" ] && continue
    for r in $(rel_of "$l"); do
      kubectl -n "$NAMESPACE" scale statefulset,deployment -l "app.kubernetes.io/instance=$r" --replicas=0 >/dev/null 2>&1 || true
    done
  done
}
ID=compare-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RESULTS_DIR"; OUT="$RESULTS_DIR/$ID.tsv"; : > "$OUT"
for t in $TARGETS; do
  l=${t%%=*}; v=${t#*=}
  scale_down "$l"
  # shellcheck disable=SC2206
  ex=(${EXTRA[$l]:-})
  for it in $ITEMS; do
    tn=${it#max:}; tag="$ID-$l-$tn"
    echo; echo "================= $l ($COMPARE_VAR=$v): $([ "$it" = "$tn" ] && echo "test $tn" || echo "find-max on test $tn") ================="
    common=("${args[@]}" "$COMPARE_VAR=$v" "RELEASE_PREFIX=$(printf 'cmp-%s' "$l" | tr 'A-Z' 'a-z')" "SWEEP_TAG=$l-$tn" "SWEEP_TEST=$tn" "RESULTS_DIR=$RESULTS_DIR")
    if [ "$it" = "$tn" ]; then
      pods=auto; for kv in "${args[@]}"; do [[ $kv == PODS=* ]] && pods=${kv#PODS=}; done
      one=(); for kv in "${common[@]}" "${ex[@]}"; do [[ $kv == SWEEP_[A-Z]*=* && $kv != SWEEP_TAG=* && $kv != SWEEP_TEST=* ]] || one+=("$kv"); done
      "$D/lib/run.sh" "$P" 12 "${one[@]}" "SWEEP_PODS=$pods" || echo "($l: test $tn failed)"   # one step: no ladder
    else
      "$D/lib/run.sh" "$P" 17 "${common[@]}" "${ex[@]}" || echo "($l: find-max on $tn failed)"
    fi
    f=$(ls -t "$RESULTS_DIR"/sweep-*-"$l-$tn".tsv 2>/dev/null | head -1)
    m=2; case $tn in 03|04) m=3 ;; esac
    # best step within the target; if none, the best step at all (marked with its verdict)
    if [ -n "$f" ]; then
      awk -F'\t' -v it="$it" -v l="$l" -v m="$m" '$16==1 { ok=($15=="ok"||$15=="flat")
          if (ok && $m+0 >= bo) { bo=$m+0; lo=$0 } if ($m+0 >= ba) { ba=$m+0; la=$0 } }
        END { if (lo!="") { x=lo; v="ok" } else if (la!="") { x=la; split(la,q,"\t"); v=q[15] } else exit
              print it "\t" l "\t" m "\t" v "\t" x }' "$f" >> "$OUT"
    fi
    grep -q "^$it	$l	" "$OUT" || printf '%s\t%s\t%s\tfailed%s\n' "$it" "$l" "$m" "$(printf '\t-%.0s' $(seq 16))" >> "$OUT"
  done
done
scale_down ""
{
  echo
  echo "COMPARISON ($P, $COMPARE_VAR): best result within the latency target per test (latencies in ms)"
  printf '%-8s %-12s %11s %9s %8s %8s %8s %8s %-14s %-14s %s\n' test system ops/s MiB/s rd_avg rd_p99 wr_avg wr_p99 pods/thr/qd verdict "vs ${labels[0]}"
  awk -F'\t' -v first="${labels[0]}" -v labs="${labels[*]}" '
    BEGIN { nl=split(labs, L, " ") }
    { k=$1; if (!(k in seen)) { seen[k]=1; ord[++n]=k } row[k, $2]=$0; if ($2==first) base[k]=$($3+4) }
    END { for (i=1;i<=n;i++) for (y=1;y<=nl;y++) { if (!((ord[i], L[y]) in row)) continue
            split(row[ord[i], L[y]], f, "\t"); b=base[ord[i]]; mv=f[f[3]+4]
            v=f[4]; if (v=="slo") v="OVER TARGET"; else if (v=="client") v="CLIENT-LIMITED"; else if (v=="failed") v="FAILED"
            rel=(f[2]==first || b+0==0) ? "-" : sprintf("%+.0f%%", 100*(mv-b)/b)
            printf "%-8s %-12s %11s %9s %8s %8s %8s %8s %-14s %-14s %s\n", f[1], f[2], f[6], f[7], f[10], f[11], f[8], f[9], f[13]"/"f[14]"/"f[15], v, rel } }' "$OUT"
  echo "(ops/s decides for IOPS tests, MiB/s for 03/04; 'vs' compares that number with the first system)"
} | tee "$RESULTS_DIR/$ID.txt"
echo "saved to: $RESULTS_DIR/$ID.txt"
