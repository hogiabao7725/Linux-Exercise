#!/bin/bash
# responsiveness.sh - Measure scheduler responsiveness (latency/interactivity)

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m'
readonly GREEN='\033[0;32m' CYAN='\033[0;36m'

# Config
readonly KERNEL_VERSION=$(uname -r)
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly NUM_CPUS=$(nproc)
readonly STRESS_TIMEOUT=30
readonly CYCLICTEST_ITERATIONS=20000
readonly STRESS_RAMPUP_DELAY=5
readonly NUM_RUNS=5

# Detect scheduler
detect_scheduler() {
    local kernel_version=$(uname -r)
    local config_file="/boot/config-${kernel_version}"
    
    [ -f "$config_file" ] && {
        grep -qiE "CONFIG_SCHED_BORE\s*=\s*y" "$config_file" 2>/dev/null && { echo "BORE"; return; }
        grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y" "$config_file" 2>/dev/null && { echo "DEFAULT"; return; }
    }
    
    [[ "$kernel_version" == *"cachyos"* ]] || [[ "$kernel_version" == *"bore"* ]] && { echo "BORE"; return; }
    echo "DEFAULT"
}

readonly KERNEL_TYPE=$(detect_scheduler)
readonly RESULT_FILE="responsiveness_${KERNEL_TYPE}_${TIMESTAMP}.txt"

# System stabilization
stabilize() {
    sync
    sleep 1
    [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null && {
        [ -w /proc/sys/vm/drop_caches ] && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
    }
    sleep 2
}

# Run hackbench multiple times
run_hackbench() {
    local args="$1"
    local times=()
    local total=0
    
    for i in $(seq 1 "$NUM_RUNS"); do
        stabilize
        local start=$(date +%s.%N)
        hackbench $args > /dev/null 2>&1 || return 1
        local end=$(date +%s.%N)
        local elapsed=$(echo "$end - $start" | bc)
        times+=("$elapsed")
        total=$(echo "$total + $elapsed" | bc)
        sleep 2
    done
    
    local avg=$(echo "scale=6; $total / $NUM_RUNS" | bc)
    echo "Average: ${avg}s" | tee -a "$RESULT_FILE"
}

# Test functions
test_1_response_under_load() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 1: Scheduling Responsiveness Under CPU Stress${R}" | tee -a "$RESULT_FILE"
    
    stabilize
    stress-ng --cpu "$NUM_CPUS" --cpu-load 95 --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 &
    local stress_pid=$!
    sleep "$STRESS_RAMPUP_DELAY"
    
    run_hackbench "-s 256 -l 100 -g 5"
    
    kill "$stress_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}

test_2_context_switch_latency() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 2: Context Switch Latency${R}" | tee -a "$RESULT_FILE"
    stabilize
    run_hackbench "-p -s 512 -l 200 -g 10"
}

test_3_wakeup_latency() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 3: Wake-up Latency${R}" | tee -a "$RESULT_FILE"
    
    stabilize
    local cmd="cyclictest -t1 -p80 -l$CYCLICTEST_ITERATIONS -q"
    [ "$EUID" -ne 0 ] && command -v sudo &> /dev/null && cmd="sudo $cmd"
    
    local results=()
    local total=0
    
    for i in $(seq 1 "$NUM_RUNS"); do
        stabilize
        local output=$($cmd 2>&1) || continue
        local max_run=$(echo "$output" | grep -oE "Max:\s*[0-9]+" | grep -oE "[0-9]+" | head -1 || echo "0")
        [ -n "$max_run" ] && [ "$max_run" != "0" ] && {
            results+=("$max_run")
            total=$(echo "$total + $max_run" | bc)
        }
        sleep 2
    done
    
    [ ${#results[@]} -gt 0 ] && {
        local avg=$(echo "scale=2; $total / ${#results[@]}" | bc)
        echo "Average Max Latency: ${avg} us" | tee -a "$RESULT_FILE"
    }
}

test_4_interactive_under_mixed_load() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 4: Interactive Task Under Mixed Load${R}" | tee -a "$RESULT_FILE"
    
    stabilize
    local cpu_stress_count=$((NUM_CPUS / 2))
    [ "$cpu_stress_count" -lt 1 ] && cpu_stress_count=1
    
    stress-ng --cpu "$cpu_stress_count" --cpu-load 100 --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 &
    local cpu_pid=$!
    stress-ng --io 2 --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 &
    local io_pid=$!
    sleep "$STRESS_RAMPUP_DELAY"
    
    run_hackbench "-s 128 -l 50 -g 3"
    
    kill "$cpu_pid" "$io_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}

# Main
main() {
    echo -e "${B}RESPONSIVENESS BENCHMARK - ${KERNEL_TYPE} SCHEDULER${R}" | tee -a "$RESULT_FILE"
    echo "Kernel: $KERNEL_VERSION | CPUs: $NUM_CPUS | Runs: $NUM_RUNS" | tee -a "$RESULT_FILE"
    echo "Date: $(date)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"
    
    test_1_response_under_load
    test_2_context_switch_latency
    test_3_wakeup_latency
    test_4_interactive_under_mixed_load
    
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${GREEN}Results saved to: $RESULT_FILE${R}" | tee -a "$RESULT_FILE"
}

cleanup() {
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
}

trap cleanup EXIT
main
