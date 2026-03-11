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

mkdir -p "$RESULTS_DIR"
LOG_FILE="${RESULTS_DIR}/orchestrator.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if an experiment result already exists (for --resume)
result_exists() {
    local tag="$1"
    ls "${RESULTS_BASE}"/*/experiment_${tag}.done 2>/dev/null | head -1
}

# Restart memcached state (clears QP info between runs)
restart_memcached() {
    log "  Restarting memcached..."
    # Kill and restart memcached
    pkill memcached 2>/dev/null || true
    sleep 1
    memcached -d -m 1024 -l "$MEMC_IP" -p "$MEMC_PORT"
    sleep 1
    # Also run DEX's own restart script if available
    cd "$DEX_DIR"
    ./restartMemc.sh 2>/dev/null || true
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
    mkdir -p "$exp_dir"

    log "  RUN: $tag"
    local start_time=$(date +%s)

    # Restart memcached before each run
    restart_memcached

    cd "$DEX_DIR"

    # DEX invocation policy:
    # - We mirror DEX's own script arrays in `dex/script/run.sh` to define 5 workload
    #   types (indices into read/insert/update/delete/range arrays):
    #       0: read-only        -> 100% reads
    #       1: read-intensive   -> 50% reads, 50% updates
    #       2: write-intensive  -> 95% reads, 5% updates
    #       3: insert-intensive -> 100% inserts
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
        log "  Running DEX benchmark with op_index=$op_index (read=$read_ratio, insert=$insert_ratio, update=$update_ratio, delete=$delete_ratio, range=$range_ratio), uniform_flag=$uniform_flag, zipf_theta=$zipf_theta"

        # Operation mixes mirrored from dex/script/run.sh.
        local read_arr=(100 50 95 0 0)
        local insert_arr=(0 0 0 100 5)
        local update_arr=(0 50 5 0 0)
        local delete_arr=(0 0 0 0 0)
        local range_arr=(0 0 0 0 95)

        local read_ratio=${read_arr[$op_index]}
        local insert_ratio=${insert_arr[$op_index]}
        local update_ratio=${update_arr[$op_index]}
        local delete_ratio=${delete_arr[$op_index]}
        local range_ratio=${range_arr[$op_index]}

        # DEX benchmark parameters (mirroring script defaults where possible).
        local kNodeCount=2          # matches nodenum in run.sh
        local mem_threads=4         # mem_threads[1] in run.sh
        local cache_mb=256          # cache[3] in run.sh
        local bulk_million=50       # bulk in run.sh
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

        # Threads from orchestrator drive totalThreadCount.
        local total_threads="$threads"

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

        # Run the benchmark, appending full output.
        log "  Running DEX benchmark command: ${cmd[*]}"
        "${cmd[@]}" >> "$exp_dir/output.log" 2>&1
    else
        # Non-DEX systems are not yet wired up; keep previous placeholder behavior.
        echo "PLACEHOLDER: Benchmark invocation for system '$system' not yet implemented." > "$exp_dir/output.log"
        echo "System: $system, Workload: $workload, Distribution: $dist, Threads: $threads" >> "$exp_dir/output.log"
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Mark as done
    echo "$tag completed in ${elapsed}s at $(date)" > "${exp_dir}/experiment_${tag}.done"

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
# PHASE B: Baselines (Sherman, SMART) for Figures 6 & 7
# ============================================================
run_phase_b() {
    log "========== PHASE B: Baselines (Sherman, SMART) =========="
    for system in "sherman" "smart"; do
        for dist in "${DISTRIBUTIONS[@]}"; do
            for wl in "${WORKLOADS[@]}"; do
                for tc in "${THREAD_COUNTS[@]}"; do
                    run_experiment "$system" "$wl" "$dist" "$tc"
                done
            done
        done
    done
    # P-Sherman and P-SMART (with logical partitioning)
    for system in "p-sherman" "p-smart"; do
        for dist in "${DISTRIBUTIONS[@]}"; do
            for wl in "${WORKLOADS[@]}"; do
                for tc in "${THREAD_COUNTS[@]}"; do
                    run_experiment "$system" "$wl" "$dist" "$tc"
                done
            done
        done
    done
    log "========== PHASE B COMPLETE =========="
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

# Ensure memcached is running
if ! ss -tlnp | grep -q ":11211"; then
    log "Starting memcached on $MEMC_IP..."
    memcached -d -m 1024 -l "$MEMC_IP" -p "$MEMC_PORT"
fi

OVERALL_START=$(date +%s)

if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "A" ]; then run_phase_a; fi
if [ -z "$PHASE_FILTER" ] || [ "$PHASE_FILTER" = "B" ]; then run_phase_b; fi
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