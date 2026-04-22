#!/usr/bin/env bash
set -uo pipefail

# ═══════════════════════════════════════════
# Usage: ./grader.sh [github-url|local-path]
#   No argument = run from current directory
# ═══════════════════════════════════════════

PASS=0
FAIL=0
TOTAL=0
WORK_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { ((PASS++)); ((TOTAL++)); echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { ((FAIL++)); ((TOTAL++)); echo -e "${RED}[FAIL]${NC} $1"; }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ─── Resolve repo directory ───
REPO_ARG="${1:-}"
if [[ -z "$REPO_ARG" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ "$REPO_ARG" == http* ]]; then
    WORK_DIR="$(mktemp -d /tmp/grader_XXXXXX)"
    echo -e "${CYAN}[INFO]${NC} Cloning $REPO_ARG ..."
    if git clone --depth 1 "$REPO_ARG" "$WORK_DIR/repo" 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} Repository cloned successfully"
        SCRIPT_DIR="$WORK_DIR/repo"
    else
        echo -e "${RED}[FAIL]${NC} Failed to clone repository"
        exit 1
    fi
elif [[ -d "$REPO_ARG" ]]; then
    SCRIPT_DIR="$(cd "$REPO_ARG" && pwd)"
else
    echo "Usage: $0 [github-url|local-path]"
    exit 1
fi

NGINX_PORT=$(grep 'port:' "$SCRIPT_DIR/manifest.yaml" | sed -n '2p' | awk '{print $2}')
[ -z "$NGINX_PORT" ] && NGINX_PORT=8080
BASE_URL="http://localhost:${NGINX_PORT}"

cleanup() {
    echo -e "\n${YELLOW}[CLEANUP]${NC} Tearing down..."
    ./swiftdeploy teardown --clean >/dev/null 2>&1
    sed -i 's/mode: canary/mode: stable/' manifest.yaml 2>/dev/null
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════
# TEST FUNCTIONS
# ═══════════════════════════════════════════

test_file_structure() {
    section "1. FILE STRUCTURE"

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
}

test_manifest() {
    section "2. MANIFEST VALIDATION"

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
}

test_init() {
    section "3. INIT SUBCOMMAND"

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
}

test_compose_content() {
    section "4. GENERATED DOCKER-COMPOSE CHECKS"

    local checks=(
        "swiftdeploy:latest|docker-compose.yml uses correct app image|docker-compose.yml missing app image"
        "MODE=stable|docker-compose.yml injects MODE env var|docker-compose.yml missing MODE env var"
        "APP_VERSION|docker-compose.yml injects APP_VERSION env var|docker-compose.yml missing APP_VERSION env var"
        "APP_PORT|docker-compose.yml injects APP_PORT env var|docker-compose.yml missing APP_PORT env var"
        "cap_drop|docker-compose.yml drops capabilities|docker-compose.yml missing cap_drop"
        "no-new-privileges|docker-compose.yml sets no-new-privileges|docker-compose.yml missing no-new-privileges"
        "swiftdeploy-net|docker-compose.yml uses defined network|docker-compose.yml missing network"
        "healthcheck|docker-compose.yml defines healthcheck|docker-compose.yml missing healthcheck"
        "swiftdeploy-logs|docker-compose.yml mounts named volume|docker-compose.yml missing named volume"
    )

    for check in "${checks[@]}"; do
        IFS='|' read -r pattern pass_msg fail_msg <<< "$check"
        if grep -q "$pattern" docker-compose.yml; then
            pass "$pass_msg"
        else
            fail "$fail_msg"
        fi
    done

    local app_port_exposed
    app_port_exposed=$(grep -A2 "ports:" docker-compose.yml | grep "3000" || true)
    if [[ -z "$app_port_exposed" ]]; then
        pass "App port 3000 not directly exposed"
    else
        fail "App port 3000 is directly exposed (should only go through nginx)"
    fi
}

test_nginx_content() {
    section "5. GENERATED NGINX.CONF CHECKS"

    if grep -q "listen ${NGINX_PORT}" nginx.conf; then
        pass "nginx.conf listens on correct port"
    else
        fail "nginx.conf not listening on port ${NGINX_PORT}"
    fi

    local checks=(
        "X-Deployed-By|nginx.conf adds X-Deployed-By header|nginx.conf missing X-Deployed-By header"
        "X-Mode|nginx.conf forwards X-Mode header|nginx.conf missing X-Mode forwarding"
    )

    for check in "${checks[@]}"; do
        IFS='|' read -r pattern pass_msg fail_msg <<< "$check"
        if grep -q "$pattern" nginx.conf; then
            pass "$pass_msg"
        else
            fail "$fail_msg"
        fi
    done

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
}

test_regeneration() {
    section "6. REGENERATION TEST (delete + re-init)"

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
}

test_dockerfile() {
    section "7. DOCKERFILE CHECKS"

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
}

test_deploy() {
    section "8. BUILD & DEPLOY"

    echo -e "${YELLOW}[INFO]${NC} Building and deploying (this may take a minute)..."

    local output
    output=$(./swiftdeploy deploy 2>&1)
    local deploy_exit=$?

    if [[ $deploy_exit -eq 0 ]] || echo "$output" | grep -qi "healthy"; then
        pass "swiftdeploy deploy completed successfully"
    else
        fail "swiftdeploy deploy failed (exit=$deploy_exit)"
        echo "$output" | tail -5
    fi

    sleep 3
}

test_validate() {
    section "9. VALIDATE SUBCOMMAND"

    local val_output
    val_output=$(./swiftdeploy validate 2>&1)

    local checks=(
        "manifest.yaml exists|validate: manifest.yaml check"
        "required fields|validate: required fields check"
        "docker image|validate: docker image check"
        "port|validate: port check"
        "nginx.conf|validate: nginx.conf syntax check"
    )

    for check in "${checks[@]}"; do
        IFS='|' read -r pattern msg <<< "$check"
        if echo "$val_output" | grep -qi "$pattern"; then
            pass "$msg"
        else
            fail "$msg missing"
        fi
    done
}

test_api_stable() {
    section "10. API ENDPOINTS (STABLE MODE)"

    local root_response
    root_response=$(curl -sf "$BASE_URL/" 2>/dev/null)

    if [[ -n "$root_response" ]]; then
        pass "GET / returns response"
    else
        fail "GET / no response"
    fi

    for field in mode version timestamp; do
        if echo "$root_response" | grep -q "\"$field\""; then
            pass "GET / includes $field"
        else
            fail "GET / missing $field"
        fi
    done

    if echo "$root_response" | grep -q "stable"; then
        pass "GET / shows stable mode"
    else
        fail "GET / not showing stable mode"
    fi

    local health_response
    health_response=$(curl -sf "$BASE_URL/healthz" 2>/dev/null)

    if [[ -n "$health_response" ]]; then
        pass "GET /healthz returns response"
    else
        fail "GET /healthz no response"
    fi

    for field in status uptime_seconds; do
        if echo "$health_response" | grep -q "\"$field\""; then
            pass "GET /healthz includes $field"
        else
            fail "GET /healthz missing $field"
        fi
    done

    local chaos_code
    chaos_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/chaos" \
        -H "Content-Type: application/json" -d '{"mode":"slow","duration":1}' 2>/dev/null)
    if [[ "$chaos_code" == "403" ]]; then
        pass "POST /chaos blocked in stable mode (403)"
    else
        fail "POST /chaos should return 403 in stable mode (got $chaos_code)"
    fi
}

test_headers_stable() {
    section "11. RESPONSE HEADERS"

    local headers
    headers=$(curl -s -D- -o /dev/null "$BASE_URL/healthz" 2>/dev/null)

    if echo "$headers" | grep -qi "X-Deployed-By: swiftdeploy"; then
        pass "X-Deployed-By: swiftdeploy header present"
    else
        fail "X-Deployed-By header missing"
    fi

    if echo "$headers" | grep -qi "X-Mode"; then
        fail "X-Mode header should NOT be present in stable mode"
    else
        pass "X-Mode header correctly absent in stable mode"
    fi
}

test_promote_canary() {
    section "12. PROMOTE TO CANARY"

    local promote_output
    promote_output=$(./swiftdeploy promote canary 2>&1)

    if echo "$promote_output" | grep -qi "confirmed.*canary\|mode.*canary"; then
        pass "promote canary confirmed"
    else
        fail "promote canary not confirmed"
    fi

    if grep -q "mode: canary" manifest.yaml; then
        pass "manifest.yaml updated to canary"
    else
        fail "manifest.yaml not updated to canary"
    fi

    if grep -q "MODE=canary" docker-compose.yml; then
        pass "docker-compose.yml regenerated with MODE=canary"
    else
        fail "docker-compose.yml not regenerated with canary"
    fi

    sleep 2

    local canary_response
    canary_response=$(curl -sf "$BASE_URL/healthz" 2>/dev/null)
    if echo "$canary_response" | grep -q "canary"; then
        pass "GET /healthz returns canary mode"
    else
        fail "GET /healthz not returning canary mode"
    fi

    local canary_headers
    canary_headers=$(curl -s -D- -o /dev/null "$BASE_URL/healthz" 2>/dev/null)
    if echo "$canary_headers" | grep -qi "X-Mode: canary"; then
        pass "X-Mode: canary header present"
    else
        fail "X-Mode: canary header missing"
    fi
}

test_chaos() {
    section "13. CHAOS ENDPOINTS (CANARY MODE)"

    local slow_response
    slow_response=$(curl -sf -X POST "$BASE_URL/chaos" \
        -H "Content-Type: application/json" -d '{"mode":"slow","duration":1}' 2>/dev/null)
    if echo "$slow_response" | grep -q "slow"; then
        pass "POST /chaos slow accepted"
    else
        fail "POST /chaos slow not working"
    fi

    curl -sf -X POST "$BASE_URL/chaos" \
        -H "Content-Type: application/json" -d '{"mode":"recover"}' >/dev/null 2>&1

    local error_response
    error_response=$(curl -sf -X POST "$BASE_URL/chaos" \
        -H "Content-Type: application/json" -d '{"mode":"error","rate":0.5}' 2>/dev/null)
    if echo "$error_response" | grep -q "error"; then
        pass "POST /chaos error accepted"
    else
        fail "POST /chaos error not working"
    fi

    local recover_response
    recover_response=$(curl -sf -X POST "$BASE_URL/chaos" \
        -H "Content-Type: application/json" -d '{"mode":"recover"}' 2>/dev/null)
    if echo "$recover_response" | grep -q "recovered"; then
        pass "POST /chaos recover works"
    else
        fail "POST /chaos recover not working"
    fi
}

test_promote_stable() {
    section "14. PROMOTE BACK TO STABLE"

    local promote_output
    promote_output=$(./swiftdeploy promote stable 2>&1)

    if echo "$promote_output" | grep -qi "confirmed.*stable\|mode.*stable"; then
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

    local stable_response
    stable_response=$(curl -sf "$BASE_URL/healthz" 2>/dev/null)
    if echo "$stable_response" | grep -q "stable"; then
        pass "GET /healthz returns stable mode after promote"
    else
        fail "GET /healthz not returning stable after promote"
    fi

    local stable_headers
    stable_headers=$(curl -s -D- -o /dev/null "$BASE_URL/healthz" 2>/dev/null)
    if echo "$stable_headers" | grep -qi "X-Mode"; then
        fail "X-Mode header still present after promote stable"
    else
        pass "X-Mode header correctly removed after promote stable"
    fi
}

test_nginx_logs() {
    section "15. NGINX ACCESS LOGS"

    local log_output
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
}

test_container_security() {
    section "16. CONTAINER SECURITY"

    local app_user
    app_user=$(docker exec swiftdeploy-app whoami 2>/dev/null || \
        docker inspect --format '{{.Config.User}}' swiftdeploy-app 2>/dev/null)
    if [[ -n "$app_user" ]] && [[ "$app_user" != "root" ]]; then
        pass "App container runs as non-root ($app_user)"
    else
        fail "App container may be running as root"
    fi

    if docker port swiftdeploy-app 2>/dev/null | grep -q "3000"; then
        fail "App port 3000 is exposed on host"
    else
        pass "App port 3000 not exposed on host"
    fi
}

test_teardown() {
    section "17. TEARDOWN"

    ./swiftdeploy teardown >/dev/null 2>&1

    local running
    running=$(docker ps --filter name=swiftdeploy --format "{{.Names}}" 2>/dev/null)
    if [[ -z "$running" ]]; then
        pass "teardown removed all containers"
    else
        fail "teardown left containers running: $running"
    fi

    if [[ -f docker-compose.yml ]] && [[ -f nginx.conf ]]; then
        pass "teardown (without --clean) preserves generated configs"
    else
        fail "teardown (without --clean) deleted generated configs"
    fi

    ./swiftdeploy teardown --clean >/dev/null 2>&1

    if [[ ! -f docker-compose.yml ]] && [[ ! -f nginx.conf ]]; then
        pass "teardown --clean deletes generated configs"
    else
        fail "teardown --clean did not delete generated configs"
    fi
}

print_results() {
    section "RESULTS"
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
}

# ═══════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════

test_file_structure
test_manifest
test_init
test_compose_content
test_nginx_content
test_regeneration
test_dockerfile
test_deploy
test_validate
test_api_stable
test_headers_stable
test_promote_canary
test_chaos
test_promote_stable
test_nginx_logs
test_container_security
test_teardown
print_results
