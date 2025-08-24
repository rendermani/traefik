#!/bin/bash

# Service Discovery and Health Check Script

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[CHECK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Service definitions with health endpoints
declare -A SERVICES=(
    ["vault"]="8200:/v1/sys/health"
    ["nomad"]="4646:/v1/status/leader"
    ["prometheus"]="9090:/-/healthy"
    ["grafana"]="3000:/api/health"
    ["loki"]="3100:/ready"
    ["minio"]="9000:/minio/health/live"
    ["backend"]="8000:/health"
    ["frontend"]="3001:/"
    ["postgres"]="5432:"
    ["redis"]="6379:"
)

# Check individual service
check_service() {
    local NAME=$1
    local CONFIG=$2
    
    IFS=':' read -r PORT ENDPOINT <<< "$CONFIG"
    
    if [ -z "$ENDPOINT" ]; then
        # TCP check only (for databases)
        if nc -z localhost "$PORT" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        # HTTP health check
        if curl -f -s --max-time 2 "http://localhost:${PORT}${ENDPOINT}" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi
}

# Discover all services
discover_services() {
    log_step "Discovering services..."
    
    FOUND_SERVICES=()
    MISSING_SERVICES=()
    
    for SERVICE in "${!SERVICES[@]}"; do
        if check_service "$SERVICE" "${SERVICES[$SERVICE]}"; then
            FOUND_SERVICES+=("$SERVICE")
            IFS=':' read -r PORT ENDPOINT <<< "${SERVICES[$SERVICE]}"
            log_info "✅ $SERVICE detected on port $PORT"
        else
            MISSING_SERVICES+=("$SERVICE")
        fi
    done
    
    echo ""
    if [ ${#FOUND_SERVICES[@]} -gt 0 ]; then
        log_info "Found ${#FOUND_SERVICES[@]} services:"
        for SERVICE in "${FOUND_SERVICES[@]}"; do
            echo "  - $SERVICE"
        done
    fi
    
    if [ ${#MISSING_SERVICES[@]} -gt 0 ]; then
        log_warn "Missing ${#MISSING_SERVICES[@]} services:"
        for SERVICE in "${MISSING_SERVICES[@]}"; do
            echo "  - $SERVICE"
        done
    fi
}

# Check Traefik routing
check_routing() {
    log_step "Checking Traefik routing..."
    
    DOMAIN="${1:-cloudya.net}"
    
    # Check if Traefik is running
    if ! systemctl is-active traefik >/dev/null 2>&1; then
        log_error "Traefik is not running"
        return 1
    fi
    
    # Check Traefik API
    if curl -f -s http://localhost:8080/api/http/routers 2>/dev/null | jq -e . >/dev/null 2>&1; then
        ROUTERS=$(curl -s http://localhost:8080/api/http/routers | jq -r '.[].name')
        log_info "Active routers:"
        echo "$ROUTERS" | while read -r ROUTER; do
            echo "  - $ROUTER"
        done
    else
        log_warn "Cannot access Traefik API"
    fi
    
    # Check service endpoints
    echo ""
    log_step "Testing service endpoints..."
    
    for SERVICE in "${FOUND_SERVICES[@]}"; do
        case $SERVICE in
            vault) SUBDOMAIN="vault" ;;
            nomad) SUBDOMAIN="nomad" ;;
            prometheus) SUBDOMAIN="metrics" ;;
            grafana) SUBDOMAIN="grafana" ;;
            loki) SUBDOMAIN="logs" ;;
            minio) SUBDOMAIN="storage" ;;
            backend) SUBDOMAIN="api" ;;
            frontend) SUBDOMAIN="app" ;;
            *) continue ;;
        esac
        
        URL="https://${SUBDOMAIN}.${DOMAIN}"
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -L "$URL" 2>/dev/null || echo "000")
        
        case $STATUS in
            200|301|302|401)
                log_info "✅ $URL - HTTP $STATUS"
                ;;
            000)
                log_error "❌ $URL - Connection failed"
                ;;
            *)
                log_warn "⚠️ $URL - HTTP $STATUS"
                ;;
        esac
    done
}

# Generate Traefik configuration
generate_config() {
    log_step "Generating Traefik configuration..."
    
    OUTPUT_DIR="${1:-/tmp}"
    
    # Generate services configuration
    cat > "$OUTPUT_DIR/services.yml" << EOF
http:
  services:
EOF
    
    for SERVICE in "${FOUND_SERVICES[@]}"; do
        IFS=':' read -r PORT ENDPOINT <<< "${SERVICES[$SERVICE]}"
        
        # Skip non-HTTP services
        if [ -z "$ENDPOINT" ]; then
            continue
        fi
        
        cat >> "$OUTPUT_DIR/services.yml" << EOF
    ${SERVICE}:
      loadBalancer:
        servers:
          - url: "http://localhost:${PORT}"
EOF
        
        # Add health check if available
        if [ -n "$ENDPOINT" ]; then
            cat >> "$OUTPUT_DIR/services.yml" << EOF
        healthCheck:
          path: "${ENDPOINT}"
          interval: 10s
          timeout: 3s
EOF
        fi
    done
    
    log_info "Configuration generated at $OUTPUT_DIR/services.yml"
}

# Monitor service health
monitor_health() {
    log_step "Monitoring service health..."
    
    INTERVAL="${1:-5}"
    DURATION="${2:-60}"
    
    END_TIME=$(($(date +%s) + DURATION))
    
    while [ $(date +%s) -lt $END_TIME ]; do
        clear
        echo "=== Service Health Monitor ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        for SERVICE in "${!SERVICES[@]}"; do
            if check_service "$SERVICE" "${SERVICES[$SERVICE]}"; then
                echo -e "${GREEN}✅${NC} $SERVICE: UP"
            else
                echo -e "${RED}❌${NC} $SERVICE: DOWN"
            fi
        done
        
        echo ""
        echo "Press Ctrl+C to stop monitoring"
        sleep "$INTERVAL"
    done
}

# Export Prometheus metrics
export_metrics() {
    log_step "Exporting metrics..."
    
    METRICS_FILE="${1:-/var/lib/node_exporter/traefik_services.prom}"
    
    # Create metrics file
    cat > "$METRICS_FILE" << EOF
# HELP traefik_service_up Service availability (1 = up, 0 = down)
# TYPE traefik_service_up gauge
EOF
    
    for SERVICE in "${!SERVICES[@]}"; do
        if check_service "$SERVICE" "${SERVICES[$SERVICE]}"; then
            echo "traefik_service_up{service=\"$SERVICE\"} 1" >> "$METRICS_FILE"
        else
            echo "traefik_service_up{service=\"$SERVICE\"} 0" >> "$METRICS_FILE"
        fi
    done
    
    log_info "Metrics exported to $METRICS_FILE"
}

# Main execution
ACTION="${1:-discover}"

case "$ACTION" in
    discover)
        discover_services
        ;;
    routing)
        discover_services
        check_routing "$2"
        ;;
    generate)
        discover_services
        generate_config "$2"
        ;;
    monitor)
        monitor_health "$2" "$3"
        ;;
    metrics)
        export_metrics "$2"
        ;;
    all)
        discover_services
        echo ""
        check_routing
        ;;
    *)
        echo "Usage: $0 <action> [options]"
        echo ""
        echo "Actions:"
        echo "  discover         - Discover available services"
        echo "  routing [domain] - Check Traefik routing"
        echo "  generate [dir]   - Generate Traefik configuration"
        echo "  monitor [interval] [duration] - Monitor service health"
        echo "  metrics [file]   - Export Prometheus metrics"
        echo "  all             - Run all checks"
        ;;
esac