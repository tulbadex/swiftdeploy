# SwiftDeploy — Build the Tool That Builds the Stack

A declarative deployment tool that reads a single `manifest.yaml` and generates all infrastructure configs, manages the container lifecycle, and keeps your stack running. The manifest is the single source of truth — delete the generated files, re-run `./swiftdeploy init`, and everything regenerates.

## Project Structure

```
├── manifest.yaml                  # Single source of truth (only file you edit)
├── swiftdeploy                    # Bash CLI tool (executable)
├── Dockerfile                     # Lightweight Python 3.12 Alpine container
├── app/
│   └── main.py                    # HTTP API service (stable/canary modes)
├── templates/
│   ├── nginx.conf.tmpl            # Nginx config template
│   └── docker-compose.yml.tmpl    # Docker Compose template
└── README.md
```

## Prerequisites

- Docker (with Docker Compose v2)
- Bash 4.0+
- curl

## Quick Start

```bash
git clone <repository-url>
cd swiftdeploy

chmod +x swiftdeploy

# Deploy the full stack (builds image, generates configs, starts containers, waits for health)
./swiftdeploy deploy

# Verify
curl http://localhost:8080/
curl http://localhost:8080/healthz
```

## Subcommands

### `./swiftdeploy init`

Parses `manifest.yaml` and generates `nginx.conf` + `docker-compose.yml` from the templates directory.

```bash
./swiftdeploy init
```

```
[INFO]  Parsing manifest.yaml...
[INFO]  Generating nginx.conf from template...
[INFO]  Generating docker-compose.yml from template...
[PASS]  Generated nginx.conf
[PASS]  Generated docker-compose.yml
```

The grader can delete generated files and re-run `init` — they regenerate identically from the manifest.

### `./swiftdeploy validate`

Runs 5 pre-flight checks. Exits non-zero on any failure.

```bash
./swiftdeploy validate
```

```
[PASS]  manifest.yaml exists and is valid YAML
[PASS]  All required fields are present and non-empty
[PASS]  Docker image 'swiftdeploy:latest' exists locally
[PASS]  Port 8080 is available
[PASS]  nginx.conf is syntactically valid

[PASS]  All checks passed
```

Checks performed:
1. `manifest.yaml` exists and is valid YAML
2. All required fields are present and non-empty
3. Docker image referenced in the manifest exists locally
4. Nginx port is not already bound on the host
5. Generated `nginx.conf` is syntactically valid (tested via `nginx -t`)

### `./swiftdeploy deploy`

Runs `init`, builds the Docker image, brings up the stack via Docker Compose, and blocks until the health check passes (60s timeout).

```bash
./swiftdeploy deploy
```

```
[INFO]  Running init...
[PASS]  Generated nginx.conf
[PASS]  Generated docker-compose.yml
[INFO]  Building Docker image...
[INFO]  Bringing up the stack...
[INFO]  Waiting for health checks (timeout: 60s)...

[PASS]  Stack is healthy!
{
    "status": "healthy",
    "mode": "stable",
    "uptime_seconds": 3.79
}

[PASS]  SwiftDeploy stack is running on port 8080
```

### `./swiftdeploy promote <canary|stable>`

Switches deployment mode with a rolling service restart.

```bash
# Switch to canary mode
./swiftdeploy promote canary

# Switch back to stable mode
./swiftdeploy promote stable
```

```
[INFO]  Promoting from stable → canary...
[INFO]  Regenerating docker-compose.yml...
[INFO]  Restarting app service...
[INFO]  Confirming new mode...

[PASS]  Mode confirmed: canary
{
    "status": "healthy",
    "mode": "canary",
    "uptime_seconds": 1.03
}

[INFO]  Response headers:
X-Mode: canary
```

What it does:
- Updates `mode` in `manifest.yaml` in-place
- Regenerates `docker-compose.yml` with the new `MODE` env var
- Restarts only the app container (nginx stays up)
- Confirms the new mode is active by hitting `/healthz`
- `promote stable` reverses all of the above

### `./swiftdeploy teardown [--clean]`

Removes all containers, networks, and volumes.

```bash
# Teardown stack only
./swiftdeploy teardown

# Teardown + delete generated configs (nginx.conf, docker-compose.yml)
./swiftdeploy teardown --clean
```

```
[INFO]  Tearing down the stack...
[PASS]  Containers, networks, and volumes removed
[INFO]  Cleaning generated config files...
[PASS]  Generated configs deleted
```

## API Endpoints

All traffic routes through Nginx on port `8080`. The app service port (`3000`) is never exposed directly.

### `GET /`

Returns a welcome message with the current mode, version, and server timestamp.

```bash
curl http://localhost:8080/
```

```json
{
  "message": "Welcome to SwiftDeploy API (stable mode)",
  "mode": "stable",
  "version": "1.0.0",
  "timestamp": "2025-01-15T12:00:00.000000+00:00"
}
```

### `GET /healthz`

Liveness check returning status and process uptime in seconds.

```bash
curl http://localhost:8080/healthz
```

```json
{
  "status": "healthy",
  "mode": "stable",
  "uptime_seconds": 42.5
}
```

### `POST /chaos` (canary mode only)

Accepts a JSON body to simulate degraded behaviour. Returns `403` in stable mode.

```bash
# Slow: sleep N seconds before responding
curl -X POST http://localhost:8080/chaos \
  -H "Content-Type: application/json" \
  -d '{"mode": "slow", "duration": 8}'

# Error: return 500 on ~50% of subsequent requests
curl -X POST http://localhost:8080/chaos \
  -H "Content-Type: application/json" \
  -d '{"mode": "error", "rate": 0.5}'

# Recover: cancel any active chaos
curl -X POST http://localhost:8080/chaos \
  -H "Content-Type: application/json" \
  -d '{"mode": "recover"}'
```

## Manifest Reference

`manifest.yaml` is the only file you edit. Everything else is derived from it.

```yaml
services:
  app:
    image: swiftdeploy:latest
    port: 3000
    mode: stable
    version: "1.0.0"
    replicas: 1
    restart_policy: unless-stopped

nginx:
  image: nginx:latest
  port: 8080
  proxy_timeout: 30
  contact: admin@swiftdeploy.local

network:
  name: swiftdeploy-net
  driver_type: bridge

volumes:
  logs:
    name: swiftdeploy-logs
```

## Nginx Configuration

Generated from `templates/nginx.conf.tmpl` with values from the manifest:

- Listens on `nginx.port` (8080)
- Proxy timeouts set from `nginx.proxy_timeout`
- Reverse proxies to the app service on the internal Docker network
- Adds `X-Deployed-By: swiftdeploy` header to all responses
- Forwards `X-Mode` header from upstream (present in canary mode)
- Returns JSON error bodies on 502/503/504:
  ```json
  {"error": "Bad Gateway", "code": 502, "service": "swiftdeploy", "contact": "admin@swiftdeploy.local"}
  ```
- Access logs in the required format:
  ```
  $time_iso8601 | $status | ${request_time}s | $upstream_addr | $request
  ```

## Docker & Security

- Containers run as a non-root user (`appuser`)
- Linux capabilities dropped (`cap_drop: ALL`) with only required caps added back for nginx
- `no-new-privileges` security option enabled on all containers
- `MODE`, `APP_VERSION`, `APP_PORT` injected into the service container as env vars
- Named volume `swiftdeploy-logs` mounted for log persistence
- Health check defined on `/healthz` with 10s interval
- App port never exposed to the host — all traffic routes through Nginx
- Uses the defined network (`swiftdeploy-net`, bridge driver) and restart policy (`unless-stopped`)

## Viewing Logs

```bash
# Nginx access logs (via docker logs, since access_log writes to stdout in the container)
docker logs swiftdeploy-nginx --tail 20

# App container logs
docker logs swiftdeploy-app
```

Example nginx access log output:
```
2025-01-15T12:00:01+00:00 | 200 | 0.002s | 172.20.0.2:3000 | GET / HTTP/1.1
2025-01-15T12:00:02+00:00 | 200 | 0.001s | 172.20.0.2:3000 | GET /healthz HTTP/1.1
```
