#!/bin/bash

set -euo pipefail

NODES=("node-0" "node-1" "node-2" "node-3")

# Optional override via --nodes "node-0 node-1 node-2 node-3"
if [[ "${1:-}" == "--nodes" && -n "${2:-}" ]]; then
    read -ra NODES <<< "$2"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# On CloudLab, /users is local per-node. Remote nodes only have your
# CloudLab-registered key in authorized_keys (not the generated id_ed25519).
# SSH agent forwarding is required so this script can authenticate to
# remote nodes using your forwarded key and add id_ed25519 there.
_ssh_add_rc=0
ssh-add -l &>/dev/null || _ssh_add_rc=$?
if [ "$_ssh_add_rc" -eq 2 ]; then
    echo "ERROR: No SSH agent socket found (SSH_AUTH_SOCK not set or agent unreachable)."
    echo ""
    echo "On CloudLab, this script requires SSH agent forwarding to reach"
    echo "remote nodes. Reconnect with agent forwarding enabled:"
    echo ""
    echo "  ssh -A $(hostname -f)"
    echo ""
    echo "Then re-run: bash /local/repository/scripts/setup_ssh.sh"
    exit 1
elif [ "$_ssh_add_rc" -eq 1 ]; then
    echo "ERROR: SSH agent is running but has no identities loaded."
    echo ""
    echo "Add your CloudLab private key to the agent on your *local* machine"
    echo "before connecting with ssh -A:"
    echo ""
    echo "  ssh-add ~/.ssh/your_cloudlab_key   # run locally"
    echo "  ssh -A $(hostname -f)"
    echo ""
    exit 1
fi

echo "============================================="
echo "DEX SSH Key Distribution — $(date)"
echo "============================================="
echo "Nodes: ${NODES[*]}"
echo ""

# Generate key on node-0 locally (already running here — no SSH needed)
echo "Generating ed25519 key on node-0..."
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "node-0-dex-cluster"
    echo "  Key generated: $KEY"
else
    echo "  Key already exists: $KEY"
fi

# Read node-0's public key
echo ""
echo "Reading node-0 public key..."
NODE0_PUBKEY=$(cat "$KEY.pub")
echo "  Public key: ${NODE0_PUBKEY:0:60}..."

# Distribute to all nodes
echo ""
echo "Distributing public key to all nodes..."
for node in "${NODES[@]}"; do
    echo -n "  $node: "
    if [ "$node" == "node-0" ]; then
        # Already running on node-0 — update authorized_keys locally (no SSH needed)
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        touch "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        if ! grep -qF "${NODE0_PUBKEY}" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
            echo "${NODE0_PUBKEY}" >> "$HOME/.ssh/authorized_keys"
            echo "key added"
        else
            echo "key already present"
        fi
    else
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
    fi
done

# Verify SSH from node-0 to all other nodes
echo ""
echo "Verifying SSH from node-0 to all nodes..."
FAIL=0
for node in "${NODES[@]}"; do
    result=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 $node hostname 2>&1 || echo "FAILED")
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