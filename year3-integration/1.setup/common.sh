#!/bin/bash
# ============================================================================
# KETI AI Storage Platform - Common Functions
# Year 3 Integration Setup Scripts
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log directory
LOG_DIR="/var/log/keti-setup"
mkdir -p "$LOG_DIR"

# Get current script name for logging
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"

# ============================================================================
# Logging Functions
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Write to log file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Print to console with color
    case "$level" in
        INFO)
            echo -e "${GREEN}[$timestamp]${NC} ${BLUE}[INFO]${NC} $message"
            ;;
        WARN)
            echo -e "${GREEN}[$timestamp]${NC} ${YELLOW}[WARN]${NC} $message"
            ;;
        ERROR)
            echo -e "${GREEN}[$timestamp]${NC} ${RED}[ERROR]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[$timestamp]${NC} ${GREEN}[SUCCESS]${NC} $message"
            ;;
        STEP)
            echo -e "${GREEN}[$timestamp]${NC} ${PURPLE}[STEP]${NC} $message"
            ;;
        *)
            echo -e "${GREEN}[$timestamp]${NC} $message"
            ;;
    esac
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_step() { log "STEP" "$@"; }

# ============================================================================
# Header/Footer Functions
# ============================================================================

print_header() {
    local title="$1"
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${PURPLE}$title${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  KETI AI Storage Platform - Year 3 Integration"
    echo -e "${CYAN}║${NC}  Log file: $LOG_FILE"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_info "========== Starting: $title =========="
}

print_footer() {
    local status="$1"
    local title="$2"

    echo ""
    if [ "$status" = "success" ]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✓ $title - COMPLETED SUCCESSFULLY${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
        log_success "========== Completed: $title =========="
    else
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ✗ $title - FAILED${NC}"
        echo -e "${RED}║  Check log: $LOG_FILE${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
        log_error "========== Failed: $title =========="
    fi
    echo ""
}

# ============================================================================
# Execution Functions
# ============================================================================

run_cmd() {
    local description="$1"
    shift
    local cmd="$*"

    log_step "$description"
    log_info "Running: $cmd"

    # Run command and capture output
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        log_success "$description - OK"
        return 0
    else
        log_error "$description - FAILED"
        log_error "Command: $cmd"
        return 1
    fi
}

run_cmd_allow_fail() {
    local description="$1"
    shift
    local cmd="$*"

    log_step "$description"
    log_info "Running: $cmd"

    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        log_success "$description - OK"
    else
        log_warn "$description - FAILED (continuing anyway)"
    fi
    return 0
}

# ============================================================================
# Check Functions
# ============================================================================

check_command() {
    local cmd="$1"
    if command -v "$cmd" &> /dev/null; then
        log_info "Found: $cmd ($(command -v "$cmd"))"
        return 0
    else
        log_warn "Not found: $cmd"
        return 1
    fi
}

check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        log_info "Service running: $service"
        return 0
    else
        log_warn "Service not running: $service"
        return 1
    fi
}

wait_for_pods() {
    local namespace="$1"
    local timeout="${2:-300}"
    local label="${3:-}"

    log_info "Waiting for pods in namespace '$namespace' to be ready (timeout: ${timeout}s)..."

    local cmd="kubectl wait --for=condition=Ready pods --all -n $namespace --timeout=${timeout}s"
    if [ -n "$label" ]; then
        cmd="kubectl wait --for=condition=Ready pods -l $label -n $namespace --timeout=${timeout}s"
    fi

    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        log_success "All pods ready in namespace '$namespace'"
        return 0
    else
        log_error "Timeout waiting for pods in namespace '$namespace'"
        kubectl get pods -n "$namespace" >> "$LOG_FILE" 2>&1
        return 1
    fi
}

# ============================================================================
# Utility Functions
# ============================================================================

confirm_continue() {
    local message="${1:-Continue?}"
    read -p "$message [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

get_node_role() {
    if kubectl get nodes 2>/dev/null | grep -q "control-plane\|master"; then
        echo "master"
    else
        echo "worker"
    fi
}

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID $VERSION_ID"
    else
        echo "unknown"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# ============================================================================
# Summary Function
# ============================================================================

print_summary() {
    local title="$1"
    shift
    local items=("$@")

    echo ""
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} ${PURPLE}$title${NC}"
    echo -e "${CYAN}├────────────────────────────────────────────────────────────────────┤${NC}"

    for item in "${items[@]}"; do
        echo -e "${CYAN}│${NC}   $item"
    done

    echo -e "${CYAN}└────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}
