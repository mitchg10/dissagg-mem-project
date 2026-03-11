#!/bin/bash
# collect_results.sh — Gather results and system info from all nodes to node-0.
# Run this on node-0 periodically during experiments and before reservation expires.
#
# Usage: bash collect_results.sh [results_dir]

set -uo pipefail

NODES=("node-0" "node-1" "node-2" "node-3")
RESULTS_DIR="${1:-/mydata/results}"
COLLECT_DIR="${RESULTS_DIR}/collected_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$COLLECT_DIR"

echo "Collecting results to: $COLLECT_DIR"

# ---- Gather from each node ----
for node in "${NODES[@]}"; do
    echo "  Collecting from $node..."
    node_dir="$COLLECT_DIR/$node"
    mkdir -p "$node_dir"

    # System info snapshot
    ssh -o StrictHostKeyChecking=no "$node" bash -s << 'REMOTE_EOF' > "$node_dir/system_info.txt" 2>&1
echo "=== hostname ==="
hostname
echo "=== date ==="
date
echo "=== uname ==="
uname -a
echo "=== CPU ==="
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|Socket"
echo "=== Memory ==="
free -h
echo "=== Hugepages ==="
grep Huge /proc/meminfo
echo "=== RDMA ==="
ibv_devinfo 2>/dev/null | head -20
echo "=== NIC counters ==="
cat /sys/class/infiniband/*/ports/1/counters/port_rcv_data 2>/dev/null
cat /sys/class/infiniband/*/ports/1/counters/port_xmit_data 2>/dev/null
echo "=== CPU governor ==="
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
echo "=== GCC ==="
gcc --version | head -1
REMOTE_EOF

    # Copy any logs and results from DEX build directory
    scp -o StrictHostKeyChecking=no -rq "$node:/mydata/dex/build/*.log" "$node_dir/" 2>/dev/null || true
    scp -o StrictHostKeyChecking=no -rq "$node:/mydata/dex/build/*.txt" "$node_dir/" 2>/dev/null || true
    scp -o StrictHostKeyChecking=no -rq "$node:/mydata/dex/build/*.csv" "$node_dir/" 2>/dev/null || true

    # Copy setup log
    scp -o StrictHostKeyChecking=no -q "$node:/local/logs/setup.log" "$node_dir/setup.log" 2>/dev/null || true
done

# ---- Also copy the experiment results directory structure ----
echo "  Copying experiment results..."
cp -r "${RESULTS_DIR}"/2* "$COLLECT_DIR/experiments/" 2>/dev/null || true

# ---- Create a summary ----
echo "  Generating summary..."
{
    echo "DEX Experiment Results Collection"
    echo "================================="
    echo "Collected at: $(date)"
    echo "From nodes: ${NODES[*]}"
    echo ""
    echo "Experiment runs found:"
    find "${RESULTS_DIR}" -name "*.done" -exec cat {} \; 2>/dev/null | sort
    echo ""
    echo "Total result files:"
    find "$COLLECT_DIR" -type f | wc -l
} > "$COLLECT_DIR/SUMMARY.txt"

echo ""
echo "Collection complete: $COLLECT_DIR"
echo "Files collected: $(find "$COLLECT_DIR" -type f | wc -l)"
echo ""
echo "To backup to your local machine:"
echo "  scp -r $(whoami)@$(hostname -f):${COLLECT_DIR} ~/dex-results/"