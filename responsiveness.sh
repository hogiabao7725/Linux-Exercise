#!/bin/bash
################################################################################
# test_responsiveness.sh
#
# Purpose: Measure scheduler responsiveness (latency/interactivity)
#          BORE scheduler is designed to optimize interactive workloads
#
# Requirements: stress-ng, hackbench, cyclictest, bc
# Installation: sudo apt install stress-ng hackbench rt-tests bc
#
# Author: Benchmark script for comparing BORE vs Ubuntu Default kernel
################################################################################

set -e
set -o pipefail

################################################################################
# COLOR CODES
################################################################################

readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_DIM='\033[2m'

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[0;37m'

readonly COLOR_BG_BLUE='\033[44m'
readonly COLOR_BG_GREEN='\033[42m'

################################################################################
# CONFIGURATION
################################################################################

readonly KERNEL_VERSION=$(uname -r)
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly NUM_CPUS=$(nproc)
readonly STRESS_TIMEOUT=30
readonly CYCLICTEST_ITERATIONS=10000
readonly STRESS_RAMPUP_DELAY=3
readonly CLEANUP_DELAY=2

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Detect scheduler type - Simple approach: prefer environment variable
# Usage: Set SCHEDULER_TYPE="BORE" or "DEFAULT" before running tests
#        If not set, will auto-detect from kernel version (fallback)
detect_scheduler() {
    # Method 1: Environment variable
    if [ -n "$SCHEDULER_TYPE" ]; then
        case "${SCHEDULER_TYPE^^}" in
            BORE|BORE_SCHEDULER)
                echo "BORE"
                return 0
                ;;
            DEFAULT|EEVDF|CFS)
                echo "DEFAULT"
                return 0
                ;;
        esac
    fi

    # Method 2: Auto-detect from kernel version (fallback only)
    # Simple detection: check if kernel version contains known BORE indicators
    if [[ $KERNEL_VERSION == *"cachyos"* ]] || [[ $KERNEL_VERSION == *"bore"* ]]; then
        echo "BORE"
        return 0
    fi

    # Default: assume DEFAULT (EEVDF/CFS scheduler)
    echo "DEFAULT"
}

# Detect scheduler type
readonly KERNEL_TYPE=$(detect_scheduler)

readonly RESULT_FILE="responsiveness_${KERNEL_TYPE}_${TIMESTAMP}.txt"
readonly LOG_FILE="responsiveness_${KERNEL_TYPE}_${TIMESTAMP}.log"

# Color output functions
print_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${COLOR_RED}✗${COLOR_RESET} ${COLOR_RED}$1${COLOR_RESET}" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} ${COLOR_YELLOW}$1${COLOR_RESET}" | tee -a "$LOG_FILE"
}

print_info() {
    echo -e "${COLOR_CYAN}ℹ${COLOR_RESET} $1" | tee -a "$LOG_FILE"
}

print_header() {
    local title=$1
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}${COLOR_BG_BLUE}${COLOR_WHITE}================================================================" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}${COLOR_BG_BLUE}${COLOR_WHITE}$title${COLOR_RESET}" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}${COLOR_BG_BLUE}${COLOR_WHITE}================================================================" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_RESET}" | tee -a "$RESULT_FILE"
}

print_test() {
    local test_num=$1
    local test_name=$2
    local scenario=$3

    echo "" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}TEST $test_num:${COLOR_RESET} ${COLOR_BOLD}$test_name${COLOR_RESET}" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_DIM}Scenario: $scenario${COLOR_RESET}" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_DIM}----------------------------------------${COLOR_RESET}" | tee -a "$RESULT_FILE"
}

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" >> "$LOG_FILE"
    echo -e "${COLOR_DIM}$message${COLOR_RESET}"
}

check_tool() {
    local tool=$1
    local package=$2

    if ! command -v "$tool" &> /dev/null; then
        print_error "$tool not found"
        print_info "Please install: sudo apt install $package"
        exit 1
    fi
    print_success "Found: $tool"
}

run_hackbench() {
    local args="$1"
    local description="$2"

    print_info "Running hackbench: $description"
    echo "Running hackbench: $description..." | tee -a "$RESULT_FILE"

    local start_time=$(date +%s.%N)
    local output=$(hackbench $args 2>&1)
    local exit_code=$?
    local end_time=$(date +%s.%N)

    if [ $exit_code -eq 0 ]; then
        if echo "$output" | grep -q "Time:"; then
            echo "$output" | grep "Time:" | tee -a "$RESULT_FILE"
        else
            echo -e "${COLOR_YELLOW}Time: (output format may differ)${COLOR_RESET}" | tee -a "$RESULT_FILE"
            echo "$output" | tee -a "$RESULT_FILE"
        fi
    else
        print_error "hackbench failed with exit code $exit_code"
        echo "$output" | tee -a "$RESULT_FILE"
    fi

    local elapsed=$(echo "$end_time - $start_time" | bc)
    echo -e "${COLOR_GREEN}Elapsed time: ${elapsed}s${COLOR_RESET}" | tee -a "$RESULT_FILE"

    return $exit_code
}

cleanup_background_jobs() {
    print_info "Cleaning up background jobs..."
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    sleep 1
}

################################################################################
# TEST FUNCTIONS
################################################################################

test_1_response_under_load() {
    print_test "1" \
        "Scheduling Responsiveness Under CPU Stress" \
        "Heavy background task (95% CPU) + interactive task switching"

    log "Starting Test 1: Response under load"

    print_info "Launching stress-ng with 95% CPU load on $NUM_CPUS cores"
    stress-ng --cpu "$NUM_CPUS" --cpu-load 95 --timeout "${STRESS_TIMEOUT}s" \
        > /dev/null 2>&1 &
    local stress_pid=$!

    sleep "$STRESS_RAMPUP_DELAY"
    print_success "CPU stress active, running hackbench test"

    run_hackbench "-s 256 -l 100 -g 5" \
        "5 groups, 100 loops, 256B messages"

    kill "$stress_pid" 2>/dev/null || true
    wait "$stress_pid" 2>/dev/null || true
    sleep "$CLEANUP_DELAY"

    log "Test 1 completed"
}

test_2_context_switch_latency() {
    print_test "2" \
        "Context Switch Latency" \
        "Rapid task switching via inter-process communication"

    log "Starting Test 2: Context switch latency"

    run_hackbench "-p -s 512 -l 200 -g 10" \
        "pipe mode, 10 groups, 200 loops, 512B messages"

    log "Test 2 completed"
}

test_3_wakeup_latency() {
    print_test "3" \
        "Wake-up Latency for Sleeping Tasks" \
        "Application waking from idle state (e.g., click event)"

    log "Starting Test 3: Wake-up latency"

    print_info "Running cyclictest ($CYCLICTEST_ITERATIONS iterations, priority 80)"
    echo "Running cyclictest ($CYCLICTEST_ITERATIONS iterations, priority 80)..." | tee -a "$RESULT_FILE"

    local cyclictest_cmd="cyclictest -t1 -p80 -l$CYCLICTEST_ITERATIONS -q"

    if command -v sudo &> /dev/null; then
        if sudo $cyclictest_cmd 2>&1 | tee -a "$RESULT_FILE"; then
            print_success "Test 3 completed successfully"
        else
            print_warning "cyclictest may have issues, check output"
        fi
    else
        print_warning "sudo not found, trying cyclictest without sudo"
        if $cyclictest_cmd 2>&1 | tee -a "$RESULT_FILE"; then
            print_success "Test 3 completed successfully"
        else
            print_warning "cyclictest may have issues, check output"
        fi
    fi

    log "Test 3 completed"
}

test_4_interactive_under_mixed_load() {
    print_test "4" \
        "Interactive Task Latency Under Mixed Workload" \
        "Simulating desktop/gaming: Background CPU + I/O + user interaction"

    log "Starting Test 4: Interactive under mixed load"

    local cpu_stress_count=$((NUM_CPUS / 2))
    [ "$cpu_stress_count" -lt 1 ] && cpu_stress_count=1

    print_info "Launching mixed workload: $cpu_stress_count CPU cores + 2 I/O workers"

    stress-ng --cpu "$cpu_stress_count" --cpu-load 100 --timeout "${STRESS_TIMEOUT}s" \
        > /dev/null 2>&1 &
    local cpu_pid=$!

    stress-ng --io 2 --timeout "${STRESS_TIMEOUT}s" \
        > /dev/null 2>&1 &
    local io_pid=$!

    sleep 2
    print_success "Mixed load active, testing interactive response"

    run_hackbench "-s 128 -l 50 -g 3" \
        "3 groups, 50 loops, 128B messages (simulating UI events)"

    kill "$cpu_pid" "$io_pid" 2>/dev/null || true
    wait 2>/dev/null || true

    log "Test 4 completed"
}

################################################################################
# MAIN PROGRAM
################################################################################

main() {
    print_header "RESPONSIVENESS BENCHMARK - ${KERNEL_TYPE} SCHEDULER"

    echo -e "${COLOR_BOLD}Kernel Version:${COLOR_RESET} $KERNEL_VERSION" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}Scheduler Type:${COLOR_RESET} $KERNEL_TYPE" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}CPU Cores:${COLOR_RESET} $NUM_CPUS" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}Test Date:${COLOR_RESET} $(date)" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}Hostname:${COLOR_RESET} $(hostname)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    log "Starting responsiveness benchmark on $KERNEL_TYPE scheduler"
    log "Detected scheduler: $KERNEL_TYPE (kernel: $KERNEL_VERSION)"

    if [ -z "$SCHEDULER_TYPE" ]; then
        print_info "Tip: Set SCHEDULER_TYPE=\"BORE\" or \"DEFAULT\" to explicitly specify scheduler"
    fi

    print_info "Checking required tools..."
    echo "Checking required tools..." | tee -a "$RESULT_FILE"
    check_tool stress-ng "stress-ng"
    check_tool hackbench "hackbench"
    check_tool cyclictest "rt-tests"
    check_tool bc "bc"

    echo "" | tee -a "$RESULT_FILE"
    print_success "All tools available, starting tests..."
    echo "" | tee -a "$RESULT_FILE"

    test_1_response_under_load
    test_2_context_switch_latency
    test_3_wakeup_latency
    test_4_interactive_under_mixed_load

    print_header "BENCHMARK COMPLETED"
    echo -e "${COLOR_GREEN}Results saved to:${COLOR_RESET} $RESULT_FILE" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_GREEN}Log saved to:${COLOR_RESET} $LOG_FILE" | tee -a "$RESULT_FILE"

    print_success "Benchmark completed successfully"
}

################################################################################
# ENTRY POINT
################################################################################

trap cleanup_background_jobs EXIT
main
exit 0
