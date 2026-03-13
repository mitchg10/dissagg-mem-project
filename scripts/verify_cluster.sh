#!/bin/bash

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

echo "DEX Cluster Verification — $(date)"
echo ""

echo "=== Setup Status ==="
for node in "${NODES[@]}"; do
    status=$(ssh -o StrictHostKeyChecking=no "$node" "cat /local/setup_status.txt 2>/dev/null" || echo "UNREACHABLE")
    if [ "$status" = "RUNNING" ]; then
        check 0 "$node setup complete"
    else
        check 1 "$node setup status: $status"
    fi
done
echo ""

echo "=== Network Connectivity ==="
for i in "${!IPS[@]}"; do
    ping -c 1 -W 2 "${IPS[$i]}" > /dev/null 2>&1
    check $? "Ping ${NODES[$i]} (${IPS[$i]})"
done
echo ""

echo "=== RDMA Devices ==="
for node in "${NODES[@]}"; do
    rdma_dev=$(ssh -o StrictHostKeyChecking=no "$node" "cat /local/rdma_device.txt 2>/dev/null" || echo "NONE")
    if [ "$rdma_dev" != "NONE" ] && [ -n "$rdma_dev" ]; then
        check 0 "$node RDMA device: $rdma_dev"
    else
        check 1 "$node: no RDMA device"
    fi
done
echo ""

echo "=== Hugepages ==="
for node in "${NODES[@]}"; do
    hp=$(ssh -o StrictHostKeyChecking=no "$node" "grep HugePages_Total /proc/meminfo | awk '{print \$2}'" 2>/dev/null || echo "0")
    if [ "$hp" -ge 4096 ] 2>/dev/null; then
        check 0 "$node hugepages: $hp"
    else
        check 1 "$node hugepages: $hp (need ≥4096)"
    fi
done
echo ""

echo "=== DEX Build ==="
for node in "${NODES[@]}"; do
    has_dex=$(ssh -o StrictHostKeyChecking=no "$node" "ls /mydata/dex/build/dex_benchmark 2>/dev/null && echo YES || echo NO" 2>/dev/null || echo "NO")
    if [ "$has_dex" = "NO" ]; then
        has_dex=$(ssh -o StrictHostKeyChecking=no "$node" "ls /mydata/dex/build/*.out /mydata/dex/build/benchmark* 2>/dev/null | head -1 && echo YES || echo NO" 2>/dev/null || echo "NO")
    fi
    check $([ "$has_dex" != "NO" ] && echo 0 || echo 1) "$node DEX binary exists"
done
echo ""

echo "=== RDMA Bandwidth Test ==="
RDMA_DEV=$(cat /local/rdma_device.txt 2>/dev/null | head -1)
RDMA_DEV="${RDMA_DEV:-mlx5_0}"

ib_send_bw -d "$RDMA_DEV" -x 3 --report_gbits -D 3 &
SERVER_PID=$!
sleep 1

BW_RESULT=$(ssh -o StrictHostKeyChecking=no node-1 \
    "ib_send_bw -d \$(cat /local/rdma_device.txt 2>/dev/null | head -1 || echo mlx5_0) -x 3 --report_gbits -D 3 10.10.1.1 2>&1" || echo "FAILED")

wait $SERVER_PID 2>/dev/null || true

if echo "$BW_RESULT" | grep -q "BW peak"; then
    BW=$(echo "$BW_RESULT" | grep -A1 "BW peak" | tail -1 | awk '{print $4}')
    check 0 "RDMA bandwidth: ${BW} Gbps"
else
    check 1 "RDMA bandwidth test failed"
    yellow "  Try: ibv_devinfo -d $RDMA_DEV"
    yellow "  Or adjust: -x 0, -x 1, -x 2, -x 3"
fi
echo ""

echo "=== Memcached Config ==="
for node in "${NODES[@]}"; do
    has_conf=$(ssh -o StrictHostKeyChecking=no "$node" "cat /mydata/dex/build/memcached.conf 2>/dev/null | head -1" || echo "MISSING")
    if [ "$has_conf" = "10.10.1.1" ]; then
        check 0 "$node memcached.conf OK"
    else
        check 1 "$node memcached.conf: '$has_conf' (expected 10.10.1.1)"
    fi
done
echo ""

echo "============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "============================================="

if [ $FAIL -eq 0 ]; then
    green "Ready to run experiments."
    echo ""
    echo "Next:"
    echo "  memcached -d -m 1024 -l 10.10.1.1 -p 11211"
    echo "  cd /mydata/dex/build && ./restartMemc.sh && ./run.sh"
else
    red "Fix the issues above first."
fi
