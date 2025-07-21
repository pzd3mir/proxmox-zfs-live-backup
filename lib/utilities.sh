#!/bin/bash
# lib/utilities.sh - Common utility functions for ZFS backup system

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging and output functions
log_message() {
    local log_file="${LOG_FILE:-/var/log/zfs-backup.log}"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

print_status() {
    echo -e "${GREEN}✅ $1${NC}"
    log_message "STATUS: $1"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
    log_message "WARNING: $1"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
    log_message "ERROR: $1"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_debug() {
    if [ "${DEBUG_MODE:-false}" = true ]; then
        echo -e "${CYAN}🐛 DEBUG: $1${NC}"
        log_message "DEBUG: $1"
    fi
}

print_main_header() {
    echo ""
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

print_section_header() {
    echo ""
    echo "$1"
    echo "$(echo "$1" | sed 's/./=/g')"
}

# Progress indicators
show_progress_spinner() {
    local pid=$1
    local message="$2"
    local spinner="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}${spinner:$i:1} $message${NC}"
        i=$(( (i+1) % ${#spinner} ))
        sleep 0.1
    done
    printf "\r"
}

show_countdown() {
    local seconds="$1"
    local message="$2"

    while [ $seconds -gt 0 ]; do
        printf "\r${CYAN}$message in %d seconds... (press any key to interrupt)${NC}" $seconds
        if read -t 1 -n 1 -s 2>/dev/null; then
            echo ""
            return 1  # User interrupted
        fi
        seconds=$((seconds - 1))
    done
    echo ""
    return 0  # Timeout reached
}

# Cleanup function
cleanup() {
    echo ""
    print_info "Cleaning up..."

    # Unmount any mounted backup targets
    if mountpoint -q "${TEMP_MOUNT:-/mnt/zfs-backup-temp}" 2>/dev/null; then
        print_info "Unmounting backup target..."
        umount "${TEMP_MOUNT:-/mnt/zfs-backup-temp}" 2>/dev/null || true
    fi

    # Clean up USB mount points
    for mount_point in /mnt/usb-backup-auto /mnt/usb-backup-*; do
        if [ -d "$mount_point" ] && mountpoint -q "$mount_point" 2>/dev/null; then
            print_info "Unmounting USB: $mount_point"
            umount "$mount_point" 2>/dev/null || true
        fi
    done

    # Remove snapshots if they exist and aren't needed
    if [ -n "${SNAPSHOT_NAME:-}" ] && [ "${KEEP_SNAPSHOT:-false}" != true ] && zfs list "$SNAPSHOT_NAME" >/dev/null 2>&1; then
        print_info "Removing snapshot: $SNAPSHOT_NAME"
        zfs destroy -r "$SNAPSHOT_NAME" 2>/dev/null || true
    fi

    # Clear sensitive variables
    ENCRYPTION_PASS=""
    NAS_PASSWORD=""

    # Remove temporary files
    rm -f /tmp/.nas-creds-* 2>/dev/null || true
    rm -f /tmp/.usb-backup-* 2>/dev/null || true

    print_info "Cleanup completed"
}

# Set up cleanup trap
setup_cleanup_trap() {
    trap cleanup EXIT INT TERM QUIT
}

# System requirement checks
check_system_requirements() {
    print_section_header "🔍 SYSTEM REQUIREMENTS CHECK"

    # Check if running as root (recommended)
    if [ "$EUID" -ne 0 ]; then
        print_warning "⚠️  Running as non-root user"
        print_info "Some features may not work properly. For system backups, run as root."
        echo ""
    else
        print_status "✅ Running with root privileges"
    fi

    print_info "🔍 Checking required packages..."

    local missing_packages=""
    local required_packages=(
        "zfsutils-linux:zfs"
        "gnupg:gpg"
        "cifs-utils:mount.cifs"
        "lsof:lsof"
        "gdisk:sgdisk"
    )

    for package_info in "${required_packages[@]}"; do
        local package_name="${package_info%:*}"
        local command_name="${package_info#*:}"

        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing_packages="$missing_packages $package_name"
            print_warning "Missing: $package_name"
        else
            print_debug "Found: $command_name"
        fi
    done

    if [ -n "$missing_packages" ]; then
        print_warning "Missing required packages:$missing_packages"
        if [ "$EUID" -eq 0 ]; then
            print_info "📦 Installing required packages..."
            if apt update >/dev/null 2>&1 && apt install -y $missing_packages >/dev/null 2>&1; then
                print_status "✅ All required packages installed"
            else
                print_error "❌ Failed to install packages"
                return 1
            fi
        else
            print_error "❌ Please install required packages: apt install$missing_packages"
            return 1
        fi
    else
        print_status "✅ All required packages are available"
    fi

    return 0
}

# ZFS pool validation
validate_zfs_pool() {
    print_section_header "📊 ZFS POOL VALIDATION"
    print_info "Validating ZFS pool: $ZFS_POOL"

    if ! zpool list "$ZFS_POOL" >/dev/null 2>&1; then
        print_error "❌ ZFS pool '$ZFS_POOL' not found"
        echo ""
        echo "Available pools:"
        if zpool list 2>/dev/null; then
            echo ""
            echo "To use a different pool: $0 --pool POOL_NAME"
        else
            echo "No ZFS pools found on this system"
        fi
        return 1
    fi

    # Check pool health
    local pool_health=$(zpool list -H -o health "$ZFS_POOL" 2>/dev/null)
    case "$pool_health" in
        "ONLINE")
            print_status "✅ ZFS pool '$ZFS_POOL' is healthy (ONLINE)"
            ;;
        "DEGRADED")
            print_warning "⚠️  ZFS pool '$ZFS_POOL' is DEGRADED but functional"
            ;;
        *)
            print_error "❌ ZFS pool '$ZFS_POOL' health: $pool_health"
            print_warning "Pool may not be suitable for backup"
            ;;
    esac

    # Show pool information
    local pool_size=$(zpool list -H -o size "$ZFS_POOL" 2>/dev/null)
    local pool_used=$(zpool list -H -o capacity "$ZFS_POOL" 2>/dev/null)
    print_info "Pool size: $pool_size | Used: $pool_used"

    return 0
}

# Snapshot management
create_backup_snapshot() {
    print_section_header "📸 SNAPSHOT CREATION"
    print_info "Creating ZFS snapshot for consistent backup..."

    local date=$(date +%Y%m%d-%H%M)
    local snapshot_name="$ZFS_POOL@backup-$date"

    # Check if snapshot already exists
    if zfs list "$snapshot_name" >/dev/null 2>&1; then
        print_status "Using existing ZFS snapshot: $snapshot_name"
        SNAPSHOT_NAME="$snapshot_name"
        return 0
    fi

    print_debug "Creating snapshot: $snapshot_name"
    if ! zfs snapshot -r "$snapshot_name" 2>/dev/null; then
        print_error "❌ Failed to create ZFS snapshot"
        print_info "Possible causes:"
        echo "• Insufficient pool space"
        echo "• Pool is read-only"
        echo "• Permission issues"
        echo "• Another backup process running"
        return 1
    fi

    SNAPSHOT_NAME="$snapshot_name"
    print_status "✅ Snapshot created: $SNAPSHOT_NAME"

    # Verify snapshot was created successfully
    if ! zfs list "$SNAPSHOT_NAME" >/dev/null 2>&1; then
        print_error "❌ Snapshot verification failed"
        return 1
    fi

    print_debug "Snapshot verified successfully"
    return 0
}

# File size and space utilities
format_bytes() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}B"
    elif [ $bytes -lt 1048576 ]; then
        echo "$((bytes / 1024))KB"
    elif [ $bytes -lt 1073741824 ]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

check_disk_space() {
    local path="$1"
    local required_gb="$2"

    local available_bytes=$(df -B1 "$path" 2>/dev/null | tail -1 | awk '{print $4}')
    local available_gb=$((available_bytes / 1073741824))

    if [ $available_gb -lt $required_gb ]; then
        print_error "Insufficient space: need ${required_gb}GB, have ${available_gb}GB"
        return 1
    fi

    print_info "Available space: ${available_gb}GB"
    return 0
}

# Process monitoring utilities
monitor_background_process() {
    local pid="$1"
    local description="$2"
    local file_to_monitor="$3"

    print_debug "Monitoring process PID: $pid ($description)"

    while kill -0 "$pid" 2>/dev/null; do
        if [ -n "$file_to_monitor" ] && [ -f "$file_to_monitor" ]; then
            local current_size=$(stat -c%s "$file_to_monitor" 2>/dev/null || echo 0)
            if [ "$current_size" -gt 0 ]; then
                local size_mb=$((current_size / 1048576))
                echo "$(date '+%H:%M:%S') - $description: ${size_mb}MB written..."
            fi
        else
            echo "$(date '+%H:%M:%S') - $description: Processing..."
        fi
        sleep 30
    done

    wait "$pid"
    local exit_code=$?
    print_debug "Process completed with exit code: $exit_code"
    return $exit_code
}

# Safe mount/unmount utilities
safe_mount() {
    local device="$1"
    local mount_point="$2"
    local mount_options="$3"

    print_debug "Attempting to mount $device to $mount_point"

    # Create mount point if it doesn't exist
    mkdir -p "$mount_point"

    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        print_warning "Mount point $mount_point is already in use"
        return 1
    fi

    # Try mounting with specified options
    if [ -n "$mount_options" ]; then
        if mount -o "$mount_options" "$device" "$mount_point" 2>/dev/null; then
            print_debug "Successfully mounted with options: $mount_options"
            return 0
        fi
    fi

    # Try basic mount
    if mount "$device" "$mount_point" 2>/dev/null; then
        print_debug "Successfully mounted with default options"
        return 0
    fi

    print_error "Failed to mount $device"
    return 1
}

safe_unmount() {
    local mount_point="$1"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        print_debug "Mount point $mount_point is not mounted"
        return 0
    fi

    print_debug "Unmounting $mount_point"

    # Sync first
    sync

    # Try normal unmount
    if umount "$mount_point" 2>/dev/null; then
        print_debug "Successfully unmounted $mount_point"
        return 0
    fi

    # Try lazy unmount as fallback
    print_warning "Normal unmount failed, trying lazy unmount"
    if umount -l "$mount_point" 2>/dev/null; then
        print_debug "Lazy unmount successful"
        return 0
    fi

    print_error "Failed to unmount $mount_point"
    return 1
}

# Network connectivity utilities
test_network_connectivity() {
    local host="$1"
    local timeout="${2:-10}"

    print_debug "Testing connectivity to $host (timeout: ${timeout}s)"

    if timeout "$timeout" ping -c 2 "$host" >/dev/null 2>&1; then
        print_debug "Network connectivity to $host: OK"
        return 0
    else
        print_debug "Network connectivity to $host: FAILED"
        return 1
    fi
}

# Validation utilities
validate_block_device() {
    local device="$1"

    if [ ! -b "$device" ]; then
        print_error "Not a valid block device: $device"
        return 1
    fi

    print_debug "Validated block device: $device"
    return 0
}

validate_file_exists() {
    local file="$1"

    if [ ! -f "$file" ]; then
        print_error "File not found: $file"
        return 1
    fi

    print_debug "Validated file exists: $file"
    return 0
}

validate_directory_writable() {
    local directory="$1"

    if [ ! -d "$directory" ]; then
        print_error "Directory not found: $directory"
        return 1
    fi

    if [ ! -w "$directory" ]; then
        print_error "Directory not writable: $directory"
        return 1
    fi

    print_debug "Validated writable directory: $directory"
    return 0
}