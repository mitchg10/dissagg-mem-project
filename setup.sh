#!/bin/bash
set -euo pipefail
exec > /local/logs/setup.log 2>&1

echo "=== DEX Setup: $(hostname) ==="

# ---- System packages ----
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake gcc g++ \
    libibverbs-dev librdmacm-dev rdma-core ibverbs-utils \
    perftest \
    libmemcached-dev memcached \
    git numactl htop linux-tools-common \
    python3 python3-pip

# ---- Mellanox OFED (optional: use inbox drivers first) ----
# The inbox rdma-core + kernel drivers on Ubuntu 22.04 support
# ConnectX-5 RoCE v2 out of the box. If you need full MLNX_OFED:
#   wget https://content.mellanox.com/ofed/MLNX_OFED-5.x/...
#   sudo ./mlnxofedinstall --force

# ---- Verify RDMA devices ----
echo "=== RDMA devices ==="
ibv_devices || echo "WARNING: No RDMA devices found yet"
ibv_devinfo || true

# ---- Identify the experiment network interface ----
# On d6515, the ConnectX-5 ports are typically mlx5_0 and mlx5_1.
# The experiment interface has the 10.10.1.x address.
EXP_IP=$(ip -4 addr show | grep "10.10.1" | awk '{print $2}' | cut -d/ -f1)
EXP_IFACE=$(ip -4 addr show | grep "10.10.1" | awk '{print $NF}')
echo "Experiment IP: $EXP_IP on interface $EXP_IFACE"

# ---- Find the correct RDMA device for the experiment interface ----
# CRITICAL: Must use the RDMA device bound to the experiment NIC,
# not the control network NIC.
RDMA_DEV=$(rdma link show | grep "$EXP_IFACE" | awk '{print $2}' | cut -d/ -f1)
echo "RDMA device for experiment: $RDMA_DEV"
echo "$RDMA_DEV" > /local/rdma_device.txt

# ---- Enable RoCE v2 (if applicable) ----
# For ConnectX-5 on Ethernet, ensure RoCE v2 is the default
if [ -n "$RDMA_DEV" ]; then
    cma_port=$(rdma link show "$RDMA_DEV"/1 2>/dev/null | grep -oP 'port \K\d+' || echo "1")
    # Set default GID type to RoCE v2
    echo "RoCE v2 configuration for $RDMA_DEV"
fi

# ---- Configure hugepages (DEX requirement) ----
echo 4096 | sudo tee /proc/sys/vm/nr_hugepages
echo "vm.nr_hugepages = 4096" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Verify
echo "Hugepages allocated: $(grep HugePages_Total /proc/meminfo)"

# ---- Disable CPU frequency scaling for stable benchmarks ----
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$cpu" 2>/dev/null || true
done

# ---- Clone and build DEX ----
cd /mydata
git clone https://github.com/baotonglu/dex.git
cd dex
./script/hugepage.sh || true   # may overlap with our hugepage setup

mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)

# Copy run scripts
cp ../script/restartMemc.sh .
cp ../script/run*.sh .

echo "=== DEX build complete on $(hostname) ==="

