#!/bin/bash
# setup_ssh.sh — Run ONCE from your LOCAL MACHINE after all nodes complete setup.
#
# Generates an ed25519 key pair on node-0 (if absent) and appends node-0's
# public key to ~/.ssh/authorized_keys on every node.  After this runs,
# node-0 can SSH to all nodes without a password, which is required for
# verify_cluster.sh and DEX's pdsh-based launch.
#
# Prerequisites:
#   - Your CloudLab account SSH key must already be on all nodes.
#   - Run from your local machine (not from inside a node).
#
# Usage:
#   bash /path/to/scripts/setup_ssh.sh
#   bash /path/to/scripts/setup_ssh.sh --nodes "node-0 node-1 node-2 node-3"

set -euo pipefail

NODES=("node-0" "node-1" "node-2" "node-3")

# Optional override via --nodes flag
if [[ "${1:-}" == "--nodes" && -n "${2:-}" ]]; then
    read -ra NODES <<< "$2"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "============================================="
echo "DEX SSH Key Distribution — $(date)"
echo "============================================="
echo "Nodes: ${NODES[*]}"
echo ""

# ---- Step 1: Generate key on node-0 if absent ----
echo "[1/3] Generating ed25519 key on node-0 (if absent)..."
ssh $SSH_OPTS node-0 'bash -s' << 'REMOTE'
set -euo pipefail
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "node-0-dex-cluster"
    echo "  Key generated: $KEY"
else
    echo "  Key already exists: $KEY"
fi
REMOTE

# ---- Step 2: Read node-0's public key ----
echo ""
echo "[2/3] Reading node-0 public key..."
NODE0_PUBKEY=$(ssh $SSH_OPTS node-0 'cat ~/.ssh/id_ed25519.pub')
echo "  Public key: ${NODE0_PUBKEY:0:60}..."

# ---- Step 3: Distribute to all nodes ----
echo ""
echo "[3/3] Distributing public key to all nodes..."
for node in "${NODES[@]}"; do
    echo -n "  $node: "
    ssh $SSH_OPTS "$node" 'bash -s' << REMOTE
set -euo pipefail
mkdir -p "\$HOME/.ssh"
chmod 700 "\$HOME/.ssh"
touch "\$HOME/.ssh/authorized_keys"
chmod 600 "\$HOME/.ssh/authorized_keys"
# Append only if not already present
if ! grep -qF "${NODE0_PUBKEY}" "\$HOME/.ssh/authorized_keys" 2>/dev/null; then
    echo "${NODE0_PUBKEY}" >> "\$HOME/.ssh/authorized_keys"
    echo "key added"
else
    echo "key already present"
fi
REMOTE
done

# ---- Verify: SSH from node-0 to all other nodes ----
echo ""
echo "Verifying SSH from node-0 to all nodes..."
FAIL=0
for node in "${NODES[@]}"; do
    result=$(ssh $SSH_OPTS node-0 "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 $node hostname 2>&1" || echo "FAILED")
    if echo "$result" | grep -qv "FAILED\|denied\|error\|Error"; then
        echo "  ✓ node-0 → $node: $result"
    else
        echo "  ✗ node-0 → $node: $result"
        ((FAIL++))
    fi
done

echo ""
echo "============================================="
if [ "$FAIL" -eq 0 ]; then
    echo "SSH setup complete. node-0 can reach all nodes."
    echo ""
    echo "Next: run verify_cluster.sh from node-0:"
    echo "  ssh node-0 'bash /local/repository/scripts/verify_cluster.sh'"
else
    echo "WARNING: $FAIL node(s) unreachable from node-0."
    echo "Check authorized_keys permissions and sshd config on affected nodes."
fi
echo "============================================="
