#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { ((PASS++)); ((TOTAL++)); echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { ((FAIL++)); ((TOTAL++)); echo -e "${RED}[FAIL]${NC} $1"; }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

NGINX_PORT=$(grep 'port:' "$SCRIPT_DIR/manifest.yaml" | sed -n '2p' | awk '{print $2}')
[ -z "$NGINX_PORT" ] && NGINX_PORT=8080
BASE_URL="http://localhost:${NGINX_PORT}"

cleanup() {
    echo -e "\n${YELLOW}[CLEANUP]${NC} Tearing down..."
    ./swiftdeploy teardown --clean >/dev/null 2>&1
    # Reset manifest to stable if changed
    sed -i 's/mode: canary/mode: stable/' manifest.yaml 2>/dev/null
}

trap cleanup EXIT

cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════
section "1. FILE STRUCTURE"
# ═══════════════════════════════════════════

for f in manifest.yaml swiftdeploy app/main.py Dockerfile templates/nginx.conf.tmpl templates/docker-compose.yml.tmpl README.md; do
    if [[ -f "$f" ]]; then
        pass "File exists: $f"
    else
        fail "File missing: $f"
    fi
done

if [[ -x swiftdeploy ]] || head -1 swiftdeploy | grep -q "bash"; then
    pass "swiftdeploy is a bash script"
else
    fail "swiftdeploy is not a bash script"
fi

# ═══════════════════════════════════════════
section "2. MANIFEST VALIDATION"
# ═══════════════════════════════════════════

for key in "image:" "port:" "mode:" "version:"; do
    if grep -q "$key" manifest.yaml; then
        pass "manifest.yaml contains '$key'"
    else
        fail "manifest.yaml missing '$key'"
    fi
done

if grep -q "swiftdeploy-net" manifest.yaml; then
    pass "manifest.yaml defines network name"
else
    fail "manifest.yaml missing network name"
fi

if grep -q "bridge" manifest.yaml; then
    pass "manifest.yaml defines bridge driver"
else
    fail "manifest.yaml missing bridge driver"
fi

# ═══════════════════════════════════════════
section "3. INIT SUBCOMMAND"
# ═══════════════════════════════════════════

# Clean any previous generated files
rm -f docker-compose.yml nginx.conf

output=$(./swiftdeploy init 2>&1)
if [[ $? -eq 0 ]]; then
    pass "swiftdeploy init exits 0"
else
    fail "swiftdeploy init exits non-zero"
fi

if [[ -f docker-compose.yml ]]; then
    pass "docker-compose.yml generated"
else
    fail "docker-compose.yml not generated"
fi

if [[ -f nginx.conf ]]; then
    pass "nginx.conf generated"
else
    fail "nginx.conf not generated"
fi

# Verify no template placeholders remain
if grep -q '{{' docker-compose.yml 2>/dev/null; then
    fail "docker-compose.yml still has template placeholders"
else
    pass "docker-compose.yml has no template placeholders"
fi

if grep -q '{{' nginx.conf 2>/dev/null; then
    fail "nginx.conf still has template placeholders"
else
    pass "nginx.conf has no template placeholders"
fi

# ═══════════════════════════════════════════
section "4. GENERATED DOCKER-COMPOSE CHECKS"
# ═══════════════════════════════════════════

if grep -q "swiftdeploy:latest" docker-compose.yml; then
    pass "docker-compose.yml uses correct app image"
else
    fail "docker-compose.yml missing app image"
fi

if grep -q "MODE=stable" docker-compose.yml; then
    pass "docker-compose.yml injects MODE env var"
else
    fail "docker-compose.yml missing MODE env var"
fi

if grep -q "APP_VERSION" docker-compose.yml; then
    pass "docker-compose.yml injects APP_VERSION env var"
else
    fail "docker-compose.yml missing APP_VERSION env var"
fi

if grep -q "APP_PORT" docker-compose.yml; then
    pass "docker-compose.yml injects APP_PORT env var"
else
    fail "docker-compose.yml missing APP_PORT env var"
fi

if grep -q "cap_drop" docker-compose.yml; then
    pass "docker-compose.yml drops capabilities"
else
    fail "docker-compose.yml missing cap_drop"
fi

if grep -q "no-new-privileges" docker-compose.yml; then
    pass "docker-compose.yml sets no-new-privileges"
else
    fail "docker-compose.yml missing no-new-privileges"
fi

if grep -q "swiftdeploy-net" docker-compose.yml; then
    pass "docker-compose.yml uses defined network"
else
    fail "docker-compose.yml missing network"
fi

if grep -q "healthcheck" docker-compose.yml; then
    pass "docker-compose.yml defines healthcheck"
else
    fail "docker-compose.yml missing healthcheck"
fi

if grep -q "swiftdeploy-logs" docker-compose.yml; then
    pass "docker-compose.yml mounts named volume"
else
    fail "docker-compose.yml missing named volume"
fi

# App port should NOT be in the ports section (only nginx port)
app_port_exposed=$(grep -A2 "ports:" docker-compose.yml | grep "3000" || true)
if [[ -z "$app_port_exposed" ]]; then
    pass "App port 3000 not directly exposed"
else
    fail "App port 3000 is directly exposed (should only go through nginx)"
fi

# ═══════════════════════════════════════════
section "5. GENERATED NGINX.CONF CHECKS"
# ═══════════════════════════════════════════

if grep -q "listen ${NGINX_PORT}" nginx.conf; then
    pass "nginx.conf listens on correct port"
else
    fail "nginx.conf not listening on port ${NGINX_PORT}"
fi

if grep -q "X-Deployed-By" nginx.conf; then
    pass "nginx.conf adds X-Deployed-By header"
else
    fail "nginx.conf missing X-Deployed-By header"
fi

if grep -q "X-Mode" nginx.conf; then
    pass "nginx.conf forwards X-Mode header"
else
    fail "nginx.conf missing X-Mode forwarding"
fi

if grep -q "proxy_timeout\|proxy_read_timeout" nginx.conf; then
    pass "nginx.conf sets proxy timeouts"
else
    fail "nginx.conf missing proxy timeouts"
fi

if grep -q "502" nginx.conf && grep -q "503" nginx.conf && grep -q "504" nginx.conf; then
    pass "nginx.conf defines JSON error pages for 502/503/504"
else
    fail "nginx.conf missing JSON error pages"
fi

if grep -q 'time_iso8601.*status.*request_time.*upstream_addr.*request' nginx.conf; then
    pass "nginx.conf uses required log format"
else
    fail "nginx.conf missing required log format"
fi

# ═══════════════════════════════════════════
section "6. REGENERATION TEST (delete + re-init)"
# ═══════════════════════════════════════════

cp docker-compose.yml /tmp/compose_before.yml
cp nginx.conf /tmp/nginx_before.yml
rm -f docker-compose.yml nginx.conf

./swiftdeploy init >/dev/null 2>&1

if [[ -f docker-compose.yml ]] && [[ -f nginx.conf ]]; then
    pass "Files regenerated after deletion"
else
    fail "Files did NOT regenerate after deletion"
fi

if diff -q docker-compose.yml /tmp/compose_before.yml >/dev/null 2>&1; then
    pass "Regenerated docker-compose.yml is identical"
else
    fail "Regenerated docker-compose.yml differs from original"
fi

if diff -q nginx.conf /tmp/nginx_before.yml >/dev/null 2>&1; then
    pass "Regenerated nginx.conf is identical"
else
    fail "Regenerated nginx.conf differs from original"
fi

rm -f /tmp/compose_before.yml /tmp/nginx_before.yml

# ═══════════════════════════════════════════
section "7. DOCKERFILE CHECKS"
# ═══════════════════════════════════════════

if grep -qi "alpine\|slim" Dockerfile; then
    pass "Dockerfile uses lightweight base image"
else
    fail "Dockerfile not using lightweight image"
fi

if grep -q "USER" Dockerfile; then
    pass "Dockerfile runs as non-root user"
else
    fail "Dockerfile missing non-root USER"
fi

if grep -q "HEALTHCHECK" Dockerfile; then
    pass "Dockerfile defines HEALTHCHECK"
else
    fail "Dockerfile missing HEALTHCHECK"
fi

# ═══════════════════════════════════════════
section "8. BUILD & DEPLOY"
# ═══════════════════════════════════════════

echo -e "${YELLOW}[INFO]${NC} Building and deploying (this may take a minute)..."

output=$(./swiftdeploy deploy 2>&1)
deploy_exit=$?

if [[ $deploy_exit -eq 0 ]] || echo "$output" | grep -qi "healthy"; then
    pass "swiftdeploy deploy completed successfully"
else
    fail "swiftdeploy deploy failed (exit=$deploy_exit)"
    echo "$output" | tail -5
fi

# Wait a moment for everything to settle
sleep 3

# ═══════════════════════════════════════════
section "9. VALIDATE SUBCOMMAND"
# ═══════════════════════════════════════════

val_output=$(./swiftdeploy validate 2>&1)
val_exit=$?

if echo "$val_output" | grep -qi "manifest.yaml exists"; then
    pass "validate: manifest.yaml check"
else
    fail "validate: manifest.yaml check missing"
fi

if echo "$val_output" | grep -qi "required fields"; then
    pass "validate: required fields check"
else
    fail "validate: required fields check missing"
fi

if echo "$val_output" | grep -qi "docker image"; then
    pass "validate: docker image check"
else
    fail "validate: docker image check missing"
fi

if echo "$val_output" | grep -qi "port"; then
    pass "validate: port check"
else
    fail "validate: port check missing"
fi

if echo "$val_output" | grep -qi "nginx.conf"; then
    pass "validate: nginx.conf syntax check"
else
    fail "validate: nginx.conf syntax check missing"
fi

# ═══════════════════════════════════════════
section "10. API ENDPOINTS (STABLE MODE)"
# ═══════════════════════════════════════════

# GET /
root_response=$(curl -sf "$BASE_URL/" 2>/dev/null)
if [[ -n "$root_response" ]]; then
    pass "GET / returns response"
else
    fail "GET / no response"
fi

if echo "$root_response" | grep -q '"mode"'; then
    pass "GET / includes mode"
else
    fail "GET / missing mode"
fi

if echo "$root_response" | grep -q '"version"'; then
    pass "GET / includes version"
else
    fail "GET / missing version"
fi

if echo "$root_response" | grep -q '"timestamp"'; then
    pass "GET / includes timestamp"
else
    fail "GET / missing timestamp"
fi

if echo "$root_response" | grep -q "stable"; then
    pass "GET / shows stable mode"
else
    fail "GET / not showing stable mode"
fi

# GET /healthz
health_response=$(curl -sf "$BASE_URL/healthz" 2>/dev/null)
if [[ -n "$health_response" ]]; then
    pass "GET /healthz returns response"
else
    fail "GET /healthz no response"
fi

if echo "$health_response" | grep -q '"status"'; then
    pass "GET /healthz includes status"
else
    fail "GET /healthz missing status"
fi

if echo "$health_response" | grep -q '"uptime_seconds"'; then
    pass "GET /healthz includes uptime_seconds"
else
    fail "GET /healthz missing uptime_seconds"
fi

# POST /chaos should be blocked in stable mode
chaos_response=$(curl -sf -X POST "$BASE_URL/chaos" -H "Content-Type: application/json" -d '{"mode":"slow","duration":1}' 2>/dev/null)
chaos_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/chaos" -H "Content-Type: application/json" -d '{"mode":"slow","duration":1}' 2>/dev/null)
if [[ "$chaos_code" == "403" ]]; then
    pass "POST /chaos blocked in stable mode (403)"
else
    fail "POST /chaos should return 403 in stable mode (got $chaos_code)"
fi

# ═══════════════════════════════════════════
section "11. RESPONSE HEADERS"
# ═══════════════════════════════════════════

headers=$(curl -s -D- -o /dev/null "$BASE_URL/healthz" 2>/dev/null)

if echo "$headers" | grep -qi "X-Deployed-By: swiftdeploy"; then
    pass "X-Deployed-By: swiftdeploy header present"
else
    fail "X-Deployed-By header missing"
fi

# In stable mode, X-Mode should NOT be present
if echo "$headers" | grep -qi "X-Mode"; then
    fail "X-Mode header should NOT be present in stable mode"
else
    pass "X-Mode header correctly absent in stable mode"
fi

# ═══════════════════════════════════════════
section "12. PROMOTE TO CANARY"
# ═══════════════════════════════════════════

promote_output=$(./swiftdeploy promote canary 2>&1)
if echo "$promote_output" | grep -qi "confirmed.*canary\|mode.*canary"; then
    pass "promote canary confirmed"
else
    fail "promote canary not confirmed"
fi

# Verify manifest was updated
if grep -q "mode: canary" manifest.yaml; then
    pass "manifest.yaml updated to canary"
else
    fail "manifest.yaml not updated to canary"
fi

# Verify docker-compose.yml regenerated with canary
if grep -q "MODE=canary" docker-compose.yml; then
    pass "docker-compose.yml regenerated with MODE=canary"
else
    fail "docker-compose.yml not regenerated with canary"
fi

sleep 2

# Verify API now returns canary
canary_response=$(curl -sf "$BASE_URL/healthz" 2>/dev/null)
if echo "$canary_response" | grep -q "canary"; then
    pass "GET /healthz returns canary mode"
else
    fail "GET /healthz not returning canary mode"
fi

# Verify X-Mode header present in canary
canary_headers=$(curl -s -D- -o /dev/null "$BASE_URL/healthz" 2>/dev/null)
if echo "$canary_headers" | grep -qi "X-Mode: canary"; then
    pass "X-Mode: canary header present"
else
    fail "X-Mode: canary header missing"
fi

# ═══════════════════════════════════════════
section "13. CHAOS ENDPOINTS (CANARY MODE)"
# ═══════════════════════════════════════════

# Chaos slow
slow_response=$(curl -sf -X POST "$BASE_URL/chaos" -H "Content-Type: application/json" -d '{"mode":"slow","duration":1}' 2>/dev/null)
if echo "$slow_response" | grep -q "slow"; then
    pass "POST /chaos slow accepted"
else
    fail "POST /chaos slow not working"
fi

# Recover before testing error
curl -sf -X POST "$BASE_URL/chaos" -H "Content-Type: application/json" -d '{"mode":"recover"}' >/dev/null 2>&1

# Chaos error
error_response=$(curl -sf -X POST "$BASE_URL/chaos" -H "Content-Type: application/json" -d '{"mode":"error","rate":0.5}' 2>/dev/null)
if echo "$error_response" | grep -q "error"; then
    pass "POST /chaos error accepted"
else
    fail "POST /chaos error not working"
fi

# Chaos recover
recover_response=$(curl -sf -X POST "$BASE_URL/chaos" -H "Content-Type: application/json" -d '{"mode":"recover"}' 2>/dev/null)
if echo "$recover_response" | grep -q "recovered"; then
    pass "POST /chaos recover works"
else
    fail "POST /chaos recover not working"
fi

# ═══════════════════════════════════════════
section "14. PROMOTE BACK TO STABLE"
# ═══════════════════════════════════════════

promote_stable_output=$(./swiftdeploy promote stable 2>&1)
if echo "$promote_stable_output" | grep -qi "confirmed.*stable\|mode.*stable"; then
    pass "promote stable confirmed"
else
    fail "promote stable not confirmed"
fi

if grep -q "mode: stable" manifest.yaml; then
    pass "manifest.yaml reverted to stable"
else
    fail "manifest.yaml not reverted to stable"
fi

sleep 2

stable_response=$(curl -sf "$BASE_URL/healthz" 2>/dev/null)
if echo "$stable_response" | grep -q "stable"; then
    pass "GET /healthz returns stable mode after promote"
else
    fail "GET /healthz not returning stable after promote"
fi

# X-Mode should be gone
stable_headers=$(curl -s -D- -o /dev/null "$BASE_URL/healthz" 2>/dev/null)
if echo "$stable_headers" | grep -qi "X-Mode"; then
    fail "X-Mode header still present after promote stable"
else
    pass "X-Mode header correctly removed after promote stable"
fi

# ═══════════════════════════════════════════
section "15. NGINX ACCESS LOGS"
# ═══════════════════════════════════════════

log_output=$(docker logs swiftdeploy-nginx --tail 5 2>&1)

if echo "$log_output" | grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2}T"; then
    pass "Nginx logs contain ISO 8601 timestamps"
else
    fail "Nginx logs missing ISO 8601 timestamps"
fi

if echo "$log_output" | grep -q "|"; then
    pass "Nginx logs use pipe-delimited format"
else
    fail "Nginx logs not pipe-delimited"
fi

if echo "$log_output" | grep -q "GET"; then
    pass "Nginx logs contain request info"
else
    fail "Nginx logs missing request info"
fi

# ═══════════════════════════════════════════
section "16. CONTAINER SECURITY"
# ═══════════════════════════════════════════

app_user=$(docker exec swiftdeploy-app whoami 2>/dev/null || docker inspect --format '{{.Config.User}}' swiftdeploy-app 2>/dev/null)
if [[ -n "$app_user" ]] && [[ "$app_user" != "root" ]]; then
    pass "App container runs as non-root ($app_user)"
else
    fail "App container may be running as root"
fi

# Check app port not exposed on host
if docker port swiftdeploy-app 2>/dev/null | grep -q "3000"; then
    fail "App port 3000 is exposed on host"
else
    pass "App port 3000 not exposed on host"
fi

# ═══════════════════════════════════════════
section "17. TEARDOWN"
# ═══════════════════════════════════════════

# Teardown without --clean first
./swiftdeploy teardown >/dev/null 2>&1

running=$(docker ps --filter name=swiftdeploy --format "{{.Names}}" 2>/dev/null)
if [[ -z "$running" ]]; then
    pass "teardown removed all containers"
else
    fail "teardown left containers running: $running"
fi

# Check configs still exist (no --clean)
if [[ -f docker-compose.yml ]] && [[ -f nginx.conf ]]; then
    pass "teardown (without --clean) preserves generated configs"
else
    fail "teardown (without --clean) deleted generated configs"
fi

# Now teardown --clean
./swiftdeploy teardown --clean >/dev/null 2>&1

if [[ ! -f docker-compose.yml ]] && [[ ! -f nginx.conf ]]; then
    pass "teardown --clean deletes generated configs"
else
    fail "teardown --clean did not delete generated configs"
fi

# ═══════════════════════════════════════════
section "RESULTS"
# ═══════════════════════════════════════════

echo ""
echo -e "${GREEN}Passed: $PASS${NC}"
echo -e "${RED}Failed: $FAIL${NC}"
echo -e "Total:  $TOTAL"
echo ""

if (( FAIL == 0 )); then
    echo -e "${GREEN}━━━ ALL TESTS PASSED ━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━ $FAIL TEST(S) FAILED ━━━${NC}"
    exit 1
fi
