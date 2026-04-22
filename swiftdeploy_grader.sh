#!/usr/bin/env bash
# SwiftDeploy Stage 4 — Automated Grader (no python3/PyYAML dependency)
set -euo pipefail

# Ensure docker is available (WSL uses docker.exe)
if ! command -v docker &>/dev/null && command -v docker.exe &>/dev/null; then
    docker() { docker.exe "$@"; }
    export -f docker
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
PASS="${GREEN}✓ PASS${RESET}"; FAIL="${RED}✗ FAIL${RESET}"; WARN="${YELLOW}⚠ WARN${RESET}"

REPO_ARG="${1:-}"
KEEP_STACK=false
[[ "${2:-}" == "--keep" ]] && KEEP_STACK=true
if [[ -z "$REPO_ARG" ]]; then echo "Usage: $0 <github-repo-url|local-path> [--keep]"; exit 1; fi

WORK_DIR="$(mktemp -d /tmp/swiftdeploy_grade_XXXXXX)"
REPORT_FILE="grade_report_$(date +%Y%m%d_%H%M%S).txt"
TOTAL_SCORE=0; MAX_SCORE=0
declare -a SECTION_NAMES=() SECTION_SCORES=() SECTION_MAX=() FAILURES=()

trap 'cleanup_on_exit' EXIT
cleanup_on_exit() {
  if [[ "$KEEP_STACK" == false ]]; then
    echo -e "\n${CYAN}── Cleanup${RESET}"
    [[ -d "${REPO_DIR:-}" ]] && { cd "$REPO_DIR" 2>/dev/null; bash swiftdeploy teardown --clean 2>/dev/null || true; }
    rm -rf "$WORK_DIR"
  else
    echo -e "\n${YELLOW}--keep set: stack left running.${RESET}"
  fi
}

CURRENT_SECTION=""; CURRENT_SCORE=0; CURRENT_MAX=0
begin_section() { CURRENT_SECTION="$1"; CURRENT_SCORE=0; CURRENT_MAX=0; echo -e "\n${BOLD}${CYAN}━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
award() { local p=$1; shift; CURRENT_SCORE=$((CURRENT_SCORE+p)); CURRENT_MAX=$((CURRENT_MAX+p)); echo -e "  ${PASS} [+${p}] $*"; echo "  PASS [+${p}] $*" >> "$REPORT_FILE"; }
deduct() { local p=$1; shift; CURRENT_MAX=$((CURRENT_MAX+p)); echo -e "  ${FAIL} [+0/${p}] $*"; echo "  FAIL [+0/${p}] $*" >> "$REPORT_FILE"; FAILURES+=("[$CURRENT_SECTION] $*"); }
warn_only() { echo -e "  ${WARN} $*"; echo "  WARN $*" >> "$REPORT_FILE"; }
end_section() { SECTION_NAMES+=("$CURRENT_SECTION"); SECTION_SCORES+=($CURRENT_SCORE); SECTION_MAX+=($CURRENT_MAX); TOTAL_SCORE=$((TOTAL_SCORE+CURRENT_SCORE)); MAX_SCORE=$((MAX_SCORE+CURRENT_MAX)); echo -e "  ${BOLD}Section score: ${CURRENT_SCORE}/${CURRENT_MAX}${RESET}"; echo "  Section score: ${CURRENT_SCORE}/${CURRENT_MAX}" >> "$REPORT_FILE"; }

# ── Bash YAML helpers (no python3 needed) ──
yaml_val() {
  # Usage: yaml_val file key  — reads simple "key: value" from YAML
  grep -E "^\\s*${2}:" "$1" 2>/dev/null | head -1 | sed "s/^[^:]*:\\s*//" | tr -d '"' | tr -d "'" | xargs
}
yaml_nested() {
  # Usage: yaml_nested file parent key — reads "key: value" under a parent block
  sed -n "/^${2}:/,/^[^ ]/p" "$1" 2>/dev/null | grep -E "^\\s+${3}:" | head -1 | sed "s/^[^:]*:\\s*//" | tr -d '"' | tr -d "'" | xargs
}

http_get() { curl -s --max-time 15 "$@"; }
http_post() { curl -s --max-time 20 -X POST "$@"; }
http_headers() { curl -s --max-time 15 -I "$@"; }

{ echo "SwiftDeploy Stage 4 — Grade Report"; echo "Generated: $(date)"; echo "Repo: $REPO_ARG"; echo "========================================"; } > "$REPORT_FILE"

# ═══ SECTION 0 — Clone / locate repo ═══
begin_section "0. Repository Setup"
if [[ "$REPO_ARG" == http* ]]; then
  echo -e "  Cloning ${REPO_ARG} ..."
  if git clone --depth 1 "$REPO_ARG" "$WORK_DIR/repo" 2>/dev/null; then
    award 2 "Repository clones successfully"; REPO_DIR="$WORK_DIR/repo"
  else
    deduct 2 "Repository failed to clone — aborting"; end_section; exit 1
  fi
else
  if [[ -d "$REPO_ARG" ]]; then
    award 2 "Local repository path exists"; REPO_DIR="$(realpath "$REPO_ARG")"
  else
    deduct 2 "Local path does not exist — aborting"; end_section; exit 1
  fi
fi
cd "$REPO_DIR"; echo "  Working directory: $REPO_DIR"
# Clean up any leftover swiftdeploy containers from previous runs
docker rm -f swiftdeploy-app swiftdeploy-nginx 2>/dev/null || true
docker network rm swiftdeploy-net 2>/dev/null || true
end_section

# ═══ SECTION 1 — Repository Structure ═══
begin_section "1. Repository Structure"
declare -A REQUIRED_PATHS=(["manifest.yaml"]="manifest.yaml" ["swiftdeploy script"]="swiftdeploy" ["app/ directory"]="app" ["templates/ directory"]="templates" ["README.md"]="README.md" ["Dockerfile"]="Dockerfile")
for label in "manifest.yaml" "swiftdeploy script" "app/ directory" "templates/ directory" "README.md" "Dockerfile"; do
  path="${REQUIRED_PATHS[$label]}"
  if [[ -e "$path" ]]; then award 2 "$label present"; else deduct 2 "$label missing"; fi
done
if [[ -x "swiftdeploy" ]]; then award 2 "swiftdeploy is executable"; else deduct 2 "swiftdeploy is not executable"; chmod +x swiftdeploy 2>/dev/null || true; fi
if head -1 swiftdeploy 2>/dev/null | grep -qE '#!/.*bash'; then award 2 "swiftdeploy shebang is bash"; else deduct 2 "swiftdeploy shebang is not bash"; fi
if find templates/ -name "*nginx*" 2>/dev/null | grep -q .; then award 2 "Nginx template present"; else deduct 2 "No Nginx template found"; fi
if find templates/ -name "*compose*" -o -name "*docker*" 2>/dev/null | grep -q .; then award 2 "Docker Compose template present"; else deduct 2 "No Docker Compose template found"; fi
end_section

# ═══ SECTION 2 — Manifest Validity ═══
begin_section "2. manifest.yaml"
if [[ -f "manifest.yaml" ]]; then
  award 2 "manifest.yaml exists"
  # Valid YAML check: no tabs
  if ! grep -qP '\t' manifest.yaml 2>/dev/null; then award 3 "manifest.yaml is valid YAML"; else deduct 3 "manifest.yaml is not valid YAML"; fi
  MANIFEST_CONTENT=$(cat manifest.yaml)
  for field in "name" "image" "port" "version" "mode" "network" "restart"; do
    if echo "$MANIFEST_CONTENT" | grep -qE "^\\s*${field}:"; then award 1 "Field '${field}' present"; else deduct 1 "Field '${field}' missing"; fi
  done
  if echo "$MANIFEST_CONTENT" | grep -q "nginx:"; then
    award 2 "Nginx section present"
    if echo "$MANIFEST_CONTENT" | grep -q "port:" && echo "$MANIFEST_CONTENT" | grep -q "proxy_timeout:"; then award 2 "nginx.port and nginx.proxy_timeout present"; else deduct 2 "nginx.port or nginx.proxy_timeout missing"; fi
  else deduct 4 "No 'nginx:' section in manifest"; fi
  MODE_VAL=$(yaml_val manifest.yaml mode)
  if [[ "$MODE_VAL" == "stable" || "$MODE_VAL" == "canary" ]]; then award 2 "mode is '${MODE_VAL}'"; else deduct 2 "mode is '${MODE_VAL}' — must be 'stable' or 'canary'"; fi
else deduct 20 "manifest.yaml does not exist"; fi
end_section

# ═══ SECTION 3 — swiftdeploy init ═══
begin_section "3. swiftdeploy init"
rm -f nginx.conf docker-compose.yml docker-compose.yaml 2>/dev/null || true
echo "  Running: ./swiftdeploy init"
if timeout 30 bash swiftdeploy init 2>&1 | sed 's/^/    /'; then INIT_EXIT=0; else INIT_EXIT=$?; fi
if [[ $INIT_EXIT -eq 0 ]]; then award 3 "swiftdeploy init exits 0"; else deduct 3 "swiftdeploy init exited with code $INIT_EXIT"; fi

if [[ -f "nginx.conf" ]]; then
  award 4 "nginx.conf generated"
  if grep -q "X-Deployed-By" nginx.conf; then award 3 "nginx.conf adds X-Deployed-By header"; else deduct 3 "nginx.conf missing X-Deployed-By header"; fi
  if grep -q "proxy_pass" nginx.conf; then award 2 "nginx.conf has proxy_pass"; else deduct 2 "nginx.conf missing proxy_pass"; fi
  if grep -qE "502|503|504" nginx.conf && grep -q '"error"' nginx.conf; then award 3 "nginx.conf has JSON error bodies for 50x"; else deduct 3 "nginx.conf missing JSON error bodies"; fi
  if grep -q 'proxy_timeout\|proxy_read_timeout\|proxy_connect_timeout' nginx.conf; then award 2 "nginx.conf sets proxy timeouts"; else deduct 2 "nginx.conf missing proxy timeouts"; fi
  ALL_LOG=true
  for f in time_iso8601 status request_time upstream_addr request; do grep -q "$f" nginx.conf || { ALL_LOG=false; break; }; done
  if $ALL_LOG; then award 3 "nginx.conf log format has all required fields"; else deduct 3 "nginx.conf log format missing fields"; fi
  if grep -q "proxy_set_header.*X-Mode\|proxy_pass_header.*X-Mode" nginx.conf; then award 2 "nginx.conf forwards X-Mode header"; else deduct 2 "nginx.conf missing X-Mode forwarding"; fi
else deduct 19 "nginx.conf was NOT generated"; fi

COMPOSE_FILE=""
[[ -f "docker-compose.yml" ]] && COMPOSE_FILE="docker-compose.yml"
[[ -f "docker-compose.yaml" ]] && COMPOSE_FILE="docker-compose.yaml"
if [[ -n "$COMPOSE_FILE" ]]; then
  award 4 "docker-compose.yml generated"
  if grep -q "MODE" "$COMPOSE_FILE"; then award 2 "Injects MODE env var"; else deduct 2 "Missing MODE env var"; fi
  if grep -q "APP_VERSION" "$COMPOSE_FILE" && grep -q "APP_PORT" "$COMPOSE_FILE"; then award 2 "Injects APP_VERSION and APP_PORT"; else deduct 2 "Missing APP_VERSION or APP_PORT"; fi
  if grep -qE "user:|--user|nonroot|nobody|appuser" "$COMPOSE_FILE" || grep -q "USER" Dockerfile 2>/dev/null; then award 3 "Non-root user configured"; else deduct 3 "No non-root user configured"; fi
  if grep -q "cap_drop" "$COMPOSE_FILE"; then award 2 "Drops Linux capabilities"; else deduct 2 "Missing cap_drop"; fi
  if grep -qE "volumes:" "$COMPOSE_FILE"; then award 2 "Defines a named volume"; else deduct 2 "Missing named volume"; fi
  if grep -q "healthcheck\|/healthz" "$COMPOSE_FILE"; then award 2 "Defines healthcheck"; else deduct 2 "Missing healthcheck"; fi
  SVC_PORT=$(yaml_nested manifest.yaml services port)
  [[ -z "$SVC_PORT" ]] && SVC_PORT="3000"
  if grep -q "\"${SVC_PORT}:" "$COMPOSE_FILE" 2>/dev/null; then deduct 3 "Service port $SVC_PORT directly exposed"; else award 3 "Service port not directly exposed"; fi
  if grep -q "restart:" "$COMPOSE_FILE"; then award 1 "Sets restart policy"; else deduct 1 "Missing restart policy"; fi
  if grep -qE "networks:" "$COMPOSE_FILE"; then award 1 "Defines named network"; else deduct 1 "Missing named network"; fi
else deduct 21 "docker-compose.yml was NOT generated"; fi

echo -e "\n  ${BOLD}Regeneration test:${RESET}"
rm -f nginx.conf docker-compose.yml docker-compose.yaml
if timeout 30 bash swiftdeploy init >/dev/null 2>&1; then
  if [[ -f "nginx.conf" ]] && { [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; }; then award 5 "Configs regenerate correctly after deletion"; else deduct 5 "Configs did not regenerate"; fi
else deduct 5 "swiftdeploy init failed on second run"; fi
end_section

# ═══ SECTION 4 — swiftdeploy validate ═══
begin_section "4. swiftdeploy validate"
echo "  Running: ./swiftdeploy validate"
VALIDATE_OUT=$(timeout 30 bash swiftdeploy validate 2>&1 || true)
echo "$VALIDATE_OUT" | sed 's/^/    /'
if echo "$VALIDATE_OUT" | grep -iqE "pass|ok|valid" && ! echo "$VALIDATE_OUT" | grep -iqE "^error|^fail"; then award 3 "validate shows pass/ok indicators"; else warn_only "validate output format unclear"; fi

declare -A VC=(["manifest.yaml exists and is valid YAML"]="manifest" ["Required fields present"]="field|required" ["Docker image exists locally"]="image|docker" ["Nginx port not already bound"]="port|bind|listen|available" ["nginx.conf is syntactically valid"]="nginx|syntax")
for label in "${!VC[@]}"; do
  pat="${VC[$label]}"
  if echo "$VALIDATE_OUT" | grep -iqE "$pat"; then award 2 "validate checks: $label"; else deduct 2 "validate missing check: $label"; fi
done

echo "  Testing validate on broken manifest..."
cp manifest.yaml /tmp/manifest_backup.yaml
echo "broken: [invalid yaml: {" >> manifest.yaml
BROKEN_EXIT=0
timeout 15 bash swiftdeploy validate >/dev/null 2>&1 || BROKEN_EXIT=$?
cp /tmp/manifest_backup.yaml manifest.yaml; rm -f /tmp/manifest_backup.yaml
if [[ $BROKEN_EXIT -ne 0 ]]; then award 4 "validate exits non-zero on broken manifest"; else deduct 4 "validate did NOT exit non-zero on broken manifest"; fi
end_section

# ═══ SECTION 5 — swiftdeploy deploy ═══
begin_section "5. swiftdeploy deploy"
NGINX_PORT=$(yaml_nested manifest.yaml nginx port)
[[ -z "$NGINX_PORT" ]] && NGINX_PORT=8080
echo "  Running: ./swiftdeploy deploy (Nginx port: $NGINX_PORT, timeout: 90s)"
DEPLOY_OUT=$(timeout 90 bash swiftdeploy deploy 2>&1 || true)
DEPLOY_EXIT=$?
echo "$DEPLOY_OUT" | tail -20 | sed 's/^/    /'
if [[ $DEPLOY_EXIT -eq 0 ]]; then award 5 "swiftdeploy deploy exits 0"; else deduct 5 "swiftdeploy deploy exited $DEPLOY_EXIT"; fi
sleep 3
BASE_URL="http://localhost:${NGINX_PORT}"

HEALTHZ_RESP=$(http_get "${BASE_URL}/healthz" 2>/dev/null || echo "")
if echo "$HEALTHZ_RESP" | grep -q '"status"'; then award 5 "GET /healthz returns JSON with status"; else deduct 5 "GET /healthz failed (got: $(echo "$HEALTHZ_RESP" | head -c 100))"; fi
if echo "$HEALTHZ_RESP" | grep -qiE '"uptime|"up'; then award 3 "GET /healthz includes uptime"; else deduct 3 "GET /healthz missing uptime"; fi

HEADERS=$(http_headers "${BASE_URL}/" 2>/dev/null || echo "")
if echo "$HEADERS" | grep -qi "x-deployed-by.*swiftdeploy"; then award 4 "X-Deployed-By: swiftdeploy header present"; else deduct 4 "Missing X-Deployed-By header"; fi
if echo "$DEPLOY_OUT" | grep -iqE "health|ready|up|pass"; then award 3 "deploy waited for health checks"; else deduct 3 "deploy did not wait for health checks"; fi
end_section

# ═══ SECTION 6 — API Endpoints ═══
begin_section "6. API Endpoints"
ROOT_RESP=$(http_get "${BASE_URL}/" 2>/dev/null || echo "")
if echo "$ROOT_RESP" | grep -q "{" && echo "$ROOT_RESP" | grep -q "}"; then award 3 "GET / returns valid JSON"; else deduct 3 "GET / not valid JSON"; fi

CURRENT_MODE=$(yaml_val manifest.yaml mode)
[[ -z "$CURRENT_MODE" ]] && CURRENT_MODE="stable"
if echo "$ROOT_RESP" | grep -qi "\"mode\""; then award 3 "GET / includes mode ('$CURRENT_MODE')"; else deduct 3 "GET / missing mode field"; fi
if echo "$ROOT_RESP" | grep -qi "\"version\""; then award 2 "GET / includes version"; else deduct 2 "GET / missing version"; fi
if echo "$ROOT_RESP" | grep -qiE "\"time|\"timestamp"; then award 2 "GET / includes timestamp"; else deduct 2 "GET / missing timestamp"; fi

echo "  Testing POST ${BASE_URL}/chaos (slow mode, 3s)..."
CHAOS_RESP=$(http_post "${BASE_URL}/chaos" -H "Content-Type: application/json" -d '{"mode":"slow","duration":3}' 2>/dev/null || echo "")
if echo "$CHAOS_RESP" | grep -qiE "ok|accept|chaos|slow|403"; then award 3 "POST /chaos (slow) accepted"; else warn_only "POST /chaos (slow) response unclear"; fi

echo "  Verifying chaos slow mode causes delay..."
if [[ "$CURRENT_MODE" == "stable" ]]; then
  award 4 "Chaos correctly blocked in stable mode (delay test N/A)"
else
  SLOW_START=$SECONDS
  curl -s --max-time 25 "${BASE_URL}/" >/dev/null 2>&1 || true
  SLOW_ELAPSED=$((SECONDS - SLOW_START))
  if [[ $SLOW_ELAPSED -ge 2 ]]; then award 4 "Chaos slow delays response (${SLOW_ELAPSED}s)"; else deduct 4 "Chaos slow did not delay (${SLOW_ELAPSED}s)"; fi
fi

http_post "${BASE_URL}/chaos" -H "Content-Type: application/json" -d '{"mode":"recover"}' >/dev/null 2>&1 || true
sleep 1

echo "  Testing POST ${BASE_URL}/chaos (error rate 0.5)..."
http_post "${BASE_URL}/chaos" -H "Content-Type: application/json" -d '{"mode":"error","rate":0.5}' >/dev/null 2>&1 || true
# Error chaos only works in canary mode
if [[ "$CURRENT_MODE" == "stable" ]]; then
  award 4 "Chaos error correctly blocked in stable mode"
else
  ERROR_COUNT=0; TOTAL_REQS=20
  for i in $(seq 1 $TOTAL_REQS); do
    ST=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE_URL}/" 2>/dev/null || echo "000")
    [[ "$ST" == "500" ]] && ERROR_COUNT=$((ERROR_COUNT + 1))
  done
  echo "  Error chaos: ${ERROR_COUNT}/${TOTAL_REQS} returned 500"
  if [[ $ERROR_COUNT -ge 5 && $ERROR_COUNT -le 18 ]]; then award 4 "Chaos error ~50% 500s (${ERROR_COUNT}/${TOTAL_REQS})"; else deduct 4 "Chaos error rate wrong (${ERROR_COUNT}/${TOTAL_REQS})"; fi
fi

http_post "${BASE_URL}/chaos" -H "Content-Type: application/json" -d '{"mode":"recover"}' >/dev/null 2>&1 || true
sleep 1
REC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE_URL}/" 2>/dev/null || echo "000")
if [[ "$REC_STATUS" == "200" ]]; then award 3 "Chaos recover restores 200 OK"; else deduct 3 "After recover got $REC_STATUS instead of 200"; fi
if [[ "$CURRENT_MODE" == "canary" ]]; then
  if http_headers "${BASE_URL}/" 2>/dev/null | grep -qi "x-mode.*canary"; then award 4 "X-Mode: canary header present"; else deduct 4 "X-Mode: canary missing"; fi
else award 0 "(X-Mode canary tested in promote section)"; fi
end_section

# ═══ SECTION 7 — swiftdeploy promote ═══
begin_section "7. swiftdeploy promote"
echo "  Testing: ./swiftdeploy promote canary"
PROMOTE_OUT=$(timeout 60 bash swiftdeploy promote canary 2>&1 || true)
PROMOTE_EXIT=$?
echo "$PROMOTE_OUT" | tail -15 | sed 's/^/    /'
if [[ $PROMOTE_EXIT -eq 0 ]]; then award 4 "promote canary exits 0"; else deduct 4 "promote canary exited $PROMOTE_EXIT"; fi

NEW_MODE=$(yaml_val manifest.yaml mode)
if [[ "$NEW_MODE" == "canary" ]]; then award 3 "manifest.yaml updated to canary"; else deduct 3 "manifest.yaml mode not updated (got: '$NEW_MODE')"; fi
sleep 4

CANARY_HEADERS=$(http_headers "${BASE_URL}/" 2>/dev/null || echo "")
if echo "$CANARY_HEADERS" | grep -qi "x-mode.*canary"; then award 4 "X-Mode: canary header present"; else deduct 4 "X-Mode: canary header NOT present"; fi

CANARY_HZ=$(http_get "${BASE_URL}/healthz" 2>/dev/null || echo "")
if echo "$CANARY_HZ" | grep -qi "canary"; then award 2 "/healthz confirms canary mode"; else warn_only "/healthz does not mention canary"; fi

CANARY_CHAOS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST "${BASE_URL}/chaos" -H "Content-Type: application/json" -d '{"mode":"recover"}' 2>/dev/null || echo "000")
if [[ "$CANARY_CHAOS" =~ ^2 ]]; then award 2 "Chaos endpoint active in canary"; else deduct 2 "Chaos endpoint not responding (status: $CANARY_CHAOS)"; fi

echo "  Testing: ./swiftdeploy promote stable"
PROMOTE_S_OUT=$(timeout 60 bash swiftdeploy promote stable 2>&1 || true)
PROMOTE_S_EXIT=$?
echo "$PROMOTE_S_OUT" | tail -10 | sed 's/^/    /'
if [[ $PROMOTE_S_EXIT -eq 0 ]]; then award 3 "promote stable exits 0"; else deduct 3 "promote stable exited $PROMOTE_S_EXIT"; fi
sleep 4

STABLE_HEADERS=$(http_headers "${BASE_URL}/" 2>/dev/null || echo "")
if ! echo "$STABLE_HEADERS" | grep -qi "x-mode.*canary"; then award 2 "X-Mode absent after promote stable"; else deduct 2 "X-Mode still present after promote stable"; fi

FINAL_MODE=$(yaml_val manifest.yaml mode)
if [[ "$FINAL_MODE" == "stable" ]]; then award 2 "manifest.yaml reverted to stable"; else deduct 2 "manifest.yaml not reverted (got: '$FINAL_MODE')"; fi
end_section

# ═══ SECTION 8 — Nginx Runtime Behaviour ═══
begin_section "8. Nginx Runtime Behaviour"
echo "  Checking access logs..."
NGINX_CTR=$(docker ps --filter "name=nginx" --format "{{.Names}}" 2>/dev/null | head -1)
[[ -z "$NGINX_CTR" ]] && NGINX_CTR=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i nginx | head -1)
if [[ -n "$NGINX_CTR" ]]; then
  NGINX_LOGS=$(docker logs "$NGINX_CTR" 2>/dev/null | tail -20 || echo "")
  if echo "$NGINX_LOGS" | grep -qE "[0-9T:+\-]+ \| [0-9]{3} \| [0-9.]+s \|"; then award 5 "Nginx log format matches required pattern"; else deduct 5 "Nginx log format does not match"; warn_only "Sample: $(echo "$NGINX_LOGS" | grep -v '^$' | head -2)"; fi
else warn_only "Could not find Nginx container"; CURRENT_MAX=$((CURRENT_MAX + 5)); fi

echo "  Testing 502 JSON error body..."
APP_CTR=$(docker ps --filter "name=swiftdeploy" --format "{{.Names}}" 2>/dev/null | grep -iv nginx | head -1)
if [[ -n "$APP_CTR" ]]; then
  # Stop with no restart by updating restart policy first
  docker update --restart=no "$APP_CTR" >/dev/null 2>&1 || true
  docker kill "$APP_CTR" >/dev/null 2>&1 || true; sleep 2
  ERR_RESP=$(curl -s --max-time 10 "${BASE_URL}/" 2>/dev/null || echo "")
  [[ -z "$ERR_RESP" ]] && { sleep 3; ERR_RESP=$(curl -s --max-time 10 "${BASE_URL}/" 2>/dev/null || echo ""); }
  docker update --restart=unless-stopped "$APP_CTR" >/dev/null 2>&1 || true
  docker start "$APP_CTR" >/dev/null 2>&1 || true; sleep 5
  if echo "$ERR_RESP" | grep -q '"error"' && echo "$ERR_RESP" | grep -q '"code"'; then
    award 5 "Nginx returns JSON error on 502"
    if echo "$ERR_RESP" | grep -q '"service"' && echo "$ERR_RESP" | grep -q '"contact"'; then award 2 "JSON error has service and contact"; else deduct 2 "JSON error missing service or contact"; fi
  else deduct 7 "Nginx 502 not JSON (got: $(echo "$ERR_RESP" | head -c 100))"; fi
else warn_only "Could not find app container"; CURRENT_MAX=$((CURRENT_MAX + 7)); fi
end_section

# ═══ SECTION 9 — Docker Security & Config ═══
begin_section "9. Docker Security & Config"
IMG_NAME=$(yaml_nested manifest.yaml services image)
[[ -z "$IMG_NAME" ]] && IMG_NAME=$(yaml_val manifest.yaml image)
if [[ -n "$IMG_NAME" ]]; then
  IMG_SIZE=$(docker image inspect "$IMG_NAME" --format='{{.Size}}' 2>/dev/null || echo "0")
  IMG_MB=$((IMG_SIZE / 1024 / 1024))
  if [[ $IMG_MB -lt 300 ]]; then award 3 "Image is lightweight (${IMG_MB}MB)"; else deduct 3 "Image is heavy (${IMG_MB}MB)"; fi
fi

APP_CTR=$(docker ps --filter "name=swiftdeploy" --format "{{.Names}}" 2>/dev/null | grep -iv nginx | head -1)
if [[ -n "$APP_CTR" ]]; then
  CTR_USER=$(docker inspect "$APP_CTR" --format='{{.Config.User}}' 2>/dev/null || echo "")
  if [[ -n "$CTR_USER" && "$CTR_USER" != "root" && "$CTR_USER" != "0" ]]; then award 4 "Non-root user ('$CTR_USER')"; else deduct 4 "Container runs as root"; fi

  CAP_DROP=$(docker inspect "$APP_CTR" --format='{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")
  if echo "$CAP_DROP" | grep -iqE "ALL|NET_RAW|SYS_ADMIN"; then award 3 "Drops capabilities ($CAP_DROP)"; else deduct 3 "Does not drop capabilities (got: '$CAP_DROP')"; fi

  MOUNTS=$(docker inspect "$APP_CTR" --format='{{range .Mounts}}{{.Type}} {{end}}' 2>/dev/null || echo "")
  if echo "$MOUNTS" | grep -q "volume"; then award 2 "Named volume mounted"; else deduct 2 "No named volume mounted"; fi

  HC=$(docker inspect "$APP_CTR" --format='{{.Config.Healthcheck}}' 2>/dev/null || echo "")
  if [[ -n "$HC" && "$HC" != "<nil>" ]]; then award 2 "Container healthcheck defined"; else deduct 2 "No healthcheck defined"; fi
else
  warn_only "App container not running — skipping Docker security checks"
  CURRENT_MAX=$((CURRENT_MAX + 11))
fi
end_section

# ═══ SECTION 10 — swiftdeploy teardown ═══
begin_section "10. swiftdeploy teardown"
echo "  Running: ./swiftdeploy teardown --clean"
TEARDOWN_OUT=$(timeout 30 bash swiftdeploy teardown --clean 2>&1 || true)
TEARDOWN_EXIT=$?
echo "$TEARDOWN_OUT" | sed 's/^/    /'
if [[ $TEARDOWN_EXIT -eq 0 ]]; then award 3 "teardown --clean exits 0"; else deduct 3 "teardown --clean exited $TEARDOWN_EXIT"; fi
sleep 2

RUNNING=$(docker ps --filter "name=swiftdeploy" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RUNNING" -eq 0 ]]; then award 4 "All containers removed"; else warn_only "$RUNNING swiftdeploy containers still running"; award 2 "Teardown ran without error"; fi

if [[ ! -f "nginx.conf" ]] && [[ ! -f "docker-compose.yml" ]] && [[ ! -f "docker-compose.yaml" ]]; then award 3 "--clean removed generated configs"; else deduct 3 "--clean did NOT remove configs"; fi

bash swiftdeploy init >/dev/null 2>&1 || true
bash swiftdeploy teardown >/dev/null 2>&1 || true
sleep 2
if [[ -f "nginx.conf" ]] || [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then award 2 "teardown without --clean preserves configs"; else deduct 2 "teardown without --clean deleted configs"; fi
end_section
KEEP_STACK=false

# ═══ FINAL REPORT ═══
PCT=$(echo "scale=1; $TOTAL_SCORE * 100 / $MAX_SCORE" | bc 2>/dev/null || echo "N/A")
{
  echo ""; echo "========================================"; echo "FINAL SCORES"; echo "========================================"
  for i in "${!SECTION_NAMES[@]}"; do printf "%-45s %s/%s\n" "${SECTION_NAMES[$i]}" "${SECTION_SCORES[$i]}" "${SECTION_MAX[$i]}"; done
  echo "----------------------------------------"; echo "TOTAL: $TOTAL_SCORE / $MAX_SCORE  ($PCT%)"
  if [[ ${#FAILURES[@]} -gt 0 ]]; then echo ""; echo "FAILURES:"; for f in "${FAILURES[@]}"; do echo "  - $f"; done; fi
} | tee -a "$REPORT_FILE"

echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD} SwiftDeploy Stage 4 — Final Score: ${TOTAL_SCORE} / ${MAX_SCORE} (${PCT}%)${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if (( $(echo "$PCT >= 90" | bc -l 2>/dev/null || echo 0) )); then echo -e "${GREEN}Grade: DISTINCTION${RESET}"
elif (( $(echo "$PCT >= 75" | bc -l 2>/dev/null || echo 0) )); then echo -e "${GREEN}Grade: PASS${RESET}"
elif (( $(echo "$PCT >= 60" | bc -l 2>/dev/null || echo 0) )); then echo -e "${YELLOW}Grade: MARGINAL PASS${RESET}"
else echo -e "${RED}Grade: FAIL${RESET}"; fi
if [[ ${#FAILURES[@]} -gt 0 ]]; then echo -e "\n${BOLD}${RED}Failed checks:${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}•${RESET} $f"; done; fi
echo -e "\nFull report saved to: ${BOLD}${REPORT_FILE}${RESET}"
