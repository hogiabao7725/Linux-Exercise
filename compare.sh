#!/bin/bash
################################################################################
# compare.sh
#
# Purpose: Compare benchmark results between BORE and DEFAULT schedulers
#
# Usage: ./compare.sh [responsiveness|throughput]
#        ./compare.sh [file1] [file2]
#        Or let it auto-detect latest files
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
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_MAGENTA='\033[0;35m'

################################################################################
# UTILITY FUNCTIONS
################################################################################

print_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_RED}✗${COLOR_RESET} ${COLOR_RED}$1${COLOR_RESET}"
}

print_warning() {
    echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} ${COLOR_YELLOW}$1${COLOR_RESET}"
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

print_better() {
    local value=$1
    local label=$2
    echo -e "  ${COLOR_GREEN}→ $label: $value${COLOR_RESET}"
}

print_worse() {
    local value=$1
    local label=$2
    echo -e "  ${COLOR_RED}→ $label: $value${COLOR_RESET}"
}

find_latest_file() {
    local pattern=$1
    ls -t ${pattern}*.txt 2>/dev/null | head -1
}

extract_scheduler_type() {
    local file=$1
    if echo "$file" | grep -qi "BORE"; then
        echo "BORE"
    elif echo "$file" | grep -qi "DEFAULT"; then
        echo "DEFAULT"
    else
        echo "UNKNOWN"
    fi
}

extract_test_section() {
    local file=$1
    local test_num=$2
    local lines_after=$3
    grep -A "${lines_after:-20}" "TEST $test_num:" "$file" 2>/dev/null || echo ""
}

extract_elapsed_time() {
    local section=$1
    echo "$section" | grep -oE "Elapsed time: [0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1
}

extract_hackbench_time() {
    local section=$1
    echo "$section" | grep -oE "Time: [0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1
}

extract_cyclictest_metrics() {
    local section=$1
    local metric=$2  # "Min", "Avg", "Max"
    echo "$section" | grep -oE "${metric}:\s*[0-9]+" | grep -oE "[0-9]+" | head -1
}

extract_bogo_ops() {
    local file=$1
    grep "bogo ops/s" "$file" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1
}

extract_stddev() {
    local file=$1
    grep "Standard deviation:" "$file" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1
}

extract_sysbench_events() {
    local file=$1
    grep -A 20 "TEST 4:" "$file" 2>/dev/null | grep -oE "events per second:\s*[0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1
}

calculate_percentage() {
    local val1=$1
    local val2=$2
    if [ -z "$val1" ] || [ -z "$val2" ] || [ "$val2" = "0" ]; then
        echo "N/A"
        return
    fi
    local diff=$(echo "scale=2; ($val1 - $val2) / $val2 * 100" | bc 2>/dev/null)
    echo "$diff"
}

compare_responsiveness() {
    local file1=$1
    local file2=$2
    local scheduler1=$(extract_scheduler_type "$file1")
    local scheduler2=$(extract_scheduler_type "$file2")
    
    print_header "RESPONSIVENESS COMPARISON: ${scheduler1} vs ${scheduler2}"
    
    echo -e "${COLOR_BOLD}${scheduler1}:${COLOR_RESET} $(basename "$file1")"
    echo -e "${COLOR_BOLD}${scheduler2}:${COLOR_RESET} $(basename "$file2")"
    echo ""
    
    # Test 1: Response under load
    echo -e "${COLOR_BOLD}Test 1: Response Under Load${COLOR_RESET}"
    local section1=$(extract_test_section "$file1" "1" 10)
    local section2=$(extract_test_section "$file2" "1" 10)
    local time1=$(extract_elapsed_time "$section1")
    local time2=$(extract_elapsed_time "$section2")
    
    if [ -n "$time1" ] && [ -n "$time2" ]; then
        local diff=$(calculate_percentage "$time1" "$time2")
        if (( $(echo "$time1 < $time2" | bc -l) )); then
            print_better "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for Test 1"
    fi
    
    echo ""
    
    # Test 2: Context switch latency
    echo -e "${COLOR_BOLD}Test 2: Context Switch Latency${COLOR_RESET}"
    local section1=$(extract_test_section "$file1" "2" 10)
    local section2=$(extract_test_section "$file2" "2" 10)
    local time1=$(extract_elapsed_time "$section1")
    local time2=$(extract_elapsed_time "$section2")
    
    if [ -n "$time1" ] && [ -n "$time2" ]; then
        local diff=$(calculate_percentage "$time1" "$time2")
        if (( $(echo "$time1 < $time2" | bc -l) )); then
            print_better "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for Test 2"
    fi
    
    echo ""
    
    # Test 3: Wake-up latency (cyclictest)
    echo -e "${COLOR_BOLD}Test 3: Wake-up Latency (cyclictest)${COLOR_RESET}"
    local section1=$(extract_test_section "$file1" "3" 5)
    local section2=$(extract_test_section "$file2" "3" 5)
    
    local min1=$(extract_cyclictest_metrics "$section1" "Min")
    local avg1=$(extract_cyclictest_metrics "$section1" "Avg")
    local max1=$(extract_cyclictest_metrics "$section1" "Max")
    
    local min2=$(extract_cyclictest_metrics "$section2" "Min")
    local avg2=$(extract_cyclictest_metrics "$section2" "Avg")
    local max2=$(extract_cyclictest_metrics "$section2" "Max")
    
    if [ -n "$min1" ] && [ -n "$min2" ]; then
        local diff_min=$(calculate_percentage "$min1" "$min2")
        if (( $(echo "$min1 < $min2" | bc -l) )); then
            print_better "${scheduler1} Min: ${min1}μs vs ${scheduler2} Min: ${min2}μs (${scheduler1} is ${diff_min}% lower)" "Lower is better"
        else
            print_worse "${scheduler1} Min: ${min1}μs vs ${scheduler2} Min: ${min2}μs (${scheduler1} is ${diff_min}% higher)" "Lower is better"
        fi
    fi
    
    if [ -n "$avg1" ] && [ -n "$avg2" ]; then
        local diff_avg=$(calculate_percentage "$avg1" "$avg2")
        if (( $(echo "$avg1 < $avg2" | bc -l) )); then
            print_better "${scheduler1} Avg: ${avg1}μs vs ${scheduler2} Avg: ${avg2}μs (${scheduler1} is ${diff_avg}% lower)" "Lower is better"
        else
            print_worse "${scheduler1} Avg: ${avg1}μs vs ${scheduler2} Avg: ${avg2}μs (${scheduler1} is ${diff_avg}% higher)" "Lower is better"
        fi
    fi
    
    if [ -n "$max1" ] && [ -n "$max2" ]; then
        local diff_max=$(calculate_percentage "$max1" "$max2")
        if (( $(echo "$max1 < $max2" | bc -l) )); then
            print_better "${scheduler1} Max: ${max1}μs vs ${scheduler2} Max: ${max2}μs (${scheduler1} is ${diff_max}% lower)" "Lower is better"
        else
            print_worse "${scheduler1} Max: ${max1}μs vs ${scheduler2} Max: ${max2}μs (${scheduler1} is ${diff_max}% higher)" "Lower is better"
        fi
    fi
    
    if [ -z "$min1" ] && [ -z "$avg1" ] && [ -z "$max1" ]; then
        print_warning "Could not extract cyclictest metrics. Check raw output in files."
    fi
    
    echo ""
    
    # Test 4: Interactive under mixed load
    echo -e "${COLOR_BOLD}Test 4: Interactive Under Mixed Load${COLOR_RESET}"
    local section1=$(extract_test_section "$file1" "4" 10)
    local section2=$(extract_test_section "$file2" "4" 10)
    local time1=$(extract_elapsed_time "$section1")
    local time2=$(extract_elapsed_time "$section2")
    
    if [ -n "$time1" ] && [ -n "$time2" ]; then
        local diff=$(calculate_percentage "$time1" "$time2")
        if (( $(echo "$time1 < $time2" | bc -l) )); then
            print_better "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for Test 4"
    fi
}

compare_throughput() {
    local file1=$1
    local file2=$2
    local scheduler1=$(extract_scheduler_type "$file1")
    local scheduler2=$(extract_scheduler_type "$file2")
    
    print_header "THROUGHPUT & FAIRNESS COMPARISON: ${scheduler1} vs ${scheduler2}"
    
    echo -e "${COLOR_BOLD}${scheduler1}:${COLOR_RESET} $(basename "$file1")"
    echo -e "${COLOR_BOLD}${scheduler2}:${COLOR_RESET} $(basename "$file2")"
    echo ""
    
    # Test 1: Maximum CPU throughput
    echo -e "${COLOR_BOLD}Test 1: Maximum CPU Throughput${COLOR_RESET}"
    local ops1=$(extract_bogo_ops "$file1")
    local ops2=$(extract_bogo_ops "$file2")
    
    if [ -n "$ops1" ] && [ -n "$ops2" ]; then
        local diff=$(calculate_percentage "$ops1" "$ops2")
        if (( $(echo "$ops1 > $ops2" | bc -l) )); then
            print_better "${scheduler1}: ${ops1} vs ${scheduler2}: ${ops2} ops/s (${scheduler1} is ${diff}% higher)" "Higher is better"
        else
            print_worse "${scheduler1}: ${ops1} vs ${scheduler2}: ${ops2} ops/s (${scheduler1} is ${diff}% lower)" "Higher is better"
        fi
    else
        print_warning "Could not extract bogo ops/s values"
    fi
    
    echo ""
    
    # Test 2: Server workload
    echo -e "${COLOR_BOLD}Test 2: Server Workload${COLOR_RESET}"
    local section1=$(extract_test_section "$file1" "2" 10)
    local section2=$(extract_test_section "$file2" "2" 10)
    local time1=$(extract_elapsed_time "$section1")
    local time2=$(extract_elapsed_time "$section2")
    
    if [ -n "$time1" ] && [ -n "$time2" ]; then
        local diff=$(calculate_percentage "$time1" "$time2")
        if (( $(echo "$time1 < $time2" | bc -l) )); then
            print_better "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for Test 2"
    fi
    
    echo ""
    
    # Test 3: Fairness
    echo -e "${COLOR_BOLD}Test 3: CPU Time Fairness${COLOR_RESET}"
    local stddev1=$(extract_stddev "$file1")
    local stddev2=$(extract_stddev "$file2")
    
    if [ -n "$stddev1" ] && [ -n "$stddev2" ]; then
        local diff=$(calculate_percentage "$stddev1" "$stddev2")
        if (( $(echo "$stddev1 < $stddev2" | bc -l) )); then
            print_better "${scheduler1}: ${stddev1} vs ${scheduler2}: ${stddev2} (${scheduler1} is ${diff}% lower)" "Lower StdDev = more fair"
        else
            print_worse "${scheduler1}: ${stddev1} vs ${scheduler2}: ${stddev2} (${scheduler1} is ${diff}% higher)" "Lower StdDev = more fair"
        fi
    else
        print_warning "Could not extract standard deviation values"
    fi
    
    echo ""
    
    # Test 4: Sustained throughput
    echo -e "${COLOR_BOLD}Test 4: Sustained Throughput (sysbench)${COLOR_RESET}"
    local events1=$(extract_sysbench_events "$file1")
    local events2=$(extract_sysbench_events "$file2")
    
    if [ -n "$events1" ] && [ -n "$events2" ]; then
        local diff=$(calculate_percentage "$events1" "$events2")
        if (( $(echo "$events1 > $events2" | bc -l) )); then
            print_better "${scheduler1}: ${events1} vs ${scheduler2}: ${events2} events/s (${scheduler1} is ${diff}% higher)" "Higher is better"
        else
            print_worse "${scheduler1}: ${events1} vs ${scheduler2}: ${events2} events/s (${scheduler1} is ${diff}% lower)" "Higher is better"
        fi
    else
        print_warning "Could not extract sysbench events per second. Check raw output in files."
    fi
    
    echo ""
    
    # Test 5: Multi-process throughput
    echo -e "${COLOR_BOLD}Test 5: Multi-Process Throughput${COLOR_RESET}"
    local section1=$(extract_test_section "$file1" "5" 10)
    local section2=$(extract_test_section "$file2" "5" 10)
    local time1=$(extract_elapsed_time "$section1")
    local time2=$(extract_elapsed_time "$section2")
    
    if [ -n "$time1" ] && [ -n "$time2" ]; then
        local diff=$(calculate_percentage "$time1" "$time2")
        if (( $(echo "$time1 < $time2" | bc -l) )); then
            print_better "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${scheduler1}: ${time1}s vs ${scheduler2}: ${time2}s (${scheduler1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for Test 5"
    fi
}

detect_file_type() {
    local file=$1
    if echo "$file" | grep -qi "responsiveness"; then
        echo "responsiveness"
    elif echo "$file" | grep -qi "throughput"; then
        echo "throughput"
    else
        echo "unknown"
    fi
}

################################################################################
# MAIN PROGRAM
################################################################################

main() {
    local file1=""
    local file2=""
    local compare_type=""
    
    # Parse arguments
    if [ $# -eq 2 ]; then
        # Two files provided
        file1="$1"
        file2="$2"
    elif [ $# -eq 1 ]; then
        # One argument: type or file
        if [ "$1" = "responsiveness" ] || [ "$1" = "throughput" ]; then
            compare_type="$1"
        else
            print_error "Invalid argument: $1"
            print_info "Usage: $0 [responsiveness|throughput]"
            print_info "       $0 [file1] [file2]"
            exit 1
        fi
    elif [ $# -eq 0 ]; then
        # Auto-detect
        compare_type="auto"
    else
        print_error "Invalid arguments"
        print_info "Usage: $0 [responsiveness|throughput]"
        print_info "       $0 [file1] [file2]"
        print_info "       $0 (auto-detect)"
        exit 1
    fi
    
    # Auto-detect files if needed
    if [ -z "$file1" ] || [ -z "$file2" ]; then
        print_info "Auto-detecting latest benchmark files..."
        
        if [ "$compare_type" = "responsiveness" ] || ([ "$compare_type" = "auto" ] && [ -z "$compare_type" ]); then
            local resp_bore=$(find_latest_file "responsiveness_BORE")
            local resp_default=$(find_latest_file "responsiveness_DEFAULT")
            
            if [ -n "$resp_bore" ] && [ -n "$resp_default" ]; then
                print_success "Found responsiveness files"
                file1="$resp_default"
                file2="$resp_bore"
                compare_type="responsiveness"
            fi
        fi
        
        if [ "$compare_type" = "throughput" ] || ([ "$compare_type" = "auto" ] && [ -z "$file1" ]); then
            local thr_bore=$(find_latest_file "throughput_BORE")
            local thr_default=$(find_latest_file "throughput_DEFAULT")
            
            if [ -n "$thr_bore" ] && [ -n "$thr_default" ]; then
                print_success "Found throughput files"
                file1="$thr_default"
                file2="$thr_bore"
                compare_type="throughput"
            fi
        fi
        
        if [ -z "$file1" ] || [ -z "$file2" ]; then
            print_error "Could not find matching benchmark files"
            print_info "Usage: $0 [responsiveness|throughput]"
            print_info "       $0 [file1] [file2]"
            print_info "Or ensure you have run benchmarks on both schedulers"
            exit 1
        fi
    fi
    
    # Check files exist
    if [ ! -f "$file1" ]; then
        print_error "File not found: $file1"
        exit 1
    fi
    
    if [ ! -f "$file2" ]; then
        print_error "File not found: $file2"
        exit 1
    fi
    
    # Detect file type
    local type1=$(detect_file_type "$file1")
    local type2=$(detect_file_type "$file2")
    
    if [ "$type1" != "$type2" ]; then
        print_error "Files are of different types"
        print_info "File 1: $type1"
        print_info "File 2: $type2"
        exit 1
    fi
    
    # Check bc is available
    if ! command -v bc &> /dev/null; then
        print_error "bc is required but not found"
        print_info "Install with: sudo apt install bc (Ubuntu) or sudo pacman -S bc (CachyOS)"
        exit 1
    fi
    
    # Compare based on type
    if [ "$type1" = "responsiveness" ]; then
        compare_responsiveness "$file1" "$file2"
    elif [ "$type1" = "throughput" ]; then
        compare_throughput "$file1" "$file2"
    else
        print_error "Unknown file type"
        exit 1
    fi
    
    echo ""
    print_header "COMPARISON COMPLETE"
    print_info "For detailed results, check the individual benchmark files"
}

################################################################################
# ENTRY POINT
################################################################################

main "$@"
exit 0
