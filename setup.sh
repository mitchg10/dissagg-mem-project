#!/bin/bash
# setup.sh — Runs automatically on each node at boot via CloudLab profile.
# Installs all dependencies, verifies RDMA, builds DEX + baselines.
#
# Logs to /local/logs/setup.log — check this first if something breaks.
# Status file: /local/setup_status.txt — "DONE" when complete.

set -euo pipefail
mkdir -p /local/logs
exec > >(tee -a /local/logs/setup.log) 2>&1

echo "============================================="
echo "DEX Setup: $(hostname) — $(date)"
echo "============================================="

STATUS_FILE="/local/setup_status.txt"
echo "RUNNING" > "$STATUS_FILE"

# ---- System packages ----
echo "[1/8] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential cmake gcc g++ \
    libtbb-dev \
    libibverbs-dev librdmacm-dev rdma-core ibverbs-utils \
    perftest google-perftools libgoogle-perftools-dev \
    libmemcached-dev memcached libboost-all-dev \
    git numactl htop linux-tools-common iotop \
    python3 python3-pip python3-venv \
    pdsh tmux screen \
    2>&1 | tail -5

# ---- GCC 13 (to match paper: GCC 13.1.1) ----
echo "[2/8] Installing GCC 13..."
if ! gcc-13 --version &>/dev/null; then
    sudo add-apt-repository ppa:ubuntu-toolchain-r/test -y >/dev/null 2>&1
    sudo apt-get update -qq
    sudo apt-get install -y -qq gcc-13 g++-13
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100
fi
echo "  GCC version: $(gcc --version | head -1)"

# ---- Hugepages ----
echo "[3/8] Configuring hugepages..."
echo 4096 | sudo tee /proc/sys/vm/nr_hugepages > /dev/null
if ! grep -q "vm.nr_hugepages" /etc/sysctl.conf; then
    echo "vm.nr_hugepages = 4096" | sudo tee -a /etc/sysctl.conf > /dev/null
fi
sudo sysctl -p > /dev/null 2>&1
HP_TOTAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
echo "  Hugepages allocated: $HP_TOTAL"

# ---- CPU performance mode ----
echo "[4/8] Setting CPU governor to performance..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$cpu" > /dev/null 2>&1 || true
done

# ---- RDMA device discovery ----
echo "[5/8] Discovering RDMA devices..."
echo "  RDMA devices found:"
ibv_devices 2>/dev/null || echo "  WARNING: No RDMA devices found"

# Find the experiment network interface (10.10.1.x) — retry up to 60s
EXP_IP=""
EXP_IFACE=""
for i in $(seq 1 12); do
    EXP_IP=$(ip -4 addr show | grep "10.10.1" | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "")
    EXP_IFACE=$(ip -4 addr show | grep "10.10.1" | grep -oP '(?<=\s)\S+$' | head -1 || echo "")
    [ -n "$EXP_IP" ] && break
    echo "  Waiting for experiment interface (10.10.1.x)... attempt $i/12"
    sleep 5
done

if [ -n "$EXP_IP" ]; then
    echo "  Experiment IP: $EXP_IP on interface $EXP_IFACE"

    # Map netdev to RDMA device
    RDMA_DEV=$(rdma link show 2>/dev/null | grep "$EXP_IFACE" | awk '{print $2}' | cut -d/ -f1 || echo "")
    if [ -n "$RDMA_DEV" ]; then
        echo "  RDMA device for experiment network: $RDMA_DEV"
        echo "$RDMA_DEV" > /local/rdma_device.txt
        echo "$EXP_IP" > /local/experiment_ip.txt
        echo "$EXP_IFACE" > /local/experiment_iface.txt
    else
        echo "  WARNING: Could not map RDMA device to experiment interface"
        # Try to find it via mlx5 devices
        for dev in $(ibv_devices 2>/dev/null | grep mlx5 | awk '{print $1}'); do
            echo "  Checking $dev..."
            ibv_devinfo -d "$dev" 2>/dev/null | head -10
        done
    fi
else
    echo "  WARNING: No experiment IP (10.10.1.x) found after 60s"
    echo "  Control network only — experiment LAN may not be ready"
fi

# ---- Set MTU to 9000 (jumbo frames) for experiment interface ----
if [ -n "$EXP_IFACE" ]; then
    echo "  Setting jumbo frames on $EXP_IFACE..."
    sudo ip link set "$EXP_IFACE" mtu 9000 2>/dev/null || true
fi

# ---- Build DEX ----
echo "[6/8] Building DEX..."

# ---- Fix /mydata ownership ----
echo "Fixing /mydata permissions..."
sudo chown -R "$(whoami)" /mydata
sudo chmod -R 755 /mydata

# ---- Install CityHash ----
echo "Installing CityHash..."
if [ ! -d "/tmp/cityhash" ]; then
    cd /tmp
    git clone https://github.com/google/cityhash.git
    cd cityhash
    ./configure && make all CXXFLAGS="-g -O3" && sudo make install && sudo ldconfig || echo "  WARNING: CityHash installation failed"
else
    echo "  CityHash already installed"
fi

cd /mydata
if [ ! -d "dex" ]; then
    git clone https://github.com/baotonglu/dex.git
fi
cd dex
./script/hugepage.sh 2>/dev/null || true

mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tail -3
make -j$(nproc) 2>&1 | tail -5

# Copy run scripts into build dir
cp ../script/restartMemc.sh . 2>/dev/null || true
cp ../script/run*.sh . 2>/dev/null || true

echo "  DEX build: SUCCESS"

# ---- Build Sherman (baseline) ----
# echo "[7/8] Building Sherman..."
# cd /mydata
# if [ ! -d "Sherman" ]; then
#     git clone https://github.com/thustorage/Sherman.git
# fi
# cd Sherman
# mkdir -p build && cd build
# cmake -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tail -3
# make -j$(nproc) 2>&1 | tail -5 || echo "  WARNING: Sherman build had issues"
# echo "  Sherman build: ATTEMPTED"

# # ---- Build SMART (baseline) ----
# echo "[8/8] Building SMART..."
# cd /mydata
# if [ ! -d "SMART" ]; then
#     git clone https://github.com/dmemsys/SMART.git
# fi
# cd SMART
# # Install SMART dependencies
# sh ./script/installMLNX.sh 2>/dev/null || echo "  WARNING: SMART dependency installation had issues"
# mkdir -p build && cd build
# cmake -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tail -3
# make -j$(nproc) 2>&1 | tail -5 || echo "  WARNING: SMART build had issues"
# echo "  SMART build: ATTEMPTED"

# ---- Copy experiment scripts from repo ----
echo "Copying experiment scripts to /mydata/scripts/..."
mkdir -p /mydata/scripts
cp /local/repository/scripts/*.sh /mydata/scripts/ 2>/dev/null || true
cp /local/repository/configs/* /mydata/configs/ 2>/dev/null || true
chmod +x /mydata/scripts/*.sh 2>/dev/null || true

# ---- Generate memcached.conf (node-0 = 10.10.1.1 is coordinator) ----
mkdir -p /mydata/configs
cat > /mydata/dex/build/memcached.conf << 'EOF'
10.10.1.1
11211
EOF

# ---- Python analysis dependencies (non-blocking) ----
pip3 install matplotlib pandas numpy --break-system-packages -q 2>/dev/null &

# ---- Summary ----
echo ""
echo "============================================="
echo "Setup complete on $(hostname) at $(date)"
echo "============================================="
echo "  Experiment IP:  ${EXP_IP:-UNKNOWN}"
echo "  RDMA device:    ${RDMA_DEV:-UNKNOWN}"
echo "  Hugepages:      $HP_TOTAL"
echo "  GCC:            $(gcc --version | head -1)"
echo "  DEX:            /mydata/dex/build/"
echo "  Sherman:        /mydata/Sherman/build/"
echo "  SMART:          /mydata/SMART/build/"
echo "============================================="
echo ""
echo "NOTE: Inter-node SSH not yet configured."
echo "Run this ONCE from your local machine to enable node-0 → all-nodes SSH:"
echo "  bash /local/repository/scripts/setup_ssh.sh"
echo "This is required before running verify_cluster.sh."
echo "============================================="

echo "DONE" > "$STATUS_FILE"