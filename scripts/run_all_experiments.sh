#!/bin/bash
# run_all_experiments.sh — Master orchestrator for DEX experiments.
# Run on node-0 only. Coordinates all nodes via pdsh/ssh.
#
# Usage:
#   bash run_all_experiments.sh              # Run everything
#   bash run_all_experiments.sh --phase A    # Run only Phase A
#   bash run_all_experiments.sh --resume     # Skip completed experiments
#
# Results saved to: /mydata/results/<timestamp>/

set -uo pipefail

# ---- Configuration ----
NODES=("node-0" "node-1" "node-2" "node-3")
IPS=("10.10.1.1" "10.10.1.2" "10.10.1.3" "10.10.1.4")
MEMC_IP="10.10.1.1"
MEMC_PORT="11211"
DEX_DIR="/mydata/dex/build"
RESULTS_BASE="/mydata/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${RESULTS_BASE}/${TIMESTAMP}"

# Thread counts adapted for d6515 (32 cores: 28 compute + 4 memory)
# Paper uses: 2, 18, 36, 72, 108, 144
# Scaled:     2, 14, 28, 56, 84, 112
THREAD_COUNTS=(2 14 28 56 84 112)

# Maximum wall-clock seconds to allow a single benchmark run before killing it.
# Prevents indefinite hangs when node-0 stalls at the DSM init barrier waiting
# for memory nodes that never fully joined (SSH failure, OOM, etc.).
EXP_TIMEOUT=${EXP_TIMEOUT:-300}
MAX_RETRIES=${MAX_RETRIES:-3}

# Packets/sec cap applied to node-0 → memcached traffic while memory nodes are
# performing their one-time serverEnter() INCR.  The tight serverConnect() busy-
# wait loop can generate millions of GETs/s on a single keep-alive connection;
# at that rate memcached's libevent loop falls behind on accept(), causing every
# new TCP SYN from node-{1,2,3} to hit libmemcached's ~4 s connect timeout.
# 1 000 pps is enough for the INCR itself but starves the GET flood.
MEMC_THROTTLE_PPS=${MEMC_THROTTLE_PPS:-1000}

# Workloads from Table 1
WORKLOADS=("read-only" "read-intensive" "write-intensive" "insert-intensive" "scan-intensive")
DISTRIBUTIONS=("zipfian" "uniform")

# Parse args
PHASE_FILTER=""
RESUME=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --phase) PHASE_FILTER="$2"; shift 2 ;;
        --resume) RESUME=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

mkdir -p "$RESULTS_DIR" || {
    echo "ERROR: Cannot create results directory: $RESULTS_DIR"
    echo "       Fix with: sudo mkdir -p $RESULTS_BASE && sudo chown \$(whoami) $RESULTS_BASE"
    exit 1
}
LOG_FILE="${RESULTS_DIR}/orchestrator.log"

# PIDs of background SSH sessions running memory-node newbench processes.
MEMORY_PIDS=()

# Globals set inside run_experiment() so the trap can clean up mid-run.
_CLEANUP_PID=""
_CLEANUP_KNODECOUNT=4

_cleanup() {
    log "Interrupt received — killing all nodes and exiting"
    _throttle_stop        # always remove iptables rules before exiting
    [[ -n "$_CLEANUP_PID" ]] && kill "$_CLEANUP_PID" 2>/dev/null || true
    kill_memory_nodes "$_CLEANUP_KNODECOUNT"
    exit 130
}
trap _cleanup SIGINT SIGTERM

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Install an iptables rate-limit chain that caps outbound traffic from this node
# to the memcached port.  Called after node-0 claims nodeID 0 and its
# serverConnect() polling loop begins; removed once all nodes have registered.
_throttle_start() {
    # Create (or flush if leftover) a dedicated chain for this purpose.
    sudo iptables -N MEMC_THROTTLE 2>/dev/null \
        || sudo iptables -F MEMC_THROTTLE 2>/dev/null || true
    # Allow up to MEMC_THROTTLE_PPS packets/s; drop the rest.
    sudo iptables -A MEMC_THROTTLE \
        -m limit --limit "${MEMC_THROTTLE_PPS}/sec" \
        --limit-burst "${MEMC_THROTTLE_PPS}" -j ACCEPT 2>/dev/null || true
    sudo iptables -A MEMC_THROTTLE -j DROP 2>/dev/null || true
    # Redirect matching OUTPUT traffic into the chain.
    if sudo iptables -I OUTPUT 1 \
            -d "$MEMC_IP" -p tcp --dport "$MEMC_PORT" \
            -j MEMC_THROTTLE 2>/dev/null; then
        log "  Memcached throttle active (${MEMC_THROTTLE_PPS} pps cap on node-0 → memcached)"
    else
        log "  WARNING: could not install memcached throttle via iptables — memory nodes may time out"
    fi
}

# Remove the rate-limit chain installed by _throttle_start.  Safe to call even
# if _throttle_start was never invoked or partially failed.
_throttle_stop() {
    sudo iptables -D OUTPUT \
        -d "$MEMC_IP" -p tcp --dport "$MEMC_PORT" \
        -j MEMC_THROTTLE 2>/dev/null || true
    sudo iptables -F MEMC_THROTTLE 2>/dev/null || true
    sudo iptables -X MEMC_THROTTLE 2>/dev/null || true
}

# Poll memcached's serverNum key via the ASCII protocol until it reaches TARGET
# (meaning that many nodes have called serverEnter()), or until TIMEOUT_SEC
# seconds have elapsed.  Returns 0 on success, 1 on timeout.
wait_servernum() {
    local target="$1"
    local timeout_sec="${2:-60}"
    local elapsed=0
    local memc_ip="$MEMC_IP"
    local memc_port="$MEMC_PORT"
    while (( elapsed < timeout_sec )); do
        local val
        val=$(python3 -c "
import socket
try:
    s = socket.create_connection(('${memc_ip}', ${memc_port}), timeout=2)
    s.sendall(b'get serverNum\r\n')
    data = s.recv(512).decode('ascii', errors='replace')
    s.close()
    lines = data.splitlines()
    for i, l in enumerate(lines):
        if l.startswith('VALUE'):
            print(lines[i + 1].strip())
            break
except Exception:
    pass
" 2>/dev/null) || val=""
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= target )); then
            return 0
        fi
        sleep 1
        (( elapsed += 1 ))
    done
    return 1
}

# Check if an experiment result already exists (for --resume)
result_exists() {
    local tag="$1"
    ls "${RESULTS_BASE}"/*/experiment_${tag}.done 2>/dev/null | head -1
}

# Kill newbench on memory nodes (nodes 1..kNodeCount-1) via SSH.
kill_memory_nodes() {
    local kNodeCount="$1"
    for (( i=1; i<kNodeCount; i++ )); do
        local node="${NODES[$i]}"
        log "  Killing newbench on $node..."
        ssh -o StrictHostKeyChecking=no "$node" \
            "sudo pkill -9 newbench 2>/dev/null || true" || true
    done
    # Also reap any lingering background SSH PIDs from the previous run.
    for pid in "${MEMORY_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    MEMORY_PIDS=()
}

# Start newbench on memory nodes in the background via SSH.
# All nodes run the identical binary+args; role is assigned by memcached counter order.
start_memory_nodes() {
    local kNodeCount="$1"
    shift
    local mem_cmd="$*"
    MEMORY_PIDS=()
    for (( i=1; i<kNodeCount; i++ )); do
        local node="${NODES[$i]}"
        log "  Starting memory server on $node..."
        # Redirect output to the same results dir so it is captured alongside node-0.
        ssh -o StrictHostKeyChecking=no "$node" \
            "cd $DEX_DIR && $mem_cmd" >> "${CURRENT_EXP_DIR}/${node}_output.log" 2>&1 &
        MEMORY_PIDS+=($!)
    done
}

# Restart memcached state (clears QP info between runs).
# Also kills any live memory-node newbench processes first.
restart_memcached() {
    local kNodeCount="$1"
    kill_memory_nodes "$kNodeCount"
    log "  Restarting memcached..."
    pkill memcached 2>/dev/null || true
    cd "$DEX_DIR"
    ./restartMemc.sh
    log "  Memcached restarted."
}

# Run a single experiment across all nodes
# Args: system workload distribution threads [extra_args]
run_experiment() {
    local system="$1"
    local workload="$2"
    local dist="$3"
    local threads="$4"
    local extra="${5:-}"
    local tag="${system}_${workload}_${dist}_${threads}t${extra:+_$extra}"
    log "Starting experiment: $tag"

    # Resume support
    if $RESUME && result_exists "$tag" >/dev/null 2>&1; then
        log "  SKIP (already done): $tag"
        return 0
    fi

    local exp_dir="${RESULTS_DIR}/${tag}"
    # Expose to start_memory_nodes() so it can direct remote output here.
    CURRENT_EXP_DIR="$exp_dir"
    mkdir -p "$exp_dir" || { log "ERROR: Cannot create experiment dir: $exp_dir"; return 1; }

    log "  RUN: $tag"
    local start_time=$(date +%s)

    # kNodeCount = all 4 nodes always; CNodeCount = ceil(totalThreads / kMaxThread).
    # nodeIDs 0..CNodeCount-1 are CNodes; the rest are MNodes (set later after kMaxThread is known).
    local kNodeCount=${#NODES[@]}
    local bench_exit=0

    # Restart memcached before each run (also kills any live memory-node newbench)
    restart_memcached "$kNodeCount"

    cd "$DEX_DIR"

    # DEX invocation policy:
    # - We mirror DEX's own script arrays in `dex/script/run.sh` to define 5 workload
    #   types (indices into read/insert/update/delete/range arrays):
    #       0: read-only        -> 100% reads
    #       1: read-intensive   -> 95% reads, 5% updates
    #       2: write-intensive  -> 50% reads, 50% updates
    #       3: insert-intensive -> 50% inserts, 50% reads
    #       4: scan-intensive   -> 95% range, 5% inserts
    # - The original DEX paper only reports read-only and write-intensive results.
    #   This orchestrator intentionally extends to all five mixes for a richer study,
    #   using the authors' configuration as the source of truth.
    #
    # Currently, we directly invoke DEX's `newbench` binary on this node for any
    # system tag that starts with "dex". Baseline systems (Sherman, SMART, etc.)
    # are left for future integration.

    if [[ "$system" == dex* ]]; then
        # Map high-level workload name to op-index used by DEX scripts.
        local op_index
        case "$workload" in
            "read-only")       op_index=0 ;;
            "read-intensive")  op_index=1 ;;
            "write-intensive") op_index=2 ;;
            "insert-intensive") op_index=3 ;;
            "scan-intensive")  op_index=4 ;;
            *)
                echo "ERROR: Unknown DEX workload '$workload'" | tee "$exp_dir/output.log"
                return 1
                ;;
        esac
        log "  Mapped workload '$workload' to DEX op_index=$op_index"

        # Map distribution to DEX's uniform/zipf knobs.
        local uniform_flag zipf_theta
        case "$dist" in
            "zipfian")
                uniform_flag=0
                zipf_theta=0.99
                ;;
            "uniform")
                uniform_flag=1
                zipf_theta=0.99
                ;;
            *)
                echo "ERROR: Unknown distribution '$dist'" | tee "$exp_dir/output.log"
                return 1
                ;;
        esac
        # Operation mixes mirrored from dex/script/run.sh.
        local read_arr=(100 95 50 50 0)
        local insert_arr=(0 0 0 50 5)
        local update_arr=(0 5 50 0 0)
        local delete_arr=(0 0 0 0 0)
        local range_arr=(0 0 0 0 95)

        local read_ratio=${read_arr[$op_index]}
        local insert_ratio=${insert_arr[$op_index]}
        local update_ratio=${update_arr[$op_index]}
        local delete_ratio=${delete_arr[$op_index]}
        local range_ratio=${range_arr[$op_index]}

        log "  Running DEX benchmark with op_index=$op_index (read=$read_ratio, insert=$insert_ratio, update=$update_ratio, delete=$delete_ratio, range=$range_ratio), uniform_flag=$uniform_flag, zipf_theta=$zipf_theta"

        # DEX benchmark parameters (mirroring script defaults)
        local mem_threads=4         # mem_threads[1] in run.sh
        local cache_mb=256          # cache[3] in run.sh
        local bulk_million=200      # bulk in run.sh (paper uses 200M records ≈ 3.2 GB)
        local warmup_million=10     # warmup in run.sh
        local op_million=50         # runnum in run.sh
        local check_correctness=0   # correct in run.sh
        local time_based=1          # timebase in run.sh
        local early_stop=1          # early in run.sh
        local index_type=0          # 0=DEX, 1=Sherman, 2=SMART
        local rpc_rate=1            # rpc in run.sh
        local admission_rate=0.1    # admit in run.sh
        local auto_tune=0           # tune in run.sh
        local kMaxThread=36         # last argument in run.sh

        # Allow Phase D extra tags to override cache_mb:
        #   "cache64mb"  → cache_mb=64   (absolute MB, used by Figure 9 design sweep)
        #   "cachepct8"  → cache_mb = bulk_million × 16 MB × 8 / 100  (% of dataset)
        # With bulk_million=200 (3.2 GB dataset): cachepct1=32, cachepct8=256, cachepct32=1024, etc.
        if [[ "$extra" =~ cache([0-9]+)mb ]]; then
            cache_mb="${BASH_REMATCH[1]}"
        elif [[ "$extra" =~ cachepct([0-9]+) ]]; then
            local _pct="${BASH_REMATCH[1]}"
            cache_mb=$(( bulk_million * 16 * _pct / 100 ))
        fi

        # Threads from orchestrator drive totalThreadCount.
        local total_threads="$threads"

        # CNodeCount = ceil(totalThreads / kMaxThread); must pass correct kNodeCount to newbench.
        local cnode_count=$(( (total_threads + kMaxThread - 1) / kMaxThread ))

        local cmd=(sudo ./newbench
            "$kNodeCount"
            "$read_ratio" "$insert_ratio" "$update_ratio" "$delete_ratio" "$range_ratio"
            "$total_threads" "$mem_threads"
            "$cache_mb" "$uniform_flag" "$zipf_theta"
            "$bulk_million" "$warmup_million" "$op_million"
            "$check_correctness" "$time_based" "$early_stop"
            "$index_type" "$rpc_rate" "$admission_rate" "$auto_tune"
            "$kMaxThread"
        )

        {
            echo "System: $system"
            echo "Workload: $workload (op_index=$op_index, read=$read_ratio, insert=$insert_ratio, update=$update_ratio, delete=$delete_ratio, range=$range_ratio)"
            echo "Distribution: $dist (uniform=$uniform_flag, zipf_theta=$zipf_theta)"
            echo "Threads: total=$total_threads, mem_threads=$mem_threads"
            echo "Command: ${cmd[*]}"
            echo ""
        } > "$exp_dir/output.log"

        local attempt
        for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
            if (( attempt > 1 )); then
                log "  RETRY $attempt/$MAX_RETRIES for $tag"
                restart_memcached "$kNodeCount"
            fi
            echo "=== ATTEMPT $attempt/$MAX_RETRIES ===" >> "$exp_dir/output.log"

            # Launch node-0 (compute) first so it wins the memcached serverNum race
            # and gets nodeID 0.  Memory nodes start only after node-0 has
            # registered (serverNum == 1) to guarantee node-0 gets nodeID 0.
            # Node-0 then blocks at the DSM-init barrier until all kNodeCount
            # nodes have joined, then the experiment runs normally.
            log "  Running DEX benchmark command (attempt $attempt/$MAX_RETRIES): ${cmd[*]}"
            timeout "$EXP_TIMEOUT" "${cmd[@]}" >> "$exp_dir/output.log" 2>&1 &
            local node0_pid=$!

            # Block until node-0's serverEnter() INCR has landed (serverNum >= 1).
            # This replaces the previous blind sleep 0.5: it confirms nodeID 0 is
            # claimed before we open the race to memory nodes.
            if ! wait_servernum 1 15; then
                log "  WARNING: node-0 did not register in memcached within 15s"
            fi

            # Now node-0 is inside serverConnect(), spinning with no sleep and
            # sending millions of memcached_get("serverNum") calls/s.  This can
            # fill memcached's accept backlog, causing every incoming TCP SYN from
            # node-{1,2,3} to hit libmemcached's ~4 s connect timeout.
            # Cap the GET flood for the brief window while memory nodes register.
            _throttle_start

            start_memory_nodes "$kNodeCount" "${cmd[*]}"

            # Wait until all kNodeCount nodes have registered, then lift the cap so
            # the benchmark itself runs at full memcached bandwidth.
            if wait_servernum "$kNodeCount" 60; then
                log "  All $kNodeCount nodes registered in memcached"
            else
                log "  WARNING: not all nodes registered within 60s; continuing anyway"
            fi
            _throttle_stop

            # Expose PID/count to the trap so Ctrl+C cleans up mid-run.
            _CLEANUP_PID=$node0_pid
            _CLEANUP_KNODECOUNT=$kNodeCount

            # Wait for the compute-node benchmark to finish, then tear down servers.
            wait "$node0_pid"
            bench_exit=$?
            _CLEANUP_PID=""

            kill_memory_nodes "$kNodeCount"

            if [[ $bench_exit -eq 124 ]]; then
                log "  WARNING: experiment timed out after ${EXP_TIMEOUT}s (attempt $attempt/$MAX_RETRIES)"
                (( attempt < MAX_RETRIES )) && continue
                log "  FAILED: all $MAX_RETRIES attempts timed out — $tag"
            else
                break
            fi
        done
    else
        # Non-DEX systems are not yet wired up; keep previous placeholder behavior.
        echo "PLACEHOLDER: Benchmark invocation for system '$system' not yet implemented." > "$exp_dir/output.log"
        echo "System: $system, Workload: $workload, Distribution: $dist, Threads: $threads" >> "$exp_dir/output.log"
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Mark as done (skipped if all retries timed out, so --resume will retry it)
    if [[ $bench_exit -ne 124 ]]; then
        echo "$tag completed in ${elapsed}s at $(date)" > "${exp_dir}/experiment_${tag}.done"
    else
        log "  Skipping .done marker; experiment can be retried with --resume"
    fi

    # Collect system stats from all nodes
    for node in "${NODES[@]}"; do
        ssh -o StrictHostKeyChecking=no "$node" \
            "grep Huge /proc/meminfo; cat /sys/class/infiniband/*/ports/1/counters/port_rcv_data 2>/dev/null" \
            > "$exp_dir/${node}_stats.txt" 2>/dev/null || true
    done

    log "  DONE: $tag (${elapsed}s)"
}

# ============================================================
# PHASE A: DEX Scalability (Figures 6 & 7) — HIGHEST PRIORITY
# ============================================================
run_phase_a() {
    log "========== PHASE A: DEX Scalability (Figures 6 & 7) =========="
    for dist in "${DISTRIBUTIONS[@]}"; do
        for wl in "${WORKLOADS[@]}"; do
            for tc in "${THREAD_COUNTS[@]}"; do
                run_experiment "dex" "$wl" "$dist" "$tc"
            done
        done
    done
    log "========== PHASE A COMPLETE =========="
}

# ============================================================
# PHASE C: Ablation Study (Figure 8)
# ============================================================
run_phase_c() {
    log "========== PHASE C: Ablation Study (Figure 8) =========="
    for dist in "zipfian" "uniform"; do
        for tc in "${THREAD_COUNTS[@]}"; do
            run_experiment "dex-onesided"     "write-intensive" "$dist" "$tc" "ablation"
            run_experiment "dex-partitioning"  "write-intensive" "$dist" "$tc" "ablation"
            run_experiment "dex-cache"         "write-intensive" "$dist" "$tc" "ablation"
            run_experiment "dex-full"          "write-intensive" "$dist" "$tc" "ablation"
        done
    done
    log "========== PHASE C COMPLETE =========="
}

# ============================================================
# PHASE D: Cache Design + Size Sensitivity (Figures 9, 11)
# ============================================================
run_phase_d() {
    log "========== PHASE D: Cache Studies (Figures 9, 11) =========="

    # Figure 9: Cache design choices
    for cache_mb in 64 256; do
        run_experiment "dex-baseline-cache"    "read-intensive" "zipfian" 112 "cache${cache_mb}mb"
        run_experiment "dex-cooling-map"        "read-intensive" "zipfian" 112 "cache${cache_mb}mb"
        run_experiment "dex-leaf-admission"     "read-intensive" "zipfian" 112 "cache${cache_mb}mb"
    done

    # Figure 11: Cache size sensitivity
    for pct in 1 2 4 8 16 32 64; do
        run_experiment "dex" "read-intensive" "zipfian" 112 "cachepct${pct}"
        run_experiment "dex" "write-intensive" "zipfian" 112 "cachepct${pct}"
    done

    log "========== PHASE D COMPLETE =========="
}

# ============================================================
# PHASE E: Offloading Sensitivity (Figure 12)
# ============================================================
run_phase_e() {
    log "========== PHASE E: Offloading Sensitivity (Figure 12) =========="
    for mem_threads in 0 1 2 4; do
        for tc in "${THREAD_COUNTS[@]}"; do
            run_experiment "dex" "read-intensive" "zipfian" "$tc" "memthreads${mem_threads}"
            run_experiment "dex" "write-intensive" "zipfian" "$tc" "memthreads${mem_threads}"
        done
    done
    log "========== PHASE E COMPLETE =========="
}

# ============================================================
# PHASE F: Repartitioning Cost (Figure 10)
# ============================================================
run_phase_f() {
    log "========== PHASE F: Repartitioning Cost (Figure 10) =========="
    for cache_mb in 256 512 1024; do
        run_experiment "dex" "write-intensive" "zipfian" 112 "repart_cache${cache_mb}mb"
    done
    log "========== PHASE F COMPLETE =========="
}

# ============================================================
# Main Execution
# ============================================================

log "DEX Experiment Suite starting at $(date)"
log "Results directory: $RESULTS_DIR"
log "Phase filter: ${PHASE_FILTER:-ALL}"
echo ""

# Ensure memcached is running.
# -t 8         : 8 worker threads (default 4) so the event loop can keep up
#                with node-0's GET flood while also accepting new connections
# -b 65536     : kernel listen backlog (default 1024); prevents SYN drops when
#                the accept queue briefly fills under heavy load
# -c 4096      : max simultaneous connections (default 1024)
if ! ss -tlnp | grep -q ":11211"; then
    log "Starting memcached on $MEMC_IP..."
    memcached -d -m 1024 -l "$MEMC_IP" -p "$MEMC_PORT" -t 8 -b 65536 -c 4096
fi

OVERALL_START=$(date +%s)

if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "A" ]; then run_phase_a; fi
if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "C" ]; then run_phase_c; fi
if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "D" ]; then run_phase_d; fi
if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "E" ]; then run_phase_e; fi
if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "F" ]; then run_phase_f; fi

OVERALL_END=$(date +%s)
OVERALL_ELAPSED=$(( (OVERALL_END - OVERALL_START) / 60 ))

log ""
log "============================================="
log "ALL EXPERIMENTS COMPLETE"
log "Total time: ${OVERALL_ELAPSED} minutes"
log "Results in: $RESULTS_DIR"
log "============================================="
log ""
log "NEXT: Run backup_results.sh to copy results off-cluster!"