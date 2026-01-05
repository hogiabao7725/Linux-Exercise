#!/bin/bash
# throughput.sh - Measure scheduler throughput and fairness

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m'
readonly GREEN='\033[0;32m' CYAN='\033[0;36m'

# Config
readonly KERNEL_VERSION=$(uname -r)
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly NUM_CPUS=$(nproc)
readonly STRESS_TIMEOUT=30
readonly SYSBENCH_TIMEOUT=60
readonly FAIRNESS_TASKS=8
readonly FAIRNESS_COMPUTATION_SIZE=2000000
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
readonly RESULT_FILE="throughput_${KERNEL_TYPE}_${TIMESTAMP}.txt"

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
test_1_maximum_cpu_throughput() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 1: Maximum CPU Throughput${R}" | tee -a "$RESULT_FILE"
    
    stabilize
    local times=()
    local total=0
    
    for i in $(seq 1 "$NUM_RUNS"); do
        stabilize
        local start=$(date +%s.%N)
        stress-ng --cpu "$NUM_CPUS" --timeout "${STRESS_TIMEOUT}s" > /dev/null 2>&1 || continue
        local end=$(date +%s.%N)
        local elapsed=$(echo "$end - $start" | bc)
        times+=("$elapsed")
        total=$(echo "$total + $elapsed" | bc)
        sleep 2
    done
    
    [ ${#times[@]} -gt 0 ] && {
        local avg=$(echo "scale=6; $total / ${#times[@]}" | bc)
        echo "Average execution time: ${avg}s" | tee -a "$RESULT_FILE"
    }
}

test_2_server_workload() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 2: Server-Style Parallel Task Handling${R}" | tee -a "$RESULT_FILE"
    stabilize
    run_hackbench "-g 50 -l 1000 -s 512"
}

test_3_fairness_test() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 3: CPU Time Fairness${R}" | tee -a "$RESULT_FILE"
    
    stabilize
    local all_means=()
    local total_mean=0
    
    for run in $(seq 1 "$NUM_RUNS"); do
        stabilize
        local temp_script="/tmp/fairness_$$_${run}.sh"
        local results_file="/tmp/fairness_results_$$_${run}.txt"
        
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
        
        local pids=()
        for i in $(seq 1 "$FAIRNESS_TASKS"); do
            "$temp_script" "$i" >> "$results_file" 2>&1 &
            pids+=($!)
        done
        wait "${pids[@]}"
        
        [ -f "$results_file" ] && [ -s "$results_file" ] && {
            local mean=$(awk '/^Task/ {sum+=$3; n++} END {if(n>0) printf "%.6f", sum/n}' "$results_file")
            [ -n "$mean" ] && {
                all_means+=("$mean")
                total_mean=$(echo "$total_mean + $mean" | bc)
            }
        }
        
        rm -f "$temp_script" "$results_file"
        sleep 2
    done
    
    [ ${#all_means[@]} -gt 0 ] && {
        local avg_mean=$(echo "scale=6; $total_mean / ${#all_means[@]}" | bc)
        local variance=0
        for mean in "${all_means[@]}"; do
            local diff=$(echo "$mean - $avg_mean" | bc)
            local diff_sq=$(echo "$diff * $diff" | bc)
            variance=$(echo "$variance + $diff_sq" | bc)
        done
        variance=$(echo "scale=6; $variance / ${#all_means[@]}" | bc)
        local stddev=$(echo "scale=6; sqrt($variance)" | bc)
        echo "Average Mean: ${avg_mean}s" | tee -a "$RESULT_FILE"
        echo "StdDev: ${stddev}s" | tee -a "$RESULT_FILE"
    }
}

test_4_sustained_throughput() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 4: Sustained CPU Throughput${R}" | tee -a "$RESULT_FILE"
    
    stabilize
    local events_per_sec=()
    local total=0
    
    for i in $(seq 1 "$NUM_RUNS"); do
        stabilize
        local output=$(sysbench cpu --cpu-max-prime=20000 --threads="$NUM_CPUS" --time="$SYSBENCH_TIMEOUT" run 2>&1) || continue
        local eps=$(echo "$output" | grep -oE "events per second:\s*[0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1 || echo "0")
        [ -n "$eps" ] && [ "$eps" != "0" ] && {
            events_per_sec+=("$eps")
            total=$(echo "$total + $eps" | bc)
        }
        sleep 2
    done
    
    [ ${#events_per_sec[@]} -gt 0 ] && {
        local avg=$(echo "scale=2; $total / ${#events_per_sec[@]}" | bc)
        echo "Average events per second: ${avg}" | tee -a "$RESULT_FILE"
    }
}

test_5_multiprocess_throughput() {
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${B}${CYAN}TEST 5: Multi-Process Parallel Throughput${R}" | tee -a "$RESULT_FILE"
    stabilize
    run_hackbench "-p -g 30 -l 500 -s 256"
}

# Main
main() {
    echo -e "${B}THROUGHPUT & FAIRNESS BENCHMARK - ${KERNEL_TYPE} SCHEDULER${R}" | tee -a "$RESULT_FILE"
    echo "Kernel: $KERNEL_VERSION | CPUs: $NUM_CPUS | Runs: $NUM_RUNS" | tee -a "$RESULT_FILE"
    echo "Date: $(date)" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"
    
    test_1_maximum_cpu_throughput
    test_2_server_workload
    test_3_fairness_test
    test_4_sustained_throughput
    test_5_multiprocess_throughput
    
    echo "" | tee -a "$RESULT_FILE"
    echo -e "${GREEN}Results saved to: $RESULT_FILE${R}" | tee -a "$RESULT_FILE"
}

cleanup() {
    rm -f /tmp/fairness_*.sh /tmp/fairness_results_*.txt
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
}

trap cleanup EXIT
main
