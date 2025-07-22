#!/bin/bash
# ZFS Backup System - Main Script
# Hybrid backup only (boot partition + ZFS) with modular architecture
# Version: 2.0 - Modular Edition

set -e

# Script directory and library path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Source all library files in order
source "${LIB_DIR}/utilities.sh"
source "${LIB_DIR}/credentials.sh"
source "${LIB_DIR}/system-detection.sh"
source "${LIB_DIR}/nas-functions.sh"
source "${LIB_DIR}/usb-functions.sh"
source "${LIB_DIR}/hybrid-backup.sh"

# Default configuration
load_default_config() {
    # ZFS Configuration
    export ZFS_POOL="${ZFS_POOL:-rpool}"

    # NAS Configuration (defaults - may be overridden by credentials)
    : "${NAS_IP:=192.168.1.100}"
    : "${NAS_SHARE:=backups}"  
    : "${NAS_BACKUP_PATH:=NAS/proxmox/system-images}"
    export NAS_IP NAS_SHARE NAS_BACKUP_PATH

    # Backup Configuration (hybrid only)
    export BACKUP_PREFIX="${BACKUP_PREFIX:-zfs-backup}"
    export COMPRESSION="${COMPRESSION:-lz4}"
    export ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-AES256}"

    # Timing and Behavior
    export NAS_TIMEOUT="${NAS_TIMEOUT:-30}"
    export USER_TIMEOUT="${USER_TIMEOUT:-60}"
    export AUTO_BACKUP_DELAY="${AUTO_BACKUP_DELAY:-10}"

    # Paths
    export CREDENTIALS_FILE="${CREDENTIALS_FILE:-${HOME:-/root}/.zfs-backup-credentials}"
    export LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/zfs-backup.log}"
    export TEMP_MOUNT="${TEMP_MOUNT:-/mnt/zfs-backup-temp}"
}

# Global variables
export BACKUP_TARGET=""
export SELECTED_TARGET=""
export AUTO_MODE=false
export DEBUG_MODE=false
export SNAPSHOT_NAME=""

# Simplified target selection
select_backup_target() {
    echo "BACKUP TARGET SELECTION"
    echo "======================="
    
    # Auto mode - use NAS only
    if [ "$AUTO_MODE" = true ]; then
        if test_nas_connectivity; then
            BACKUP_TARGET="nas"
            print_status "Auto mode: Using NAS backup"
            return 0
        else
            print_error "Auto mode requires NAS availability"
            return 1
        fi
    fi
    
    # Interactive mode
    local nas_available=false
    if test_nas_connectivity; then
        nas_available=true
        print_status "NAS is available"
    else
        print_warning "NAS not available"
    fi
    
    if [ "$nas_available" = true ]; then
        echo "1) NAS Backup (recommended)"
        echo "2) USB Backup"
        echo ""
        
        # Show countdown timer
        if show_countdown "$USER_TIMEOUT" "Auto-selecting NAS backup in ${USER_TIMEOUT} seconds..."; then
            # Timeout reached - use default (NAS)
            choice=""
        else
            # User interrupted - ask for manual selection
            read -p "Select target (1-2, default 1): " choice
        fi
        
        case "$choice" in
            2) BACKUP_TARGET="usb" ;;
            *) BACKUP_TARGET="nas" ;;
        esac
    else
        echo "Only USB backup available"
        
        # Show countdown timer for USB backup
        if show_countdown "$USER_TIMEOUT" "Auto-continuing with USB backup in ${USER_TIMEOUT} seconds..."; then
            # Timeout reached - use USB backup
            confirm="y"
        else
            # User interrupted - ask for confirmation
            read -p "Continue with USB backup? (y/n): " confirm
        fi
        case "$confirm" in
            n|N) print_info "Backup cancelled"; exit 0 ;;
            *) BACKUP_TARGET="usb" ;;
        esac
    fi
    
    print_status "Selected: $(echo $BACKUP_TARGET | tr '[:lower:]' '[:upper:]') backup"
}

# Execute backup based on selected target
execute_backup() {
    echo "BACKUP EXECUTION"
    echo "================"
    
    # Show backup summary
    local pool_used=$(zfs list -H -p -o used "$ZFS_POOL" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "~4GB")
    local efi_size="~144MB"
    echo "Backing up: EFI boot partition ($efi_size) + ZFS pool '$ZFS_POOL' ($pool_used used)"
    echo "Target: $(echo $BACKUP_TARGET | tr '[:lower:]' '[:upper:]') backup"
    echo ""

    local backup_success=false

    case "$BACKUP_TARGET" in
        "nas")
            print_info "Starting NAS hybrid backup..."
            if backup_hybrid_to_nas; then
                backup_success=true
                print_status "NAS backup completed successfully"
            else
                print_error "NAS backup failed"
            fi

            # USB fallback for interactive mode
            if [ "$backup_success" = false ] && [ "$AUTO_MODE" = false ]; then
                echo ""
                print_info "Attempting USB fallback..."
                if list_usb_drives && backup_hybrid_to_usb "$SELECTED_TARGET"; then
                    backup_success=true
                    print_status "USB fallback backup completed"
                fi
            fi
            ;;
        "usb")
            print_info "Starting USB hybrid backup..."
            if list_usb_drives; then
                if [ -z "$SELECTED_TARGET" ]; then
                    print_error "No USB drive selected"
                    backup_success=false
                elif backup_hybrid_to_usb "$SELECTED_TARGET"; then
                    backup_success=true
                    print_status "USB backup completed successfully"
                else
                    print_error "USB backup failed"
                fi
            else
                print_error "No USB drives available"
            fi
            ;;
    esac

    return $([ "$backup_success" = true ] && echo 0 || echo 1)
}

# Print success summary
print_success_summary() {
    echo ""
    echo "BACKUP COMPLETED SUCCESSFULLY!"
    echo "=============================="
    echo "Completed: $(date)"
    echo "Method: $(echo $BACKUP_TARGET | tr '[:lower:]' '[:upper:]')"
    echo "Pool: $ZFS_POOL"
    echo "Snapshot: $SNAPSHOT_NAME"
    echo ""
    echo "Next steps:"
    echo "1. Test backup integrity: ./integrity-check.sh"
    echo "2. Test restore process: ./restore.sh on spare hardware"
    echo "3. Schedule regular backups if needed"
}

# Print failure summary
print_failure_summary() {
    echo ""
    echo "BACKUP FAILED!"
    echo "=============="
    echo "Failed: $(date)"
    echo "Method: $(echo $BACKUP_TARGET | tr '[:lower:]' '[:upper:]')"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check network connectivity (for NAS)"
    echo "2. Verify credentials: ./zfs-backup.sh test-nas"
    echo "3. Check disk space on target"
    echo "4. Review error messages above"
    echo ""
    echo "Support:"
    echo "- Check logs: $LOG_FILE"
    echo "- Pool status: zpool status $ZFS_POOL"
}

# Main execution function
main() {
    # Initialize system (load config first!)
    load_default_config
    setup_cleanup_trap

    # Print main header
    echo "ZFS BACKUP SYSTEM - MODULAR EDITION"
    echo "===================================="
    echo "System: $(hostname) | User: $(whoami) | Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # System checks
    check_system_requirements || exit 1
    load_backup_credentials || exit 1
    validate_zfs_pool || exit 1

    # Create logs directory
    mkdir -p "$(dirname "$LOG_FILE")"

    # Interactive target selection
    select_backup_target || exit 1

    # Execute backup (snapshot creation happens inside backup functions)
    # This ensures we only create snapshots when we know backup will work
    if execute_backup; then
        print_success_summary
    else
        print_failure_summary
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --pool)
            ZFS_POOL="$2"
            shift 2
            ;;
        --help)
            echo "ZFS Backup System - Modular Edition"
            echo ""
            echo "USAGE:"
            echo "  $0 [OPTIONS] [COMMAND]"
            echo ""
            echo "COMMANDS:"
            echo "  (none)          Interactive hybrid backup"
            echo "  setup           Setup credentials and configuration"
            echo "  test-nas        Test NAS connectivity"
            echo ""
            echo "OPTIONS:"
            echo "  --auto          Automated mode (no prompts, for cron)"
            echo "  --pool POOL     Override ZFS pool name"
            echo "  --help          Show this help message"
            echo ""
            echo "FEATURES:"
            echo "  - Hybrid backup (boot partition + ZFS)"
            echo "  - Smart target selection (NAS preferred, USB fallback)"
            echo "  - Automated and interactive modes"
            echo "  - Comprehensive error handling and recovery"
            echo ""
            exit 0
            ;;
        setup)
            load_default_config
            setup_backup_credentials
            exit 0
            ;;
        test-nas)
            load_default_config
            load_backup_credentials || exit 1
            if test_nas_connectivity; then
                print_status "NAS connectivity test passed"
                echo "Ready for automated backups"
            else
                print_error "NAS connectivity test failed"
                echo "Check your network and credentials"
            fi
            exit $?
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"