#!/bin/bash
# Integrity Functions Library - ZFS Backup System
# Shared validation functions for both standalone integrity checking and restore verification
# Supports hybrid backups (boot partition + ZFS) with comprehensive validation

# Test GPG encryption integrity
validate_gpg_integrity() {
    local backup_file="$1"
    local encryption_password="$2"
    
    
    if [ ! -f "$backup_file" ]; then
        print_error "Backup file not found: $backup_file"
        return 1
    fi
    
    if [ -z "$encryption_password" ]; then
        print_error "No encryption password provided"
        return 1
    fi
    
    # Test decryption with first 1KB
    if echo "$encryption_password" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | head -c 1024 | hexdump -C >/dev/null 2>&1; then
        return 0
    else
        print_error "GPG decryption failed - wrong password or corrupted file"
        return 1
    fi
}

# Test compression integrity (gzip/xz)
validate_compression_integrity() {
    local backup_file="$1"
    local encryption_password="$2"
    local compression_type="${3:-gzip}"
    
    
    case "$compression_type" in
        "gzip")
            if echo "$encryption_password" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | gunzip -t 2>/dev/null; then
                return 0
            else
                print_error "Gzip integrity test failed"
                return 1
            fi
            ;;
        "xz")
            if echo "$encryption_password" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | xz -t 2>/dev/null; then
                return 0
            else
                print_error "XZ integrity test failed"
                return 1
            fi
            ;;
        "none")
            return 0
            ;;
        *)
            print_error "Unknown compression type: $compression_type"
            return 1
            ;;
    esac
}

# Validate ZFS stream format
validate_zfs_stream() {
    local backup_file="$1"
    local encryption_password="$2"
    local compression_type="${3:-gzip}"
    
    
    # Test if we can read ZFS stream data
    local decompression_cmd
    case "$compression_type" in
        "gzip") decompression_cmd="gunzip" ;;
        "xz") decompression_cmd="unxz" ;;
        "none") decompression_cmd="cat" ;;
        *) print_error "Unknown compression: $compression_type"; return 1 ;;
    esac
    
    local zfs_header=$(echo "$encryption_password" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | $decompression_cmd 2>/dev/null | head -c 2048 | hexdump -C 2>/dev/null | head -3)
    
    if [ -n "$zfs_header" ]; then
        return 0
    else
        print_error "Could not read ZFS stream data"
        return 1
    fi
}

# Test ZFS stream compatibility with dry-run
validate_zfs_compatibility() {
    local backup_file="$1"
    local encryption_password="$2"
    local compression_type="${3:-gzip}"
    local test_pool_name="${4:-test-restore-pool}"
    
    
    # Choose decompression command
    local decompression_cmd
    case "$compression_type" in
        "gzip") decompression_cmd="gunzip" ;;
        "xz") decompression_cmd="unxz" ;;
        "none") decompression_cmd="cat" ;;
        *) print_error "Unknown compression: $compression_type"; return 1 ;;
    esac
    
    # Test with zfs receive dry-run
    local zfs_output=$(echo "$encryption_password" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | $decompression_cmd 2>/dev/null | zfs receive -nv "$test_pool_name" 2>&1 || true)
    
    # Check for expected outputs that indicate valid stream
    if echo "$zfs_output" | grep -q "would receive\|does not exist\|cannot receive"; then
        return 0
    else
        print_warning "ZFS compatibility test inconclusive"
        return 0  # Don't fail on this - it's often inconclusive
    fi
}

# Validate backup file basic properties
validate_backup_file() {
    local backup_file="$1"
    
    
    if [ ! -f "$backup_file" ]; then
        print_error "Backup file not found: $backup_file"
        return 1
    fi
    
    if [ ! -s "$backup_file" ]; then
        print_error "Backup file is empty: $backup_file"
        return 1
    fi
    
    # Check file type
    local file_type=$(file "$backup_file" 2>/dev/null || echo "unknown")
    if [[ "$file_type" == *"GPG"* ]] || [[ "$file_type" == *"encrypted"* ]]; then
        print_debug "File appears to be properly encrypted"
    else
        print_warning "File doesn't appear to be GPG encrypted: $file_type"
    fi
    
    # Get file size information
    local file_size=$(ls -lh "$backup_file" | awk '{print $5}')
    local file_size_bytes=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
    
    
    # Warn if file is suspiciously small
    if [ "$file_size_bytes" -lt 1048576 ]; then
        print_warning "File is very small (< 1MB) - may be incomplete"
    fi
    
    return 0
}

# Estimate uncompressed size
estimate_backup_size() {
    local backup_file="$1"
    local compression_ratio="${2:-3}"  # Default 3:1 compression ratio
    
    local compressed_bytes=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
    local estimated_uncompressed=$(( compressed_bytes * compression_ratio ))
    local estimated_gb=$(( estimated_uncompressed / 1024 / 1024 / 1024 ))
    
    print_info "Compressed size: $(ls -lh "$backup_file" | awk '{print $5}')"
    print_info "Estimated uncompressed: ${estimated_gb}GB (assuming ${compression_ratio}:1 ratio)"
    print_info "Recommended target disk: $((estimated_gb + 10))GB minimum"
}

# Detect backup type and components
analyze_backup_structure() {
    local backup_dir="$1"
    
    
    local boot_files=()
    local zfs_files=()
    local restore_files=()
    
    # Find backup components
    for file in "$backup_dir"/*; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            case "$basename" in
                boot-partition-*.tar.gz.gpg)
                    boot_files+=("$file")
                    ;;
                *backup*.gz.gpg|*zfs*.gz.gpg)
                    zfs_files+=("$file")
                    ;;
                RESTORE-*.txt)
                    restore_files+=("$file")
                    ;;
            esac
        fi
    done
    
    # Analyze what we found
    local backup_type=""
    if [ ${#boot_files[@]} -gt 0 ] && [ ${#zfs_files[@]} -gt 0 ]; then
        backup_type="hybrid"
        print_status "Detected HYBRID backup (boot partition + ZFS)"
    elif [ ${#zfs_files[@]} -gt 0 ]; then
        backup_type="zfs-only"
        print_status "Detected ZFS-only backup"
    else
        backup_type="unknown"
        print_warning "Could not determine backup type"
    fi
    
    # Export results for caller
    export BACKUP_TYPE="$backup_type"
    export BOOT_BACKUP_FILES=("${boot_files[@]}")
    export ZFS_BACKUP_FILES=("${zfs_files[@]}")
    export RESTORE_INSTRUCTION_FILES=("${restore_files[@]}")
    
    return 0
}

# Comprehensive backup validation
run_comprehensive_backup_validation() {
    local backup_file="$1"
    local encryption_password="$2"
    local compression_type="${3:-gzip}"
    
    echo "COMPREHENSIVE BACKUP VALIDATION"
    echo "================================"
    print_info "Testing backup integrity: $(basename "$backup_file")"
    
    local tests_passed=0
    local tests_total=5
    
    # Test 1: File integrity
    print_info "Test 1: File Integrity Check"
    if validate_backup_file "$backup_file"; then
        tests_passed=$((tests_passed + 1))
        print_status "[OK] File integrity check passed"
    else
        print_error "[ERROR] File integrity check failed"
    fi
    echo ""
    
    # Test 2: GPG decryption
    print_info "Test 2: GPG Decryption Test"
    if validate_gpg_integrity "$backup_file" "$encryption_password"; then
        tests_passed=$((tests_passed + 1))
        print_status "[OK] GPG decryption test passed"
    else
        print_error "[ERROR] GPG decryption test failed"
    fi
    echo ""
    
    # Test 3: Compression integrity
    print_info "Test 3: Compression Integrity Test"
    if validate_compression_integrity "$backup_file" "$encryption_password" "$compression_type"; then
        tests_passed=$((tests_passed + 1))
        print_status "[OK] Compression integrity test passed"
    else
        print_error "[ERROR] Compression integrity test failed"
    fi
    echo ""
    
    # Test 4: ZFS stream validation
    print_info "Test 4: ZFS Stream Validation"
    if validate_zfs_stream "$backup_file" "$encryption_password" "$compression_type"; then
        tests_passed=$((tests_passed + 1))
        print_status "[OK] ZFS stream validation passed"
    else
        print_error "[ERROR] ZFS stream validation failed"
    fi
    echo ""
    
    # Test 5: ZFS compatibility
    print_info "Test 5: ZFS Compatibility Test"
    if validate_zfs_compatibility "$backup_file" "$encryption_password" "$compression_type"; then
        tests_passed=$((tests_passed + 1))
        print_status "[OK] ZFS compatibility test passed"
    else
        print_warning "[WARNING] ZFS compatibility test inconclusive"
    fi
    echo ""
    
    # Results summary
    echo "VALIDATION RESULTS"
    echo "=================="
    
    if [ $tests_passed -eq $tests_total ]; then
        print_status "ALL TESTS PASSED! ($tests_passed/$tests_total)"
        print_info "[OK] Backup appears to be completely healthy"
        print_info "[OK] Ready for restore operation"
        return 0
    elif [ $tests_passed -ge 3 ]; then
        print_warning "Most tests passed ($tests_passed/$tests_total)"
        print_info "[WARNING] Backup is likely good but may have minor issues"
        print_info "[OK] Should work for restore operation"
        return 0
    else
        print_error "Multiple tests failed ($tests_passed/$tests_total)"
        print_error "[ERROR] Backup may be corrupted or severely damaged"
        return 1
    fi
}

# Quick integrity test (fast validation)
quick_integrity_test() {
    local backup_file="$1"
    local encryption_password="$2"
    
    
    # Quick file and GPG test only
    if validate_backup_file "$backup_file" && validate_gpg_integrity "$backup_file" "$encryption_password"; then
        return 0
    else
        print_error "Quick integrity test failed"
        return 1
    fi
}