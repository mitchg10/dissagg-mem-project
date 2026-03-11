#!/bin/bash
# verify_cluster.sh — Run on node-0 after all nodes complete setup.
# Checks: setup status, RDMA devices, network connectivity, RDMA bandwidth.
# Usage: bash /local/repository/scripts/verify_cluster.sh

set -uo pipefail

NODES=("node-0" "node-1" "node-2" "node-3")
IPS=("10.10.1.1" "10.10.1.2" "10.10.1.3" "10.10.1.4")
PASS=0
FAIL=0

green()  { echo -e "\033[32m$1\033[0m"; }
red()    { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

check() {
    if [ $1 -eq 0 ]; then
        green "  ✓ $2"
        ((PASS++))
    else
        red "  ✗ $2"
        ((FAIL++))
    fi
}

echo "============================================="
echo "DEX Cluster Verification — $(date)"
echo "============================================="
echo ""

# ---- 1. Check setup completion on all nodes ----
echo "=== Phase 1: Setup Status ==="
for node in "${NODES[@]}"; do
    status=$(ssh -o StrictHostKeyChecking=no "$node" "cat /local/setup_status.txt 2>/dev/null" || echo "UNREACHABLE")
    if [ "$status" = "DONE" ]; then
        check 0 "$node setup complete"
    else
        check 1 "$node setup status: $status"
    fi
done
echo ""

# ---- 2. Check experiment network connectivity ----
echo "=== Phase 2: Network Connectivity (10.10.1.x) ==="
for i in "${!IPS[@]}"; do
    ping -c 1 -W 2 "${IPS[$i]}" > /dev/null 2>&1
    check $? "Ping ${NODES[$i]} (${IPS[$i]})"
done
echo ""

# ---- 3. Check RDMA devices on all nodes ----
echo "=== Phase 3: RDMA Devices ==="
for node in "${NODES[@]}"; do
    rdma_dev=$(ssh -o StrictHostKeyChecking=no "$node" "cat /local/rdma_device.txt 2>/dev/null" || echo "NONE")
    if [ "$rdma_dev" != "NONE" ] && [ -n "$rdma_dev" ]; then
        check 0 "$node RDMA device: $rdma_dev"
    else
        check 1 "$node: no RDMA device mapped to experiment interface"
    fi
done
echo ""

# ---- 4. Check hugepages on all nodes ----
echo "=== Phase 4: Hugepages ==="
for node in "${NODES[@]}"; do
    hp=$(ssh -o StrictHostKeyChecking=no "$node" "grep HugePages_Total /proc/meminfo | awk '{print \$2}'" 2>/dev/null || echo "0")
    if [ "$hp" -ge 4096 ] 2>/dev/null; then
        check 0 "$node hugepages: $hp"
    else
        check 1 "$node hugepages: $hp (need ≥4096)"
    fi
done
echo ""

# ---- 5. Check DEX build on all nodes ----
echo "=== Phase 5: DEX Build ==="
for node in "${NODES[@]}"; do
    has_dex=$(ssh -o StrictHostKeyChecking=no "$node" "ls /mydata/dex/build/dex_benchmark 2>/dev/null && echo YES || echo NO" 2>/dev/null || echo "NO")
    # DEX binary name may differ — check for any executable in build/
    if [ "$has_dex" = "NO" ]; then
        has_dex=$(ssh -o StrictHostKeyChecking=no "$node" "ls /mydata/dex/build/*.out /mydata/dex/build/benchmark* 2>/dev/null | head -1 && echo YES || echo NO" 2>/dev/null || echo "NO")
    fi
    check $([ "$has_dex" != "NO" ] && echo 0 || echo 1) "$node DEX binary exists"
done
echo ""

# ---- 6. RDMA bandwidth test (node-0 ↔ node-1) ----
echo "=== Phase 6: RDMA Bandwidth Test (node-0 ↔ node-1) ==="
RDMA_DEV=$(cat /local/rdma_device.txt 2>/dev/null || echo "mlx5_0")

echo "  Starting ib_send_bw server on node-0..."
ib_send_bw -d "$RDMA_DEV" -x 3 --report_gbits -D 3 &
SERVER_PID=$!
sleep 1

echo "  Running ib_send_bw client from node-1..."
BW_RESULT=$(ssh -o StrictHostKeyChecking=no node-1 \
    "ib_send_bw -d \$(cat /local/rdma_device.txt 2>/dev/null || echo mlx5_0) -x 3 --report_gbits -D 3 10.10.1.1 2>&1" || echo "FAILED")

wait $SERVER_PID 2>/dev/null || true

if echo "$BW_RESULT" | grep -q "BW peak"; then
    BW=$(echo "$BW_RESULT" | grep -A1 "BW peak" | tail -1 | awk '{print $4}')
    echo "  Measured bandwidth: ${BW} Gbps"
    check 0 "RDMA bandwidth test: ${BW} Gbps"
else
    echo "  $BW_RESULT"
    check 1 "RDMA bandwidth test failed"
    echo ""
    yellow "  Troubleshooting:"
    echo "    1. Check 'ibv_devinfo -d $RDMA_DEV' on both nodes"
    echo "    2. Verify GID table: ibv_devinfo -d $RDMA_DEV -v | grep GID"
    echo "    3. Try different -x (GID index): -x 0, -x 1, -x 2, -x 3"
    echo "    4. Check 'dmesg | grep mlx' for NIC errors"
fi
echo ""

# ---- 7. Check memcached.conf on all nodes ----
echo "=== Phase 7: Memcached Config ==="
for node in "${NODES[@]}"; do
    has_conf=$(ssh -o StrictHostKeyChecking=no "$node" "cat /mydata/dex/build/memcached.conf 2>/dev/null | head -1" || echo "MISSING")
    if [ "$has_conf" = "10.10.1.1" ]; then
        check 0 "$node memcached.conf points to 10.10.1.1"
    else
        check 1 "$node memcached.conf: '$has_conf' (expected 10.10.1.1)"
    fi
done
echo ""

# ---- Summary ----
echo "============================================="
echo "Verification complete: $PASS passed, $FAIL failed"
echo "============================================="

if [ $FAIL -eq 0 ]; then
    green "All checks passed! Ready to run experiments."
    echo ""
    echo "Next steps:"
    echo "  1. Start memcached on node-0:"
    echo "     memcached -d -m 1024 -l 10.10.1.1 -p 11211"
    echo "  2. Smoke test DEX:"
    echo "     cd /mydata/dex/build && ./restartMemc.sh && ./run.sh"
    echo "  3. Run full experiments:"
    echo "     bash /local/repository/scripts/run_all_experiments.sh"
else
    red "Some checks failed. Fix issues above before running experiments."
fi