#!/bin/bash
# compare.sh - Compare benchmark results between BORE and DEFAULT schedulers
# Usage: ./compare.sh [responsiveness|throughput] | ./compare.sh [file1] [file2] | ./compare.sh

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m' D='\033[2m'
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' CYAN='\033[0;36m'

# Print functions
print_success() { echo -e "${GREEN}✓${R} $1"; }
print_error() { echo -e "${RED}✗${R} ${RED}$1${R}"; }
print_warning() { echo -e "${YELLOW}⚠${R} ${YELLOW}$1${R}"; }
print_info() { echo -e "${CYAN}ℹ${R} $1"; }
print_header() {
    echo ""; echo -e "${B}${BLUE}================================================================"
    echo -e "$1"; echo -e "================================================================${R}"
}
print_better() { echo -e "  ${GREEN}→ $2: $1${R}"; }
print_worse() { echo -e "  ${RED}→ $2: $1${R}"; }

# Utility functions
find_latest_file() { ls -t ${1}*.txt 2>/dev/null | head -1; }
extract_scheduler_type() {
    local f="$1"
    if echo "$f" | grep -qi "BORE"; then echo "BORE"
    elif echo "$f" | grep -qi "DEFAULT"; then echo "DEFAULT"
    else echo "UNKNOWN"; fi
}
extract_test_section() { grep -A "${3:-20}" "TEST $2:" "$1" 2>/dev/null || echo ""; }
extract_elapsed_time() { echo "$1" | grep -oE "Elapsed time: [0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1; }
extract_hackbench_time() { echo "$1" | grep -oE "Time: [0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1; }
extract_cyclictest_metrics() { echo "$1" | grep -oE "${2}:\s*[0-9]+" | grep -oE "[0-9]+" | head -1; }

extract_bogo_ops() {
    local file="$1" section result
    section=$(extract_test_section "$file" "1" 40)
    result=$(echo "$section" | grep -iE "bogo[-\s]?ops?/s" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    [ -z "$result" ] && result=$(grep -iE "bogo[-\s]?ops?/s" "$file" 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    [ -z "$result" ] && result=$(grep -iE "bogo[-\s]?ops?" "$file" 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    echo "$result"
}

extract_stddev() { grep "Standard deviation:" "$1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1; }

extract_sysbench_events() {
    local file="$1" section result
    section=$(extract_test_section "$file" "4" 30)
    result=$(echo "$section" | grep -iE "events per second" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [ -z "$result" ] && result=$(grep -A 30 "TEST 4:" "$file" 2>/dev/null | grep -iE "events.*second" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    echo "$result"
}

calculate_percentage() {
    local v1="$1" v2="$2"
    [ -z "$v1" ] || [ -z "$v2" ] || [ "$v2" = "0" ] && { echo "N/A"; return; }
    echo "scale=2; ($v1 - $v2) / $v2 * 100" | bc 2>/dev/null
}

compare_test_time() {
    local s1="$1" s2="$2" sched1="$3" sched2="$4" test_name="$5"
    local t1 t2 diff

    t1=$(extract_hackbench_time "$s1")
    [ -z "$t1" ] && t1=$(extract_elapsed_time "$s1")
    t2=$(extract_hackbench_time "$s2")
    [ -z "$t2" ] && t2=$(extract_elapsed_time "$s2")

    if [ -n "$t1" ] && [ -n "$t2" ]; then
        diff=$(calculate_percentage "$t1" "$t2")
        if (( $(echo "$t1 < $t2" | bc -l) )); then
            print_better "${sched1}: ${t1}s vs ${sched2}: ${t2}s (${sched1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${sched1}: ${t1}s vs ${sched2}: ${t2}s (${sched1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for $test_name"
    fi
}

compare_responsiveness() {
    local f1="$1" f2="$2" s1 s2
    s1=$(extract_scheduler_type "$f1")
    s2=$(extract_scheduler_type "$f2")

    print_header "RESPONSIVENESS COMPARISON: ${s1} vs ${s2}"
    echo -e "${B}${s1}:${R} $(basename "$f1")"
    echo -e "${B}${s2}:${R} $(basename "$f2")"
    echo ""

    # Test 1: Response under load
    echo -e "${B}Test 1: Response Under Load${R}"
    compare_test_time "$(extract_test_section "$f1" "1" 10)" "$(extract_test_section "$f2" "1" 10)" "$s1" "$s2" "Test 1"
    echo ""

    # Test 2: Context switch latency
    echo -e "${B}Test 2: Context Switch Latency${R}"
    compare_test_time "$(extract_test_section "$f1" "2" 10)" "$(extract_test_section "$f2" "2" 10)" "$s1" "$s2" "Test 2"
    echo ""

    # Test 3: Wake-up latency (cyclictest)
    echo -e "${B}Test 3: Wake-up Latency (cyclictest)${R}"
    local s1=$(extract_test_section "$f1" "3" 5) s2=$(extract_test_section "$f2" "3" 5)
    local min1 avg1 max1 min2 avg2 max2
    min1=$(extract_cyclictest_metrics "$s1" "Min"); avg1=$(extract_cyclictest_metrics "$s1" "Avg"); max1=$(extract_cyclictest_metrics "$s1" "Max")
    min2=$(extract_cyclictest_metrics "$s2" "Min"); avg2=$(extract_cyclictest_metrics "$s2" "Avg"); max2=$(extract_cyclictest_metrics "$s2" "Max")

    [ -n "$min1" ] && [ -n "$min2" ] && {
        local diff=$(calculate_percentage "$min1" "$min2")
        if (( $(echo "$min1 < $min2" | bc -l) )); then
            print_better "${s1} Min: ${min1}μs vs ${s2} Min: ${min2}μs (${s1} is ${diff}% lower)" "Lower is better"
        else
            print_worse "${s1} Min: ${min1}μs vs ${s2} Min: ${min2}μs (${s1} is ${diff}% higher)" "Lower is better"
        fi
    }
    [ -n "$avg1" ] && [ -n "$avg2" ] && {
        local diff=$(calculate_percentage "$avg1" "$avg2")
        if (( $(echo "$avg1 < $avg2" | bc -l) )); then
            print_better "${s1} Avg: ${avg1}μs vs ${s2} Avg: ${avg2}μs (${s1} is ${diff}% lower)" "Lower is better"
        else
            print_worse "${s1} Avg: ${avg1}μs vs ${s2} Avg: ${avg2}μs (${s1} is ${diff}% higher)" "Lower is better"
        fi
    }
    [ -n "$max1" ] && [ -n "$max2" ] && {
        local diff=$(calculate_percentage "$max1" "$max2")
        if (( $(echo "$max1 < $max2" | bc -l) )); then
            print_better "${s1} Max: ${max1}μs vs ${s2} Max: ${max2}μs (${s1} is ${diff}% lower)" "Lower is better"
        else
            print_worse "${s1} Max: ${max1}μs vs ${s2} Max: ${max2}μs (${s1} is ${diff}% higher)" "Lower is better"
        fi
    }
    [ -z "$min1" ] && [ -z "$avg1" ] && [ -z "$max1" ] && print_warning "Could not extract cyclictest metrics"
    echo ""

    # Test 4: Interactive under mixed load
    echo -e "${B}Test 4: Interactive Under Mixed Load${R}"
    compare_test_time "$(extract_test_section "$f1" "4" 10)" "$(extract_test_section "$f2" "4" 10)" "$s1" "$s2" "Test 4"
}

compare_throughput() {
    local f1="$1" f2="$2" s1 s2
    s1=$(extract_scheduler_type "$f1")
    s2=$(extract_scheduler_type "$f2")

    print_header "THROUGHPUT & FAIRNESS COMPARISON: ${s1} vs ${s2}"
    echo -e "${B}${s1}:${R} $(basename "$f1")"
    echo -e "${B}${s2}:${R} $(basename "$f2")"
    echo ""

    # Test 1: Maximum CPU throughput
    echo -e "${B}Test 1: Maximum CPU Throughput${R}"
    local ops1=$(extract_bogo_ops "$f1") ops2=$(extract_bogo_ops "$f2")
    if [ -n "$ops1" ] && [ -n "$ops2" ]; then
        local diff=$(calculate_percentage "$ops1" "$ops2")
        if (( $(echo "$ops1 > $ops2" | bc -l) )); then
            print_better "${s1}: ${ops1} vs ${s2}: ${ops2} ops/s (${s1} is ${diff}% higher)" "Higher is better"
        else
            print_worse "${s1}: ${ops1} vs ${s2}: ${ops2} ops/s (${s1} is ${diff}% lower)" "Higher is better"
        fi
    else
        print_warning "Could not extract bogo ops/s values"
    fi
    echo ""

    # Test 2: Server workload
    echo -e "${B}Test 2: Server Workload${R}"
    compare_test_time "$(extract_test_section "$f1" "2" 20)" "$(extract_test_section "$f2" "2" 20)" "$s1" "$s2" "Test 2"
    echo ""

    # Test 3: Fairness
    echo -e "${B}Test 3: CPU Time Fairness${R}"
    local std1=$(extract_stddev "$f1") std2=$(extract_stddev "$f2")
    if [ -n "$std1" ] && [ -n "$std2" ]; then
        local diff=$(calculate_percentage "$std1" "$std2")
        if (( $(echo "$std1 < $std2" | bc -l) )); then
            print_better "${s1}: ${std1} vs ${s2}: ${std2} (${s1} is ${diff}% lower)" "Lower StdDev = more fair"
        else
            print_worse "${s1}: ${std1} vs ${s2}: ${std2} (${s1} is ${diff}% higher)" "Lower StdDev = more fair"
        fi
    else
        print_warning "Could not extract standard deviation values"
    fi
    echo ""

    # Test 4: Sustained throughput
    echo -e "${B}Test 4: Sustained Throughput (sysbench)${R}"
    local ev1=$(extract_sysbench_events "$f1") ev2=$(extract_sysbench_events "$f2")
    if [ -n "$ev1" ] && [ -n "$ev2" ]; then
        local diff=$(calculate_percentage "$ev1" "$ev2")
        if (( $(echo "$ev1 > $ev2" | bc -l) )); then
            print_better "${s1}: ${ev1} vs ${s2}: ${ev2} events/s (${s1} is ${diff}% higher)" "Higher is better"
        else
            print_worse "${s1}: ${ev1} vs ${s2}: ${ev2} events/s (${s1} is ${diff}% lower)" "Higher is better"
        fi
    else
        print_warning "Could not extract sysbench events per second"
    fi
    echo ""

    # Test 5: Multi-process throughput
    echo -e "${B}Test 5: Multi-Process Throughput${R}"
    compare_test_time "$(extract_test_section "$f1" "5" 20)" "$(extract_test_section "$f2" "5" 20)" "$s1" "$s2" "Test 5"
}

detect_file_type() {
    local f="$1"
    echo "$f" | grep -qi "responsiveness" && echo "responsiveness" && return
    echo "$f" | grep -qi "throughput" && echo "throughput" && return
    echo "unknown"
}

main() {
    local f1="" f2="" type=""

    # Parse arguments
    case $# in
        2) f1="$1"; f2="$2" ;;
        1) if [ "$1" = "responsiveness" ] || [ "$1" = "throughput" ]; then type="$1"
           else print_error "Invalid argument: $1"; exit 1; fi ;;
        0) type="auto" ;;
        *) print_error "Invalid arguments"; exit 1 ;;
    esac

    # Auto-detect files
    if [ -z "$f1" ] || [ -z "$f2" ]; then
        print_info "Auto-detecting latest benchmark files..."

        if [ "$type" = "responsiveness" ] || ([ "$type" = "auto" ] && [ -z "$f1" ]); then
            local rb=$(find_latest_file "responsiveness_BORE")
            local rd=$(find_latest_file "responsiveness_DEFAULT")
            [ -n "$rb" ] && [ -n "$rd" ] && { f1="$rd"; f2="$rb"; type="responsiveness"; }
        fi

        if [ "$type" = "throughput" ] || ([ "$type" = "auto" ] && [ -z "$f1" ]); then
            local tb=$(find_latest_file "throughput_BORE")
            local td=$(find_latest_file "throughput_DEFAULT")
            [ -n "$tb" ] && [ -n "$td" ] && { f1="$td"; f2="$tb"; type="throughput"; }
        fi

        [ -z "$f1" ] || [ -z "$f2" ] && { print_error "Could not find matching benchmark files"; exit 1; }
    fi

    # Validate files
    [ ! -f "$f1" ] && { print_error "File not found: $f1"; exit 1; }
    [ ! -f "$f2" ] && { print_error "File not found: $f2"; exit 1; }

    # Check file types match
    local t1=$(detect_file_type "$f1") t2=$(detect_file_type "$f2")
    [ "$t1" != "$t2" ] && { print_error "Files are of different types"; exit 1; }

    # Check bc
    command -v bc &> /dev/null || { print_error "bc is required"; exit 1; }

    # Compare
    [ "$t1" = "responsiveness" ] && compare_responsiveness "$f1" "$f2"
    [ "$t1" = "throughput" ] && compare_throughput "$f1" "$f2"

    echo ""; print_header "COMPARISON COMPLETE"
    print_info "For detailed results, check the individual benchmark files"
}

main "$@"
exit 0
