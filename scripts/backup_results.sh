#!/bin/bash
# backup_results.sh — Create a compressed archive of all results.
# Run this on node-0 BEFORE your reservation expires!
#
# Usage: bash backup_results.sh [dest_user@dest_host:dest_path]
#
# Without args: creates tarball in /mydata/
# With args:    also SCPs the tarball to your specified destination

set -uo pipefail

RESULTS_DIR="/mydata/results"
ARCHIVE_NAME="dex_results_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="/mydata/$ARCHIVE_NAME"

echo "============================================="
echo "DEX Results Backup — $(date)"
echo "============================================="

# First, collect everything
echo "Step 1: Collecting results from all nodes..."
bash /local/repository/scripts/collect_results.sh "$RESULTS_DIR"

# Generate metrics summary CSV before archiving so it lands inside the tarball
echo "Step 2: Generating metrics summary CSV..."
SUMMARY_CSV="${RESULTS_DIR}/summary.csv"
python3 /local/repository/parse_logs.py "$RESULTS_DIR" --csv "$SUMMARY_CSV" \
    && echo "  Summary CSV: $SUMMARY_CSV" \
    || echo "  WARNING: parse_logs.py failed or no results yet — skipping CSV"
echo ""

# Create compressed archive
echo "Step 3: Creating archive..."
cd /mydata
tar -czf "$ARCHIVE_NAME" results/
echo "  Archive: $ARCHIVE_PATH"
echo "  Size: $(du -h "$ARCHIVE_PATH" | cut -f1)"

# SCP if destination provided
if [ -n "${1:-}" ]; then
    echo "Step 4: Transferring to $1..."
    scp "$ARCHIVE_PATH" "$1"
    echo "  Transfer complete!"
else
    echo ""
    echo "Step 4: Manual transfer needed. Run one of:"
    echo "  FROM YOUR LOCAL MACHINE:"
    echo "    scp $(whoami)@$(hostname -f):${ARCHIVE_PATH} ~/dex-results/"
    echo ""
    echo "  OR from node-0 to an external server:"
    echo "    scp ${ARCHIVE_PATH} you@your-server.edu:~/dex-results/"
fi

echo ""
echo "============================================="
echo "Backup complete."
echo "============================================="