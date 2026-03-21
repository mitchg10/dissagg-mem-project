#!/bin/bash

set -euo pipefail
mkdir -p /local/logs
exec > >(tee -a /local/logs/setup.log) 2>&1

echo "DEX Setup: $(hostname) — $(date)"

STATUS_FILE="/local/setup_status.txt"
echo "RUNNING" > "$STATUS_FILE"

echo "Installing system packages..."
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

echo "Installing GCC 13..."
if ! gcc-13 --version &>/dev/null; then
    sudo add-apt-repository ppa:ubuntu-toolchain-r/test -y >/dev/null 2>&1
    sudo apt-get update -qq
    sudo apt-get install -y -qq gcc-13 g++-13
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100
fi
echo "  GCC version: $(gcc --version | head -1)"

echo "Setting CPU governor to performance..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$cpu" > /dev/null 2>&1 || true
done

echo "Discovering RDMA devices..."
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

    # Resolve parent physical interface if EXP_IFACE is a VLAN
    # (rdma link show maps to physical interfaces, not VLAN sub-interfaces)
    PHYS_IFACE="$EXP_IFACE"
    if [ -f "/proc/net/vlan/$EXP_IFACE" ]; then
        PHYS_IFACE=$(awk '/^Device:/{print $2}' /proc/net/vlan/"$EXP_IFACE")
        echo "  VLAN interface $EXP_IFACE is on physical interface $PHYS_IFACE"
    fi

    # Map netdev to RDMA device
    RDMA_DEV=$(rdma link show 2>/dev/null | grep "$PHYS_IFACE" | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "")
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

if [ -n "$EXP_IFACE" ]; then
    echo "  Setting jumbo frames on $EXP_IFACE..."
    sudo ip link set "$EXP_IFACE" mtu 9000 2>/dev/null || true
    if [ "${PHYS_IFACE:-}" != "$EXP_IFACE" ]; then
        echo "  Setting jumbo frames on physical interface $PHYS_IFACE..."
        sudo ip link set "$PHYS_IFACE" mtu 9000 2>/dev/null || true
    fi
fi

echo "Building DEX..."

sudo chown -R "$(whoami)" /mydata
sudo chmod -R 755 /mydata

# Install CityHash dependency from source
echo "Installing CityHash..."
if [ ! -d "/tmp/cityhash" ]; then
    cd /tmp
    git clone https://github.com/google/cityhash.git
    cd cityhash
    ./configure && make all CXXFLAGS="-g -O3" && sudo make install && sudo ldconfig || echo "  WARNING: CityHash installation failed"
else
    echo "  CityHash already installed"
fi

# Install DEX from personal fork
cd /mydata
if [ ! -d "dex" ]; then
    git clone https://github.com/mitchg10/dex.git
fi
cd dex
sudo bash ./script/hugepage.sh 2>/dev/null || true

mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tail -3
if make -j$(nproc) 2>&1 | tail -5; then
    cp ../script/restartMemc.sh . 2>/dev/null || true
    cp ../script/run*.sh . 2>/dev/null || true
    cp ../memcache.conf . 2>/dev/null || echo "  WARNING: Could not copy memcache.conf"
    echo "  DEX build: SUCCESS"
else
    echo "  DEX build: FAILED"
    exit 1
fi

echo "Copying experiment scripts to /mydata/scripts/..."
mkdir -p /mydata/scripts
cp /local/repository/scripts/*.sh /mydata/scripts/ 2>/dev/null || true
cp /local/repository/configs/* /mydata/configs/ 2>/dev/null || true
chmod +x /mydata/scripts/*.sh 2>/dev/null || true

pip3 install matplotlib pandas numpy --break-system-packages -q 2>/dev/null &

# Summary
echo ""
echo "Setup complete on $(hostname) at $(date)"
echo "Experiment IP: ${EXP_IP:-UNKNOWN}"
echo "RDMA device: ${RDMA_DEV:-UNKNOWN}"
# echo "Hugepages: $HP_TOTAL"
echo "GCC: $(gcc --version | head -1)"
echo "DEX: /mydata/dex/build/"

echo "DONE" > "$STATUS_FILE"