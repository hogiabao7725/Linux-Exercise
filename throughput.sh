#!/bin/bash
################################################################################
# test_throughput.sh
#
# Purpose: Measure scheduler throughput and fairness
#          EEVDF (Ubuntu default) is designed for throughput and fairness
#
# Requirements: stress-ng, hackbench, sysbench, python3, bc
# Installation: sudo apt install stress-ng hackbench sysbench python3 bc
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
readonly SYSBENCH_TIMEOUT=60
readonly FAIRNESS_TASKS=8
readonly FAIRNESS_COMPUTATION_SIZE=2000000

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Detect scheduler type - Simple approach: prefer environment variable
# Usage: Set SCHEDULER_TYPE="BORE" or "DEFAULT" before running tests
#        If not set, will auto-detect from kernel version (fallback)
detect_scheduler() {
    # Method 1: Environment variable (RECOMMENDED - highest priority)
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

readonly RESULT_FILE="throughput_${KERNEL_TYPE}_${TIMESTAMP}.txt"
readonly LOG_FILE="throughput_${KERNEL_TYPE}_${TIMESTAMP}.log"

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
    echo -e "${COLOR_GREEN}Total elapsed time: ${elapsed}s${COLOR_RESET}" | tee -a "$RESULT_FILE"
    
    return $exit_code
}

cleanup_temp_files() {
    print_info "Cleaning up temporary files..."
    rm -f /tmp/fairness_task_*.sh
    rm -f /tmp/throughput_test_*
    rm -f /tmp/fairness_results_*.txt
}

################################################################################
# TEST FUNCTIONS
################################################################################

test_1_maximum_cpu_throughput() {
    print_test "1" \
        "Maximum CPU Operations Per Second" \
        "Heavy computation (video encoding, 3D rendering, compilation)"
    
    log "Starting Test 1: Maximum CPU throughput"
    
    print_info "Running stress-ng on $NUM_CPUS cores for ${STRESS_TIMEOUT}s"
    echo "Running stress-ng on $NUM_CPUS cores for ${STRESS_TIMEOUT}s..." | tee -a "$RESULT_FILE"
    echo "Methods: All CPU stress methods (integer, floating point, etc.)" | tee -a "$RESULT_FILE"
    
    local start_time=$(date +%s.%N)
    local output=$(stress-ng --cpu "$NUM_CPUS" \
        --cpu-method all \
        --metrics-brief \
        --timeout "${STRESS_TIMEOUT}s" 2>&1)
    local exit_code=$?
    local end_time=$(date +%s.%N)
    
    if [ $exit_code -eq 0 ]; then
        if echo "$output" | grep -q "bogo ops/s"; then
            echo "$output" | grep "bogo ops/s" | tee -a "$RESULT_FILE"
        else
            echo -e "${COLOR_YELLOW}bogo ops/s: (output format may differ)${COLOR_RESET}" | tee -a "$RESULT_FILE"
        fi
        echo "$output" >> "$LOG_FILE"
    else
        print_error "stress-ng failed with exit code $exit_code"
        echo "$output" | tee -a "$RESULT_FILE"
    fi
    
    local elapsed=$(echo "$end_time - $start_time" | bc)
    echo -e "${COLOR_GREEN}Total elapsed time: ${elapsed}s${COLOR_RESET}" | tee -a "$RESULT_FILE"
    
    log "Test 1 completed"
}

test_2_server_workload() {
    print_test "2" \
        "Server-Style Parallel Task Handling" \
        "Web server with 50 concurrent connection groups"
    
    log "Starting Test 2: Server workload"
    
    run_hackbench "-g 50 -l 1000 -s 512" \
        "50 groups, 1000 loops, 512B messages"
    
    log "Test 2 completed"
}

test_3_fairness_test() {
    print_test "3" \
        "CPU Time Fairness Between Equal-Priority Tasks" \
        "$FAIRNESS_TASKS identical tasks competing for CPU (batch processing)"
    
    log "Starting Test 3: Fairness test"
    
    local temp_script="/tmp/fairness_task_$$.sh"
    local results_file="/tmp/fairness_results_$$.txt"
    
    # Create temporary script for fairness testing
    cat > "$temp_script" << EOF
#!/bin/bash
TASK_ID=\$1
START=\$(date +%s%N)

# CPU-intensive Python computation
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
    
    rm -f "$results_file"
    
    # Run tasks in parallel and capture output
    local pids=()
    for i in $(seq 1 "$FAIRNESS_TASKS"); do
        "$temp_script" "$i" >> "$results_file" 2>&1 &
        pids+=($!)
    done
    
    print_info "Waiting for all tasks to complete..."
    wait "${pids[@]}"
    
    # Print results to RESULT_FILE
    if [ -f "$results_file" ] && [ -s "$results_file" ]; then
        cat "$results_file" | tee -a "$RESULT_FILE"
    else
        print_error "Failed to collect task results"
        echo "ERROR: Failed to collect task results" | tee -a "$RESULT_FILE"
    fi
    
    echo "" | tee -a "$RESULT_FILE"
    
    # Calculate statistics from results file
    if [ -f "$results_file" ] && [ -s "$results_file" ]; then
        print_info "Calculating fairness statistics..."
        awk '/^Task/ {print $3}' "$results_file" | \
            awk '{
                if (NF > 0 && $1 > 0) {
                    sum += $1
                    sumsq += $1 * $1
                    n++
                }
            }
            END {
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
    fi
    
    # Cleanup
    rm -f "$temp_script" "$results_file"
    
    log "Test 3 completed"
}

test_4_sustained_throughput() {
    print_test "4" \
        "Sustained CPU Throughput Over Time" \
        "Long-running batch processing (${SYSBENCH_TIMEOUT}s continuous load)"
    
    log "Starting Test 4: Sustained throughput"
    
    print_info "Running sysbench CPU test..."
    echo "Running sysbench CPU test..." | tee -a "$RESULT_FILE"
    echo "Configuration:" | tee -a "$RESULT_FILE"
    echo "  - Prime number calculation up to 20,000" | tee -a "$RESULT_FILE"
    echo "  - Threads: $NUM_CPUS" | tee -a "$RESULT_FILE"
    echo "  - Duration: ${SYSBENCH_TIMEOUT}s" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"
    
    local output=$(sysbench cpu \
        --cpu-max-prime=20000 \
        --threads="$NUM_CPUS" \
        --time="$SYSBENCH_TIMEOUT" \
        run 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        if echo "$output" | grep -qE "events per second|total time|min:|avg:|max:|95th percentile:"; then
            echo "$output" | grep -E "events per second|total time|min:|avg:|max:|95th percentile:" | tee -a "$RESULT_FILE"
        else
            print_warning "Expected metrics not found in output"
            echo "WARNING: Expected metrics not found in output" | tee -a "$RESULT_FILE"
        fi
        echo "$output" >> "$LOG_FILE"
    else
        print_error "sysbench failed with exit code $exit_code"
        echo "$output" | tee -a "$RESULT_FILE"
    fi
    
    log "Test 4 completed"
}

test_5_multiprocess_throughput() {
    print_test "5" \
        "Multi-Process Parallel Throughput" \
        "Data processing pipeline with IPC (30 parallel processes)"
    
    log "Starting Test 5: Multi-process throughput"
    
    run_hackbench "-p -g 30 -l 500 -s 256" \
        "pipe mode, 30 groups, 500 loops, 256B messages"
    
    log "Test 5 completed"
}

################################################################################
# MAIN PROGRAM
################################################################################

main() {
    print_header "THROUGHPUT & FAIRNESS BENCHMARK - ${KERNEL_TYPE} SCHEDULER"
    
    echo -e "${COLOR_BOLD}Kernel Version:${COLOR_RESET} $KERNEL_VERSION" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}Scheduler Type:${COLOR_RESET} $KERNEL_TYPE" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}CPU Cores:${COLOR_RESET} $NUM_CPUS" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}Test Date:${COLOR_RESET} $(date)" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_BOLD}Hostname:${COLOR_RESET} $(hostname)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"
    
    log "Starting throughput benchmark on $KERNEL_TYPE scheduler"
    log "Detected scheduler: $KERNEL_TYPE (kernel: $KERNEL_VERSION)"
    
    if [ -z "$SCHEDULER_TYPE" ]; then
        print_info "Tip: Set SCHEDULER_TYPE=\"BORE\" or \"DEFAULT\" to explicitly specify scheduler"
    fi
    
    print_info "Checking required tools..."
    echo "Checking required tools..." | tee -a "$RESULT_FILE"
    check_tool stress-ng "stress-ng"
    check_tool hackbench "hackbench"
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
    echo -e "${COLOR_GREEN}Results saved to:${COLOR_RESET} $RESULT_FILE" | tee -a "$RESULT_FILE"
    echo -e "${COLOR_GREEN}Log saved to:${COLOR_RESET} $LOG_FILE" | tee -a "$RESULT_FILE"
    
    print_success "Benchmark completed successfully"
}

################################################################################
# ENTRY POINT
################################################################################

trap cleanup_temp_files EXIT
main
exit 0
