#!/bin/bash
# test_scheduler_detect.sh - Test and verify scheduler detection logic
# Usage: ./test_scheduler_detect.sh

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m'
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' CYAN='\033[0;36m'

# Print functions
print_success() { echo -e "${GREEN}✓${R} $1"; }
print_error() { echo -e "${RED}✗${R} ${RED}$1${R}"; }
print_info() { echo -e "${CYAN}ℹ${R} $1"; }
print_header() {
    echo ""; echo -e "${B}${BLUE}================================================================"
    echo -e "$1"; echo -e "================================================================${R}"
}

# Detect scheduler (same logic as benchmark scripts)
detect_scheduler() {
    local KERNEL_VERSION=$(uname -r)

    # Method 1: Environment variable
    [ -n "${SCHEDULER_TYPE:-}" ] && {
        case "${SCHEDULER_TYPE^^}" in
            BORE|BORE_SCHEDULER) echo "BORE (from env: $SCHEDULER_TYPE)"; return ;;
            DEFAULT|EEVDF|CFS) echo "DEFAULT (from env: $SCHEDULER_TYPE)"; return ;;
        esac
    }

    # Method 2: Kernel config file
    local config_file="/boot/config-${KERNEL_VERSION}"
    [ -f "$config_file" ] && {
        grep -qiE "CONFIG_SCHED_BORE\s*=\s*y" "$config_file" 2>/dev/null && { echo "BORE (from config: $config_file)"; return; }
        grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y" "$config_file" 2>/dev/null && { echo "DEFAULT (from config: $config_file)"; return; }
    }

    # Method 3: /proc/config.gz
    [ -f "/proc/config.gz" ] && {
        zcat /proc/config.gz 2>/dev/null | grep -qiE "CONFIG_SCHED_BORE\s*=\s*y" && { echo "BORE (from /proc/config.gz)"; return; }
        zcat /proc/config.gz 2>/dev/null | grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y" && { echo "DEFAULT (from /proc/config.gz)"; return; }
    }

    # Method 4: dmesg
    local dmesg_output=$(dmesg 2>/dev/null | grep -iE "scheduler|bore|eevdf" | head -10)
    echo "$dmesg_output" | grep -qiE "bore.*scheduler|scheduler.*bore" && { echo "BORE (from dmesg)"; return; }
    echo "$dmesg_output" | grep -qiE "eevdf|earliest.*virtual.*deadline" && { echo "DEFAULT (from dmesg)"; return; }

    # Method 5: Kernel version string
    [[ $KERNEL_VERSION == *"cachyos"* ]] || [[ $KERNEL_VERSION == *"bore"* ]] && { echo "BORE (from kernel version: $KERNEL_VERSION)"; return; }

    # Method 6: sysfs
    [ -f "/sys/kernel/debug/sched_features" ] && {
        grep -qi "BORE" /sys/kernel/debug/sched_features 2>/dev/null && { echo "BORE (from /sys/kernel/debug/sched_features)"; return; }
    }

    echo "DEFAULT (fallback - no detection method matched)"
}

main() {
    print_header "SCHEDULER DETECTION TEST"

    local KERNEL_VERSION=$(uname -r)
    echo -e "${B}Kernel Version:${R} $KERNEL_VERSION"
    echo -e "${B}Hostname:${R} $(hostname)"
    echo ""

    print_header "DETECTION METHODS"

    # Method 1: Environment variable
    print_info "Method 1: Environment Variable"
    [ -n "${SCHEDULER_TYPE:-}" ] && echo -e "  SCHEDULER_TYPE=${GREEN}$SCHEDULER_TYPE${R}" || echo -e "  SCHEDULER_TYPE=${YELLOW}(not set)${R}"
    echo ""

    # Method 2: Kernel config file
    print_info "Method 2: Kernel Config File"
    local config_file="/boot/config-${KERNEL_VERSION}"
    [ -f "$config_file" ] && {
        echo -e "  Config file: ${GREEN}$config_file${R} (exists)"
        echo "  Checking for scheduler configs:"
        grep -iE "CONFIG_SCHED_(BORE|EEVDF|CFS)" "$config_file" 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (no scheduler configs found)"
    } || echo -e "  Config file: ${YELLOW}$config_file${R} (not found)"
    echo ""

    # Method 3: /proc/config.gz
    print_info "Method 3: /proc/config.gz"
    [ -f "/proc/config.gz" ] && {
        echo -e "  /proc/config.gz: ${GREEN}exists${R}"
        local config_results=$(zcat /proc/config.gz 2>/dev/null | grep -iE "CONFIG_SCHED_(BORE|EEVDF|CFS)" | head -5)
        [ -n "$config_results" ] && {
            echo "  Found scheduler configs:"
            echo "$config_results" | sed 's/^/    /'
        } || echo -e "  ${YELLOW}(no scheduler configs found)${R}"
    } || echo -e "  /proc/config.gz: ${YELLOW}not available${R}"
    echo ""

    # Method 4: dmesg
    print_info "Method 4: dmesg (boot messages)"
    local dmesg_sched=$(dmesg 2>/dev/null | grep -iE "scheduler|bore|eevdf" | head -5)
    [ -n "$dmesg_sched" ] && {
        echo "  Found scheduler-related messages:"
        echo "$dmesg_sched" | sed 's/^/    /'
    } || echo -e "  ${YELLOW}No scheduler-related messages found${R}"
    echo ""

    # Method 5: Kernel version
    print_info "Method 5: Kernel Version String"
    echo "  Kernel version: $KERNEL_VERSION"
    [[ $KERNEL_VERSION == *"cachyos"* ]] || [[ $KERNEL_VERSION == *"bore"* ]] && \
        echo -e "  ${GREEN}Contains 'cachyos' or 'bore' → BORE${R}" || \
        echo -e "  ${YELLOW}No BORE indicators in version string${R}"
    echo ""

    # Method 6: sysfs
    print_info "Method 6: sysfs (/sys/kernel/debug/sched_features)"
    [ -f "/sys/kernel/debug/sched_features" ] && {
        echo -e "  File exists: ${GREEN}yes${R}"
        grep -qi "BORE" /sys/kernel/debug/sched_features 2>/dev/null && \
            echo -e "  ${GREEN}Contains 'BORE'${R}" || \
            echo -e "  ${YELLOW}No 'BORE' found${R}"
    } || echo -e "  File: ${YELLOW}not available${R}"
    echo ""

    print_header "DETECTION RESULT"
    local detected=$(detect_scheduler)
    echo -e "${B}Detected Scheduler:${R} ${GREEN}$detected${R}"
    echo ""

    print_header "RECOMMENDATIONS"
    if echo "$detected" | grep -qi "BORE"; then
        print_success "BORE scheduler detected correctly!"
        local method=$(echo "$detected" | sed -n 's/.*(from \(.*\))/\1/p')
        [ -n "$method" ] && echo "  Detection method: $method"
        echo "  Your test scripts will create files with '_BORE_' suffix"
    elif echo "$detected" | grep -qi "DEFAULT"; then
        [ -z "${SCHEDULER_TYPE:-}" ] && {
            print_info "DEFAULT scheduler detected (or fallback)"
            echo "  If you're running BORE kernel but it's not detected:"
            echo -e "  ${CYAN}export SCHEDULER_TYPE=\"BORE\"${R}"
        } || print_success "DEFAULT scheduler (from environment)"
    fi

    echo ""
    print_info "To manually override detection:"
    echo -e "  ${CYAN}export SCHEDULER_TYPE=\"BORE\"${R}  # or \"DEFAULT\""
    echo -e "  ${CYAN}./throughput.sh${R} or ${CYAN}./responsiveness.sh${R}"
}

main
