#!/bin/bash
# responsiveness.sh - Measure scheduler responsiveness (latency/interactivity)
# Usage: SCHEDULER_TYPE="BORE"|"DEFAULT" ./responsiveness.sh

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m' D='\033[2m'
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' CYAN='\033[0;36m' WHITE='\033[0;37m'
readonly BG_BLUE='\033[44m'

# Config
readonly KERNEL_VERSION=$(uname -r)
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly NUM_CPUS=$(nproc)
readonly STRESS_TIMEOUT=30
readonly CYCLICTEST_ITERATIONS=10000
readonly STRESS_RAMPUP_DELAY=3
readonly CLEANUP_DELAY=2

# Detect scheduler: env var > kernel version
detect_scheduler() {
    [ -n "$SCHEDULER_TYPE" ] && {
        case "${SCHEDULER_TYPE^^}" in
            BORE|BORE_SCHEDULER) echo "BORE"; return ;;
            DEFAULT|EEVDF|CFS) echo "DEFAULT"; return ;;
        esac
    }
    [[ $KERNEL_VERSION == *"cachyos"* ]] || [[ $KERNEL_VERSION == *"bore"* ]] && { echo "BORE"; return; }
    echo "DEFAULT"
}

readonly KERNEL_TYPE=$(detect_scheduler)
readonly RESULT_FILE="responsiveness_${KERNEL_TYPE}_${TIMESTAMP}.txt"
readonly LOG_FILE="responsiveness_${KERNEL_TYPE}_${TIMESTAMP}.log"

# Print functions
print_success() { echo -e "${GREEN}✓${R} $1" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}✗${R} ${RED}$1${R}" | tee -a "$LOG_FILE"; }
print_warning() { echo -e "${YELLOW}⚠${R} ${YELLOW}$1${R}" | tee -a "$LOG_FILE"; }
print_info() { echo -e "${CYAN}ℹ${R} $1" | tee -a "$LOG_FILE"; }
print_header() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${BG_BLUE}${WHITE}================================================================" | tee -a "$RESULT_FILE"
    echo -e "${B}${BG_BLUE}${WHITE}$1${R}" | tee -a "$RESULT_FILE"
    echo -e "${B}${BG_BLUE}${WHITE}================================================================" | tee -a "$RESULT_FILE"
    echo -e "${R}" | tee -a "$RESULT_FILE"
}
print_test() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST $1:${R} ${B}$2${R}" | tee -a "$RESULT_FILE"
    echo -e "${D}Scenario: $3${R}" | tee -a "$RESULT_FILE"
    echo -e "${D}----------------------------------------${R}" | tee -a "$RESULT_FILE"
}
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${D}$msg${R}"
}

check_tool() {
    local tool="$1" pkg="$2"
    command -v "$tool" &> /dev/null && { print_success "Found: $tool"; return 0; }
    print_error "$tool not found"
    print_info "Install: sudo apt install $pkg (Ubuntu) or sudo pacman -S $pkg (CachyOS)"
    exit 1
}

run_hackbench() {
    local args="$1" desc="$2" start end output
    print_info "Running hackbench: $desc"
    echo "Running hackbench: $desc..." | tee -a "$RESULT_FILE"

    start=$(date +%s.%N)
    output=$(hackbench $args 2>&1) || { print_error "hackbench failed"; echo "$output" | tee -a "$RESULT_FILE"; return 1; }
    end=$(date +%s.%N)

    echo "$output" | grep "Time:" | tee -a "$RESULT_FILE" || echo "$output" | tee -a "$RESULT_FILE"
    echo -e "${GREEN}Elapsed time: $(echo "$end - $start" | bc)s${R}" | tee -a "$RESULT_FILE"
}

cleanup_background_jobs() {
    print_info "Cleaning up background jobs..."
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    sleep 1
}

# Test functions
test_1_response_under_load() {
    print_test "1" "Scheduling Responsiveness Under CPU Stress" "Heavy background task (95% CPU) + interactive task switching"
    log "Starting Test 1: Response under load"

    print_info "Launching stress-ng with 95% CPU load on $NUM_CPUS cores"
    stress-ng --cpu "$NUM_CPUS" --cpu-load 95 --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 &
    local stress_pid=$!

    sleep "$STRESS_RAMPUP_DELAY"
    print_success "CPU stress active, running hackbench test"

    run_hackbench "-s 256 -l 100 -g 5" "5 groups, 100 loops, 256B messages"

    kill "$stress_pid" 2>/dev/null || true
    wait "$stress_pid" 2>/dev/null || true
    sleep "$CLEANUP_DELAY"

    log "Test 1 completed"
}

test_2_context_switch_latency() {
    print_test "2" "Context Switch Latency" "Rapid task switching via inter-process communication"
    log "Starting Test 2: Context switch latency"
    run_hackbench "-p -s 512 -l 200 -g 10" "pipe mode, 10 groups, 200 loops, 512B messages"
    log "Test 2 completed"
}

test_3_wakeup_latency() {
    print_test "3" "Wake-up Latency for Sleeping Tasks" "Application waking from idle state (e.g., click event)"
    log "Starting Test 3: Wake-up latency"

    print_info "Running cyclictest ($CYCLICTEST_ITERATIONS iterations, priority 80)"
    echo "Running cyclictest ($CYCLICTEST_ITERATIONS iterations, priority 80)..." | tee -a "$RESULT_FILE"

    local cmd="cyclictest -t1 -p80 -l$CYCLICTEST_ITERATIONS -q"
    # cyclictest needs high privileges for accurate measurement
    if command -v sudo &> /dev/null; then
        if sudo $cmd 2>&1 | tee -a "$RESULT_FILE"; then
            print_success "Test 3 completed successfully"
        else
            print_warning "cyclictest may have issues - check permissions"
        fi
    else
        if $cmd 2>&1 | tee -a "$RESULT_FILE"; then
            print_success "Test 3 completed successfully"
        else
            print_warning "cyclictest may have issues - may need sudo for accurate results"
        fi
    fi

    log "Test 3 completed"
}

test_4_interactive_under_mixed_load() {
    print_test "4" "Interactive Task Latency Under Mixed Workload" "Simulating desktop/gaming: Background CPU + I/O + user interaction"
    log "Starting Test 4: Interactive under mixed load"

    local cpu_stress_count=$((NUM_CPUS / 2))
    [ "$cpu_stress_count" -lt 1 ] && cpu_stress_count=1

    print_info "Launching mixed workload: $cpu_stress_count CPU cores + 2 I/O workers"

    stress-ng --cpu "$cpu_stress_count" --cpu-load 100 --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 &
    local cpu_pid=$!

    stress-ng --io 2 --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 &
    local io_pid=$!

    sleep 2
    print_success "Mixed load active, testing interactive response"

    run_hackbench "-s 128 -l 50 -g 3" "3 groups, 50 loops, 128B messages (simulating UI events)"

    kill "$cpu_pid" "$io_pid" 2>/dev/null || true
    wait 2>/dev/null || true

    log "Test 4 completed"
}

main() {
    print_header "RESPONSIVENESS BENCHMARK - ${KERNEL_TYPE} SCHEDULER"

    echo -e "${B}Kernel Version:${R} $KERNEL_VERSION" | tee -a "$RESULT_FILE"
    echo -e "${B}Scheduler Type:${R} $KERNEL_TYPE" | tee -a "$RESULT_FILE"
    echo -e "${B}CPU Cores:${R} $NUM_CPUS" | tee -a "$RESULT_FILE"
    echo -e "${B}Test Date:${R} $(date)" | tee -a "$RESULT_FILE"
    echo -e "${B}Hostname:${R} $(hostname)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    log "Starting responsiveness benchmark on $KERNEL_TYPE scheduler"
    [ -z "$SCHEDULER_TYPE" ] && print_info "Tip: Set SCHEDULER_TYPE=\"BORE\" or \"DEFAULT\" to explicitly specify scheduler"

    print_info "Checking required tools..."
    echo "Checking required tools..." | tee -a "$RESULT_FILE"
    check_tool stress-ng "stress-ng"
    check_tool hackbench "linux-tools"
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
    echo -e "${GREEN}Results saved to:${R} $RESULT_FILE" | tee -a "$RESULT_FILE"
    echo -e "${GREEN}Log saved to:${R} $LOG_FILE" | tee -a "$RESULT_FILE"
    print_success "Benchmark completed successfully"
}

trap cleanup_background_jobs EXIT
main
exit 0
