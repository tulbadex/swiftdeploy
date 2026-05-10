# SwiftDeploy — Interview Questions & Answers

## Conceptual / Understanding Questions

### Q1: What is the purpose of `manifest.yaml` in this project?
**A:** It's the single source of truth for the entire deployment. All generated configs (nginx.conf, docker-compose.yml) are derived from it. If you delete the generated files and re-run `./swiftdeploy init`, everything regenerates identically from the manifest.

### Q2: Why is the app port (3000) never exposed directly to the host?
**A:** All traffic must route through Nginx on port 8080. This provides a reverse proxy layer for security, custom headers, access logging, error handling, and the ability to add rate limiting or other middleware without modifying the app.

### Q3: What's the difference between `stable` and `canary` mode?
**A:** Both use the same Docker image. In canary mode, the app adds an `X-Mode: canary` header to every response and enables the `/chaos` endpoint. In stable mode, `/chaos` returns 403. It simulates a blue/green or canary deployment strategy.

### Q4: Why do containers run as a non-root user with dropped capabilities?
**A:** Security best practice — principle of least privilege. If the container is compromised, the attacker has limited permissions. `cap_drop: ALL` removes all Linux capabilities, and `no-new-privileges` prevents privilege escalation.

---

## Technical / Implementation Questions

### Q5: Walk me through what happens when you run `./swiftdeploy deploy`.
**A:** It runs `init` (parses manifest, generates nginx.conf and docker-compose.yml from templates), builds the Docker image, brings up the stack via `docker compose up -d`, then polls `/healthz` every few seconds until it gets a healthy response or times out at 60 seconds.

### Q6: How does the `promote` subcommand work internally?
**A:** It updates the `mode` field in `manifest.yaml` in-place (e.g., `stable` → `canary`), regenerates `docker-compose.yml` with the new `MODE` env var, restarts only the app container (nginx stays up), then confirms the new mode by hitting `/healthz`.

### Q7: How does your Dockerfile ensure a lightweight image?
**A:** It uses `python:3.12-alpine` as the base (minimal ~50MB), creates a non-root user, copies only the app code, and defines a HEALTHCHECK. No unnecessary packages or build tools are installed.

### Q8: What are the 5 pre-flight checks in `validate`?
**A:**
1. `manifest.yaml` exists and is valid YAML
2. All required fields are present and non-empty
3. Docker image referenced in manifest exists locally
4. Nginx port is not already bound on the host
5. Generated `nginx.conf` is syntactically valid (via `nginx -t`)

### Q9: How does the chaos endpoint work?
**A:** It accepts JSON with three modes: `slow` (sleeps N seconds before responding), `error` (returns 500 on ~50% of subsequent requests based on a rate), and `recover` (cancels active chaos). It uses a thread-safe lock to manage shared state.

### Q10: What does `teardown --clean` do differently from `teardown`?
**A:** `teardown` removes containers, networks, and volumes. `teardown --clean` does all that PLUS deletes the generated config files (nginx.conf, docker-compose.yml).

---

## Nginx-Specific Questions

### Q11: What custom headers does Nginx add to responses?
**A:** `X-Deployed-By: swiftdeploy` on all responses, and it forwards `X-Mode` from the upstream app (only present in canary mode).

### Q12: What's the Nginx access log format and why?
**A:** `$time_iso8601 | $status | ${request_time}s | $upstream_addr | $request` — pipe-delimited for easy parsing, includes ISO timestamps for timezone clarity, request duration for performance monitoring, and upstream address for debugging.

### Q13: How does Nginx handle 502/503/504 errors?
**A:** It returns JSON error bodies like `{"error": "Bad Gateway", "code": 502, "service": "swiftdeploy", "contact": "admin@swiftdeploy.local"}` instead of default HTML error pages.

---

## Docker / Docker Compose Questions

### Q14: What environment variables are injected into the app container?
**A:** `MODE` (stable/canary), `APP_VERSION` (from manifest), and `APP_PORT` (3000).

### Q15: How is the health check configured in Docker Compose?
**A:** It hits `/healthz` on the internal port with a 10-second interval. The Dockerfile also defines a HEALTHCHECK using `wget -qO- http://127.0.0.1:3000/healthz || exit 1`.

### Q16: What's the purpose of the named volume `swiftdeploy-logs`?
**A:** Log persistence — if the container restarts or is recreated, logs survive because they're stored on a Docker-managed volume rather than inside the ephemeral container filesystem.

---

## Troubleshooting / Scenario Questions

### Q17: If I delete nginx.conf and docker-compose.yml, then run `./swiftdeploy init`, what should happen?
**A:** They should regenerate identically from the manifest and templates. The grader specifically tests this — the files must be byte-for-byte identical.

### Q18: What happens if port 8080 is already in use when you run `validate`?
**A:** The validate command should detect this and report a failure for the "port is not already bound" check, exiting with a non-zero code.

### Q19: If the app doesn't become healthy within 60 seconds during deploy, what happens?
**A:** The deploy command should timeout and exit with a non-zero status, indicating deployment failure.

### Q20: How would you verify the app is truly running through Nginx and not directly exposed?
**A:** Run `docker port swiftdeploy-app` — port 3000 should NOT appear. Only `curl localhost:8080` should work, not `curl localhost:3000`.

---

## Bonus / Deep-Dive Questions

### Q21: Why use templates instead of generating configs directly in the bash script?
**A:** Separation of concerns — templates are easier to maintain, read, and modify. The logic (variable substitution) stays in the script while the structure stays in the template files.

### Q22: How does the Python app handle thread safety for the chaos state?
**A:** It uses `threading.Lock()` — the chaos state dictionary includes a lock that's acquired before reading or writing the chaos mode/duration/rate values.

### Q23: Why is `http.server` used instead of Flask or FastAPI?
**A:** To keep the image lightweight with zero dependencies. The stdlib HTTP server is sufficient for this simple API, and it means no `pip install` or `requirements.txt` needed — just Python itself on Alpine.
