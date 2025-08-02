#!/bin/bash

# MariaDB Health Monitor Script
# Claude-MariaDB Database Infrastructure Specialist
# Enterprise-grade health monitoring for production MariaDB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
METRICS_DIR="${SCRIPT_DIR}/../metrics"

# Create directories if they don't exist
mkdir -p "$LOG_DIR" "$METRICS_DIR"

# Database connection parameters (using default auth)
DB_HOST="localhost"
DB_PORT="3306"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/health-monitor.log"
}

# Function to execute MySQL query safely
execute_query() {
    local query="$1"
    mysql -e "$query" 2>/dev/null
}

# Function to get numeric value from MySQL query
get_metric_value() {
    local query="$1"
    local result=$(execute_query "$query" | tail -n 1 | awk '{print $2}')
    # Return 0 if empty or invalid
    echo "${result:-0}"
}

# Function to check database connectivity
check_connectivity() {
    log "Checking MariaDB connectivity..."
    if execute_query "SELECT 1;" > /dev/null 2>&1; then
        echo "mariadb_up 1"
        log "✅ Database connectivity: OK"
        return 0
    else
        echo "mariadb_up 0"
        log "❌ Database connectivity: FAILED"
        return 1
    fi
}

# Function to collect basic metrics
collect_basic_metrics() {
    log "Collecting basic database metrics..."
    
    # Uptime
    local uptime=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Uptime';")
    echo "mariadb_uptime_seconds $uptime"
    
    # Connections
    local connections=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Connections';")
    echo "mariadb_connections_total $connections"
    
    local threads_connected=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Threads_connected';")
    echo "mariadb_threads_connected $threads_connected"
    
    local threads_running=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Threads_running';")
    echo "mariadb_threads_running $threads_running"
    
    # Buffer pool usage
    local buffer_pool_size=$(get_metric_value "SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';")
    echo "mariadb_innodb_buffer_pool_size_bytes $buffer_pool_size"
    
    # Query metrics
    local queries=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Queries';")
    echo "mariadb_queries_total $queries"
    
    local slow_queries=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Slow_queries';")
    echo "mariadb_slow_queries_total $slow_queries"
}

# Function to collect performance metrics
collect_performance_metrics() {
    log "Collecting performance metrics..."
    
    # InnoDB metrics
    local innodb_rows_read=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Innodb_rows_read';")
    echo "mariadb_innodb_rows_read_total $innodb_rows_read"
    
    local innodb_rows_inserted=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Innodb_rows_inserted';")
    echo "mariadb_innodb_rows_inserted_total $innodb_rows_inserted"
    
    local innodb_rows_updated=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Innodb_rows_updated';")
    echo "mariadb_innodb_rows_updated_total $innodb_rows_updated"
    
    local innodb_rows_deleted=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Innodb_rows_deleted';")
    echo "mariadb_innodb_rows_deleted_total $innodb_rows_deleted"
    
    # Command counters
    local com_select=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Com_select';")
    echo "mariadb_commands_select_total $com_select"
    
    local com_insert=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Com_insert';")
    echo "mariadb_commands_insert_total $com_insert"
    
    local com_update=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Com_update';")
    echo "mariadb_commands_update_total $com_update"
    
    local com_delete=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Com_delete';")
    echo "mariadb_commands_delete_total $com_delete"
}

# Function to collect database size metrics
collect_size_metrics() {
    log "Collecting database size metrics..."
    
    # Database sizes
    execute_query "SELECT 
        table_schema as database_name,
        ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS size_mb
    FROM information_schema.tables 
    WHERE table_schema NOT IN ('information_schema', 'performance_schema')
    GROUP BY table_schema;" | tail -n +2 | while read -r db_name size_mb; do
        # Replace any problematic characters in database name for Prometheus
        clean_db_name=$(echo "$db_name" | sed 's/[^a-zA-Z0-9_]/_/g')
        echo "mariadb_database_size_bytes{database=\"$db_name\"} $(echo "$size_mb * 1024 * 1024" | bc)"
    done
}

# Function to check for recent errors
check_error_log() {
    log "Checking error log for recent issues..."
    
    local error_log="/opt/homebrew/var/mysql/Jacos-Mac-mini-2.local.err"
    local recent_errors=0
    
    if [[ -f "$error_log" ]]; then
        # Count errors from last 24 hours
        recent_errors=$(grep -c "$(date -v-1d '+%Y-%m-%d')" "$error_log" 2>/dev/null || echo "0")
    fi
    
    echo "mariadb_recent_errors_total $recent_errors"
}

# Main monitoring function
main() {
    log "🚀 Starting MariaDB health monitoring..."
    
    local metrics_file="$METRICS_DIR/mariadb_metrics.prom"
    local temp_file="$metrics_file.tmp"
    
    {
        echo "# HELP mariadb_up Whether MariaDB is up and responding"
        echo "# TYPE mariadb_up gauge"
        
        if check_connectivity; then
            collect_basic_metrics
            collect_performance_metrics
            collect_size_metrics
            check_error_log
        fi
        
        echo "# Metrics generated at $(date '+%Y-%m-%d %H:%M:%S')"
    } > "$temp_file"
    
    # Atomically replace the metrics file
    mv "$temp_file" "$metrics_file"
    
    log "✅ Metrics collection completed: $metrics_file"
    
    # Also create a JSON health status for easy consumption
    create_health_status
}

# Function to create JSON health status
create_health_status() {
    local health_file="$METRICS_DIR/health_status.json"
    local temp_file="$health_file.tmp"
    
    if execute_query "SELECT 1;" > /dev/null 2>&1; then
        local uptime=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Uptime';")
        local connections=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Connections';")
        local threads_connected=$(get_metric_value "SHOW GLOBAL STATUS LIKE 'Threads_connected';")
        
        cat > "$temp_file" << EOF
{
  "status": "healthy",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "uptime_seconds": $uptime,
  "total_connections": $connections,
  "current_connections": $threads_connected,
  "version": "$(execute_query "SELECT VERSION();" | tail -n 1)",
  "agent": "Claude-MariaDB",
  "last_check": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    else
        cat > "$temp_file" << EOF
{
  "status": "unhealthy",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "error": "Database connection failed",
  "agent": "Claude-MariaDB",
  "last_check": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    fi
    
    mv "$temp_file" "$health_file"
}

# Handle script arguments
case "${1:-health}" in
    "health")
        main
        ;;
    "test")
        log "🧪 Testing database connectivity..."
        check_connectivity
        ;;
    "metrics-only")
        check_connectivity && collect_basic_metrics
        ;;
    *)
        echo "Usage: $0 [health|test|metrics-only]"
        echo "  health       - Full health check and metrics collection (default)"
        echo "  test         - Test database connectivity only"
        echo "  metrics-only - Collect basic metrics only"
        exit 1
        ;;
esac