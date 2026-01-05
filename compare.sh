#!/bin/bash
# compare.sh - Compare benchmark results between BORE and DEFAULT schedulers
# Usage: ./compare.sh [responsiveness|throughput] | ./compare.sh [file1] [file2]

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m'
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m'

# Print functions
print_error() { echo -e "${RED}✗${R} $1"; }
print_warning() { echo -e "${YELLOW}⚠${R} $1"; }
print_header() {
    echo ""
    echo -e "${B}${BLUE}================================================================"
    echo -e "$1"
    echo -e "================================================================${R}"
}
print_better() { echo -e "  ${GREEN}→ $2: $1${R}"; }
print_worse() { echo -e "  ${RED}→ $2: $1${R}"; }

# Utility functions
find_latest_file() { ls -t ${1}*.txt 2>/dev/null | head -1; }
extract_scheduler() { echo "$1" | grep -qi "BORE" && echo "BORE" || echo "DEFAULT"; }
extract_test_section() { grep -A "${3:-10}" "TEST $2:" "$1" 2>/dev/null || echo ""; }

# Extract values from files
extract_time() { echo "$1" | grep -oE "Average: [0-9]*\\.?[0-9]+" | grep -oE "[0-9]*\\.?[0-9]+" | head -1; }
extract_max_latency() { echo "$1" | grep -oE "Average Max Latency: [0-9]+\\.[0-9]+" | grep -oE "[0-9]+\\.[0-9]+" | head -1; }
extract_bogo_ops() {
    # New format: "Average execution time: Xs" (lower is better = higher throughput)
    local time=$(grep "Average execution time:" "$1" 2>/dev/null | grep -oE "[0-9]+\\.[0-9]+" | head -1)
    [ -n "$time" ] && echo "$time" || grep "Average bogo ops/s:" "$1" 2>/dev/null | grep -oE "[0-9]+\\.[0-9]+" | head -1
}
extract_stddev() { grep "StdDev:" "$1" 2>/dev/null | grep -oE "[0-9]*\\.?[0-9]+" | head -1; }
extract_sysbench() { grep "Average events per second:" "$1" 2>/dev/null | grep -oE "[0-9]+\\.[0-9]+" | head -1; }

calculate_percentage() {
    local v1="$1" v2="$2"
    [ -z "$v1" ] || [ -z "$v2" ] || [ "$v2" = "0" ] && { echo "N/A"; return; }
    echo "scale=2; ($v1 - $v2) / $v2 * 100" | bc 2>/dev/null
}

# Comparison functions
compare_time() {
    local s1="$1" s2="$2" sched1="$3" sched2="$4"
    local t1=$(extract_time "$s1") t2=$(extract_time "$s2")
    [ -z "$t1" ] || [ -z "$t2" ] && { print_warning "Could not extract time values"; return; }
    
    local diff=$(calculate_percentage "$t1" "$t2")
    if (( $(echo "$t1 < $t2" | bc -l) )); then
        print_better "${sched1}: ${t1}s vs ${sched2}: ${t2}s (${sched1} is ${diff}% faster)" "Lower is better"
    else
        print_worse "${sched1}: ${t1}s vs ${sched2}: ${t2}s (${sched1} is ${diff}% slower)" "Lower is better"
    fi
}

compare_value() {
    local v1="$1" v2="$2" sched1="$3" sched2="$4" unit="$5"
    [ -z "$v1" ] || [ -z "$v2" ] && { print_warning "Could not extract values"; return; }
    
    local diff=$(calculate_percentage "$v1" "$v2")
    if (( $(echo "$v1 > $v2" | bc -l) )); then
        print_better "${sched1}: ${v1} vs ${sched2}: ${v2} ${unit} (${sched1} is ${diff}% higher)" "Higher is better"
    else
        print_worse "${sched1}: ${v1} vs ${sched2}: ${v2} ${unit} (${sched1} is ${diff}% lower)" "Higher is better"
    fi
}

compare_latency() {
    local s1="$1" s2="$2" sched1="$3" sched2="$4"
    local v1=$(extract_max_latency "$s1") v2=$(extract_max_latency "$s2")
    [ -z "$v1" ] || [ -z "$v2" ] && { print_warning "Could not extract latency values"; return; }
    
    local diff=$(calculate_percentage "$v1" "$v2")
    if (( $(echo "$v1 < $v2" | bc -l) )); then
        print_better "${sched1}: ${v1}μs vs ${sched2}: ${v2}μs (${sched1} is ${diff}% lower)" "Lower is better"
    else
        print_worse "${sched1}: ${v1}μs vs ${sched2}: ${v2}μs (${sched1} is ${diff}% higher)" "Lower is better"
    fi
}

compare_stddev() {
    local std1="$1" std2="$2" sched1="$3" sched2="$4"
    [ -z "$std1" ] || [ -z "$std2" ] && { print_warning "Could not extract stddev values"; return; }
    
    local diff=$(calculate_percentage "$std1" "$std2")
    if (( $(echo "$std1 < $std2" | bc -l) )); then
        print_better "${sched1}: ${std1} vs ${sched2}: ${std2} (${sched1} is ${diff}% lower)" "Lower StdDev = more fair"
    else
        print_worse "${sched1}: ${std1} vs ${sched2}: ${std2} (${sched1} is ${diff}% higher)" "Lower StdDev = more fair"
    fi
}

# Comparison main functions
compare_responsiveness() {
    local f1="$1" f2="$2" s1=$(extract_scheduler "$f1") s2=$(extract_scheduler "$f2")
    print_header "RESPONSIVENESS COMPARISON: ${s1} vs ${s2}"
    echo -e "${B}${s1}:${R} $(basename "$f1")"
    echo -e "${B}${s2}:${R} $(basename "$f2")"
    echo ""
    
    echo -e "${B}Test 1: Response Under Load${R}"
    compare_time "$(extract_test_section "$f1" "1" 10)" "$(extract_test_section "$f2" "1" 10)" "$s1" "$s2"
    echo ""
    
    echo -e "${B}Test 2: Context Switch Latency${R}"
    compare_time "$(extract_test_section "$f1" "2" 10)" "$(extract_test_section "$f2" "2" 10)" "$s1" "$s2"
    echo ""
    
    echo -e "${B}Test 3: Wake-up Latency${R}"
    compare_latency "$(extract_test_section "$f1" "3" 5)" "$(extract_test_section "$f2" "3" 5)" "$s1" "$s2"
    echo ""
    
    echo -e "${B}Test 4: Interactive Under Mixed Load${R}"
    compare_time "$(extract_test_section "$f1" "4" 10)" "$(extract_test_section "$f2" "4" 10)" "$s1" "$s2"
}

compare_throughput() {
    local f1="$1" f2="$2" s1=$(extract_scheduler "$f1") s2=$(extract_scheduler "$f2")
    print_header "THROUGHPUT & FAIRNESS COMPARISON: ${s1} vs ${s2}"
    echo -e "${B}${s1}:${R} $(basename "$f1")"
    echo -e "${B}${s2}:${R} $(basename "$f2")"
    echo ""
    
    echo -e "${B}Test 1: Maximum CPU Throughput${R}"
    local t1=$(extract_bogo_ops "$f1") t2=$(extract_bogo_ops "$f2")
    # If it's execution time (contains decimal), lower is better. Otherwise it's ops/s, higher is better.
    if echo "$t1" | grep -qE "^[0-9]+\.[0-9]+$" && [ -n "$t1" ] && [ -n "$t2" ]; then
        compare_time "$(echo "Average: ${t1}s")" "$(echo "Average: ${t2}s")" "$s1" "$s2"
    else
        compare_value "$t1" "$t2" "$s1" "$s2" "ops/s"
    fi
    echo ""
    
    echo -e "${B}Test 2: Server Workload${R}"
    compare_time "$(extract_test_section "$f1" "2" 10)" "$(extract_test_section "$f2" "2" 10)" "$s1" "$s2"
    echo ""
    
    echo -e "${B}Test 3: CPU Time Fairness${R}"
    compare_stddev "$(extract_stddev "$f1")" "$(extract_stddev "$f2")" "$s1" "$s2"
    echo ""
    
    echo -e "${B}Test 4: Sustained Throughput${R}"
    compare_value "$(extract_sysbench "$f1")" "$(extract_sysbench "$f2")" "$s1" "$s2" "events/s"
    echo ""
    
    echo -e "${B}Test 5: Multi-Process Throughput${R}"
    compare_time "$(extract_test_section "$f1" "5" 10)" "$(extract_test_section "$f2" "5" 10)" "$s1" "$s2"
}

# Main
main() {
    local f1="" f2="" type=""
    
    case $# in
        2) f1="$1"; f2="$2" ;;
        1) [ "$1" = "responsiveness" ] || [ "$1" = "throughput" ] && type="$1" || { print_error "Invalid argument: $1"; exit 1; } ;;
        *) print_error "Usage: ./compare.sh [responsiveness|throughput] | ./compare.sh [file1] [file2]"; exit 1 ;;
    esac
    
    command -v bc &> /dev/null || { print_error "bc is required"; exit 1; }
    
    if [ -n "$type" ]; then
        if [ "$type" = "responsiveness" ]; then
            f1=$(find_latest_file "responsiveness_DEFAULT")
            f2=$(find_latest_file "responsiveness_BORE")
        else
            f1=$(find_latest_file "throughput_DEFAULT")
            f2=$(find_latest_file "throughput_BORE")
        fi
        [ -z "$f1" ] || [ -z "$f2" ] && { print_error "Could not find benchmark files"; exit 1; }
    fi
    
    [ ! -f "$f1" ] && { print_error "File not found: $f1"; exit 1; }
    [ ! -f "$f2" ] && { print_error "File not found: $f2"; exit 1; }
    
    local t1=$(echo "$f1" | grep -qi "responsiveness" && echo "responsiveness" || echo "throughput")
    local t2=$(echo "$f2" | grep -qi "responsiveness" && echo "responsiveness" || echo "throughput")
    [ "$t1" != "$t2" ] && { print_error "Files are of different types"; exit 1; }
    
    [ "$t1" = "responsiveness" ] && compare_responsiveness "$f1" "$f2" || compare_throughput "$f1" "$f2"
    
    echo ""
    print_header "COMPARISON COMPLETE"
}

main "$@"
