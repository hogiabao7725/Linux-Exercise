#!/bin/bash
################################################################################
# test_scheduler_detect.sh
#
# Purpose: Test and verify scheduler detection logic
#
# Usage: ./test_scheduler_detect.sh
################################################################################

set -e

################################################################################
# COLOR CODES
################################################################################

readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BLUE='\033[0;34m'

################################################################################
# UTILITY FUNCTIONS
################################################################################

print_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_RED}✗${COLOR_RESET} ${COLOR_RED}$1${COLOR_RESET}"
}

print_info() {
    echo -e "${COLOR_CYAN}ℹ${COLOR_RESET} $1"
}

print_header() {
    local title=$1
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_BLUE}================================================================"
    echo -e "$title"
    echo -e "================================================================${COLOR_RESET}"
}

# Same detect_scheduler function as in test scripts
detect_scheduler() {
    local KERNEL_VERSION=$(uname -r)
    local detected_type=""
    
    # Method 1: Check environment variable
    if [ -n "$SCHEDULER_TYPE" ]; then
        case "${SCHEDULER_TYPE^^}" in
            BORE|BORE_SCHEDULER)
                echo "BORE (from env: $SCHEDULER_TYPE)"
                return 0
                ;;
            DEFAULT|EEVDF|CFS)
                echo "DEFAULT (from env: $SCHEDULER_TYPE)"
                return 0
                ;;
        esac
    fi
    
    # Method 2: Check kernel config file
    local config_file="/boot/config-${KERNEL_VERSION}"
    if [ -f "$config_file" ]; then
        if grep -qiE "CONFIG_SCHED_BORE\s*=\s*y" "$config_file" 2>/dev/null; then
            detected_type="BORE"
            echo "BORE (from config: $config_file)"
            return 0
        elif grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y" "$config_file" 2>/dev/null; then
            detected_type="DEFAULT"
            echo "DEFAULT (from config: $config_file)"
            return 0
        fi
    fi
    
    # Method 3: Check /proc/config.gz
    if [ -f "/proc/config.gz" ]; then
        if zcat /proc/config.gz 2>/dev/null | grep -qiE "CONFIG_SCHED_BORE\s*=\s*y"; then
            detected_type="BORE"
            echo "BORE (from /proc/config.gz)"
            return 0
        elif zcat /proc/config.gz 2>/dev/null | grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y"; then
            detected_type="DEFAULT"
            echo "DEFAULT (from /proc/config.gz)"
            return 0
        fi
    fi
    
    # Method 4: Check dmesg
    local dmesg_output=$(dmesg 2>/dev/null | grep -iE "scheduler|bore|eevdf" | head -10)
    if echo "$dmesg_output" | grep -qiE "bore.*scheduler|scheduler.*bore"; then
        detected_type="BORE"
        echo "BORE (from dmesg)"
        return 0
    elif echo "$dmesg_output" | grep -qiE "eevdf|earliest.*virtual.*deadline"; then
        detected_type="DEFAULT"
        echo "DEFAULT (from dmesg)"
        return 0
    fi
    
    # Method 5: Check kernel version string
    if [[ $KERNEL_VERSION == *"cachyos"* ]] || [[ $KERNEL_VERSION == *"bore"* ]]; then
        detected_type="BORE"
        echo "BORE (from kernel version: $KERNEL_VERSION)"
        return 0
    fi
    
    # Method 6: Check sysfs
    if [ -d "/sys/kernel/debug" ] && [ -f "/sys/kernel/debug/sched_features" ]; then
        if grep -qi "BORE" /sys/kernel/debug/sched_features 2>/dev/null; then
            detected_type="BORE"
            echo "BORE (from /sys/kernel/debug/sched_features)"
            return 0
        fi
    fi
    
    # Default
    echo "DEFAULT (fallback - no detection method matched)"
}

################################################################################
# MAIN PROGRAM
################################################################################

main() {
    print_header "SCHEDULER DETECTION TEST"
    
    local KERNEL_VERSION=$(uname -r)
    
    echo -e "${COLOR_BOLD}Kernel Version:${COLOR_RESET} $KERNEL_VERSION"
    echo -e "${COLOR_BOLD}Hostname:${COLOR_RESET} $(hostname)"
    echo ""
    
    print_header "DETECTION METHODS"
    
    # Method 1: Environment variable
    print_info "Method 1: Environment Variable"
    if [ -n "$SCHEDULER_TYPE" ]; then
        echo -e "  SCHEDULER_TYPE=${COLOR_GREEN}$SCHEDULER_TYPE${COLOR_RESET}"
    else
        echo -e "  SCHEDULER_TYPE=${COLOR_YELLOW}(not set)${COLOR_RESET}"
    fi
    echo ""
    
    # Method 2: Kernel config file
    print_info "Method 2: Kernel Config File"
    local config_file="/boot/config-${KERNEL_VERSION}"
    if [ -f "$config_file" ]; then
        echo -e "  Config file: ${COLOR_GREEN}$config_file${COLOR_RESET} (exists)"
        echo "  Checking for scheduler configs:"
        grep -iE "CONFIG_SCHED_(BORE|EEVDF|CFS)" "$config_file" 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (no scheduler configs found)"
    else
        echo -e "  Config file: ${COLOR_YELLOW}$config_file${COLOR_RESET} (not found)"
    fi
    echo ""
    
    # Method 3: /proc/config.gz
    print_info "Method 3: /proc/config.gz"
    if [ -f "/proc/config.gz" ]; then
        echo -e "  /proc/config.gz: ${COLOR_GREEN}exists${COLOR_RESET}"
        local config_results=$(zcat /proc/config.gz 2>/dev/null | grep -iE "CONFIG_SCHED_(BORE|EEVDF|CFS)" | head -5)
        if [ -n "$config_results" ]; then
            echo "  Found scheduler configs:"
            echo "$config_results" | sed 's/^/    /'
        else
            echo -e "  ${COLOR_YELLOW}(no scheduler configs found - BORE may not have CONFIG flag)${COLOR_RESET}"
        fi
    else
        echo -e "  /proc/config.gz: ${COLOR_YELLOW}not available${COLOR_RESET}"
    fi
    echo ""
    
    # Method 4: dmesg
    print_info "Method 4: dmesg (boot messages)"
    local dmesg_sched=$(dmesg 2>/dev/null | grep -iE "scheduler|bore|eevdf" | head -5)
    if [ -n "$dmesg_sched" ]; then
        echo "  Found scheduler-related messages:"
        echo "$dmesg_sched" | sed 's/^/    /'
    else
        echo -e "  ${COLOR_YELLOW}No scheduler-related messages found${COLOR_RESET}"
    fi
    echo ""
    
    # Method 5: Kernel version
    print_info "Method 5: Kernel Version String"
    echo "  Kernel version: $KERNEL_VERSION"
    if [[ $KERNEL_VERSION == *"cachyos"* ]] || [[ $KERNEL_VERSION == *"bore"* ]]; then
        echo -e "  ${COLOR_GREEN}Contains 'cachyos' or 'bore' → BORE${COLOR_RESET}"
    else
        echo -e "  ${COLOR_YELLOW}No BORE indicators in version string${COLOR_RESET}"
    fi
    echo ""
    
    # Method 6: sysfs
    print_info "Method 6: sysfs (/sys/kernel/debug/sched_features)"
    if [ -f "/sys/kernel/debug/sched_features" ]; then
        echo -e "  File exists: ${COLOR_GREEN}yes${COLOR_RESET}"
        if grep -qi "BORE" /sys/kernel/debug/sched_features 2>/dev/null; then
            echo -e "  ${COLOR_GREEN}Contains 'BORE'${COLOR_RESET}"
        else
            echo -e "  ${COLOR_YELLOW}No 'BORE' found${COLOR_RESET}"
        fi
    else
        echo -e "  File: ${COLOR_YELLOW}not available${COLOR_RESET}"
    fi
    echo ""
    
    print_header "DETECTION RESULT"
    
    local detected=$(detect_scheduler)
    echo -e "${COLOR_BOLD}Detected Scheduler:${COLOR_RESET} ${COLOR_GREEN}$detected${COLOR_RESET}"
    echo ""
    
    print_header "RECOMMENDATIONS"
    
    if echo "$detected" | grep -qi "BORE"; then
        print_success "BORE scheduler detected correctly!"
        local method=$(echo "$detected" | sed -n 's/.*(from \(.*\))/\1/p')
        if [ -n "$method" ]; then
            echo "  Detection method: $method"
        fi
        echo "  Your test scripts will create files with '_BORE_' suffix"
        echo ""
        if echo "$detected" | grep -qi "kernel version"; then
            print_info "Note: BORE detected via kernel version string"
            echo "  This is reliable for CachyOS kernels. BORE may not have"
            echo "  CONFIG_SCHED_BORE flag if it's a patch applied to CFS scheduler."
        fi
    elif echo "$detected" | grep -qi "DEFAULT"; then
        if [ -z "$SCHEDULER_TYPE" ]; then
            print_info "DEFAULT scheduler detected (or fallback)"
            echo "  If you're running BORE kernel but it's not detected:"
            echo -e "  ${COLOR_CYAN}export SCHEDULER_TYPE=\"BORE\"${COLOR_RESET}"
            echo -e "  Then run: ${COLOR_CYAN}./test_1.sh${COLOR_RESET}"
        else
            print_success "DEFAULT scheduler (from environment)"
        fi
    fi
    
    echo ""
    print_info "To manually override detection:"
    echo -e "  ${COLOR_CYAN}export SCHEDULER_TYPE=\"BORE\"${COLOR_RESET}  # or \"DEFAULT\""
    echo -e "  ${COLOR_CYAN}./test_1.sh${COLOR_RESET}"
}

################################################################################
# ENTRY POINT
################################################################################

main
exit 0

