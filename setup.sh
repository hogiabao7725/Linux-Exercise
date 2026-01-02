#!/bin/bash
################################################################################
# setup.sh
#
# Purpose: Install all required dependencies for benchmark scripts
#          Supports: Ubuntu (apt) and CachyOS (pacman)
#
# Usage: ./setup.sh
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

check_command() {
    command -v "$1" &> /dev/null
}

detect_package_manager() {
    if check_command apt-get; then
        echo "apt"
    elif check_command pacman; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_package_apt() {
    local package=$1
    print_info "Installing $package..."
    sudo apt-get update -qq
    sudo apt-get install -y "$package" 2>&1 | grep -v "^\(Reading\|Building\|Get\)" || true
}

install_package_pacman() {
    local package=$1
    print_info "Installing $package..."
    sudo pacman -S --noconfirm "$package" 2>&1 | grep -v "^\(::\|resolving\|looking\)" || true
}

check_and_install() {
    local tool=$1
    local package_apt=$2
    local package_pacman=$3
    local package_name=${4:-$tool}
    
    if check_command "$tool"; then
        print_success "$tool is already installed"
        return 0
    fi
    
    print_warning "$tool not found, installing $package_name..."
    
    case "$PKG_MANAGER" in
        apt)
            if install_package_apt "$package_apt"; then
                if check_command "$tool"; then
                    print_success "$tool installed successfully"
                    return 0
                else
                    print_error "Failed to install $tool"
                    return 1
                fi
            else
                print_error "Failed to install $package_name"
                return 1
            fi
            ;;
        pacman)
            if install_package_pacman "$package_pacman"; then
                if check_command "$tool"; then
                    print_success "$tool installed successfully"
                    return 0
                else
                    print_error "Failed to install $tool"
                    return 1
                fi
            else
                print_error "Failed to install $package_name"
                return 1
            fi
            ;;
        *)
            print_error "Unknown package manager"
            return 1
            ;;
    esac
}

check_sudo() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    fi
    
    if ! check_command sudo; then
        print_error "sudo is not available and script is not running as root"
        print_info "Please run as root or install sudo"
        return 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        print_info "This script requires sudo privileges"
        print_info "You may be prompted for your password"
    fi
}

################################################################################
# MAIN PROGRAM
################################################################################

main() {
    print_header "BENCHMARK SETUP SCRIPT"
    
    echo -e "${COLOR_BOLD}Detecting system configuration...${COLOR_RESET}"
    
    # Detect package manager
    PKG_MANAGER=$(detect_package_manager)
    
    if [ "$PKG_MANAGER" = "unknown" ]; then
        print_error "Could not detect package manager"
        print_info "Supported distributions: Ubuntu (apt) and CachyOS (pacman)"
        exit 1
    fi
    
    print_success "Detected package manager: $PKG_MANAGER"
    
    # Check sudo/root
    if ! check_sudo; then
        exit 1
    fi
    
    echo ""
    print_header "INSTALLING DEPENDENCIES"
    
    local failed_packages=()
    
    # Core dependencies
    echo -e "${COLOR_BOLD}Core Tools:${COLOR_RESET}"
    
    check_and_install "stress-ng" "stress-ng" "stress-ng" "stress-ng" || failed_packages+=("stress-ng")
    check_and_install "hackbench" "hackbench" "linux-tools" "hackbench" || failed_packages+=("hackbench")
    check_and_install "cyclictest" "rt-tests" "rt-tests" "rt-tests" || failed_packages+=("rt-tests")
    check_and_install "sysbench" "sysbench" "sysbench" "sysbench" || failed_packages+=("sysbench")
    check_and_install "python3" "python3" "python" "python3" || failed_packages+=("python3")
    check_and_install "bc" "bc" "bc" "bc" || failed_packages+=("bc")
    
    echo ""
    print_header "VERIFICATION"
    
    # Verify all tools
    local all_ok=true
    local tools=("stress-ng" "hackbench" "cyclictest" "sysbench" "python3" "bc")
    
    for tool in "${tools[@]}"; do
        if check_command "$tool"; then
            local version=""
            case "$tool" in
                stress-ng)
                    version=$(stress-ng --version 2>&1 | head -1 | cut -d' ' -f2 || echo "unknown")
                    ;;
                python3)
                    version=$(python3 --version 2>&1 | cut -d' ' -f2 || echo "unknown")
                    ;;
                bc)
                    version=$(bc --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
                    ;;
                sysbench)
                    version=$(sysbench --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
                    ;;
                *)
                    version="installed"
                    ;;
            esac
            print_success "$tool (version: $version)"
        else
            print_error "$tool is not available"
            all_ok=false
        fi
    done
    
    echo ""
    print_header "SETUP SUMMARY"
    
    if [ ${#failed_packages[@]} -gt 0 ]; then
        print_warning "Some packages failed to install:"
        for pkg in "${failed_packages[@]}"; do
            echo -e "  ${COLOR_YELLOW}- $pkg${COLOR_RESET}"
        done
        echo ""
        print_info "You may need to install them manually"
    fi
    
    if [ "$all_ok" = true ]; then
        print_success "All required tools are installed and ready!"
        echo ""
        print_info "You can now run the benchmark scripts:"
        echo -e "  ${COLOR_CYAN}./test_1.sh${COLOR_RESET} - Responsiveness benchmark"
        echo -e "  ${COLOR_CYAN}./test_2.sh${COLOR_RESET} - Throughput & Fairness benchmark"
    else
        print_error "Some tools are missing. Please install them manually."
        exit 1
    fi
}

################################################################################
# ENTRY POINT
################################################################################

main
exit 0
