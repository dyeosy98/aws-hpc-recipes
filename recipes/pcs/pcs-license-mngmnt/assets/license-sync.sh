#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# /usr/local/bin/license-sync.sh
#
# Production FlexLM license sync for AWS PCS.
# Polls lmstat and updates Slurm remote license counts via sacctmgr.
# Run as ec2-user via cron every 5 minutes.
#
# The count pushed to Slurm is:
#   Total = lmstat_issued - lmstat_in_use + slurm_used
#
# This accounts for licenses checked out outside Slurm (e.g. desktop users)
# while preserving the count already tracked by running Slurm jobs.
#
# Required environment (set in /etc/cron.d/license-sync):
#   LICENSE_SERVER        FlexLM server in port@host format (e.g. 27000@license-server)
#   LICENSE_FEATURES      Comma-separated feature names (e.g. comsol,ansys)
#   FLEXLM_SERVER_NAME    Logical server name used when registering resources

set -euo pipefail

SACCTMGR=/opt/aws/pcs/scheduler/slurm-25.05/bin/sacctmgr
SCONTROL=/opt/aws/pcs/scheduler/slurm-25.05/bin/scontrol
LICENSE_SERVER="${LICENSE_SERVER:-27000@license-server.corp.example.com}"
LICENSE_FEATURES="${LICENSE_FEATURES:-comsol,ansys}"
FLEXLM_SERVER_NAME="${FLEXLM_SERVER_NAME:-flexlm-server}"

# ---------------------------------------------------------------------------
# Parse issued and in_use counts from lmstat output
# Returns: "issued in_use"
# ---------------------------------------------------------------------------
get_flexlm_counts() {
    local feature=$1
    local output
    output=$(lmstat -a -c "$LICENSE_SERVER" 2>/dev/null)

    local issued in_use
    issued=$(echo "$output" | awk -v feat="$feature" '
        $0 ~ "Users of " feat ":" {
            match($0, /Total of ([0-9]+) licenses issued/, arr)
            if (arr[1] != "") print arr[1]
        }')
    in_use=$(echo "$output" | awk -v feat="$feature" '
        $0 ~ "Users of " feat ":" {
            match($0, /Total of ([0-9]+) licenses in use/, arr)
            if (arr[1] != "") print arr[1]
        }')

    echo "$issued $in_use"
}

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
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Starting license sync (LIVE mode)"

IFS=',' read -ra FEATURES <<< "$LICENSE_FEATURES"
for feature in "${FEATURES[@]}"; do
    feature=$(echo "$feature" | tr -d ' ')

    read -r issued in_use <<< "$(get_flexlm_counts "$feature")"
    if [ -z "$issued" ] || [ -z "$in_use" ]; then
        echo "ERROR: could not parse lmstat output for '$feature'"
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

    echo "$feature: issued=$issued in_use=$in_use slurm_used=$slurm_used external=$external -> Total=$new_total"

    if update_license "$feature" "$new_total"; then
        echo "Updated $feature: Total=$new_total"
    else
        echo "ERROR: sacctmgr update failed for $feature"
    fi
done

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) License sync complete"
