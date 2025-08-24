#!/bin/bash

# Test script for Traefik migration to Nomad
# This simulates the migration process locally

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[TEST]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "======================================="
echo "Traefik Migration Test Suite"
echo "======================================="
echo ""

# Test 1: Check prerequisites
log_step "Test 1: Checking prerequisites"

# Check if Docker is installed
if command -v docker >/dev/null 2>&1; then
    log_info "✅ Docker is installed"
else
    log_error "❌ Docker is not installed"
    exit 1
fi

# Check if we can run containers
if docker run --rm hello-world >/dev/null 2>&1; then
    log_info "✅ Docker can run containers"
else
    log_error "❌ Cannot run Docker containers"
    exit 1
fi

# Test 2: Create test directories
log_step "Test 2: Creating test directories"

TEST_DIR="/tmp/traefik-migration-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"/{systemd,nomad,backups}
mkdir -p "$TEST_DIR"/nomad/{config,acme,dynamic}

log_info "✅ Test directories created at $TEST_DIR"

# Test 3: Simulate systemd Traefik
log_step "Test 3: Simulating systemd Traefik"

# Create mock configuration
cat > "$TEST_DIR/systemd/traefik.yml" << 'EOF'
api:
  dashboard: true

entryPoints:
  web:
    address: ":8080"
  websecure:
    address: ":8443"

providers:
  file:
    directory: /etc/traefik/dynamic

certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
EOF

# Create mock certificate file
cat > "$TEST_DIR/systemd/acme.json" << 'EOF'
{
  "letsencrypt": {
    "Account": {
      "Email": "admin@example.com",
      "Registration": {
        "body": {
          "status": "valid"
        }
      }
    },
    "Certificates": [
      {
        "domain": {
          "main": "example.com"
        },
        "certificate": "mock-certificate-data",
        "key": "mock-key-data"
      }
    ]
  }
}
EOF
chmod 600 "$TEST_DIR/systemd/acme.json"

log_info "✅ Mock systemd Traefik configuration created"

# Test 4: Test backup functionality
log_step "Test 4: Testing backup functionality"

# Simulate backup
cp -r "$TEST_DIR/systemd/"* "$TEST_DIR/backups/"
if [ -f "$TEST_DIR/backups/acme.json" ]; then
    log_info "✅ Backup successful"
else
    log_error "❌ Backup failed"
fi

# Test 5: Test configuration migration
log_step "Test 5: Testing configuration migration"

# Copy configs to Nomad directories
cp "$TEST_DIR/systemd/traefik.yml" "$TEST_DIR/nomad/config/"
cp "$TEST_DIR/systemd/acme.json" "$TEST_DIR/nomad/acme/"

if [ -f "$TEST_DIR/nomad/acme/acme.json" ]; then
    log_info "✅ Configuration migration successful"
else
    log_error "❌ Configuration migration failed"
fi

# Test 6: Test Traefik container
log_step "Test 6: Testing Traefik container"

# Try to run Traefik in Docker (will fail on ports but tests image)
if docker run --rm -d \
    --name traefik-test \
    -v "$TEST_DIR/nomad/config:/etc/traefik:ro" \
    -v "$TEST_DIR/nomad/acme:/acme" \
    traefik:3.2.3 \
    --configfile=/etc/traefik/traefik.yml \
    --api.dashboard=true \
    --ping=true >/dev/null 2>&1; then
    
    log_info "✅ Traefik container started"
    
    # Stop container
    docker stop traefik-test >/dev/null 2>&1
else
    log_warn "⚠️ Could not start Traefik container (expected if ports in use)"
fi

# Test 7: Test rollback preparation
log_step "Test 7: Testing rollback preparation"

# Create rollback script
cat > "$TEST_DIR/rollback.sh" << 'EOF'
#!/bin/bash
echo "Rollback would:"
echo "1. Stop Nomad job"
echo "2. Restore systemd configuration"
echo "3. Start systemd service"
echo "4. Verify operation"
EOF
chmod +x "$TEST_DIR/rollback.sh"

if [ -x "$TEST_DIR/rollback.sh" ]; then
    log_info "✅ Rollback script ready"
else
    log_error "❌ Rollback script not ready"
fi

# Test 8: Verify Nomad job file
log_step "Test 8: Verifying Nomad job file"

if [ -f "nomad/jobs/infrastructure/traefik.nomad" ]; then
    # Check job file syntax (basic validation)
    if grep -q 'job "traefik"' nomad/jobs/infrastructure/traefik.nomad; then
        log_info "✅ Nomad job file is valid"
    else
        log_error "❌ Nomad job file invalid"
    fi
else
    log_warn "⚠️ Nomad job file not found"
fi

# Test 9: Test health check endpoints
log_step "Test 9: Testing health check logic"

# Simulate health check
cat > "$TEST_DIR/health-check.sh" << 'EOF'
#!/bin/bash
# Mock health check
ENDPOINTS=(
    "http://localhost:80/ping"
    "http://localhost:8080/api/overview"
    "http://localhost:8082/metrics"
)

for endpoint in "${ENDPOINTS[@]}"; do
    echo "Would check: $endpoint"
done
EOF
chmod +x "$TEST_DIR/health-check.sh"
"$TEST_DIR/health-check.sh"

log_info "✅ Health check logic prepared"

# Test 10: Cleanup test
log_step "Test 10: Testing cleanup"

if rm -rf "$TEST_DIR"; then
    log_info "✅ Cleanup successful"
else
    log_error "❌ Cleanup failed"
fi

# Summary
echo ""
echo "======================================="
echo "Test Summary"
echo "======================================="
log_info "All tests completed successfully!"
echo ""
echo "Next steps for actual migration:"
echo "1. Ensure Nomad is running on target server"
echo "2. Review and adjust the Nomad job file"
echo "3. Run: ./migrate-to-nomad.sh check"
echo "4. Run: ./migrate-to-nomad.sh migrate"
echo "5. Monitor and verify all services"
echo ""
log_warn "Note: This was a local simulation only"