#!/bin/bash

# Constants
readonly PING_COUNT=3
readonly PING_TIMEOUT=2
readonly CHECK_INTERVAL=1
readonly CHECK_INTERVAL_ON_ERROR=15
declare -ir FAILURE_THRESHOLD=3
declare -ar PUBLIC_IPS=("1.1.1.1" "8.8.8.8" "208.67.222.222")
readonly WAN1_INTERFACE="eth0"
readonly WAN2_INTERFACE="eth1"
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
readonly SCRIPT_LOG_LEVEL="INFO"

# Global variables
USING_WAN2_ROUTE=false
declare -i WAN1_CONSECUTIVE_FAILURES=0
declare -i WAN2_CONSECUTIVE_FAILURES=0
readonly WAN1_TEMP_FILE="/tmp/wan1_status"
readonly WAN2_TEMP_FILE="/tmp/wan2_status"
readonly ROUTE_METRIC=5

# Function to log messages
log_message() {
    local log_message="$1"
    local log_priority="$2"
    
    #check if log level exists. If not, write an ERROR and exit 1.
    if [[ -z ${LOG_LEVELS[$log_priority]} ]]; then
        echo "Error: log_message was called with an invalid log level"
        exit 1
    fi

    #Only log, if log level is high enough
    if (( ${LOG_LEVELS[$SCRIPT_LOG_LEVEL]} <= ${LOG_LEVELS[$log_priority]} )); then
        echo "$log_message"
    fi
}

# Function to clean up when script exits
cleanup() {
    # Kill all processes in the same process group
    # Requires the package procps-ng-pkill
    pkill -P $$
    exit 0
}

# Function to check connectivity via a specific interface
write_unreachable_count_to_file() {
    local interface="$1"
    local temp_file="$2"
    local -i unreachable_count=0

    for ip in "${PUBLIC_IPS[@]}"; do
        if ! ping -I "$interface" -c $PING_COUNT -W $PING_TIMEOUT "$ip" >/dev/null 2>&1; then
            log_message "Cannot reach $ip via $interface" "INFO"
            ((unreachable_count++))
        else
            log_message "$ip is reachable via $interface" "DEBUG"
        fi
    done

    echo $unreachable_count >"$temp_file"
}

# Function to switch to WAN2
switch_to_wan2() {
    local wan2_gateway="$1"
    if ! $USING_WAN2_ROUTE; then
        log_message "Switching to WAN2 ($WAN2_INTERFACE)" "INFO"
        if ip route add default via "$wan2_gateway" dev $WAN2_INTERFACE metric $ROUTE_METRIC; then
            USING_WAN2_ROUTE=true
            log_message "Successfully switched to WAN2" "INFO"
        else
            log_message "Failed to add WAN2 route" "WARN"
        fi
    fi
}

# Function to switch back to WAN1
switch_to_wan1() {
    if $USING_WAN2_ROUTE; then
        log_message "Switching back to WAN1 ($WAN1_INTERFACE)" "INFO"

        if ip route del default dev $WAN2_INTERFACE metric $ROUTE_METRIC; then
            USING_WAN2_ROUTE=false
            log_message "Successfully switched back to WAN1" "INFO"
        else
            log_message "Failed to remove WAN2 route" "WARN"
        fi

        # Restart Tailscale to ensure it uses the correct interface
        if /etc/init.d/tailscale restart >/dev/null 2>&1; then
            log_message "Successfully restarted Tailscale service to switch back to WAN1" "INFO"
        else
            log_message "Error: Failed to restart Tailscale service" "ERROR"
        fi
        
    fi
}

# Main function to run the failover logic
run_failover_loop() {
    log_message "Starting WAN failover script" "DEBUG"

    local wan2_gateway wan1_unreachable_count wan2_unreachable_count wan1_pid wan2_pid

    # The following systems add/remove routes on OpenWRT in general:
    # 1. If the the public IP is set to DHCP, when getting/losing the IP address, the route is added/removed. (metric 10 for wan 1, metric 20 for wan b)
    # 2. If the public IP is static, the route is added/removed when the interface goes up/down. (metric 10 for wan 1, metric 20 for wan b)
    # 3. If it is a HA setup, routes are added/removed by keepalived (metric 10 for wan 1, metric 20 for wan b)
    # 4. If it is a HA setup, the become-backup.sh and become-master.sh scripts add/remove a route via wan c (no metric, it is the only remaining route when this script is run)
    # 5. This script
    while true; do
        # If both eth0 and eth1 do not have an IP assigned, we can remove the temp files and return
        if ! ip addr show dev $WAN1_INTERFACE | grep -q "inet "; then
            if ! ip addr show dev $WAN2_INTERFACE | grep -q "inet "; then
                log_message "No IP assigned to either $WAN1_INTERFACE or $WAN2_INTERFACE, removing temp files and exiting. Either the router is down or it is the backup OpenWRT router." "DEBUG"
                # Removing the temp files to stop the telegraf monitoring for wan failover
                rm -f "$WAN1_TEMP_FILE" "$WAN2_TEMP_FILE"
                sleep $CHECK_INTERVAL_ON_ERROR
                continue
            fi
        fi

        if ip route show dev $WAN2_INTERFACE | grep -q "metric $ROUTE_METRIC\s"; then
            USING_WAN2_ROUTE=true
            log_message "Currently using WAN2 route" "INFO"
        else
            log_message "Currently using default routes not set by this script" "DEBUG"
        fi

        wan2_gateway=$(ip route show dev eth1 | grep default | head -1 | awk '/default/ {print $3}')
        # Validate that wan2_gateway is a valid IP address
        if ! [[ "$wan2_gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            log_message "Invalid or missing gateway IP for $WAN2_INTERFACE: $wan2_gateway." "INFO"
            switch_to_wan1
            sleep $CHECK_INTERVAL_ON_ERROR
            continue
        fi

        # Check both WAN interfaces in parallel
        write_unreachable_count_to_file "$WAN1_INTERFACE" "$WAN1_TEMP_FILE" &
        wan1_pid="$!"
        write_unreachable_count_to_file "$WAN2_INTERFACE" "$WAN2_TEMP_FILE" &
        wan2_pid="$!"

        # Wait for parallel checks to complete
        wait $wan1_pid
        wait $wan2_pid

        wan1_unreachable_count=$(cat "$WAN1_TEMP_FILE")
        wan2_unreachable_count=$(cat "$WAN2_TEMP_FILE")

        if ! [[ "$wan1_unreachable_count" =~ ^[0-9]+$ ]]; then
            log_message "Error: Invalid value for WAN1 unreachable count" "ERROR"
            exit 1
        fi

        if ! [[ "$wan2_unreachable_count" =~ ^[0-9]+$ ]]; then
            log_message "Error: Invalid value for WAN2 unreachable count" "ERROR"
            exit 1
        fi

        # Update failure counters for each interface
        # If one public IP is not reachable, we don't want to react on it yet
        if [ "$wan1_unreachable_count" -gt 1 ]; then
            if ((WAN1_CONSECUTIVE_FAILURES < FAILURE_THRESHOLD)); then
                ((WAN1_CONSECUTIVE_FAILURES++))
            fi
            log_message "WAN1 connectivity check failed (${WAN1_CONSECUTIVE_FAILURES}/${FAILURE_THRESHOLD} failures)" "WARN"
        else
            if [ $WAN1_CONSECUTIVE_FAILURES -gt 0 ]; then
                log_message "WAN1 connectivity restored, resetting failure counter" "INFO"
                WAN1_CONSECUTIVE_FAILURES=0
            fi
        fi
        # If one public IP is not reachable, we don't want to react on it yet
        if [ "$wan2_unreachable_count" -gt 1 ]; then
            if ((WAN2_CONSECUTIVE_FAILURES < FAILURE_THRESHOLD)); then
                ((WAN2_CONSECUTIVE_FAILURES++))
            fi
            log_message "WAN2 connectivity check failed (${WAN2_CONSECUTIVE_FAILURES}/${FAILURE_THRESHOLD} failures)" "WARN"
        else
            if [ $WAN2_CONSECUTIVE_FAILURES -gt 0 ]; then
                log_message "WAN2 connectivity restored, resetting failure counter" "INFO"
                WAN2_CONSECUTIVE_FAILURES=0
            fi
        fi

        # Failover logic based on current state and interface failure counts
        if ! $USING_WAN2_ROUTE; then
            # Currently using WAN1
            if (( WAN1_CONSECUTIVE_FAILURES >= FAILURE_THRESHOLD )); then
                # WAN1 has failed, check if WAN2 is healthy
                if (( WAN2_CONSECUTIVE_FAILURES < FAILURE_THRESHOLD )); then
                    log_message "WAN1 failure threshold reached, WAN2 appears healthy" "INFO"
                    switch_to_wan2 "$wan2_gateway"
                else
                    log_message "WAN1 failure threshold reached, but WAN2 also appears down" "WARN"
                fi
            fi
        else
            # Currently using WAN2
            if (( WAN1_CONSECUTIVE_FAILURES == 0 )); then
                # WAN1 is now healthy, switch back
                log_message "WAN1 appears healthy, switching back from WAN2" "INFO"
                switch_to_wan1
            else
                log_message "WAN1 still down, keeping WAN2 active" "INFO"
            fi
        fi

        sleep $CHECK_INTERVAL
    done
}

trap cleanup SIGINT SIGTERM

run_failover_loop
