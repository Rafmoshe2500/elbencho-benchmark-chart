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
    pgd)         local lo hi; read -r lo hi <<< "$(pgd_range "$OBJ_CLASS")"; echo $(( PGD_OBJECTS * (lo + hi) / 2 )) ;;
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

# ------------------------------------------- test 18: one cell of the matrix ---
# PUT, GET and DELETE of PGD_OBJECTS objects of random size (OBJ_CLASS range), every object once per phase.
# The object list (treefile) gives every object its own size; --treerand mixes the sizes over the threads, and
# -b = the largest size makes every object one request. Each cell uses its own key prefix.
PGD_AWK='BEGIN { srand(seed); for (i = 0; i < n; i++) { s = lo + int(rand() * (hi - lo + 1)); if (s > hi) s = hi; t += s
  printf "f %d d%d/o%d\n", s, i % 100, i > f } close(f); printf "%d %.0f\n", n, t }'
pgd_test() {
  local lo hi tree out nobj bucket="$BUCKET_PREFIX-matrix" pfx c
  read -r lo hi <<< "$(pgd_range "$OBJ_CLASS")"
  tree=/tmp/eb/pgd-tree-$RUN_ID.txt
  pfx="pgd/${MATRIX_ID:-$RUN_ID}/$OBJ_CLASS-p$PODS-t$THREADS/"
  eb mkbucket-matrix 0 ELBENCHO_HOSTS -d -t 1 "$bucket"
  out=$(ctl "mkdir -p /tmp/eb && awk -v n=$PGD_OBJECTS -v lo=$lo -v hi=$hi -v seed=$(( ${MATRIX_SEED:-42} + PODS * 100 + THREADS )) -v f=$tree '$PGD_AWK'")
  read -r nobj PGD_BYTES <<< "$out"
  [ "${nobj:-0}" = "$PGD_OBJECTS" ] && [ "${PGD_BYTES:-0}" -gt 0 ] 2>/dev/null || die "creating the object list in the controller pod failed: $out"
  echo "PGD_BYTES=$PGD_BYTES" >> "$RUN_DIR/params.env"
  log "$PGD_OBJECTS objects, $(hr "$PGD_BYTES") in total (avg $(hr $(( PGD_BYTES / PGD_OBJECTS )))), prefix $bucket/$pfx"
  c=(-t "$THREADS" --treefile "$tree" --treerand -b "$hi" --s3objprefix "$pfx" --lathisto --cpu)
  if ! eb put 1 ELBENCHO_HOSTS -w "${c[@]}" "$bucket"; then RUN_FAILED=put
  elif ! eb get 1 ELBENCHO_HOSTS -r --s3fastget "${c[@]}" "$bucket"; then RUN_FAILED=get
  elif ! eb delete 1 ELBENCHO_HOSTS -F "${c[@]}" "$bucket"; then RUN_FAILED=delete; fi
  if [ -n "$RUN_FAILED" ]; then
    warn "phase '$RUN_FAILED' failed: removing the objects of this cell (not measured)"
    eb cleanup 0 ELBENCHO_HOSTS -F --nodelerr -t "$THREADS" --treefile "$tree" -b "$hi" --s3objprefix "$pfx" "$bucket" \
      || warn "cleanup failed: objects under $bucket/$pfx stay (remove them with your S3 tools)"
    ctl "rm -f $REMOTE_DIR/cleanup.csv $REMOTE_DIR/cleanup.txt" || true   # not a result
  fi
  ctl "rm -f $tree" || true
}

# awk functions: ISO 8601 time ("2026-11-23T06:29:16.557+0000") <-> epoch seconds (no mktime / strftime in mawk)
AWK_TIME='
function days(y, m, d,   era, yoe, doy) { y -= (m <= 2); era = int((y >= 0 ? y : y - 399) / 400); yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1; return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468 }
function iso2epoch(s,   z, o, sg) { if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9]/) return ""
  o = 0; if (match(s, /[+-][0-9][0-9]:?[0-9][0-9]$/)) { z = substr(s, RSTART); sg = (substr(z, 1, 1) == "-") ? -1 : 1
    gsub(/[^0-9]/, "", z); o = sg * (substr(z, 1, 2) * 3600 + substr(z, 3, 2) * 60) }
  return days(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18) - o }
function epoch2iso(e,   d, s, z, era, doe, yoe, y, doy, mp, dd, m) { d = int(e / 86400); s = e - d * 86400; z = d + 719468
  era = int((z >= 0 ? z : z - 146096) / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365); y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
  dd = doy - int((153 * mp + 2) / 5) + 1; m = mp + (mp < 10 ? 3 : -9); y += (m <= 2)
  return sprintf("%04d-%02d-%02dT%02d:%02d:%06.3fZ", y, m, dd, int(s / 3600), int((s - int(s / 3600) * 3600) / 60), s - int(s / 60) * 60) }'

# Storage-side latency of a phase: "avg p50 p90 p99" in ms ("-" = unknown).
#   STORAGE_LAT_CMD  any command; it gets OP (PUT|GET|DELETE), S3_API (PutObject|GetObject|DeleteObject),
#                    START_EPOCH, END_EPOCH (the phase), PODS, THREADS, OBJ_CLASS and prints "avg p50 p90 p99" in ms
#   PROM_URL         or Prometheus: PROM_Q_AVG / PROM_Q_P50 / PROM_Q_P90 / PROM_Q_P99 are PromQL queries with the
#                    placeholders %API% (PutObject), %api% (putobject), %op% (put|get|del) and %range% (the phase
#                    window, e.g. 95s), evaluated at the end of the window; PROM_UNIT = unit of the result (s|ms|us)
#   STORAGE_LAT_WAIT seconds to wait after a phase before asking (metrics are scraped with a delay); the window
#                    is phase start .. phase end + STORAGE_LAT_WAIT
: "${STORAGE_LAT_CMD:=}"; : "${PROM_URL:=}"; : "${PROM_UNIT:=s}"; : "${STORAGE_LAT_WAIT:=30}"
storage_lat_on() { [ -n "$STORAGE_LAT_CMD$PROM_URL" ]; }
prom_query() {   # prom_query <promql> <eval-epoch> -> value, or "-"
  local a=(-sS -G --max-time 30) out v
  [ "${PROM_INSECURE:-0}" = 1 ] && a+=(-k)
  [ -n "${PROM_TOKEN:-}" ] && a+=(-H "Authorization: Bearer $PROM_TOKEN")
  out=$(curl "${a[@]}" "${PROM_URL%/}/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$2" 2>&1) \
    || { warn "Prometheus query failed: $(printf '%s' "$out" | head -c 300)"; echo -; return 0; }
  out=$(printf '%s' "$out" | tr -d ' \n')
  v=$(printf '%s' "$out" | sed -n 's/.*"value":\[[^],]*,"\([^"]*\)"\].*/\1/p')
  [ -n "$v" ] || v=$(printf '%s' "$out" | sed -n 's/.*"resultType":"scalar","result":\[[^],]*,"\([^"]*\)"\].*/\1/p')
  case "$v" in
    ''|NaN|*Inf) [[ $out == *'"status":"error"'* ]] && warn "Prometheus: $(printf '%s' "$out" | head -c 300) (query: $1)"
                 echo - ;;
    *) echo "$v" ;;
  esac
}
storage_lat() {   # storage_lat <PUT|GET|DELETE> <start-epoch> <end-epoch>
  local op=$1 api k q t r out=""
  case "$op" in PUT) api=PutObject ;; GET) api=GetObject ;; *) api=DeleteObject ;; esac
  if [ -n "$STORAGE_LAT_CMD" ]; then
    out=$(OP=$op S3_API=$api START_EPOCH=$2 END_EPOCH=$3 PODS=$PODS THREADS=$THREADS OBJ_CLASS=$OBJ_CLASS \
          bash -c "$STORAGE_LAT_CMD" 2>>"$RUN_DIR/console.log" | awk 'NF { print; exit }') \
      || warn "STORAGE_LAT_CMD failed for $op (see console.log)"
  else
    t=$(awk -v e="$3" -v w="$STORAGE_LAT_WAIT" 'BEGIN { printf "%d", e + w + 0.999 }')
    r=$(awk -v s="$2" -v t="$t" 'BEGIN { printf "%ds", t - s + 0.999 }')
    for k in AVG P50 P90 P99; do
      q="PROM_Q_$k"; q=${!q:-}
      if [ -z "$q" ]; then out="$out -"; continue; fi
      q=$(awk -v q="$q" -v a="$api" -v o="$op" -v r="$r" 'function rep(s, p, v,   i) { while ((i = index(s, p)) > 0) s = substr(s, 1, i - 1) v substr(s, i + length(p)); return s }
        BEGIN { lo = (o == "DELETE") ? "del" : tolower(o); q = rep(q, "%API%", a); q = rep(q, "%api%", tolower(a)); q = rep(q, "%op%", lo); print rep(q, "%range%", r) }')
      out="$out $(prom_query "$q" "$t")"
    done
  fi
  # numbers only, converted to ms; anything else is "-"
  echo "$out" | awk -v u="$([ -n "$STORAGE_LAT_CMD" ] && echo ms || echo "$PROM_UNIT")" '{ f = (u == "s") ? 1000 : (u == "us") ? 0.001 : 1
    for (i = 1; i <= 4; i++) printf "%s%s", (i > 1 ? " " : ""), ($i ~ /^[0-9.]+([eE][-+]?[0-9]+)?$/) ? sprintf("%.3f", $i * f) : "-"; printf "\n" }'
}

# The three rows of this cell for the matrix CSV ($RUN_DIR/matrix.csv, and appended to MATRIX_CSV)
matrix_rows() {
  local i=0 ph op w st en vals pct cpu sl last=0 rng rows="$RUN_DIR/matrix.csv"
  rng=$([ "$OBJ_CLASS" = large ] && echo "$MATRIX_LARGE" || echo "$MATRIX_SMALL")
  echo "$MATRIX_HDR" > "$rows"
  # phase windows from elbencho's start time + elapsed time ("start end" in epoch seconds)
  for ph in put get delete; do
    w=""; [ -s "$RUN_DIR/$ph.csv" ] && w=$(awk -F, "$AWK_TIME"'
      NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
      /^[0-9]/ { s = iso2epoch($(h["ISO date"])); if (s != "") printf "%.3f %.3f\n", s, s + $(h["time ms [last]"]) / 1000; exit }' "$RUN_DIR/$ph.csv")
    printf -v "WIN_$ph" '%s' "$w"
    [ -n "$w" ] && last=${w#* }
  done
  if storage_lat_on && [ "$last" != 0 ]; then
    local pause; pause=$(awk -v l="$last" -v w="$STORAGE_LAT_WAIT" -v n="$(date +%s)" 'BEGIN { x = int(l + w - n + 1); print (x > 0 ? x : 0) }')
    [ "$pause" -gt 0 ] && { log "storage-side latency: waiting ${pause}s for the metrics of the last phase"; sleep "$pause"; }
  fi
  for ph in put get delete; do
    i=$((i + 1)); op=$(echo "$ph" | tr 'a-z' 'A-Z'); w="WIN_$ph"; w=${!w}
    set -- test_no=$(( ${MATRIX_SEQ:-0} + i )) matrix_id="${MATRIX_ID:-}" operation="$op" size_class="$OBJ_CLASS" \
      object_size_range="$rng" pods="$PODS" threads_per_pod="$THREADS" total_threads=$((PODS * THREADS)) run_dir="$RUN_DIR"
    if [ -z "$w" ] || [ "$ph" = "$RUN_FAILED" ]; then matrix_row "$@" verdict=failed >> "$rows"; continue; fi
    st=${w% *}; en=${w#* }
    # elbencho csv: objects, elapsed, client cpu, latency min/avg/max (per object and per request)
    vals=$(awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
      function v(k) { return (k in h && $(h[k]) != "") ? $(h[k]) : "-" }
      /^[0-9]/ { print v("entries [last]"), v("time ms [last]"), v("CPU% [last]"), v("Ent lat us [min]"), v("Ent lat us [avg]"),
                       v("Ent lat us [max]"), v("IO lat us [min]"), v("IO lat us [avg]"), v("IO lat us [max]"); exit }' "$RUN_DIR/$ph.csv")
    # p50 / p90 / p99 / p99.9 from the latency histograms (bucket upper bounds in us, the way elbencho computes
    # its own percentiles): per object (Objects lat hist) and per request (IO lat hist)
    pct=$(awk 'function pc(line, q,   b, n, i, kv, ub, c, tot, cum) { sub(/.*\[ */, "", line); sub(/ *\].*/, "", line)
          n = split(line, b, ", "); tot = 0; for (i = 1; i <= n; i++) { split(b[i], kv, ": "); ub[i] = kv[1]; c[i] = kv[2]; tot += c[i] }
          if (tot == 0) return "-"; cum = 0; for (i = 1; i <= n; i++) { cum += c[i]; if (cum >= q / 100 * tot) return ub[i] } return ub[n] }
      / lat hist / { k = ($1 == "IO") ? "io" : "ent"; r[k] = pc($0, 50) " " pc($0, 90) " " pc($0, 99) " " pc($0, 99.9) }
      END { print ("ent" in r ? r["ent"] : "- - - -"), ("io" in r ? r["io"] : "- - - -") }' "$RUN_DIR/$ph.txt" 2>/dev/null || echo "- - - - - - - -")
    cpu=$(cat "$RUN_DIR/$ph.cpu" 2>/dev/null || echo "- - - - -")
    sl="- - - -"; storage_lat_on && sl=$(storage_lat "$op" "$st" "$en")
    # shellcheck disable=SC2086
    matrix_row "$@" $(awk -v op="$op" -v b="${PGD_BYTES:-0}" -v st="$st" -v en="$en" -v vals="$vals" -v pct="$pct" -v cpu="$cpu" -v sl="$sl" \
        -v cmax="$CLIENT_CPU_MAX" "$AWK_TIME"'
      function ms(x) { return (x == "-" || x == "") ? "" : sprintf("%.3f", x / 1000) }
      function n(x) { return (x == "-" || x == "") ? "" : x }
      BEGIN { split(vals, v, " "); split(pct, p, " "); split(cpu, c, " "); split(sl, s, " ")
        obj = v[1]; el = v[2] / 1000; mib = b / 1048576
        printf "objects=%s total_mib=%.1f avg_object_kib=%.1f elapsed_s=%.3f ", obj, mib, (obj > 0 ? b / obj / 1024 : 0), el
        if (el > 0) { printf "ops_per_s=%.1f ", obj / el; if (op != "DELETE") printf "mib_per_s=%.1f ", mib / el }
        printf "lat_min_ms=%s lat_avg_ms=%s lat_max_ms=%s ", ms(v[4]), ms(v[5]), ms(v[6])
        printf "lat_p50_ms=%s lat_p90_ms=%s lat_p99_ms=%s lat_p99_9_ms=%s ", ms(p[1]), ms(p[2]), ms(p[3]), ms(p[4])
        if (op == "DELETE") { v[7] = v[4]; v[8] = v[5]; v[9] = v[6]; p[5] = p[1]; p[6] = p[2]; p[7] = p[3]; p[8] = p[4] }   # one request per object
        printf "clat_min_ms=%s clat_avg_ms=%s clat_max_ms=%s ", ms(v[7]), ms(v[8]), ms(v[9])
        printf "clat_p50_ms=%s clat_p90_ms=%s clat_p99_ms=%s clat_p99_9_ms=%s ", ms(p[5]), ms(p[6]), ms(p[7]), ms(p[8])
        printf "storage_lat_avg_ms=%s storage_lat_p50_ms=%s storage_lat_p90_ms=%s storage_lat_p99_ms=%s ", n(s[1]), n(s[2]), n(s[3]), n(s[4])
        printf "client_cpu_util_pct=%s pod_cpu_avg_cores=%s pod_cpu_busiest_cores=%s pod_cpu_busiest_pct=%s pod_cpu_throttled_pct=%s ", n(v[3]), n(c[1]), n(c[2]), n(c[3]), n(c[4])
        printf "verdict=%s start_utc=%s end_utc=%s\n", (c[3] != "-" && c[3] + 0 >= cmax + 0) ? "CLIENT-LIMITED" : "ok", epoch2iso(st), epoch2iso(en) }') >> "$rows"
  done
  [ -z "${MATRIX_CSV:-}" ] || tail -n +2 "$rows" >> "$MATRIX_CSV"
  echo "--- matrix rows (latencies in ms): $rows"
  awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
    function f(k) { return ($(h[k]) == "") ? "-" : $(h[k]) }
    { printf "%-4s %-7s %-6s pods=%-5s threads=%-3s ops/s=%-10s MiB/s=%-8s lat avg/p50/p90/p99 %s/%s/%s/%s  clat p99 %s  storage avg %s  cpu %s%%  %s\n",
        f("test_no"), f("operation"), f("size_class"), f("pods"), f("threads_per_pod"), f("ops_per_s"), f("mib_per_s"), f("lat_avg_ms"),
        f("lat_p50_ms"), f("lat_p90_ms"), f("lat_p99_ms"), f("clat_p99_ms"), f("storage_lat_avg_ms"), f("pod_cpu_busiest_pct"), f("verdict") }' "$rows"
}

post_summary() {
  [ "$TEST" = pgd ] && { matrix_rows; return 0; }
  [ -f "$RUN_DIR/mix-read.csv" ] && [ -f "$RUN_DIR/mix-write.csv" ] || return 0
  awk -F, 'FNR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $0~/^[0-9]/{o=$(h["IOPS [first]"]); m=$(h["MiB/s [first]"]); if(FILENAME~/read/){r+=o;rm+=m}else{w+=o;wm+=m}}
    END{t=r+w; printf "COMBINED  ops/s read=%d write=%d total=%d  (read share %.1f%%)  MiB/s read=%d write=%d total=%d\n", r,w,t,(t?100*r/t:0),rm,wm,rm+wm}' \
    "$RUN_DIR/mix-read.csv" "$RUN_DIR/mix-write.csv"
}

run_test() {
  [ "$TEST" = pgd ] && { pgd_test; return 0; }   # its own bucket (custom tree mode: one bucket)
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
