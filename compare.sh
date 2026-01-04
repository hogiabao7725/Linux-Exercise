#!/bin/bash
# compare.sh - Compare benchmark results between BORE and DEFAULT schedulers
# Usage: ./compare.sh [responsiveness|throughput] | ./compare.sh [file1] [file2]

set -euo pipefail

# ============================================================================
# Colors & Print Functions
# ============================================================================
readonly R='\033[0m' B='\033[1m'
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' CYAN='\033[0;36m'
print_error() { echo -e "${RED}✗${R} ${RED}$1${R}"; }
print_warning() { echo -e "${YELLOW}⚠${R} ${YELLOW}$1${R}"; }
print_info() { echo -e "${CYAN}ℹ${R} $1"; }
print_header() {
    echo ""; echo -e "${B}${BLUE}================================================================"
    echo -e "$1"; echo -e "================================================================${R}"
}
print_better() { echo -e "  ${GREEN}→ $2: $1${R}"; }
print_worse() { echo -e "  ${RED}→ $2: $1${R}"; }

# ============================================================================
# Utility Functions
# ============================================================================
find_latest_file() { ls -t ${1}*.txt 2>/dev/null | head -1; }
extract_scheduler_type() {
    echo "$1" | grep -qi "BORE" && echo "BORE" && return
    echo "$1" | grep -qi "DEFAULT" && echo "DEFAULT" && return
    echo "UNKNOWN"
}
extract_test_section() { grep -A "${3:-20}" "TEST $2:" "$1" 2>/dev/null || echo ""; }
extract_number() { echo "$1" | grep -oE "$2" | grep -oE '[0-9]+\.?[0-9]*' | head -1; }
extract_time() {
    local time=$(extract_number "$1" "Time: [0-9]+\\.[0-9]+")
    [ -z "$time" ] && time=$(extract_number "$1" "Elapsed time: [0-9]+\\.[0-9]+")
    echo "$time"
}
extract_cyclictest_metric() { echo "$1" | grep -oE "${2}:\s*[0-9]+" | grep -oE "[0-9]+" | head -1; }
extract_bogo_ops() {
    local section=$(extract_test_section "$1" "1" 40)
    local result=$(extract_number "$section" "bogo[-\s]?ops?/s")
    [ -z "$result" ] && result=$(extract_number "$(grep -iE "bogo[-\s]?ops?" "$1" 2>/dev/null)" "[0-9]+\\.[0-9]*")
    echo "$result"
}
extract_stddev() { grep "Standard deviation:" "$1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1; }
extract_sysbench_events() {
    local section=$(extract_test_section "$1" "4" 30)
    local result=$(extract_number "$section" "events per second")
    [ -z "$result" ] && result=$(extract_number "$(grep -A 30 "TEST 4:" "$1" 2>/dev/null)" "events.*second")
    echo "$result"
}
calculate_percentage() {
    local v1="$1" v2="$2"
    [ -z "$v1" ] || [ -z "$v2" ] || [ "$v2" = "0" ] && { echo "N/A"; return; }
    echo "scale=2; ($v1 - $v2) / $v2 * 100" | bc 2>/dev/null
}

# ============================================================================
# Comparison Functions
# ============================================================================
compare_time() {
    local s1="$1" s2="$2" sched1="$3" sched2="$4" test_name="$5"
    local t1=$(extract_time "$s1") t2=$(extract_time "$s2")
    if [ -n "$t1" ] && [ -n "$t2" ]; then
        local diff=$(calculate_percentage "$t1" "$t2")
        if (( $(echo "$t1 < $t2" | bc -l) )); then
            print_better "${sched1}: ${t1}s vs ${sched2}: ${t2}s (${sched1} is ${diff}% faster)" "Lower is better"
        else
            print_worse "${sched1}: ${t1}s vs ${sched2}: ${t2}s (${sched1} is ${diff}% slower)" "Lower is better"
        fi
    else
        print_warning "Could not extract time values for $test_name"
    fi
}

compare_value() {
    local v1="$1" v2="$2" sched1="$3" sched2="$4" unit="$5" test_name="$6"
    if [ -n "$v1" ] && [ -n "$v2" ]; then
        local diff=$(calculate_percentage "$v1" "$v2")
        if (( $(echo "$v1 > $v2" | bc -l) )); then
            print_better "${sched1}: ${v1} vs ${sched2}: ${v2} ${unit} (${sched1} is ${diff}% higher)" "Higher is better"
        else
            print_worse "${sched1}: ${v1} vs ${sched2}: ${v2} ${unit} (${sched1} is ${diff}% lower)" "Higher is better"
        fi
    else
        print_warning "Could not extract values for $test_name"
    fi
}

compare_cyclictest_metric() {
    local s1="$1" s2="$2" sched1="$3" sched2="$4" metric="$5"
    local v1=$(extract_cyclictest_metric "$s1" "$metric")
    local v2=$(extract_cyclictest_metric "$s2" "$metric")
    if [ -n "$v1" ] && [ -n "$v2" ]; then
        local diff=$(calculate_percentage "$v1" "$v2")
        if (( $(echo "$v1 < $v2" | bc -l) )); then
            print_better "${sched1} ${metric}: ${v1}μs vs ${sched2} ${metric}: ${v2}μs (${sched1} is ${diff}% lower)" "Lower is better"
        else
            print_worse "${sched1} ${metric}: ${v1}μs vs ${sched2} ${metric}: ${v2}μs (${sched1} is ${diff}% higher)" "Lower is better"
        fi
    fi
}

# ============================================================================
# Comparison Functions
# ============================================================================
compare_responsiveness() {
    local f1="$1" f2="$2" s1=$(extract_scheduler_type "$f1") s2=$(extract_scheduler_type "$f2")
    print_header "RESPONSIVENESS COMPARISON: ${s1} vs ${s2}"
    echo -e "${B}${s1}:${R} $(basename "$f1")"
    echo -e "${B}${s2}:${R} $(basename "$f2")"
    echo ""
    
    echo -e "${B}Test 1: Response Under Load${R}"
    compare_time "$(extract_test_section "$f1" "1" 10)" "$(extract_test_section "$f2" "1" 10)" "$s1" "$s2" "Test 1"
    echo ""
    
    echo -e "${B}Test 2: Context Switch Latency${R}"
    compare_time "$(extract_test_section "$f1" "2" 10)" "$(extract_test_section "$f2" "2" 10)" "$s1" "$s2" "Test 2"
    echo ""
    
    echo -e "${B}Test 3: Wake-up Latency (cyclictest)${R}"
    local sec1=$(extract_test_section "$f1" "3" 5) sec2=$(extract_test_section "$f2" "3" 5)
    compare_cyclictest_metric "$sec1" "$sec2" "$s1" "$s2" "Min"
    compare_cyclictest_metric "$sec1" "$sec2" "$s1" "$s2" "Avg"
    compare_cyclictest_metric "$sec1" "$sec2" "$s1" "$s2" "Max"
    [ -z "$(extract_cyclictest_metric "$sec1" "Min")" ] && print_warning "Could not extract cyclictest metrics"
    echo ""
    
    echo -e "${B}Test 4: Interactive Under Mixed Load${R}"
    compare_time "$(extract_test_section "$f1" "4" 10)" "$(extract_test_section "$f2" "4" 10)" "$s1" "$s2" "Test 4"
}

compare_throughput() {
    local f1="$1" f2="$2" s1=$(extract_scheduler_type "$f1") s2=$(extract_scheduler_type "$f2")
    print_header "THROUGHPUT & FAIRNESS COMPARISON: ${s1} vs ${s2}"
    echo -e "${B}${s1}:${R} $(basename "$f1")"
    echo -e "${B}${s2}:${R} $(basename "$f2")"
    echo ""
    
    echo -e "${B}Test 1: Maximum CPU Throughput${R}"
    compare_value "$(extract_bogo_ops "$f1")" "$(extract_bogo_ops "$f2")" "$s1" "$s2" "ops/s" "Test 1"
    echo ""
    
    echo -e "${B}Test 2: Server Workload${R}"
    compare_time "$(extract_test_section "$f1" "2" 20)" "$(extract_test_section "$f2" "2" 20)" "$s1" "$s2" "Test 2"
    echo ""
    
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
    
    echo -e "${B}Test 4: Sustained Throughput (sysbench)${R}"
    compare_value "$(extract_sysbench_events "$f1")" "$(extract_sysbench_events "$f2")" "$s1" "$s2" "events/s" "Test 4"
    echo ""
    
    echo -e "${B}Test 5: Multi-Process Throughput${R}"
    compare_time "$(extract_test_section "$f1" "5" 20)" "$(extract_test_section "$f2" "5" 20)" "$s1" "$s2" "Test 5"
}

# ============================================================================
# Main Function
# ============================================================================
detect_file_type() {
    echo "$1" | grep -qi "responsiveness" && echo "responsiveness" && return
    echo "$1" | grep -qi "throughput" && echo "throughput" && return
    echo "unknown"
}

auto_detect_files() {
    local type="$1"
    if [ "$type" = "responsiveness" ]; then
        local rb=$(find_latest_file "responsiveness_BORE")
        local rd=$(find_latest_file "responsiveness_DEFAULT")
        [ -n "$rb" ] && [ -n "$rd" ] && echo "$rd|$rb" && return 0
    elif [ "$type" = "throughput" ]; then
        local tb=$(find_latest_file "throughput_BORE")
        local td=$(find_latest_file "throughput_DEFAULT")
        [ -n "$tb" ] && [ -n "$td" ] && echo "$td|$tb" && return 0
    fi
    return 1
}

main() {
    local f1="" f2="" type=""
    
    # Parse arguments
    case $# in
        2) f1="$1"; f2="$2" ;;
        1) [ "$1" = "responsiveness" ] || [ "$1" = "throughput" ] && type="$1" || { print_error "Invalid argument: $1"; exit 1; } ;;
        *) print_error "Usage: ./compare.sh [responsiveness|throughput] | ./compare.sh [file1] [file2]"; exit 1 ;;
    esac
    
    command -v bc &> /dev/null || { print_error "bc is required"; exit 1; }
    
    # Auto-detect files if type specified
    if [ -n "$type" ]; then
        print_info "Auto-detecting latest benchmark files..."
        local result=$(auto_detect_files "$type")
        [ $? -ne 0 ] && { print_error "Could not find matching benchmark files for $type"; exit 1; }
        f1=$(echo "$result" | cut -d'|' -f1)
        f2=$(echo "$result" | cut -d'|' -f2)
    fi
    
    # Validate files
    [ ! -f "$f1" ] && { print_error "File not found: $f1"; exit 1; }
    [ ! -f "$f2" ] && { print_error "File not found: $f2"; exit 1; }
    
    # Detect and compare
    local t1=$(detect_file_type "$f1") t2=$(detect_file_type "$f2")
    [ "$t1" != "$t2" ] && { print_error "Files are of different types"; exit 1; }
    
    case "$t1" in
        responsiveness) compare_responsiveness "$f1" "$f2" ;;
        throughput) compare_throughput "$f1" "$f2" ;;
        *) print_error "Unknown file type"; exit 1 ;;
    esac
    
    echo ""
    print_header "COMPARISON COMPLETE"
    print_info "For detailed results, check the individual benchmark files"
}

main "$@"
exit 0
