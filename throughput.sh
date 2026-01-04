#!/bin/bash
# throughput.sh - Measure scheduler throughput and fairness
# Usage: ./throughput.sh

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
readonly SYSBENCH_TIMEOUT=60
readonly FAIRNESS_TASKS=8
readonly FAIRNESS_COMPUTATION_SIZE=2000000

# Detect scheduler: Method 1 (kernel config) > Method 2 (kernel version)
detect_scheduler() {
    local kernel_version=$(uname -r)
    local config_file="/boot/config-${kernel_version}"
    
    # Method 1: Kernel config file
    [ -f "$config_file" ] && {
        grep -qiE "CONFIG_SCHED_BORE\s*=\s*y" "$config_file" 2>/dev/null && { echo "BORE"; return; }
        grep -qiE "CONFIG_SCHED_EEVDF\s*=\s*y" "$config_file" 2>/dev/null && { echo "DEFAULT"; return; }
    }
    
    # Method 2: Kernel version string
    [[ "$kernel_version" == *"cachyos"* ]] || [[ "$kernel_version" == *"bore"* ]] && { echo "BORE"; return; }
    
    # Fallback
    echo "DEFAULT"
}

readonly KERNEL_TYPE=$(detect_scheduler)
readonly RESULT_FILE="throughput_${KERNEL_TYPE}_${TIMESTAMP}.txt"
readonly LOG_FILE="throughput_${KERNEL_TYPE}_${TIMESTAMP}.log"

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
    echo -e "${GREEN}Total elapsed time: $(echo "$end - $start" | bc)s${R}" | tee -a "$RESULT_FILE"
}

cleanup_temp_files() {
    rm -f /tmp/fairness_task_*.sh /tmp/throughput_test_* /tmp/fairness_results_*.txt
}

# Test functions
test_1_maximum_cpu_throughput() {
    print_test "1" "Maximum CPU Operations Per Second" "Heavy computation (video encoding, 3D rendering, compilation)"
    log "Starting Test 1: Maximum CPU throughput"

    print_info "Running stress-ng on $NUM_CPUS cores for ${STRESS_TIMEOUT}s"
    echo "Running stress-ng on $NUM_CPUS cores for ${STRESS_TIMEOUT}s..." | tee -a "$RESULT_FILE"
    echo "Methods: All CPU stress methods" | tee -a "$RESULT_FILE"

    local start=$(date +%s.%N) output end elapsed
    output=$(stress-ng --cpu "$NUM_CPUS" --cpu-method all --metrics-brief --timeout "${STRESS_TIMEOUT}s" 2>&1) || {
        print_error "stress-ng failed"; echo "$output" | tee -a "$RESULT_FILE"; return 1
    }
    end=$(date +%s.%N)

    if echo "$output" | grep -q "bogo ops/s"; then
        echo "$output" | grep "bogo ops/s" | tee -a "$RESULT_FILE"
    else
        echo -e "${YELLOW}bogo ops/s: (output format may differ)${R}" | tee -a "$RESULT_FILE"
    fi
    echo "$output" >> "$LOG_FILE"
    elapsed=$(echo "$end - $start" | bc)
    echo -e "${GREEN}Total elapsed time: ${elapsed}s${R}" | tee -a "$RESULT_FILE"
    log "Test 1 completed"
}

test_2_server_workload() {
    print_test "2" "Server-Style Parallel Task Handling" "Web server with 50 concurrent connection groups"
    log "Starting Test 2: Server workload"
    run_hackbench "-g 50 -l 1000 -s 512" "50 groups, 1000 loops, 512B messages"
    log "Test 2 completed"
}

test_3_fairness_test() {
    print_test "3" "CPU Time Fairness Between Equal-Priority Tasks" "$FAIRNESS_TASKS identical tasks competing for CPU"
    log "Starting Test 3: Fairness test"

    local temp_script="/tmp/fairness_task_$$.sh"
    local results_file="/tmp/fairness_results_$$.txt"

    cat > "$temp_script" << EOF
#!/bin/bash
TASK_ID=\$1
START=\$(date +%s%N)
python3 -c "sum([i*i for i in range($FAIRNESS_COMPUTATION_SIZE)])" > /dev/null 2>&1
END=\$(date +%s%N)
ELAPSED=\$(echo "scale=6; (\$END - \$START) / 1000000000" | bc)
echo "Task \$TASK_ID: \$ELAPSED seconds"
EOF
    chmod +x "$temp_script"

    print_info "Running $FAIRNESS_TASKS identical tasks in parallel..."
    echo "Running $FAIRNESS_TASKS identical tasks in parallel..." | tee -a "$RESULT_FILE"
    echo "Each task: sum of squares for $FAIRNESS_COMPUTATION_SIZE integers" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    local pids=()
    for i in $(seq 1 "$FAIRNESS_TASKS"); do
        "$temp_script" "$i" >> "$results_file" 2>&1 &
        pids+=($!)
    done

    print_info "Waiting for all tasks to complete..."
    wait "${pids[@]}"

    [ -f "$results_file" ] && [ -s "$results_file" ] && {
        cat "$results_file" | tee -a "$RESULT_FILE"
        echo "" | tee -a "$RESULT_FILE"
        print_info "Calculating fairness statistics..."
        awk '/^Task/ {print $3}' "$results_file" | awk '{
            if (NF > 0 && $1 > 0) { sum += $1; sumsq += $1 * $1; n++ }
        } END {
            if (n > 0) {
                mean = sum / n
                variance = (sumsq / n) - (mean * mean)
                stddev = (variance > 0) ? sqrt(variance) : 0
                printf "Average completion time: %.6f seconds\n", mean
                printf "Standard deviation: %.6f seconds\n", stddev
                if (mean > 0) {
                    cv = (stddev / mean) * 100
                    printf "Coefficient of variation: %.2f%%\n", cv
                }
                printf "\nInterpretation: Lower StdDev = more fair scheduler\n"
            } else {
                printf "ERROR: No valid task results found\n"
            }
        }' | tee -a "$RESULT_FILE"
    } || { print_error "Failed to collect task results"; echo "ERROR: Failed to collect task results" | tee -a "$RESULT_FILE"; }

    rm -f "$temp_script" "$results_file"
    log "Test 3 completed"
}

test_4_sustained_throughput() {
    print_test "4" "Sustained CPU Throughput Over Time" "Long-running batch processing (${SYSBENCH_TIMEOUT}s continuous load)"
    log "Starting Test 4: Sustained throughput"

    print_info "Running sysbench CPU test..."
    echo "Running sysbench CPU test..." | tee -a "$RESULT_FILE"
    echo "Configuration:" | tee -a "$RESULT_FILE"
    echo "  - Prime number calculation up to 20,000" | tee -a "$RESULT_FILE"
    echo "  - Threads: $NUM_CPUS" | tee -a "$RESULT_FILE"
    echo "  - Duration: ${SYSBENCH_TIMEOUT}s" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    local output
    output=$(sysbench cpu --cpu-max-prime=20000 --threads="$NUM_CPUS" --time="$SYSBENCH_TIMEOUT" run 2>&1) || {
        print_error "sysbench failed"; echo "$output" | tee -a "$RESULT_FILE"; return 1
    }

    echo "$output" | grep -E "events per second|total time|min:|avg:|max:|95th percentile:" | tee -a "$RESULT_FILE" || {
        print_warning "Expected metrics not found in output"
        echo "$output" >> "$LOG_FILE"
    }
    log "Test 4 completed"
}

test_5_multiprocess_throughput() {
    print_test "5" "Multi-Process Parallel Throughput" "Data processing pipeline with IPC (30 parallel processes)"
    log "Starting Test 5: Multi-process throughput"
    run_hackbench "-p -g 30 -l 500 -s 256" "pipe mode, 30 groups, 500 loops, 256B messages"
    log "Test 5 completed"
}

main() {
    print_header "THROUGHPUT & FAIRNESS BENCHMARK - ${KERNEL_TYPE} SCHEDULER"

    echo -e "${B}Kernel Version:${R} $KERNEL_VERSION" | tee -a "$RESULT_FILE"
    echo -e "${B}Scheduler Type:${R} $KERNEL_TYPE" | tee -a "$RESULT_FILE"
    echo -e "${B}CPU Cores:${R} $NUM_CPUS" | tee -a "$RESULT_FILE"
    echo -e "${B}Test Date:${R} $(date)" | tee -a "$RESULT_FILE"
    echo -e "${B}Hostname:${R} $(hostname)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    log "Starting throughput benchmark on $KERNEL_TYPE scheduler"

    print_info "Checking required tools..."
    echo "Checking required tools..." | tee -a "$RESULT_FILE"
    check_tool stress-ng "stress-ng"
    check_tool hackbench "linux-tools"
    check_tool sysbench "sysbench"
    check_tool python3 "python3"
    check_tool bc "bc"

    echo "" | tee -a "$RESULT_FILE"
    print_success "All tools available, starting tests..."
    echo "" | tee -a "$RESULT_FILE"

    test_1_maximum_cpu_throughput
    test_2_server_workload
    test_3_fairness_test
    test_4_sustained_throughput
    test_5_multiprocess_throughput

    cleanup_temp_files

    print_header "BENCHMARK COMPLETED"
    echo -e "${GREEN}Results saved to:${R} $RESULT_FILE" | tee -a "$RESULT_FILE"
    echo -e "${GREEN}Log saved to:${R} $LOG_FILE" | tee -a "$RESULT_FILE"
    print_success "Benchmark completed successfully"
}

trap cleanup_temp_files EXIT
main
exit 0
