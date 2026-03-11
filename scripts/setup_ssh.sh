#!/bin/bash

set -euo pipefail

NODES=("node-0" "node-1" "node-2" "node-3")

# Optional override via --nodes "node-0 node-1 node-2 node-3"
if [[ "${1:-}" == "--nodes" && -n "${2:-}" ]]; then
    read -ra NODES <<< "$2"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "============================================="
echo "DEX SSH Key Distribution — $(date)"
echo "============================================="
echo "Nodes: ${NODES[*]}"
echo ""

# Generate key on node-0 if absent
echo "Generating ed25519 key on node-0..."
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

# Read node-0's public key
echo ""
echo "Reading node-0 public key..."
NODE0_PUBKEY=$(ssh $SSH_OPTS node-0 'cat ~/.ssh/id_ed25519.pub')
echo "  Public key: ${NODE0_PUBKEY:0:60}..."

# Distribute to all nodes
echo ""
echo "Distributing public key to all nodes..."
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

# Verify SSH from node-0 to all other nodes
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
if [ "$FAIL" -eq 0 ]; then
    echo "SSH setup complete. node-0 can reach all nodes."
else
    echo "WARNING: $FAIL node(s) unreachable from node-0."
    echo "Check authorized_keys permissions and sshd config on affected nodes."
fi
