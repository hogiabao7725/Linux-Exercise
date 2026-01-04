#!/bin/bash
# test_scheduler_detect.sh - Test and verify scheduler detection logic
# Usage: ./test_scheduler_detect.sh

set -euo pipefail

# ============================================================================
# Colors
# ============================================================================
readonly R='\033[0m' B='\033[1m'
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' CYAN='\033[0;36m'

# ============================================================================
# Print Functions
# ============================================================================
print_success() { echo -e "${GREEN}✓${R} $1"; }
print_error() { echo -e "${RED}✗${R} ${RED}$1${R}"; }
print_info() { echo -e "${CYAN}ℹ${R} $1"; }
print_header() {
    echo ""
    echo -e "${B}${BLUE}================================================================"
    echo -e "$1"
    echo -e "================================================================${R}"
}

# ============================================================================
# Scheduler Detection
# ============================================================================

# Detect scheduler using kernel config file
detect_from_config() {
    local config_file="$1"
    [ ! -f "$config_file" ] && return 1
    
    if grep -qiE "CONFIG_SCHED_BORE\s*=\s*y" "$config_file" 2>/dev/null; then
        echo "BORE (from config: $config_file)"
        return 0
    fi
    
    if grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y" "$config_file" 2>/dev/null; then
        echo "DEFAULT (from config: $config_file)"
        return 0
    fi
    
    return 1
}

# Detect scheduler using kernel version string
detect_from_version() {
    local kernel_version="$1"
    if [[ "$kernel_version" == *"cachyos"* ]] || [[ "$kernel_version" == *"bore"* ]]; then
        echo "BORE (from kernel version: $kernel_version)"
        return 0
    fi
    return 1
}

# Main detection function
detect_scheduler() {
    local kernel_version=$(uname -r)
    local config_file="/boot/config-${kernel_version}"
    
    # Method 1: Kernel config file
    detect_from_config "$config_file" && return 0
    
    # Method 2: Kernel version string
    detect_from_version "$kernel_version" && return 0
    
    # Fallback
    echo "DEFAULT (fallback - no detection method matched)"
}

# ============================================================================
# Display Functions
# ============================================================================

# Show Method 1 details
show_method1() {
    local kernel_version="$1"
    local config_file="/boot/config-${kernel_version}"
    
    print_info "Method 1: Kernel Config File"
    
    if [ -f "$config_file" ]; then
        echo -e "  Config file: ${GREEN}$config_file${R} (exists)"
        echo "  Checking for scheduler configs:"
        local configs=$(grep -iE "CONFIG_SCHED_(BORE|EEVDF|CFS)" "$config_file" 2>/dev/null | head -5)
        if [ -n "$configs" ]; then
            echo "$configs" | sed 's/^/    /'
        else
            echo "    (no scheduler configs found)"
        fi
    else
        echo -e "  Config file: ${YELLOW}$config_file${R} (not found)"
    fi
    echo ""
}

# Show Method 2 details
show_method2() {
    local kernel_version="$1"
    
    print_info "Method 2: Kernel Version String"
    echo "  Kernel version: $kernel_version"
    
    if [[ "$kernel_version" == *"cachyos"* ]] || [[ "$kernel_version" == *"bore"* ]]; then
        echo -e "  ${GREEN}Contains 'cachyos' or 'bore' → BORE${R}"
    else
        echo -e "  ${YELLOW}No BORE indicators in version string${R}"
    fi
    echo ""
}

# Show recommendations
show_recommendations() {
    local detected="$1"
    
    if echo "$detected" | grep -qi "BORE"; then
        print_success "BORE scheduler detected correctly!"
        local method=$(echo "$detected" | sed -n 's/.*(from \(.*\))/\1/p')
        [ -n "$method" ] && echo "  Detection method: $method"
        echo "  Your test scripts will create files with '_BORE_' suffix"
    elif echo "$detected" | grep -qi "DEFAULT"; then
        if [ -z "${SCHEDULER_TYPE:-}" ]; then
            print_info "DEFAULT scheduler detected (or fallback)"
            echo "  If you're running BORE kernel but it's not detected:"
            echo -e "  ${CYAN}export SCHEDULER_TYPE=\"BORE\"${R}"
        else
            print_success "DEFAULT scheduler (from environment)"
        fi
    fi
    
    echo ""
    print_info "To manually override detection:"
    echo -e "  ${CYAN}export SCHEDULER_TYPE=\"BORE\"${R}  # or \"DEFAULT\""
    echo -e "  ${CYAN}./throughput.sh${R} or ${CYAN}./responsiveness.sh${R}"
}

# ============================================================================
# Main Function
# ============================================================================
main() {
    local kernel_version=$(uname -r)
    
    print_header "SCHEDULER DETECTION TEST"
    echo -e "${B}Kernel Version:${R} $kernel_version"
    echo -e "${B}Hostname:${R} $(hostname)"
    echo ""
    
    print_header "DETECTION METHODS"
    show_method1 "$kernel_version"
    show_method2 "$kernel_version"
    
    print_header "DETECTION RESULT"
    local detected=$(detect_scheduler)
    echo -e "${B}Detected Scheduler:${R} ${GREEN}$detected${R}"
    echo ""
    
    print_header "RECOMMENDATIONS"
    show_recommendations "$detected"
}

main
