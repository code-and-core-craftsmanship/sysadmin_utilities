#!/bin/bash

# Copyright (C) 2026 Alexander <aan.mailbox@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://gnu.org>.

set -uo pipefail

# ==============================================================================
# Configuration (The variable values are provided for example purposes only.)
# ==============================================================================

CONF_FILE="/etc/mikrotik/mikrotik_dev_list.conf"
RSC_BKUP_DIR="/var/backups/mikrotik/rsc"
BINARY_BKUP_DIR="/var/backups/mikrotik/binary"
BACKUP_USER="backup_user_name"
EMAIL_TO="admin@example.com"
KEEP_DAYS=30

# An array for collecting errors as the script runs
FAILED_ROUTERS=()

# ==============================================================================
# Functions
# ==============================================================================

# Function for sending an email
function send_email_report() {
    local subject="$1"
    local body="$2"

    printf "Subject: %s\nTo: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s" \
        "$subject" "$EMAIL_TO" "$body" | msmtp "$EMAIL_TO"
}

# Port‑knocking function
function port_knocking() {
    local ip=$1 p1_proto=$2 p1_port=$3 p2_proto=$4 p2_port=$5 p3_proto=$6 p3_port=$7
    local cmd_p1 cmd_p2 cmd_p3

    [[ "${p1_proto}" =~ ^[Uu][Dd][Pp]$ ]] && cmd_p1="-zu" || cmd_p1=""
    [[ "${p2_proto}" =~ ^[Uu][Dd][Pp]$ ]] && cmd_p2="-zu" || cmd_p2=""
    [[ "${p3_proto}" =~ ^[Uu][Dd][Pp]$ ]] && cmd_p3="-zu" || cmd_p3=""

    echo -n "" | nc -w 1 $cmd_p1 "$ip" "$p1_port"; sleep 0.5
    echo -n "" | nc -w 1 $cmd_p2 "$ip" "$p2_port"; sleep 0.5
    echo -n "" | nc -w 1 $cmd_p3 "$ip" "$p3_port"; sleep 1
}

# Checking the configuration file with the list of MikroTik equipment
if [[ ! -s "$CONF_FILE" ]]; then
    msg="CRITICAL: The file containing the list of MikroTik IP addresses ($CONF_FILE) was not found or is empty."
    logger -si -t MikroTik_backup "ERROR: $msg"
    send_email_report "CRITICAL: Error launching MikroTik backup" "$msg"
    exit 1
fi

# ==============================================================================
# Main loop
# ==============================================================================

while IFS=';' read -u 3 -r ip ssh_port p1_proto p1_port p2_proto p2_port p3_proto p3_port || [[ -n "${ip:-}" ]]; do
    # Guard against unbound variable check and skip empty lines / comments
    if [[ -z "${ip:-}" || "$ip" == \#* ]]; then
        continue
    fi

    # Performing port knocking
    port_knocking "$ip" "$p1_proto" "$p1_port" "$p2_proto" "$p2_port" "$p3_proto" "$p3_port"

    # Checking the availability of the SSH port after knocking
    if ! nc -z -w 2 "$ip" "$ssh_port"; then
        log_msg="The SSH port $ssh_port is closed or the device is unavailable."
        logger -si -t MikroTik_backup "ERROR: $ip - $log_msg"
        FAILED_ROUTERS+=("$ip - $log_msg")
        continue
    fi

    # SSH session options
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $ssh_port"

    # ==============================================================================
    # Text backup (/export) to Git
    # ==============================================================================
    CURRENT_RSC_DIR="$RSC_BKUP_DIR/$ip"
    mkdir -p "$CURRENT_RSC_DIR"
    
    if [[ ! -d "$CURRENT_RSC_DIR/.git" ]]; then
        git -C "$CURRENT_RSC_DIR" init >/dev/null
        git -C "$CURRENT_RSC_DIR" config user.name "systemd-backup"
        git -C "$CURRENT_RSC_DIR" config user.email "backup@$(hostname).local"
    fi

    BACKUP_RSC="$CURRENT_RSC_DIR/${ip}.rsc"

    # Performing the export. Errors (stderr) are redirected to /dev/null
    ssh $SSH_OPTS "$BACKUP_USER"@"$ip" "/export compact" > "$BACKUP_RSC" 2>/dev/null

    # Verify that the file was physically created on the server and its size is greater than 0 bytes
    if [ -s "$BACKUP_RSC" ]; then
        git -C "$CURRENT_RSC_DIR" add "${ip}.rsc"
        # Commit only if there are actual configuration changes
        if ! git -C "$CURRENT_RSC_DIR" diff-index --quiet HEAD --; then
            git -C "$CURRENT_RSC_DIR" commit -m "Backup $ip $(date +'%Y-%m-%d %H:%M:%S')" >/dev/null
            logger -si -t MikroTik_backup "Git: The changes for $ip have been committed."
        fi
    else
        log_msg="The /export command failed or returned an empty file."
        logger -si -t MikroTik_backup "ERROR: $ip - $log_msg"
        FAILED_ROUTERS+=("$ip - $log_msg (RSC Export Failed)")
        [ -f "$BACKUP_RSC" ] && rm -f "$BACKUP_RSC"
    fi

    # ==============================================================================
    # Binary backup (.backup) with renaming
    # ==============================================================================
    DATE=$(date +%Y-%m-%d_%H%M%S)
    CURRENT_BIN_DIR="$BINARY_BKUP_DIR/$ip"
    mkdir -p "$CURRENT_BIN_DIR"

    # Download the file to a folder under its original name
    scp $SSH_OPTS "$BACKUP_USER"@"$ip":binary_backup.backup "$CURRENT_BIN_DIR/" >/dev/null 2>&1

    # Verify that the original file has been downloaded successfully and it is not empty
    if [ -s "$CURRENT_BIN_DIR/binary_backup.backup" ]; then
        # Renaming it by adding the date and time
        mv "$CURRENT_BIN_DIR/binary_backup.backup" "$CURRENT_BIN_DIR/${DATE}.backup"
        logger -si -t MikroTik_backup "The binary backup for $ip was successful. File: ${DATE}.backup"
    else
        log_msg="SCP error: Failed to download the .backup file from the device"
        logger -si -t MikroTik_backup "ERROR: $ip - $log_msg"
        FAILED_ROUTERS+=("$ip - $log_msg (Binary Backup Failed)")
    fi

done 3< "$CONF_FILE"

# ==============================================================================
# Automatic binary backup rotation on a backup server
# ==============================================================================
logger -si -t MikroTik_backup "Running the rotation of files older than $KEEP_DAYS days"

if find "$BINARY_BKUP_DIR" -type f -name '*.backup' -mtime +"$KEEP_DAYS" -print0 | xargs -0 -r rm -f >/dev/null 2>&1; then
    logger -si -t MikroTik_backup "The rotation has been successfully completed."
else
    logger -si -t MikroTik_backup "ERROR: The rotation could not be completed"
    FAILED_ROUTERS+=("Error during the rotation of outdated backup files")
fi

# ==============================================================================
# Final report (EMAIL and system log)
# ==============================================================================
if [ ${#FAILED_ROUTERS[@]} -eq 0 ]; then
    report_body="All backup operations for MikroTik equipment have been completed successfully."
    send_email_report "MikroTik backup was completed successfully" "$report_body"
    logger -si -t MikroTik_backup "Result: All backups were completed successfully. The report has been sent."
else
    report_body=$(cat <<EOF
Errors occurred during the backup process.

List of problematic devices and operations:
----------------------------------------------------------------------
$(for failed in "${FAILED_ROUTERS[@]}"; do echo " • $failed"; done)
----------------------------------------------------------------------

Detailed system logs are available on the backup server.
Command to view log files:
journalctl -u mikrotik_backup.service -n 100
EOF
)
    send_email_report "Problems with MikroTik backup" "$report_body"
    logger -si -t MikroTik_backup "Result: Errors were found on ${#FAILED_ROUTERS[@]} objects. The report has been sent."
fi
