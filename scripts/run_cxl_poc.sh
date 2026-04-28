#!/bin/bash
# run_cxl_poc.sh — Build and run the CXL emulation proof-of-concept
# Usage: ./run_cxl_poc.sh
#
# Produces: cxl_poc_results.csv with all sweep data

set -euo pipefail

echo "=== Building CXL POC ==="
g++ -O2 -std=c++17 -o cxl_poc cxl_poc.cpp -lnuma -lpthread
echo "Build OK"

# Check NUMA topology first
echo ""
echo "=== NUMA Topology ==="
numactl --hardware
echo ""

# CSV header
RESULTS="cxl_poc_results.csv"
echo "delay_ns,threads,avg_read_ns,avg_cas_ns,avg_traversal_ns,throughput_mops" > "$RESULTS"

# Parse one run's output into CSV fields
parse_run() {
    local delay=$1 threads=$2 output=$3
    local read_ns cas_ns trav_ns mops
    read_ns=$(echo "$output" | grep "Avg 1KB node read" | grep -oP '[\d.]+(?= ns)')
    cas_ns=$(echo "$output" | grep "Avg CAS" | grep -oP '[\d.]+(?= ns)')
    trav_ns=$(echo "$output" | grep "Avg full traversal" | grep -oP '[\d.]+(?= ns)')
    mops=$(echo "$output" | grep "Aggregate throughput" | grep -oP '[\d.]+(?= Mops)')
    echo "${delay},${threads},${read_ns},${cas_ns},${trav_ns},${mops}" >> "$RESULTS"
}

# ── Sweep 1: Latency sweep at 1 thread ──
echo "=== Latency Sweep (1 thread) ==="
for delay in 0 70 150 250 400; do
    echo "  delay=${delay}ns ..."
    output=$(numactl --cpunodebind=0 ./cxl_poc --delay "$delay" --threads 1 --ops 200000 2>&1)
    parse_run "$delay" 1 "$output"
done

# ── Sweep 2: Thread scaling at delay=0 (native NUMA) ──
echo "=== Thread Scaling (delay=0) ==="
for threads in 1 2 4 8 16; do
    echo "  threads=${threads} ..."
    output=$(numactl --cpunodebind=0 ./cxl_poc --delay 0 --threads "$threads" --ops 100000 2>&1)
    parse_run 0 "$threads" "$output"
done

# ── Sweep 3: Thread scaling at delay=70 (realistic CXL) ──
echo "=== Thread Scaling (delay=70ns, ASIC CXL) ==="
for threads in 1 2 4 8 16; do
    echo "  threads=${threads} ..."
    output=$(numactl --cpunodebind=0 ./cxl_poc --delay 70 --threads "$threads" --ops 100000 2>&1)
    parse_run 70 "$threads" "$output"
done

echo ""
echo "=== Done! Results in $RESULTS ==="
cat "$RESULTS"
echo ""
echo "Copy this CSV off the node for plotting."
echo "Key thing to look at: how does CAS latency compare to RDMA CAS (~2000ns)?"