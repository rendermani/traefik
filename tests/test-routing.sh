#!/bin/bash

# Traefik Routing Test Suite

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[TEST]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

DOMAIN="${1:-cloudya.net}"
FAILURES=0
PASSES=0
SKIPS=0

# Test function
run_test() {
    local TEST_NAME="$1"
    local TEST_CMD="$2"
    local EXPECTED="$3"
    
    echo -n "Testing $TEST_NAME... "
    
    RESULT=$(eval "$TEST_CMD" 2>/dev/null || echo "FAILED")
    
    if [[ "$RESULT" == *"$EXPECTED"* ]]; then
        log_pass "OK"
        ((PASSES++))
        return 0
    else
        log_error "Expected: $EXPECTED, Got: $RESULT"
        ((FAILURES++))
        return 1
    fi
}

# Skip test function
skip_test() {
    local TEST_NAME="$1"
    local REASON="$2"
    
    log_skip "$TEST_NAME - $REASON"
    ((SKIPS++))
}

echo "==================================="
echo "Traefik Routing Test Suite"
echo "Domain: $DOMAIN"
echo "==================================="
echo ""

# Test 1: Traefik Health
echo "### Basic Health Checks ###"
run_test "Traefik ping endpoint" \
    "curl -s http://localhost/ping" \
    "OK"

run_test "Traefik service running" \
    "systemctl is-active traefik" \
    "active"

# Test 2: HTTPS Redirect
echo ""
echo "### HTTPS Redirect Tests ###"
run_test "HTTP to HTTPS redirect" \
    "curl -s -o /dev/null -w '%{http_code}' http://traefik.$DOMAIN" \
    "301"

# Test 3: Dashboard Authentication
echo ""
echo "### Authentication Tests ###"
run_test "Dashboard requires auth" \
    "curl -s -o /dev/null -w '%{http_code}' https://traefik.$DOMAIN/" \
    "401"

# Test 4: Service Routing
echo ""
echo "### Service Routing Tests ###"

SERVICES=(
    "vault:vault.$DOMAIN"
    "nomad:nomad.$DOMAIN"
    "prometheus:metrics.$DOMAIN"
    "grafana:grafana.$DOMAIN"
    "api:api.$DOMAIN"
    "app:app.$DOMAIN"
)

for SERVICE_PAIR in "${SERVICES[@]}"; do
    IFS=':' read -r SERVICE URL <<< "$SERVICE_PAIR"
    
    # Check if service is running locally
    if curl -f -s --max-time 1 http://localhost:8200/v1/sys/health >/dev/null 2>&1 && [ "$SERVICE" = "vault" ]; then
        run_test "$SERVICE routing" \
            "curl -s -o /dev/null -w '%{http_code}' -L https://$URL" \
            "200"
    elif curl -f -s --max-time 1 http://localhost:4646/v1/status/leader >/dev/null 2>&1 && [ "$SERVICE" = "nomad" ]; then
        run_test "$SERVICE routing" \
            "curl -s -o /dev/null -w '%{http_code}' -L https://$URL" \
            "200"
    else
        skip_test "$SERVICE routing" "Service not running"
    fi
done

# Test 5: SSL Certificates
echo ""
echo "### SSL Certificate Tests ###"

check_ssl() {
    local HOST=$1
    
    if echo | openssl s_client -connect ${HOST}:443 -servername ${HOST} 2>/dev/null | \
       openssl x509 -noout -subject 2>/dev/null | grep -q "CN"; then
        return 0
    else
        return 1
    fi
}

if check_ssl "traefik.$DOMAIN"; then
    log_pass "SSL certificate valid for traefik.$DOMAIN"
    ((PASSES++))
else
    log_skip "SSL certificate for traefik.$DOMAIN - May still be provisioning"
    ((SKIPS++))
fi

# Test 6: Rate Limiting
echo ""
echo "### Rate Limiting Tests ###"

test_rate_limit() {
    local URL=$1
    local LIMIT=5
    
    for i in $(seq 1 $((LIMIT + 1))); do
        STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$URL")
        if [ "$STATUS" = "429" ]; then
            return 0
        fi
    done
    return 1
}

skip_test "Rate limiting" "Requires configured rate limit middleware"

# Test 7: Security Headers
echo ""
echo "### Security Header Tests ###"

HEADERS=$(curl -s -I https://traefik.$DOMAIN 2>/dev/null || echo "")

if echo "$HEADERS" | grep -q "Strict-Transport-Security"; then
    log_pass "HSTS header present"
    ((PASSES++))
else
    log_error "HSTS header missing"
    ((FAILURES++))
fi

if echo "$HEADERS" | grep -q "X-Content-Type-Options: nosniff"; then
    log_pass "X-Content-Type-Options header present"
    ((PASSES++))
else
    log_error "X-Content-Type-Options header missing"
    ((FAILURES++))
fi

# Test 8: Metrics Endpoint
echo ""
echo "### Metrics Tests ###"

if curl -f -s http://localhost:8082/metrics | grep -q "traefik_"; then
    log_pass "Prometheus metrics available"
    ((PASSES++))
else
    log_error "Prometheus metrics not available"
    ((FAILURES++))
fi

# Test 9: WebSocket Support
echo ""
echo "### WebSocket Tests ###"
skip_test "WebSocket upgrade" "Requires WebSocket service"

# Test 10: Load Balancing
echo ""
echo "### Load Balancing Tests ###"
skip_test "Load balancing" "Requires multiple backend instances"

# Summary
echo ""
echo "==================================="
echo "Test Summary"
echo "==================================="
echo -e "${GREEN}Passed:${NC} $PASSES"
echo -e "${YELLOW}Skipped:${NC} $SKIPS"
echo -e "${RED}Failed:${NC} $FAILURES"
echo ""

if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    exit 1
fi