#!/usr/bin/env python3

"""
MariaDB Prometheus Exporter
Claude-MariaDB Database Infrastructure Specialist
Enterprise-grade Prometheus metrics endpoint for MariaDB monitoring
"""

import json
import os
import subprocess
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import threading
import logging
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/Users/jacocoetzee/Documents/Projects/infra/mariadb/logs/prometheus-exporter.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger('MariaDB-Prometheus-Exporter')

class MariaDBExporter:
    def __init__(self):
        self.script_dir = os.path.dirname(os.path.abspath(__file__))
        self.metrics_file = os.path.join(self.script_dir, '../metrics/mariadb_metrics.prom')
        self.health_file = os.path.join(self.script_dir, '../metrics/health_status.json')
        self.monitor_script = os.path.join(self.script_dir, 'mariadb-health-monitor.sh')
        
        # Ensure directories exist
        os.makedirs(os.path.dirname(self.metrics_file), exist_ok=True)
        os.makedirs(os.path.dirname(self.health_file), exist_ok=True)
        os.makedirs(os.path.dirname('/Users/jacocoetzee/Documents/Projects/infra/mariadb/logs/prometheus-exporter.log'), exist_ok=True)
        
        # Start background metrics collection
        self.start_metrics_collection()
    
    def start_metrics_collection(self):
        """Start background thread for metrics collection"""
        def collect_metrics():
            while True:
                try:
                    logger.info("Collecting MariaDB metrics...")
                    result = subprocess.run([self.monitor_script, 'health'], 
                                          capture_output=True, text=True, timeout=30)
                    if result.returncode == 0:
                        logger.info("✅ Metrics collection successful")
                    else:
                        logger.error(f"❌ Metrics collection failed: {result.stderr}")
                except subprocess.TimeoutExpired:
                    logger.error("❌ Metrics collection timed out")
                except Exception as e:
                    logger.error(f"❌ Metrics collection error: {e}")
                
                # Collect metrics every 15 seconds
                time.sleep(15)
        
        metrics_thread = threading.Thread(target=collect_metrics, daemon=True)
        metrics_thread.start()
        logger.info("🚀 Background metrics collection started")
    
    def get_metrics(self):
        """Get Prometheus metrics"""
        try:
            if os.path.exists(self.metrics_file):
                with open(self.metrics_file, 'r') as f:
                    metrics_content = f.read()
                
                # Add exporter-specific metrics
                exporter_metrics = f"""
# HELP mariadb_exporter_up Whether the MariaDB exporter is running
# TYPE mariadb_exporter_up gauge
mariadb_exporter_up 1

# HELP mariadb_exporter_last_scrape_timestamp_seconds Timestamp of the last successful scrape
# TYPE mariadb_exporter_last_scrape_timestamp_seconds gauge
mariadb_exporter_last_scrape_timestamp_seconds {time.time()}

"""
                return exporter_metrics + metrics_content
            else:
                logger.warning("⚠️ Metrics file not found, returning basic metrics")
                return f"""
# HELP mariadb_exporter_up Whether the MariaDB exporter is running
# TYPE mariadb_exporter_up gauge
mariadb_exporter_up 1

# HELP mariadb_up Whether MariaDB is up and responding
# TYPE mariadb_up gauge
mariadb_up 0

# Metrics file not available at {datetime.now()}
"""
        except Exception as e:
            logger.error(f"❌ Error reading metrics: {e}")
            return f"""
# HELP mariadb_exporter_up Whether the MariaDB exporter is running
# TYPE mariadb_exporter_up gauge
mariadb_exporter_up 1

# HELP mariadb_up Whether MariaDB is up and responding
# TYPE mariadb_up gauge
mariadb_up 0

# Error reading metrics: {e}
"""
    
    def get_health_status(self):
        """Get JSON health status"""
        try:
            if os.path.exists(self.health_file):
                with open(self.health_file, 'r') as f:
                    return json.load(f)
            else:
                return {
                    "status": "unknown",
                    "timestamp": datetime.utcnow().isoformat() + "Z",
                    "error": "Health status file not found",
                    "agent": "Claude-MariaDB",
                    "exporter_status": "running"
                }
        except Exception as e:
            logger.error(f"❌ Error reading health status: {e}")
            return {
                "status": "error",
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "error": str(e),
                "agent": "Claude-MariaDB",
                "exporter_status": "running"
            }

class PrometheusHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, exporter=None, **kwargs):
        self.exporter = exporter
        super().__init__(*args, **kwargs)
    
    def do_GET(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/metrics':
            self.handle_metrics()
        elif parsed_path.path == '/health':
            self.handle_health()
        elif parsed_path.path == '/':
            self.handle_root()
        else:
            self.send_error(404, "Not Found")
    
    def handle_metrics(self):
        """Handle /metrics endpoint for Prometheus"""
        try:
            metrics = self.exporter.get_metrics()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(metrics.encode('utf-8'))
            logger.info(f"📊 Served metrics to {self.client_address[0]}")
        except Exception as e:
            logger.error(f"❌ Error serving metrics: {e}")
            self.send_error(500, f"Internal Server Error: {e}")
    
    def handle_health(self):
        """Handle /health endpoint for health checks"""
        try:
            health_status = self.exporter.get_health_status()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(health_status, indent=2).encode('utf-8'))
            logger.info(f"🏥 Served health status to {self.client_address[0]}")
        except Exception as e:
            logger.error(f"❌ Error serving health status: {e}")
            self.send_error(500, f"Internal Server Error: {e}")
    
    def handle_root(self):
        """Handle root endpoint with information about available endpoints"""
        info_html = """
<!DOCTYPE html>
<html>
<head>
    <title>MariaDB Prometheus Exporter</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .header { color: #2c3e50; }
        .endpoint { background: #ecf0f1; padding: 10px; margin: 10px 0; border-radius: 5px; }
        .status { color: #27ae60; font-weight: bold; }
    </style>
</head>
<body>
    <h1 class="header">🗄️ MariaDB Prometheus Exporter</h1>
    <p><span class="status">Status: RUNNING</span></p>
    <p>Managed by: <strong>Claude-MariaDB (Database Infrastructure Specialist)</strong></p>
    
    <h2>Available Endpoints:</h2>
    <div class="endpoint">
        <strong>GET /metrics</strong><br>
        Prometheus-format metrics for database monitoring
    </div>
    <div class="endpoint">
        <strong>GET /health</strong><br>
        JSON health status for database and exporter
    </div>
    
    <h2>Service Information:</h2>
    <ul>
        <li>Database: MariaDB 11.5.2</li>
        <li>Metrics Collection: Every 15 seconds</li>
        <li>Agent: Claude-MariaDB Infrastructure Specialist</li>
        <li>Purpose: Enterprise database monitoring</li>
    </ul>
    
    <p><em>Generated at: """ + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + """</em></p>
</body>
</html>
"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(info_html.encode('utf-8'))
    
    def log_message(self, format, *args):
        # Suppress default HTTP server logging to avoid spam
        pass

def create_handler(exporter):
    """Create handler with exporter instance"""
    def handler(*args, **kwargs):
        return PrometheusHandler(*args, exporter=exporter, **kwargs)
    return handler

def main():
    port = 9104  # Standard MariaDB exporter port
    
    logger.info("🚀 Starting MariaDB Prometheus Exporter...")
    logger.info(f"📊 Agent: Claude-MariaDB Database Infrastructure Specialist")
    
    try:
        exporter = MariaDBExporter()
        handler = create_handler(exporter)
        
        httpd = HTTPServer(('0.0.0.0', port), handler)
        
        logger.info(f"✅ MariaDB Prometheus Exporter started on port {port}")
        logger.info(f"📊 Metrics endpoint: http://localhost:{port}/metrics")
        logger.info(f"🏥 Health endpoint: http://localhost:{port}/health")
        logger.info(f"🌐 Web interface: http://localhost:{port}/")
        
        httpd.serve_forever()
        
    except KeyboardInterrupt:
        logger.info("🛑 Shutting down MariaDB Prometheus Exporter...")
    except Exception as e:
        logger.error(f"❌ Failed to start exporter: {e}")
        raise

if __name__ == '__main__':
    main()