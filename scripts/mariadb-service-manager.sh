#!/bin/bash

# MariaDB Service Manager
# Claude-MariaDB Database Infrastructure Specialist
# Production-safe service management for MariaDB monitoring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_DIR/logs"
METRICS_DIR="$PROJECT_DIR/metrics"
PIDS_DIR="$PROJECT_DIR/pids"

# Create required directories
mkdir -p "$LOGS_DIR" "$METRICS_DIR" "$PIDS_DIR"

# Service configuration
PROMETHEUS_EXPORTER_PORT=9104
PROMETHEUS_EXPORTER_PID_FILE="$PIDS_DIR/prometheus-exporter.pid"
MONITOR_PID_FILE="$PIDS_DIR/health-monitor.pid"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGS_DIR/service-manager.log"
}

# Function to check if process is running
is_process_running() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$pid_file"
            return 1
        fi
    fi
    return 1
}

# Function to start Prometheus exporter
start_prometheus_exporter() {
    log "🚀 Starting MariaDB Prometheus Exporter..."
    
    if is_process_running "$PROMETHEUS_EXPORTER_PID_FILE"; then
        log "⚠️ Prometheus exporter is already running"
        return 0
    fi
    
    # Start the exporter in background
    cd "$SCRIPT_DIR"
    nohup python3 prometheus-exporter.py > "$LOGS_DIR/prometheus-exporter.out" 2>&1 &
    local pid=$!
    echo "$pid" > "$PROMETHEUS_EXPORTER_PID_FILE"
    
    # Wait a moment and check if it started successfully
    sleep 2
    if is_process_running "$PROMETHEUS_EXPORTER_PID_FILE"; then
        log "✅ Prometheus exporter started successfully (PID: $pid)"
        log "📊 Metrics endpoint: http://localhost:$PROMETHEUS_EXPORTER_PORT/metrics"
        log "🏥 Health endpoint: http://localhost:$PROMETHEUS_EXPORTER_PORT/health"
    else
        log "❌ Failed to start Prometheus exporter"
        return 1
    fi
}

# Function to stop Prometheus exporter
stop_prometheus_exporter() {
    log "🛑 Stopping MariaDB Prometheus Exporter..."
    
    if is_process_running "$PROMETHEUS_EXPORTER_PID_FILE"; then
        local pid=$(cat "$PROMETHEUS_EXPORTER_PID_FILE")
        kill "$pid"
        rm -f "$PROMETHEUS_EXPORTER_PID_FILE"
        log "✅ Prometheus exporter stopped (PID: $pid)"
    else
        log "⚠️ Prometheus exporter is not running"
    fi
}

# Function to check service status
check_status() {
    log "📊 Checking MariaDB monitoring services status..."
    
    echo "=== MariaDB Database Status ==="
    if mysql -e "SELECT 1;" > /dev/null 2>&1; then
        echo "✅ MariaDB Database: HEALTHY"
        mysql -e "SELECT CONCAT('Uptime: ', ROUND((SELECT VARIABLE_VALUE FROM INFORMATION_SCHEMA.GLOBAL_STATUS WHERE VARIABLE_NAME='UPTIME')/86400), ' days, ', VERSION()) as status;"
    else
        echo "❌ MariaDB Database: UNREACHABLE"
    fi
    
    echo ""
    echo "=== Monitoring Services Status ==="
    
    if is_process_running "$PROMETHEUS_EXPORTER_PID_FILE"; then
        local pid=$(cat "$PROMETHEUS_EXPORTER_PID_FILE")
        echo "✅ Prometheus Exporter: RUNNING (PID: $pid)"
        echo "   📊 Metrics: http://localhost:$PROMETHEUS_EXPORTER_PORT/metrics"
        echo "   🏥 Health: http://localhost:$PROMETHEUS_EXPORTER_PORT/health"
    else
        echo "❌ Prometheus Exporter: STOPPED"
    fi
    
    echo ""
    echo "=== Recent Metrics ==="
    if [[ -f "$METRICS_DIR/health_status.json" ]]; then
        cat "$METRICS_DIR/health_status.json"
    else
        echo "No metrics available yet"
    fi
}

# Function to test monitoring
test_monitoring() {
    log "🧪 Testing MariaDB monitoring system..."
    
    # Test database connectivity
    if ! "$SCRIPT_DIR/mariadb-health-monitor.sh" test; then
        log "❌ Database connectivity test failed"
        return 1
    fi
    
    # Test metrics collection
    log "Testing metrics collection..."
    if "$SCRIPT_DIR/mariadb-health-monitor.sh" health; then
        log "✅ Metrics collection test passed"
    else
        log "❌ Metrics collection test failed"
        return 1
    fi
    
    # Test Prometheus exporter if running
    if is_process_running "$PROMETHEUS_EXPORTER_PID_FILE"; then
        log "Testing Prometheus exporter endpoints..."
        if curl -s "http://localhost:$PROMETHEUS_EXPORTER_PORT/health" > /dev/null; then
            log "✅ Prometheus exporter health endpoint: OK"
        else
            log "⚠️ Prometheus exporter health endpoint: UNREACHABLE"
        fi
        
        if curl -s "http://localhost:$PROMETHEUS_EXPORTER_PORT/metrics" | grep -q "mariadb_up"; then
            log "✅ Prometheus exporter metrics endpoint: OK"
        else
            log "⚠️ Prometheus exporter metrics endpoint: NO DATA"
        fi
    fi
    
    log "✅ Monitoring system test completed"
}

# Function to show logs
show_logs() {
    local service="${1:-all}"
    
    case "$service" in
        "exporter")
            echo "=== Prometheus Exporter Logs ==="
            tail -50 "$LOGS_DIR/prometheus-exporter.log" 2>/dev/null || echo "No exporter logs found"
            ;;
        "monitor")
            echo "=== Health Monitor Logs ==="
            tail -50 "$LOGS_DIR/health-monitor.log" 2>/dev/null || echo "No monitor logs found"
            ;;
        "service")
            echo "=== Service Manager Logs ==="
            tail -50 "$LOGS_DIR/service-manager.log" 2>/dev/null || echo "No service logs found"
            ;;
        "all"|*)
            show_logs "exporter"
            echo ""
            show_logs "monitor"
            echo ""
            show_logs "service"
            ;;
    esac
}

# Function to clean up old logs and metrics
cleanup() {
    log "🧹 Cleaning up old logs and metrics..."
    
    # Keep only last 7 days of logs
    find "$LOGS_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    find "$LOGS_DIR" -name "*.out" -mtime +7 -delete 2>/dev/null || true
    
    # Keep only last 24 hours of metrics files (except current)
    find "$METRICS_DIR" -name "*.prom.old" -mtime +1 -delete 2>/dev/null || true
    
    log "✅ Cleanup completed"
}

# Main command handling
case "${1:-status}" in
    "start")
        log "🚀 Starting MariaDB monitoring services..."
        start_prometheus_exporter
        log "✅ All services started"
        ;;
    "stop")
        log "🛑 Stopping MariaDB monitoring services..."
        stop_prometheus_exporter
        log "✅ All services stopped"
        ;;
    "restart")
        log "🔄 Restarting MariaDB monitoring services..."
        stop_prometheus_exporter
        sleep 2
        start_prometheus_exporter
        log "✅ Services restarted"
        ;;
    "status")
        check_status
        ;;
    "test")
        test_monitoring
        ;;
    "logs")
        show_logs "${2:-all}"
        ;;
    "cleanup")
        cleanup
        ;;
    *)
        echo "MariaDB Service Manager - Claude-MariaDB Database Infrastructure Specialist"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  start     - Start all monitoring services"
        echo "  stop      - Stop all monitoring services"
        echo "  restart   - Restart all monitoring services"
        echo "  status    - Show status of all services (default)"
        echo "  test      - Test monitoring system functionality"
        echo "  logs      - Show service logs [exporter|monitor|service|all]"
        echo "  cleanup   - Clean up old logs and metrics"
        echo ""
        echo "Examples:"
        echo "  $0 start"
        echo "  $0 status"
        echo "  $0 logs exporter"
        echo "  $0 test"
        exit 1
        ;;
esac