#!/bin/bash
# setup.sh - Install dependencies for benchmark scripts
# Supports: Ubuntu (apt) and CachyOS (pacman)

set -euo pipefail

# Colors
readonly R='\033[0m' B='\033[1m'
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

check_command() { command -v "$1" &> /dev/null; }

detect_package_manager() {
    check_command apt-get && { echo "apt"; return; }
    check_command pacman && { echo "pacman"; return; }
    echo "unknown"
}

install_package_apt() {
    local pkg="$1"
    print_info "Installing $pkg..."
    sudo apt-get update -qq
    sudo apt-get install -y "$pkg" 2>&1 | grep -v "^\(Reading\|Building\|Get\)" || true
}

install_package_pacman() {
    local pkg="$1"
    print_info "Installing $pkg..."
    sudo pacman -S --noconfirm "$pkg" 2>&1 | grep -v "^\(::\|resolving\|looking\)" || true
}

check_and_install() {
    local tool="$1"
    local pkg_apt="$2"
    local pkg_pacman="$3"
    local pkg_name="${4:-$tool}"

    check_command "$tool" && { print_success "$tool is already installed"; return 0; }

    print_warning "$tool not found, installing $pkg_name..."

    case "$PKG_MANAGER" in
        apt) install_package_apt "$pkg_apt" && check_command "$tool" && { print_success "$tool installed"; return 0; } ;;
        pacman) install_package_pacman "$pkg_pacman" && check_command "$tool" && { print_success "$tool installed"; return 0; } ;;
        *) print_error "Unknown package manager"; return 1 ;;
    esac

    print_error "Failed to install $tool"
    return 1
}

check_sudo() {
    [ "$EUID" -eq 0 ] && return 0
    check_command sudo || { print_error "sudo not available"; return 1; }
    sudo -n true 2>/dev/null || print_info "This script requires sudo privileges"
}

main() {
    print_header "BENCHMARK SETUP SCRIPT"

    echo -e "${B}Detecting system configuration...${R}"
    PKG_MANAGER=$(detect_package_manager)

    [ "$PKG_MANAGER" = "unknown" ] && {
        print_error "Could not detect package manager"
        print_info "Supported: Ubuntu (apt) and CachyOS (pacman)"
        exit 1
    }

    print_success "Detected package manager: $PKG_MANAGER"
    check_sudo || exit 1

    echo ""
    print_header "INSTALLING DEPENDENCIES"

    local failed=()
    echo -e "${B}Core Tools:${R}"

    check_and_install "stress-ng" "stress-ng" "stress-ng" || failed+=("stress-ng")
    check_and_install "hackbench" "hackbench" "linux-tools" || failed+=("hackbench")
    check_and_install "cyclictest" "rt-tests" "rt-tests" || failed+=("rt-tests")
    check_and_install "sysbench" "sysbench" "sysbench" || failed+=("sysbench")
    check_and_install "python3" "python3" "python" || failed+=("python3")
    check_and_install "bc" "bc" "bc" || failed+=("bc")

    echo ""
    print_header "VERIFICATION"

    local all_ok=true
    local tools=("stress-ng" "hackbench" "cyclictest" "sysbench" "python3" "bc")

    for tool in "${tools[@]}"; do
        if check_command "$tool"; then
            local version="installed"
            case "$tool" in
                stress-ng) version=$(stress-ng --version 2>&1 | head -1 | cut -d' ' -f2 || echo "unknown") ;;
                python3) version=$(python3 --version 2>&1 | cut -d' ' -f2 || echo "unknown") ;;
                bc) version=$(bc --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown") ;;
                sysbench) version=$(sysbench --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown") ;;
            esac
            print_success "$tool (version: $version)"
        else
            print_error "$tool is not available"
            all_ok=false
        fi
    done

    echo ""
    print_header "SETUP SUMMARY"

    [ ${#failed[@]} -gt 0 ] && {
        print_warning "Some packages failed to install:"
        for pkg in "${failed[@]}"; do echo -e "  ${YELLOW}- $pkg${R}"; done
        echo ""; print_info "You may need to install them manually"
    }

    if [ "$all_ok" = true ]; then
        print_success "All required tools are installed and ready!"
        echo ""
        print_info "You can now run the benchmark scripts:"
        echo -e "  ${CYAN}./responsiveness.sh${R} - Responsiveness benchmark"
        echo -e "  ${CYAN}./throughput.sh${R} - Throughput & Fairness benchmark"
    else
        print_error "Some tools are missing. Please install them manually."
        exit 1
    fi
}

main
