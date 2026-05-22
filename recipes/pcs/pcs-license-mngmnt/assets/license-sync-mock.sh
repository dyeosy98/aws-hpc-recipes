#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# /usr/local/bin/license-sync-mock.sh
#
# Mock FlexLM license sync for testing AWS PCS without a real license server.
# Uses hardcoded lmstat values to simulate FlexLM output.
# Applies the same count logic as the production script:
#   Total = mock_issued - mock_in_use + slurm_used
#
# Run as ec2-user via cron every 5 minutes during testing.
#
# Required environment (set in /etc/cron.d/license-sync):
#   LICENSE_FEATURES      Comma-separated feature names (e.g. comsol,ansys)
#   FLEXLM_SERVER_NAME    Logical server name used when registering resources
#
# Optional (mock values):
#   MOCK_COMSOL_ISSUED    Total COMSOL licenses in the mock (default: 50)
#   MOCK_COMSOL_IN_USE    In-use COMSOL licenses in the mock (default: 5)
#   MOCK_ANSYS_ISSUED     Total ANSYS licenses in the mock (default: 20)
#   MOCK_ANSYS_IN_USE     In-use ANSYS licenses in the mock (default: 3)

set -euo pipefail

SACCTMGR=/opt/aws/pcs/scheduler/slurm-25.05/bin/sacctmgr
SCONTROL=/opt/aws/pcs/scheduler/slurm-25.05/bin/scontrol
LICENSE_FEATURES="${LICENSE_FEATURES:-comsol,ansys}"
FLEXLM_SERVER_NAME="${FLEXLM_SERVER_NAME:-flexlm-server}"

# ---------------------------------------------------------------------------
# Mock lmstat values — edit these or override via environment variables
# ---------------------------------------------------------------------------
declare -A MOCK_ISSUED=(
    [comsol]="${MOCK_COMSOL_ISSUED:-50}"
    [ansys]="${MOCK_ANSYS_ISSUED:-20}"
)
declare -A MOCK_IN_USE=(
    [comsol]="${MOCK_COMSOL_IN_USE:-5}"
    [ansys]="${MOCK_ANSYS_IN_USE:-3}"
)

# ---------------------------------------------------------------------------
# Get the number of licenses currently used by Slurm jobs
# ---------------------------------------------------------------------------
get_slurm_used() {
    local feature=$1
    local server=$2
    $SCONTROL show lic "${feature}@${server}" 2>/dev/null \
        | awk '/Used=/ { match($0, /Used=([0-9]+)/, arr); if (arr[1] != "") print arr[1] }'
}

# ---------------------------------------------------------------------------
# Update Slurm remote license count via sacctmgr
# ---------------------------------------------------------------------------
update_license() {
    local feature=$1
    local count=$2
    sudo -u slurm "$SACCTMGR" -i modify resource \
        name="$feature" \
        server="$FLEXLM_SERVER_NAME" \
        set count="$count"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Starting license sync (MOCK mode)"

IFS=',' read -ra FEATURES <<< "$LICENSE_FEATURES"
for feature in "${FEATURES[@]}"; do
    feature=$(echo "$feature" | tr -d ' ')

    issued="${MOCK_ISSUED[$feature]:-}"
    in_use="${MOCK_IN_USE[$feature]:-}"

    if [ -z "$issued" ] || [ -z "$in_use" ]; then
        echo "ERROR: no mock values defined for '$feature' — add to MOCK_ISSUED/MOCK_IN_USE"
        continue
    fi

    slurm_used=$(get_slurm_used "$feature" "$FLEXLM_SERVER_NAME")
    slurm_used=${slurm_used:-0}

    # Licenses held outside Slurm
    external=$((in_use - slurm_used))
    [ "$external" -lt 0 ] && external=0

    # Available slots for Slurm = total pool minus external checkouts
    new_total=$((issued - external))
    [ "$new_total" -lt 0 ] && new_total=0

    echo "$feature: mock issued=$issued in_use=$in_use slurm_used=$slurm_used external=$external -> Total=$new_total"

    if update_license "$feature" "$new_total"; then
        echo "Updated $feature: Total=$new_total"
    else
        echo "ERROR: sacctmgr update failed for $feature"
    fi
done

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) License sync complete"
