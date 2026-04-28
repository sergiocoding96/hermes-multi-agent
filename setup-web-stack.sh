#!/usr/bin/env bash
# setup-web-stack.sh — Bootstrap the Hermes web search/scraping stack
# Run this on a fresh deployment to get: Firecrawl + SearXNG + Camofox
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
FIRECRAWL_DIR="${FIRECRAWL_DIR:-$HOME/.openclaw/workspace/firecrawl}"
FIRECRAWL_REPO="${FIRECRAWL_REPO:-https://github.com/mendableai/firecrawl}"
CAMOFOX_DIR="$HERMES_HOME/hermes-agent/node_modules/@askjo/camofox-browser"
NODE_BIN=$(which node 2>/dev/null || echo "/usr/bin/node")

echo "=== Hermes Web Stack Setup ==="
echo ""

# ---------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------
echo "--- Prerequisites ---"

if command -v docker &>/dev/null; then
    ok "Docker found: $(docker --version | head -1)"
else
    fail "Docker not found. Install: https://docs.docker.com/engine/install/"
    exit 1
fi

if docker compose version &>/dev/null; then
    ok "Docker Compose found"
else
    fail "Docker Compose plugin not found. Install: https://docs.docker.com/compose/install/"
    exit 1
fi

if command -v node &>/dev/null; then
    ok "Node.js found: $(node --version)"
else
    fail "Node.js not found. Install v22+ via brew/nvm/fnm"
    exit 1
fi

# Check docker group membership (check /etc/group, not just current shell session)
if id -nG | grep -qw docker || grep -q "docker.*$(whoami)" /etc/group 2>/dev/null; then
    ok "User is in docker group"
else
    warn "User not in docker group — you may need sudo for docker commands"
    warn "Fix: sudo usermod -aG docker \$USER && newgrp docker"
fi

echo ""

# ---------------------------------------------------------------
# 1b. Bootstrap Firecrawl from upstream if missing
# ---------------------------------------------------------------
# We deliberately track upstream main rather than pinning a commit:
# Firecrawl + Playwright + anti-bot logic evolves quickly, and pinning
# would mean running a stale anti-bot stack against a moving target
# (Cloudflare, Akamai, etc). To stay current after the initial clone:
#     cd $FIRECRAWL_DIR && git pull && docker compose up -d --build
echo "--- Firecrawl ---"

if [ ! -d "$FIRECRAWL_DIR/.git" ]; then
    if [ -d "$FIRECRAWL_DIR" ]; then
        fail "$FIRECRAWL_DIR exists but is not a git checkout. Refusing to overwrite."
        fail "Move/remove it and re-run, or set FIRECRAWL_DIR to a fresh path."
        exit 1
    fi
    info "Cloning Firecrawl from $FIRECRAWL_REPO → $FIRECRAWL_DIR"
    mkdir -p "$(dirname "$FIRECRAWL_DIR")"
    if ! git clone "$FIRECRAWL_REPO" "$FIRECRAWL_DIR"; then
        fail "Clone failed. Check network / repo URL ($FIRECRAWL_REPO) and re-run."
        exit 1
    fi
    ok "Cloned Firecrawl (tracking upstream main)"
else
    ok "Firecrawl present at $FIRECRAWL_DIR"
fi

# Bootstrap .env from upstream's example so SEARXNG_ENDPOINT can be appended later.
if [ ! -f "$FIRECRAWL_DIR/.env" ]; then
    if [ -f "$FIRECRAWL_DIR/.env.example" ]; then
        cp "$FIRECRAWL_DIR/.env.example" "$FIRECRAWL_DIR/.env"
        ok "Copied .env.example → .env (review and fill in API keys before production use)"
    else
        warn "No .env or .env.example in $FIRECRAWL_DIR — upstream layout may have changed."
    fi
fi

echo ""

# ---------------------------------------------------------------
# 2. SearXNG config (if not present)
# ---------------------------------------------------------------
echo "--- SearXNG ---"

SEARXNG_SETTINGS="$FIRECRAWL_DIR/searxng-settings.yml"
if [ ! -f "$SEARXNG_SETTINGS" ]; then
    cat > "$SEARXNG_SETTINGS" << 'SEARXNG_EOF'
use_default_settings: true

general:
  instance_name: "Hermes Search"
  enable_metrics: false

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json

server:
  secret_key: "hermes-local-searxng-change-me"
  bind_address: "0.0.0.0"
  port: 8080
  limiter: false
  image_proxy: false
  public_instance: false

engines:
  - name: google
    engine: google
    shortcut: g
    disabled: false
  - name: bing
    engine: bing
    shortcut: b
    disabled: false
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
    disabled: false
  - name: brave
    engine: brave
    shortcut: br
    disabled: false
  - name: wikipedia
    engine: wikipedia
    shortcut: wp
    disabled: false
  - name: arxiv
    engine: arxiv
    shortcut: ar
    disabled: false
  - name: github
    engine: github
    shortcut: gh
    disabled: false
SEARXNG_EOF
    ok "Created SearXNG settings at $SEARXNG_SETTINGS"
else
    ok "SearXNG settings already exist"
fi

# ---------------------------------------------------------------
# 3. Add SearXNG service via docker-compose.override.yaml
# ---------------------------------------------------------------
# Use Docker Compose's native override mechanism rather than patching
# upstream's docker-compose.yaml. Compose auto-merges override.yaml at
# runtime, so this stays valid even when upstream Firecrawl renames or
# restructures its compose file. We own the override; they own the base.
#
# Legacy installs may still have searxng wired directly into the main
# compose — leave those alone to avoid double-defining the service.
COMPOSE_FILE="$FIRECRAWL_DIR/docker-compose.yaml"
[ -f "$COMPOSE_FILE" ] || COMPOSE_FILE="$FIRECRAWL_DIR/docker-compose.yml"
OVERRIDE_FILE="$FIRECRAWL_DIR/docker-compose.override.yaml"

if [ -f "$COMPOSE_FILE" ] && grep -q "searxng" "$COMPOSE_FILE"; then
    ok "SearXNG already integrated into main compose (legacy install)"
elif [ -f "$OVERRIDE_FILE" ] && grep -q "searxng" "$OVERRIDE_FILE"; then
    ok "SearXNG already present in docker-compose.override.yaml"
else
    cat > "$OVERRIDE_FILE" << 'OVERRIDE_EOF'
# Hermes Web Stack — SearXNG override
# Owned by hermes-multi-agent (sergiocoding96/hermes-multi-agent).
# Compose auto-merges this with the upstream Firecrawl compose at runtime,
# so upstream layout changes don't break us.
services:
  searxng:
    image: searxng/searxng:latest
    ports:
      - "127.0.0.1:8888:8080"
    volumes:
      - ./searxng-settings.yml:/etc/searxng/settings.yml:ro
    restart: unless-stopped
OVERRIDE_EOF
    ok "Wrote SearXNG override → $OVERRIDE_FILE"
fi

# ---------------------------------------------------------------
# 4. Ensure SEARXNG_ENDPOINT in Firecrawl .env
# ---------------------------------------------------------------
FIRECRAWL_ENV="$FIRECRAWL_DIR/.env"
if [ -f "$FIRECRAWL_ENV" ]; then
    if grep -q "SEARXNG_ENDPOINT" "$FIRECRAWL_ENV"; then
        ok "SEARXNG_ENDPOINT already in Firecrawl .env"
    else
        echo "SEARXNG_ENDPOINT=http://searxng:8080" >> "$FIRECRAWL_ENV"
        ok "Added SEARXNG_ENDPOINT to Firecrawl .env"
    fi
else
    warn "Firecrawl .env not found at $FIRECRAWL_ENV"
fi

# ---------------------------------------------------------------
# 5. Start Firecrawl + SearXNG
# ---------------------------------------------------------------
echo ""
echo "--- Starting Firecrawl + SearXNG ---"
cd "$FIRECRAWL_DIR"
# Use sg to ensure docker group is active in this shell, fall back to sudo
if sg docker -c "docker compose up -d" 2>&1 | grep -E "Running|Started|Created" || true; then
    :
elif sudo docker compose up -d 2>&1 | grep -E "Running|Started|Created" || true; then
    :
fi

# Wait for services
sleep 5
if curl -sf "http://localhost:8888/search?q=test&format=json" >/dev/null 2>&1; then
    ok "SearXNG responding on :8888"
else
    warn "SearXNG not responding yet (may need more time to pull image)"
fi

if curl -sf "http://localhost:3002/" >/dev/null 2>&1; then
    ok "Firecrawl API responding on :3002"
else
    warn "Firecrawl API not responding yet — check: docker compose logs api"
fi

# ---------------------------------------------------------------
# 6. Camofox — rebuild native modules if needed
# ---------------------------------------------------------------
echo ""
echo "--- Camofox ---"

if [ -d "$CAMOFOX_DIR" ]; then
    ok "Camofox found at $CAMOFOX_DIR"

    # Check if better-sqlite3 needs rebuild
    if ! "$NODE_BIN" -e "require('$HERMES_HOME/hermes-agent/node_modules/better-sqlite3')" 2>/dev/null; then
        warn "better-sqlite3 needs rebuild for Node $(node --version)"
        cd "$HERMES_HOME/hermes-agent" && npm rebuild better-sqlite3 2>&1 | tail -1
        ok "Rebuilt better-sqlite3"
    else
        ok "better-sqlite3 native module OK"
    fi

    # Start Camofox if not running
    if curl -sf "http://localhost:9377/health" >/dev/null 2>&1; then
        ok "Camofox already running on :9377"
    else
        echo "Starting Camofox..."
        cd "$CAMOFOX_DIR"
        CAMOFOX_PORT=9377 nohup "$NODE_BIN" server.js >> "$HERMES_HOME/logs/camofox.log" 2>&1 &
        sleep 3
        if curl -sf "http://localhost:9377/health" >/dev/null 2>&1; then
            ok "Camofox started on :9377"
        else
            fail "Camofox failed to start — check $HERMES_HOME/logs/camofox.log"
        fi
    fi
else
    warn "Camofox not found — install hermes-agent first: cd ~/.hermes/hermes-agent && npm install"
fi

# ---------------------------------------------------------------
# 7. Hermes config — set web backend to firecrawl
# ---------------------------------------------------------------
echo ""
echo "--- Hermes Config ---"

HERMES_CONFIG="$HERMES_HOME/config.yaml"
if [ -f "$HERMES_CONFIG" ]; then
    CURRENT_BACKEND=$(grep -A1 "^web:" "$HERMES_CONFIG" | grep "backend:" | awk '{print $2}' || echo "unknown")
    if [ "$CURRENT_BACKEND" = "firecrawl" ]; then
        ok "web.backend already set to firecrawl"
    else
        warn "web.backend is '$CURRENT_BACKEND' — change to 'firecrawl' in $HERMES_CONFIG"
        warn "  Edit: web.backend: firecrawl"
    fi
else
    warn "Hermes config not found at $HERMES_CONFIG"
fi

# ---------------------------------------------------------------
# 8. Setup @reboot cron entries
# ---------------------------------------------------------------
echo ""
echo "--- Boot Persistence ---"

CRON_FIRECRAWL="@reboot cd $FIRECRAWL_DIR && /usr/bin/docker compose up -d"
CRON_CAMOFOX="@reboot sleep 5 && CAMOFOX_PORT=9377 $NODE_BIN $CAMOFOX_DIR/server.js >> $HERMES_HOME/logs/camofox.log 2>&1"

CURRENT_CRON=$(crontab -l 2>/dev/null || true)
UPDATED=false

if ! echo "$CURRENT_CRON" | grep -qF "firecrawl"; then
    CURRENT_CRON="$CURRENT_CRON
$CRON_FIRECRAWL"
    UPDATED=true
    ok "Added Firecrawl @reboot cron"
else
    ok "Firecrawl @reboot cron already exists"
fi

if ! echo "$CURRENT_CRON" | grep -qF "camofox"; then
    CURRENT_CRON="$CURRENT_CRON
$CRON_CAMOFOX"
    UPDATED=true
    ok "Added Camofox @reboot cron"
else
    ok "Camofox @reboot cron already exists"
fi

if [ "$UPDATED" = true ]; then
    echo "$CURRENT_CRON" | crontab -
fi

# ---------------------------------------------------------------
# 9. Final health check
# ---------------------------------------------------------------
echo ""
echo "=== Health Check ==="
PASS=0; TOTAL=3

if curl -sf "http://localhost:9377/health" >/dev/null 2>&1; then
    ok "Camofox     :9377  — anti-bot browser"; ((PASS++))
else
    fail "Camofox     :9377  — not responding"
fi

if curl -sf "http://localhost:8888/search?q=test&format=json" >/dev/null 2>&1; then
    ok "SearXNG     :8888  — search engine"; ((PASS++))
else
    fail "SearXNG     :8888  — not responding"
fi

if curl -sf "http://localhost:3002/" >/dev/null 2>&1; then
    ok "Firecrawl   :3002  — scrape + search API"; ((PASS++))
else
    fail "Firecrawl   :3002  — not responding"
fi

echo ""
if [ "$PASS" -eq "$TOTAL" ]; then
    ok "All $TOTAL services healthy. Web stack ready."
else
    warn "$PASS/$TOTAL services healthy. Check logs above."
fi
