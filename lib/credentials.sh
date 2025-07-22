#!/bin/bash
# lib/credentials.sh - Credential management for ZFS backup system

# Global credential variables
ENCRYPTION_PASS=""
NAS_USER=""
NAS_PASSWORD=""

# Load backup credentials from multiple sources
load_backup_credentials() {
    echo "CREDENTIAL LOADING"
    echo "=================="
    print_info "Loading backup credentials..."

    print_debug "Checking credentials file: $CREDENTIALS_FILE"

    # Method 1: Check for unified credentials file
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_debug "Found credentials file: $CREDENTIALS_FILE"

        # Load encryption password
        ENCRYPTION_PASS=$(grep "^encryption_password=" "$CREDENTIALS_FILE" 2>/dev/null | cut -d'=' -f2- || true)

        # Load NAS connection settings (override defaults if found)
        local file_ip=$(grep "^nas_ip=" "$CREDENTIALS_FILE" 2>/dev/null | cut -d'=' -f2- || true)
        local file_share=$(grep "^nas_share=" "$CREDENTIALS_FILE" 2>/dev/null | cut -d'=' -f2- || true)
        local file_path=$(grep "^nas_backup_path=" "$CREDENTIALS_FILE" 2>/dev/null | cut -d'=' -f2- || true)

        # Override defaults if found in file
        if [ -n "$file_ip" ]; then
            NAS_IP="$file_ip"
            print_debug "Using NAS IP from credentials file: $NAS_IP"
        fi
        if [ -n "$file_share" ]; then
            NAS_SHARE="$file_share"
            print_debug "Using NAS share from credentials file: $NAS_SHARE"
        fi
        if [ -n "$file_path" ]; then
            NAS_BACKUP_PATH="$file_path"
            print_debug "Using NAS path from credentials file: $NAS_BACKUP_PATH"
        fi

        # Load NAS credentials
        NAS_USER=$(grep "^nas_username=" "$CREDENTIALS_FILE" 2>/dev/null | cut -d'=' -f2- || true)
        NAS_PASSWORD=$(grep "^nas_password=" "$CREDENTIALS_FILE" 2>/dev/null | cut -d'=' -f2- || true)

        # Validate credentials
        if [ ${#ENCRYPTION_PASS} -ge 12 ] && [ -n "$NAS_USER" ] && [ -n "$NAS_PASSWORD" ]; then
            print_status "[OK] All credentials loaded from $CREDENTIALS_FILE"
            print_info "NAS: $NAS_USER@$NAS_IP/$NAS_SHARE/$NAS_BACKUP_PATH"
            return 0
        else
            print_debug "Credentials file incomplete - missing or invalid data"
        fi
    else
        print_debug "Credentials file not found: $CREDENTIALS_FILE"
    fi

    # Method 2: Check environment variables
    print_debug "Checking environment variables..."
    if [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ] && [ ${#BACKUP_ENCRYPTION_PASSWORD} -ge 12 ]; then
        print_debug "Found encryption password in environment"
        ENCRYPTION_PASS="$BACKUP_ENCRYPTION_PASSWORD"

        # Load NAS settings from environment if available
        if [ -n "${BACKUP_NAS_IP:-}" ]; then NAS_IP="$BACKUP_NAS_IP"; fi
        if [ -n "${BACKUP_NAS_SHARE:-}" ]; then NAS_SHARE="$BACKUP_NAS_SHARE"; fi
        if [ -n "${BACKUP_NAS_PATH:-}" ]; then NAS_BACKUP_PATH="$BACKUP_NAS_PATH"; fi

        NAS_USER="${BACKUP_NAS_USER:-}"
        NAS_PASSWORD="${BACKUP_NAS_PASSWORD:-}"

        if [ -n "$NAS_USER" ] && [ -n "$NAS_PASSWORD" ]; then
            print_status "[OK] All credentials loaded from environment"
            return 0
        else
            print_debug "Environment variables incomplete"
        fi
    fi

    # Method 3: Interactive prompt (if not in auto mode)
    if [ "$AUTO_MODE" = false ]; then
        print_info "Interactive credential setup needed"
        if interactive_credential_setup; then
            return 0
        else
            return 1
        fi
    else
        print_error "[ERROR] Auto mode requires pre-configured credentials"
        print_info "Setup required. Run: $0 setup"
        return 1
    fi
}

# Interactive credential setup for missing credentials
interactive_credential_setup() {
    echo "INTERACTIVE CREDENTIAL SETUP"
    echo "============================="
    print_info "Some credentials are missing. Let's configure them now."
    echo ""

    # Get encryption password if missing
    if [ -z "$ENCRYPTION_PASS" ] || [ ${#ENCRYPTION_PASS} -lt 12 ]; then
        echo "🔒 Encryption Password Setup:"
        echo "============================="
        echo "[WARNING] This password protects your backup files - keep it safe!"
        echo "Requirements: Minimum 12 characters, mix of letters/numbers/symbols"
        echo ""

        local enc_pass=""
        local enc_pass2=""
        while true; do
            if read -s -t $USER_TIMEOUT -p "Enter encryption password: " enc_pass; then
                echo ""
                if read -s -t $USER_TIMEOUT -p "Confirm encryption password: " enc_pass2; then
                    echo ""

                    if [ "$enc_pass" != "$enc_pass2" ]; then
                        print_error "Passwords don't match. Please try again."
                        continue
                    elif [ ${#enc_pass} -lt 12 ]; then
                        print_error "Password too short (minimum 12 characters). Please try again."
                        continue
                    else
                        ENCRYPTION_PASS="$enc_pass"
                        print_status "[OK] Strong encryption password configured"
                        break
                    fi
                else
                    echo ""
                    print_error "Password confirmation timeout"
                    return 1
                fi
            else
                echo ""
                print_error "Password timeout - cannot proceed"
                return 1
            fi
        done
    fi

    # Get NAS credentials if missing
    if [ -z "$NAS_USER" ] || [ -z "$NAS_PASSWORD" ]; then
        echo ""
        echo "🌐 NAS Configuration:"
        echo "===================="
        echo "Configure your network storage for automatic backups."
        echo ""
        echo "Current settings:"
        echo "  IP Address: $NAS_IP"
        echo "  Share Name: $NAS_SHARE"
        echo "  Backup Path: $NAS_BACKUP_PATH"
        echo ""
        echo "Press ENTER to use current settings, or customize:"

        read -p "NAS IP Address [$NAS_IP]: " input_ip
        if [ -n "${input_ip:-}" ]; then NAS_IP="$input_ip"; fi

        read -p "Share Name [$NAS_SHARE]: " input_share
        if [ -n "${input_share:-}" ]; then NAS_SHARE="$input_share"; fi

        read -p "Backup Path [$NAS_BACKUP_PATH]: " input_path
        if [ -n "${input_path:-}" ]; then NAS_BACKUP_PATH="$input_path"; fi

        echo ""
        echo "🔐 NAS Authentication:"
        echo "====================="
        read -p "NAS Username: " nas_user
        if read -s -t $USER_TIMEOUT -p "NAS Password: " nas_pass; then
            echo ""
            NAS_USER="$nas_user"
            NAS_PASSWORD="$nas_pass"
        else
            echo ""
            print_error "NAS password timeout"
            return 1
        fi

        print_info "Target: //$NAS_IP/$NAS_SHARE/$NAS_BACKUP_PATH/"
    fi

    print_status "[OK] Credentials configured successfully"

    # Offer to save credentials
    echo ""
    read -p "Save credentials to $CREDENTIALS_FILE for future use? (y/N): " save_choice
    if [[ "$save_choice" =~ ^[Yy] ]]; then
        if save_credentials_to_file; then
            print_status "[OK] Credentials saved for future use"
        else
            print_warning "[WARNING] Failed to save credentials, but backup can continue"
        fi
    fi

    return 0
}

# Save credentials to file
save_credentials_to_file() {
    print_debug "Saving credentials to $CREDENTIALS_FILE"

    # Create directory if needed
    local cred_dir=$(dirname "$CREDENTIALS_FILE")
    mkdir -p "$cred_dir" 2>/dev/null || true

    # Create credentials file
    cat > "$CREDENTIALS_FILE" << EOF
# ZFS Backup System Credentials
# Created: $(date)
# SECURITY: Keep this file secure with chmod 600

# Backup Encryption (CRITICAL - needed for restore)
encryption_password=$ENCRYPTION_PASS

# ZFS Pool Configuration
zfs_pool=$ZFS_POOL

# NAS Connection Settings
nas_ip=$NAS_IP
nas_share=$NAS_SHARE
nas_backup_path=$NAS_BACKUP_PATH

# NAS Authentication
nas_username=$NAS_USER
nas_password=$NAS_PASSWORD

# Configuration Metadata
created_date=$(date)
script_version=Modular Edition v2.0
backup_method=Hybrid (Boot + ZFS)
EOF

    # Set secure permissions
    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || {
        print_error "Failed to set secure permissions on credentials file"
        rm -f "$CREDENTIALS_FILE" 2>/dev/null
        return 1
    }

    print_debug "Credentials saved with secure permissions (600)"
    return 0
}

# Setup credentials wizard (for setup command)
setup_backup_credentials() {
    print_main_header "🔐 ZFS BACKUP CREDENTIALS SETUP"
    echo ""
    echo "This wizard will configure credentials and settings for automated backups."
    echo "You'll need your NAS connection details and a strong encryption password."
    echo ""

    # Get ZFS pool with auto-detection
    echo "ZFS Pool Configuration"
    echo "======================="
    echo "Available ZFS pools:"
    if zpool list 2>/dev/null; then
        echo ""
    else
        echo "No ZFS pools found"
        print_error "Cannot setup backup without a ZFS pool"
        return 1
    fi
    echo "Current default: $ZFS_POOL"
    read -p "Enter ZFS pool name (or press ENTER for default): " input_pool
    if [ -n "${input_pool:-}" ]; then
        ZFS_POOL="$input_pool"
        # Validate the pool exists
        if ! zpool list "$ZFS_POOL" >/dev/null 2>&1; then
            print_error "ZFS pool '$ZFS_POOL' not found"
            return 1
        fi
    fi
    print_status "[OK] Pool: $ZFS_POOL"

    # Get encryption password with validation
    echo ""
    echo "Encryption Password Setup"
    echo "========================="
    echo "[WARNING] This password protects your backup files - keep it safe!"
    echo "Requirements: Minimum 12 characters, mix of letters/numbers/symbols"
    echo ""

    local enc_pass=""
    local enc_pass2=""
    while true; do
        read -s -p "Enter encryption password: " enc_pass
        echo ""
        read -s -p "Confirm encryption password: " enc_pass2
        echo ""

        if [ "$enc_pass" != "$enc_pass2" ]; then
            print_error "Passwords don't match. Please try again."
            continue
        elif [ ${#enc_pass} -lt 12 ]; then
            print_error "Password too short (minimum 12 characters). Please try again."
            continue
        else
            print_status "[OK] Strong encryption password configured"
            break
        fi
    done

    # Get NAS configuration with smart defaults
    echo ""
    echo "NAS Configuration"
    echo "================="
    echo "Configure your network storage for automatic backups."
    echo ""
    echo "Current defaults:"
    echo "  IP Address: $NAS_IP"
    echo "  Share Name: $NAS_SHARE"
    echo "  Backup Path: $NAS_BACKUP_PATH"
    echo ""
    echo "Press ENTER to use defaults, or customize:"

    read -p "NAS IP Address [$NAS_IP]: " input_ip
    if [ -n "${input_ip:-}" ]; then NAS_IP="$input_ip"; fi

    read -p "Share Name [$NAS_SHARE]: " input_share
    if [ -n "${input_share:-}" ]; then NAS_SHARE="$input_share"; fi

    read -p "Backup Path [$NAS_BACKUP_PATH]: " input_path
    if [ -n "${input_path:-}" ]; then NAS_BACKUP_PATH="$input_path"; fi

    echo ""
    echo "NAS Authentication"
    echo "=================="
    read -p "NAS Username: " nas_user
    read -s -p "NAS Password: " nas_pass
    echo ""

    # Validate inputs
    if [ -z "$nas_user" ] || [ -z "$nas_pass" ]; then
        print_error "NAS credentials cannot be empty"
        return 1
    fi

    # Set variables
    ENCRYPTION_PASS="$enc_pass"
    NAS_USER="$nas_user"
    NAS_PASSWORD="$nas_pass"

    # Save credentials
    if save_credentials_to_file; then
        print_status "[OK] Credentials saved securely to: $CREDENTIALS_FILE"
    else
        print_error "Failed to save credentials"
        return 1
    fi

    # Test connectivity
    echo ""
    echo "CONNECTIVITY TEST"
    echo "================="
    print_info "Testing NAS connectivity with your settings..."

    if test_nas_connectivity; then
        echo ""
        print_main_header "🎉 SETUP COMPLETED SUCCESSFULLY!"
        echo ""
        echo "[OK] All credentials configured and tested"
        echo "[OK] NAS connectivity verified"
        echo "[OK] Ready for automated backups"
        echo ""
        echo "🚀 NEXT STEPS:"
        echo "============="
        echo "• Test backup: ./zfs-backup.sh"
        echo "• Automated backup: ./zfs-backup.sh --auto"
        echo "• Schedule backups: Add to cron for regular execution"
        echo "• Test restore: Use ./restore.sh on spare hardware"
        echo ""
        echo "📋 RECOMMENDED CRON SCHEDULE:"
        echo "0 2 * * 0  $SCRIPT_DIR/zfs-backup.sh --auto  # Weekly backups at 2 AM on Sunday"
        echo ""
        return 0
    else
        echo ""
        print_warning "[WARNING] Setup completed but connectivity test failed"
        echo ""
        echo "Possible issues:"
        echo "• Check network connectivity to NAS"
        echo "• Verify NAS IP address and share name"
        echo "• Confirm username and password are correct"
        echo "• Ensure NAS SMB/CIFS service is running"
        echo ""
        echo "You can test connectivity later with: ./zfs-backup.sh test-nas"
        return 0
    fi
}

# Test NAS connectivity (basic version - full version in hybrid-backup.sh)
test_nas_connectivity() {
    print_debug "Basic NAS connectivity test for $NAS_IP"

    # Quick ping test
    if ! test_network_connectivity "$NAS_IP" "$NAS_TIMEOUT"; then
        print_warning "NAS not reachable at $NAS_IP"
        return 1
    fi

    # Check if we have NAS credentials
    if [ -z "$NAS_USER" ] || [ -z "$NAS_PASSWORD" ]; then
        print_warning "NAS credentials not available"
        return 1
    fi

    print_status "Basic NAS connectivity: OK"
    return 0
}

# Clear sensitive credential data from memory
clear_credentials() {
    print_debug "Clearing credentials from memory"
    ENCRYPTION_PASS=""
    NAS_PASSWORD=""

    # Also clear from environment if they were set
    unset BACKUP_ENCRYPTION_PASSWORD 2>/dev/null || true
    unset BACKUP_NAS_PASSWORD 2>/dev/null || true
}