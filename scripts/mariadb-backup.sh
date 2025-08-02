#!/bin/bash

# MariaDB Backup Manager
# Claude-MariaDB Database Infrastructure Specialist
# Enterprise-grade backup and recovery for production MariaDB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"
LOGS_DIR="$PROJECT_DIR/logs"

# Backup configuration
BACKUP_RETENTION_DAYS=30
DAILY_BACKUP_HOUR=2
MAX_PARALLEL_BACKUPS=1

# Create required directories
mkdir -p "$BACKUP_DIR" "$LOGS_DIR"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGS_DIR/backup.log"
}

# Function to format bytes for human reading
format_bytes() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec "$bytes"
    else
        # Fallback for macOS
        if [[ $bytes -lt 1024 ]]; then
            echo "${bytes}B"
        elif [[ $bytes -lt 1048576 ]]; then
            echo "$((bytes / 1024))KB"
        elif [[ $bytes -lt 1073741824 ]]; then
            echo "$((bytes / 1048576))MB"
        else
            echo "$((bytes / 1073741824))GB"
        fi
    fi
}

# Function to get database list
get_databases() {
    mysql -e "SHOW DATABASES;" | grep -v -E "^(Database|information_schema|performance_schema)$"
}

# Function to create a backup
create_backup() {
    local backup_type="${1:-full}"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="mariadb_${backup_type}_${timestamp}"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    log "🚀 Starting $backup_type backup: $backup_name"
    
    # Create backup directory
    mkdir -p "$backup_path"
    
    # Backup configuration
    local backup_config="$backup_path/backup_config.json"
    cat > "$backup_config" << EOF
{
  "backup_type": "$backup_type",
  "timestamp": "$timestamp",
  "created_by": "Claude-MariaDB",
  "mariadb_version": "$(mysql -e "SELECT VERSION();" | tail -n 1)",
  "backup_method": "mariadb-dump",
  "compression": "gzip",
  "databases": [],
  "status": "in_progress",
  "start_time": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
    
    local backup_success=true
    local backup_size=0
    local databases_backed_up=()
    
    case "$backup_type" in
        "full")
            log "Creating full database backup..."
            
            # Get list of databases to backup
            local databases=($(get_databases))
            
            for db in "${databases[@]}"; do
                log "Backing up database: $db"
                local db_backup_file="$backup_path/${db}.sql.gz"
                
                if mariadb-dump --single-transaction --routines --triggers "$db" | gzip > "$db_backup_file"; then
                    local db_size=$(du -b "$db_backup_file" 2>/dev/null | cut -f1 || echo "0")
                    backup_size=$((backup_size + db_size))
                    databases_backed_up+=("$db")
                    log "✅ Database $db backed up successfully ($(format_bytes $db_size))"
                else
                    log "❌ Failed to backup database: $db"
                    backup_success=false
                fi
            done
            ;;
            
        "config")
            log "Creating configuration backup..."
            
            # MariaDB configuration
            if [[ -f "/opt/homebrew/etc/my.cnf" ]]; then
                cp "/opt/homebrew/etc/my.cnf" "$backup_path/my.cnf" || true
            fi
            
            # Custom configuration files
            if [[ -d "/opt/homebrew/etc/my.cnf.d" ]]; then
                cp -r "/opt/homebrew/etc/my.cnf.d" "$backup_path/" 2>/dev/null || true
            fi
            
            # User and privilege backup
            log "Backing up users and privileges..."
            if mysql -e "SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') AS query FROM mysql.user;" | tail -n +2 > "$backup_path/grants.sql"; then
                gzip "$backup_path/grants.sql"
                log "✅ User grants backed up successfully"
            else
                log "⚠️ Failed to backup user grants"
            fi
            ;;
            
        "schema")
            log "Creating schema-only backup..."
            
            local databases=($(get_databases))
            
            for db in "${databases[@]}"; do
                log "Backing up schema for database: $db"
                local schema_file="$backup_path/${db}_schema.sql.gz"
                
                if mariadb-dump --no-data --routines --triggers "$db" | gzip > "$schema_file"; then
                    local schema_size=$(du -b "$schema_file" 2>/dev/null | cut -f1 || echo "0")
                    backup_size=$((backup_size + schema_size))
                    databases_backed_up+=("$db")
                    log "✅ Schema for $db backed up successfully"
                else
                    log "❌ Failed to backup schema for database: $db"
                    backup_success=false
                fi
            done
            ;;
            
        *)
            log "❌ Unknown backup type: $backup_type"
            return 1
            ;;
    esac
    
    # Update backup configuration with results
    local end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local status="completed"
    if [[ "$backup_success" != "true" ]]; then
        status="failed"
    fi
    
    # Create updated backup config
    cat > "$backup_config" << EOF
{
  "backup_type": "$backup_type",
  "timestamp": "$timestamp",
  "created_by": "Claude-MariaDB",
  "mariadb_version": "$(mysql -e "SELECT VERSION();" | tail -n 1)",
  "backup_method": "mariadb-dump",
  "compression": "gzip",
  "databases": $(printf '%s\n' "${databases_backed_up[@]}" | jq -R . | jq -s .),
  "status": "$status",
  "start_time": "$(jq -r '.start_time' < "$backup_config")",
  "end_time": "$end_time",
  "backup_size_bytes": $backup_size,
  "backup_size_human": "$(format_bytes $backup_size)",
  "backup_path": "$backup_path"
}
EOF
    
    # Create backup summary
    local summary_file="$backup_path/BACKUP_SUMMARY.md"
    cat > "$summary_file" << EOF
# MariaDB Backup Summary

**Backup Type**: $backup_type  
**Created**: $(date '+%Y-%m-%d %H:%M:%S')  
**Agent**: Claude-MariaDB Database Infrastructure Specialist  
**Status**: $status  

## Backup Details

- **MariaDB Version**: $(mysql -e "SELECT VERSION();" | tail -n 1)
- **Backup Size**: $(numfmt --to=iec $backup_size)
- **Databases**: ${#databases_backed_up[@]}
- **Compression**: gzip

## Databases Backed Up

$(for db in "${databases_backed_up[@]}"; do echo "- $db"; done)

## Files

\`\`\`
$(ls -la "$backup_path" | tail -n +2)
\`\`\`

## Recovery Instructions

To restore from this backup:

1. **Stop MariaDB service**: \`brew services stop mariadb\`
2. **Extract and restore databases**:
   \`\`\`bash
   cd "$backup_path"
   for db_file in *.sql.gz; do
     db_name=\${db_file%.sql.gz}
     gunzip -c "\$db_file" | mysql "\$db_name"
   done
   \`\`\`
3. **Start MariaDB service**: \`brew services start mariadb\`

Generated by Claude-MariaDB Infrastructure Specialist
EOF
    
    if [[ "$backup_success" == "true" ]]; then
        log "✅ $backup_type backup completed successfully: $backup_name"
        log "📦 Backup size: $(format_bytes $backup_size)"
        log "📁 Backup location: $backup_path"
    else
        log "❌ $backup_type backup completed with errors: $backup_name"
    fi
    
    return $([[ "$backup_success" == "true" ]] && echo 0 || echo 1)
}

# Function to verify backup integrity
verify_backup() {
    local backup_path="$1"
    
    if [[ ! -d "$backup_path" ]]; then
        log "❌ Backup directory not found: $backup_path"
        return 1
    fi
    
    log "🔍 Verifying backup integrity: $(basename "$backup_path")"
    
    local config_file="$backup_path/backup_config.json"
    if [[ ! -f "$config_file" ]]; then
        log "❌ Backup configuration file missing"
        return 1
    fi
    
    local backup_type=$(jq -r '.backup_type' < "$config_file")
    local verification_success=true
    
    case "$backup_type" in
        "full"|"schema")
            # Verify SQL dump files
            for sql_file in "$backup_path"/*.sql.gz; do
                if [[ -f "$sql_file" ]]; then
                    if gunzip -t "$sql_file" 2>/dev/null; then
                        log "✅ $(basename "$sql_file"): integrity OK"
                    else
                        log "❌ $(basename "$sql_file"): corruption detected"
                        verification_success=false
                    fi
                fi
            done
            ;;
            
        "config")
            # Verify configuration files exist
            local essential_files=("backup_config.json")
            for file in "${essential_files[@]}"; do
                if [[ -f "$backup_path/$file" ]]; then
                    log "✅ $file: present"
                else
                    log "❌ $file: missing"
                    verification_success=false
                fi
            done
            ;;
    esac
    
    if [[ "$verification_success" == "true" ]]; then
        log "✅ Backup verification passed: $(basename "$backup_path")"
        return 0
    else
        log "❌ Backup verification failed: $(basename "$backup_path")"
        return 1
    fi
}

# Function to list backups
list_backups() {
    log "📋 Available backups:"
    
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        log "No backups found"
        return 0
    fi
    
    for backup_dir in "$BACKUP_DIR"/mariadb_*; do
        if [[ -d "$backup_dir" ]]; then
            local config_file="$backup_dir/backup_config.json"
            if [[ -f "$config_file" ]]; then
                local name=$(basename "$backup_dir")
                local type=$(jq -r '.backup_type' < "$config_file" 2>/dev/null || echo "unknown")
                local status=$(jq -r '.status' < "$config_file" 2>/dev/null || echo "unknown")
                local size=$(jq -r '.backup_size_human' < "$config_file" 2>/dev/null || echo "unknown")
                local created=$(jq -r '.start_time' < "$config_file" 2>/dev/null || echo "unknown")
                
                echo "  📦 $name"
                echo "     Type: $type | Status: $status | Size: $size | Created: $created"
            fi
        fi
    done
}

# Function to cleanup old backups
cleanup_old_backups() {
    log "🧹 Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
    
    local deleted_count=0
    local saved_space=0
    
    find "$BACKUP_DIR" -type d -name "mariadb_*" -mtime +$BACKUP_RETENTION_DAYS | while read -r old_backup; do
        if [[ -d "$old_backup" ]]; then
            local backup_size=$(du -sb "$old_backup" 2>/dev/null | cut -f1 || echo "0")
            rm -rf "$old_backup"
            log "🗑️ Deleted old backup: $(basename "$old_backup")"
            deleted_count=$((deleted_count + 1))
            saved_space=$((saved_space + backup_size))
        fi
    done
    
    if [[ $deleted_count -gt 0 ]]; then
        log "✅ Cleanup completed: $deleted_count backups deleted, $(numfmt --to=iec $saved_space) freed"
    else
        log "✅ No old backups to clean up"
    fi
}

# Main command handling
case "${1:-help}" in
    "full")
        create_backup "full"
        ;;
    "config")
        create_backup "config"
        ;;
    "schema")
        create_backup "schema"
        ;;
    "verify")
        if [[ -n "${2:-}" ]]; then
            verify_backup "$BACKUP_DIR/$2"
        else
            echo "Usage: $0 verify <backup_name>"
            exit 1
        fi
        ;;
    "list")
        list_backups
        ;;
    "cleanup")
        cleanup_old_backups
        ;;
    "help"|*)
        echo "MariaDB Backup Manager - Claude-MariaDB Database Infrastructure Specialist"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  full      - Create full database backup (data + schema)"
        echo "  schema    - Create schema-only backup (no data)"
        echo "  config    - Create configuration backup (users, grants, config files)"
        echo "  verify    - Verify backup integrity: verify <backup_name>"
        echo "  list      - List all available backups"
        echo "  cleanup   - Remove backups older than $BACKUP_RETENTION_DAYS days"
        echo ""
        echo "Examples:"
        echo "  $0 full                                    # Create full backup"
        echo "  $0 verify mariadb_full_20250802_210000    # Verify specific backup"
        echo "  $0 list                                    # Show all backups"
        echo "  $0 cleanup                                 # Clean old backups"
        echo ""
        echo "Backup Location: $BACKUP_DIR"
        echo "Retention Policy: $BACKUP_RETENTION_DAYS days"
        exit 0
        ;;
esac