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

    # NAS Configuration  
    export NAS_IP="${NAS_IP:-192.168.1.100}"
    export NAS_SHARE="${NAS_SHARE:-backups}"
    export NAS_BACKUP_PATH="${NAS_BACKUP_PATH:-NAS/proxmox/system-images}"

    # Backup Configuration (hybrid only)
    export BACKUP_PREFIX="${BACKUP_PREFIX:-zfs-backup}"
    export COMPRESSION="${COMPRESSION:-gzip}"
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
export DEBUG_MODE=true
export SNAPSHOT_NAME=""

# Enhanced target selection with smart defaults
select_backup_target() {
    print_section_header "🎯 BACKUP TARGET SELECTION"

    # Test NAS availability first
    print_info "🔍 Detecting available backup targets..."

    local nas_available=false
    if test_nas_connectivity; then
        nas_available=true
        print_status "✅ NAS is online and accessible"
    else
        print_warning "❌ NAS not available"
    fi

    echo ""

    if [ "$AUTO_MODE" = true ]; then
        print_status "🤖 Running in automated mode"
        if [ "$nas_available" = true ]; then
            print_status "Using NAS backup (automated)"
            BACKUP_TARGET="nas"
            return 0
        else
            print_error "Auto mode requires NAS availability"
            return 1
        fi
    else
        # Interactive mode with enhanced UX
        if [ "$nas_available" = true ]; then
            echo "Available options:"
            echo "1) 🌐 NAS Backup (recommended) - Fast, automatic, networked storage"
            echo "2) 💾 USB Backup - Portable, offline storage"
            echo ""

            # Auto-countdown with visual feedback
            print_info "⏰ Auto-selecting NAS backup in ${AUTO_BACKUP_DELAY} seconds..."
            echo "Press any key to choose manually, or wait for auto-start..."

            local countdown=$AUTO_BACKUP_DELAY
            while [ $countdown -gt 0 ]; do
                printf "\r🌐 Auto-starting NAS backup in %d seconds... (press any key to choose manually)" $countdown
                if read -t 1 -n 1 -s choice 2>/dev/null; then
                    echo ""
                    echo ""
                    echo "🎯 Manual selection mode activated"
                    echo ""
                    read -p "Choose backup target (1=NAS, 2=USB): " choice
                    echo ""
                    case "$choice" in
                        1|"1")
                            print_status "✅ Selected: NAS backup"
                            BACKUP_TARGET="nas"
                            ;;
                        2|"2")
                            print_status "✅ Selected: USB backup"
                            BACKUP_TARGET="usb"
                            ;;
                        "")
                            print_status "✅ Selected: NAS backup (default)"
                            BACKUP_TARGET="nas"
                            ;;
                        *)
                            print_warning "Invalid choice '$choice', using NAS backup"
                            BACKUP_TARGET="nas"
                            ;;
                    esac
                    break
                fi
                countdown=$((countdown - 1))
            done

            if [ $countdown -eq 0 ]; then
                echo ""
                echo ""
                print_status "🌐 Auto-starting NAS backup..."
                BACKUP_TARGET="nas"
            fi
        else
            # NAS not available - offer USB only
            print_warning "NAS not available - USB backup mode"
            echo ""
            echo "Available options:"
            echo "1) 💾 USB Backup - Manual drive selection required"
            echo "2) ❌ Cancel backup"
            echo ""

            read -p "Continue with USB backup? (1=Yes, 2=Cancel): " choice
            echo ""
            case "$choice" in
                1|"")
                    print_status "✅ Selected: USB backup"
                    BACKUP_TARGET="usb"
                    ;;
                *)
                    print_info "Backup cancelled by user"
                    exit 0
                    ;;
            esac
        fi
    fi

    # Display selected configuration
    echo ""
    print_section_header "🎯 BACKUP CONFIGURATION"
    echo "Mode: HYBRID (Boot Partition + ZFS Pool)"
    case "$BACKUP_TARGET" in
        "nas")
            print_status "Target: NAS (Network Attached Storage)"
            print_info "Location: //$NAS_IP/$NAS_SHARE/$NAS_BACKUP_PATH/"
            print_info "Benefits: Automatic, fast, always available"
            ;;
        "usb")
            print_status "Target: USB/External Drive"
            print_info "Benefits: Portable, offline storage, air-gapped security"
            print_warning "Note: USB drive selection required"
            ;;
    esac

    print_info "Components: EFI boot partition + Complete ZFS pool"
    print_info "Expected size: ~6-12GB total"
    print_info "Expected duration: ~8-15 minutes"
    print_info "Encryption: $ENCRYPTION_ALGO"
    print_info "Compression: $COMPRESSION"
    echo ""
}

# Execute backup based on selected target
execute_backup() {
    print_section_header "🚀 BACKUP EXECUTION"

    local backup_success=false

    case "$BACKUP_TARGET" in
        "nas")
            print_info "Starting NAS hybrid backup process..."
            if backup_hybrid_to_nas; then
                backup_success=true
                print_status "✅ Hybrid NAS backup completed successfully!"
            else
                print_error "❌ Hybrid NAS backup failed"
            fi

            # USB fallback for interactive mode
            if [ "$backup_success" = false ] && [ "$AUTO_MODE" = false ]; then
                echo ""
                print_info "🔄 Attempting USB fallback..."
                if list_usb_drives; then
                    if backup_hybrid_to_usb "$SELECTED_TARGET"; then
                        backup_success=true
                        print_status "✅ Hybrid USB fallback backup completed!"
                    fi
                fi
            fi
            ;;
        "usb")
            print_info "Starting USB hybrid backup process..."
            if list_usb_drives; then
                if backup_hybrid_to_usb "$SELECTED_TARGET"; then
                    backup_success=true
                    print_status "✅ Hybrid USB backup completed successfully!"
                else
                    print_error "❌ Hybrid USB backup failed!"
                fi
            else
                print_error "❌ USB backup failed - no drives available!"
            fi
            ;;
    esac

    return $([ "$backup_success" = true ] && echo 0 || echo 1)
}

# Print success summary
print_success_summary() {
    echo ""
    print_main_header "🎉 BACKUP COMPLETED SUCCESSFULLY!"
    echo "📅 Completed: $(date)"
    echo "💾 Method: $(echo $BACKUP_TARGET | tr '[:lower:]' '[:upper:]')"
    echo "🔧 Mode: HYBRID (Boot + ZFS)"
    echo "🔒 Encryption: $ENCRYPTION_ALGO"
    echo "📦 Compression: $COMPRESSION"
    echo "🗄️  Pool: $ZFS_POOL"
    echo "📸 Snapshot: $SNAPSHOT_NAME"
    echo ""
    echo "✅ SUCCESS INDICATORS:"
    echo "• Backup files created and verified"
    echo "• All processes completed without errors"
    echo "• System snapshot safely created"
    echo ""
    echo "🚀 RECOMMENDED NEXT STEPS:"
    echo "========================="
    echo "1. 🧪 Test backup integrity: ./integrity-check.sh"
    echo "2. 🔄 Test restore process: Use ./restore.sh on spare hardware"
    echo "3. 📅 Schedule automation: Add to cron for regular backups"
    echo "4. 💾 Store safely: Keep backup drive in secure location"
    echo ""
    echo "⚡ AUTOMATION COMMANDS:"
    echo "• Manual backup: ./zfs-backup.sh"
    echo "• Automated backup: ./zfs-backup.sh --auto"
    echo "• Test connectivity: ./zfs-backup.sh test-nas"
    echo ""
}

# Print failure summary
print_failure_summary() {
    echo ""
    print_main_header "❌ BACKUP FAILED!"
    echo "📅 Failed: $(date)"
    echo "💾 Attempted method: $(echo $BACKUP_TARGET | tr '[:lower:]' '[:upper:]')"
    echo ""
    echo "🔧 TROUBLESHOOTING STEPS:"
    echo "========================"
    echo "1. Check network connectivity (for NAS)"
    echo "2. Verify credentials: ./zfs-backup.sh test-nas"
    echo "3. Check disk space on target"
    echo "4. Review error messages above"
    echo "5. Try manual USB backup if NAS failed"
    echo ""
    echo "📞 SUPPORT INFORMATION:"
    echo "• Check logs: $LOG_FILE"
    echo "• Verify pool status: zpool status $ZFS_POOL"
    echo "• Test credentials: ./zfs-backup.sh test-nas"
    echo ""
}

# Main execution function
main() {
    # Initialize system (load config first!)
    load_default_config
    setup_cleanup_trap

    # Print main header
    print_main_header "🔄 ZFS BACKUP SYSTEM - MODULAR EDITION"
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
            echo "  ✅ Hybrid backup only (boot partition + ZFS)"
            echo "  ✅ Smart target selection (NAS preferred, USB fallback)"
            echo "  ✅ Enhanced user experience with countdown timers"
            echo "  ✅ Comprehensive error handling and recovery"
            echo ""
            exit 0
            ;;
        setup)
            load_default_config
            print_debug "Setup command - CREDENTIALS_FILE: $CREDENTIALS_FILE"
            setup_backup_credentials
            exit 0
            ;;
        test-nas)
            load_default_config
            load_backup_credentials || exit 1
            if test_nas_connectivity; then
                print_status "✅ NAS connectivity test passed!"
                echo "Ready for automated backups"
            else
                print_error "❌ NAS connectivity test failed!"
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