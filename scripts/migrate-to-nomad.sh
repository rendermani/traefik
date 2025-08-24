#!/bin/bash

# Migrate Traefik from systemd to Nomad deployment
# This script provides zero-downtime migration

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[MIGRATE]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Configuration
ACTION="${1:-check}"
ROLLBACK_ENABLED=true
BACKUP_DIR="/backups/traefik/migration-$(date +%Y%m%d-%H%M%S)"

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check if Traefik is running via systemd
    if systemctl is-active traefik >/dev/null 2>&1; then
        log_info "✅ Traefik running via systemd"
        CURRENT_MODE="systemd"
    else
        CURRENT_MODE="unknown"
    fi
    
    # Check if Nomad is running
    if ! systemctl is-active nomad >/dev/null 2>&1; then
        log_error "❌ Nomad is not running"
        exit 1
    fi
    log_info "✅ Nomad is running"
    
    # Check if Nomad job exists
    if nomad job status traefik >/dev/null 2>&1; then
        log_warn "⚠️ Traefik job already exists in Nomad"
        NOMAD_JOB_EXISTS=true
    else
        NOMAD_JOB_EXISTS=false
    fi
    
    # Check certificate files
    if [ -f /etc/traefik/acme.json ]; then
        log_info "✅ Certificate file found"
        CERT_SIZE=$(stat -c%s /etc/traefik/acme.json)
        log_info "  Certificate file size: $CERT_SIZE bytes"
    else
        log_warn "⚠️ No certificate file found"
    fi
    
    echo ""
    log_info "Current deployment mode: $CURRENT_MODE"
    log_info "Nomad job exists: $NOMAD_JOB_EXISTS"
}

# Backup current configuration
backup_configuration() {
    log_step "Creating backup..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup systemd service
    if [ -f /etc/systemd/system/traefik.service ]; then
        cp /etc/systemd/system/traefik.service "$BACKUP_DIR/"
    fi
    
    # Backup Traefik configuration
    if [ -d /etc/traefik ]; then
        tar -czf "$BACKUP_DIR/traefik-config.tar.gz" /etc/traefik/
    fi
    
    # Backup certificates
    if [ -f /etc/traefik/acme.json ]; then
        cp /etc/traefik/acme.json "$BACKUP_DIR/acme.json"
        chmod 600 "$BACKUP_DIR/acme.json"
    fi
    
    # Save current state
    cat > "$BACKUP_DIR/state.json" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "mode": "$CURRENT_MODE",
  "traefik_version": "$(traefik version 2>/dev/null | grep Version | cut -d: -f2 | xargs || echo 'unknown')",
  "nomad_job_exists": $NOMAD_JOB_EXISTS
}
EOF
    
    log_info "✅ Backup created at: $BACKUP_DIR"
}

# Prepare Nomad directories
prepare_nomad_env() {
    log_step "Preparing Nomad environment..."
    
    # Create directories for Nomad
    mkdir -p /opt/traefik/{config,acme,dynamic}
    mkdir -p /backups/traefik
    
    # Copy current configuration
    if [ -d /etc/traefik ]; then
        log_info "Copying configuration files..."
        
        # Copy static config
        if [ -f /etc/traefik/traefik.yml ]; then
            cp /etc/traefik/traefik.yml /opt/traefik/config/
        fi
        
        # Copy dynamic configs
        if [ -d /etc/traefik/dynamic ]; then
            cp -r /etc/traefik/dynamic/* /opt/traefik/dynamic/ 2>/dev/null || true
        fi
        
        # Copy certificates with proper permissions
        if [ -f /etc/traefik/acme.json ]; then
            cp /etc/traefik/acme.json /opt/traefik/acme/acme.json
            chmod 600 /opt/traefik/acme/acme.json
        fi
    fi
    
    # Store configuration in Consul/Vault if available
    if command -v consul >/dev/null 2>&1; then
        log_info "Storing configuration in Consul..."
        
        # Store ACME email
        if [ -f /root/traefik-credentials.txt ]; then
            ACME_EMAIL=$(grep -E "^[^@]+@[^@]+\.[^@]+$" /etc/traefik/traefik.yml | head -1 | xargs)
            consul kv put traefik/config/acme_email "$ACME_EMAIL" || true
        fi
        
        # Store dashboard auth
        if [ -f /etc/traefik/dynamic/middlewares.yml ]; then
            DASHBOARD_AUTH=$(grep -A2 "auth-dashboard:" /etc/traefik/dynamic/middlewares.yml | grep "users:" -A1 | tail -1 | xargs)
            consul kv put traefik/auth/dashboard "$DASHBOARD_AUTH" || true
        fi
    fi
    
    log_info "✅ Nomad environment prepared"
}

# Deploy Traefik to Nomad
deploy_to_nomad() {
    log_step "Deploying Traefik to Nomad..."
    
    # Create the job file
    cat > /tmp/traefik.nomad << 'EOF'
job "traefik" {
  datacenters = ["dc1"]
  type        = "system"
  priority    = 90

  update {
    max_parallel      = 1
    health_check      = "checks"
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    auto_revert       = true
  }

  group "traefik" {
    network {
      mode = "host"
      port "web" { static = 80 }
      port "websecure" { static = 443 }
      port "dashboard" { static = 8080 }
      port "metrics" { static = 8082 }
    }

    task "traefik" {
      driver = "docker"
      
      config {
        image = "traefik:3.2.3"
        network_mode = "host"
        
        volumes = [
          "/opt/traefik/config:/etc/traefik:ro",
          "/opt/traefik/acme:/acme",
          "/opt/traefik/dynamic:/etc/traefik/dynamic:ro"
        ]
        
        args = [
          "--configfile=/etc/traefik/traefik.yml",
          "--api.dashboard=true",
          "--ping=true"
        ]
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name = "traefik"
        port = "web"
        
        check {
          type     = "http"
          path     = "/ping"
          port     = "web"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
EOF
    
    # Plan the job
    log_info "Planning Nomad job..."
    nomad job plan /tmp/traefik.nomad
    
    # Deploy the job
    log_info "Deploying job to Nomad..."
    if nomad job run -check-index 0 /tmp/traefik.nomad; then
        log_info "✅ Job submitted to Nomad"
    else
        log_error "❌ Failed to deploy to Nomad"
        return 1
    fi
    
    # Wait for deployment
    log_info "Waiting for Nomad deployment..."
    sleep 10
    
    # Check deployment status
    if nomad job status traefik | grep -q "running"; then
        log_info "✅ Traefik running on Nomad"
    else
        log_error "❌ Traefik not running on Nomad"
        return 1
    fi
}

# Perform cutover from systemd to Nomad
perform_cutover() {
    log_step "Performing cutover..."
    
    # Test Nomad deployment first
    log_info "Testing Nomad deployment..."
    if curl -f -s http://localhost:8080/ping >/dev/null 2>&1; then
        log_info "✅ Nomad Traefik is responding"
    else
        log_error "❌ Nomad Traefik not responding"
        return 1
    fi
    
    # Stop systemd Traefik
    log_info "Stopping systemd Traefik..."
    systemctl stop traefik
    systemctl disable traefik
    
    # Quick health check
    sleep 5
    if curl -f -s http://localhost/ping >/dev/null 2>&1; then
        log_info "✅ Traffic successfully routed through Nomad Traefik"
    else
        log_error "❌ Traffic not being routed"
        
        if [ "$ROLLBACK_ENABLED" = true ]; then
            log_warn "Initiating rollback..."
            rollback
        fi
        return 1
    fi
    
    log_info "✅ Cutover completed successfully"
}

# Rollback to systemd
rollback() {
    log_step "Rolling back to systemd..."
    
    # Stop Nomad job
    nomad job stop -purge traefik || true
    
    # Restore systemd service
    systemctl start traefik
    systemctl enable traefik
    
    # Verify rollback
    if systemctl is-active traefik >/dev/null 2>&1; then
        log_info "✅ Rolled back to systemd successfully"
    else
        log_error "❌ Rollback failed!"
        exit 1
    fi
}

# Verify migration
verify_migration() {
    log_step "Verifying migration..."
    
    CHECKS_PASSED=0
    CHECKS_FAILED=0
    
    # Check Nomad job status
    echo -n "Nomad job status: "
    if nomad job status traefik 2>/dev/null | grep -q "running"; then
        log_pass "PASS"
        ((CHECKS_PASSED++))
    else
        log_error "FAIL"
        ((CHECKS_FAILED++))
    fi
    
    # Check HTTP endpoint
    echo -n "HTTP endpoint: "
    if curl -f -s http://localhost/ping >/dev/null 2>&1; then
        log_pass "PASS"
        ((CHECKS_PASSED++))
    else
        log_error "FAIL"
        ((CHECKS_FAILED++))
    fi
    
    # Check HTTPS redirect
    echo -n "HTTPS redirect: "
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
    if [ "$STATUS" = "301" ] || [ "$STATUS" = "308" ]; then
        log_pass "PASS"
        ((CHECKS_PASSED++))
    else
        log_error "FAIL (Status: $STATUS)"
        ((CHECKS_FAILED++))
    fi
    
    # Check certificate persistence
    echo -n "Certificate file: "
    if [ -f /opt/traefik/acme/acme.json ]; then
        log_pass "PASS"
        ((CHECKS_PASSED++))
    else
        log_error "FAIL"
        ((CHECKS_FAILED++))
    fi
    
    # Check metrics endpoint
    echo -n "Metrics endpoint: "
    if curl -f -s http://localhost:8082/metrics | grep -q "traefik_"; then
        log_pass "PASS"
        ((CHECKS_PASSED++))
    else
        log_error "FAIL"
        ((CHECKS_FAILED++))
    fi
    
    echo ""
    log_info "Verification Results:"
    log_info "  Passed: $CHECKS_PASSED"
    log_info "  Failed: $CHECKS_FAILED"
    
    if [ $CHECKS_FAILED -eq 0 ]; then
        log_info "✅ All checks passed!"
        return 0
    else
        log_error "❌ Some checks failed"
        return 1
    fi
}

# Clean up old systemd files
cleanup_systemd() {
    log_step "Cleaning up systemd files..."
    
    # Remove systemd service file
    rm -f /etc/systemd/system/traefik.service
    systemctl daemon-reload
    
    # Archive old configuration
    if [ -d /etc/traefik ]; then
        tar -czf "/backups/traefik/systemd-config-$(date +%Y%m%d).tar.gz" /etc/traefik/
        log_info "Old configuration archived"
    fi
    
    log_info "✅ Systemd cleanup completed"
}

# Main execution
case "$ACTION" in
    check)
        check_prerequisites
        ;;
    
    prepare)
        check_prerequisites
        backup_configuration
        prepare_nomad_env
        ;;
    
    migrate)
        check_prerequisites
        backup_configuration
        prepare_nomad_env
        deploy_to_nomad
        perform_cutover
        verify_migration
        ;;
    
    deploy-only)
        check_prerequisites
        prepare_nomad_env
        deploy_to_nomad
        ;;
    
    cutover)
        perform_cutover
        verify_migration
        ;;
    
    verify)
        verify_migration
        ;;
    
    rollback)
        rollback
        ;;
    
    cleanup)
        cleanup_systemd
        ;;
    
    full)
        # Complete migration with all steps
        check_prerequisites
        backup_configuration
        prepare_nomad_env
        deploy_to_nomad
        perform_cutover
        verify_migration
        cleanup_systemd
        ;;
    
    *)
        echo "Usage: $0 <action>"
        echo ""
        echo "Actions:"
        echo "  check       - Check prerequisites"
        echo "  prepare     - Prepare for migration"
        echo "  migrate     - Perform migration (recommended)"
        echo "  deploy-only - Deploy to Nomad without cutover"
        echo "  cutover     - Switch from systemd to Nomad"
        echo "  verify      - Verify migration status"
        echo "  rollback    - Rollback to systemd"
        echo "  cleanup     - Clean up old systemd files"
        echo "  full        - Complete migration with cleanup"
        echo ""
        echo "Recommended sequence:"
        echo "  1. $0 check"
        echo "  2. $0 migrate"
        echo "  3. $0 verify"
        echo "  4. $0 cleanup (after verification)"
        ;;
esac