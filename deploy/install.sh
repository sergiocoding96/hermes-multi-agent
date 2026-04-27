#!/usr/bin/env bash
# install.sh — Deploy Hermes Agent with the optimal multi-agent research stack
# Usage:
#   git clone https://github.com/sergiocoding96/hermes-multi-agent
#   cd hermes-multi-agent/deploy && ./install.sh
#
# Prerequisites:
#   - Hermes Agent CLI installed
#   - Docker running (for Firecrawl + SearXNG)
#   - Python 3.10+ (for setup-memos-agents.py)
#   - Patched MemOS running at localhost:8001 (see sergiocoding96/memos)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Hermes Agent — Optimal Setup Installer     ║"
echo "║   Multi-agent research + email marketing     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------
# 1. Check Hermes is installed
# ---------------------------------------------------------------
if ! command -v hermes &>/dev/null; then
    fail "Hermes Agent not found. Install first:"
    echo "  curl -fsSL https://hermes-agent.nousresearch.com/install | bash"
    exit 1
fi
ok "Hermes Agent found: $(hermes version 2>/dev/null | head -1)"

# ---------------------------------------------------------------
# 2. Deploy config
# ---------------------------------------------------------------
info "Deploying configuration..."

# Backup existing config
if [ -f "$HERMES_HOME/config.yaml" ]; then
    cp "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.bak.$(date +%s)"
    ok "Backed up existing config.yaml"
fi

cp "$REPO_DIR/config/config.yaml" "$HERMES_HOME/config.yaml"
ok "Deployed config.yaml"

# Deploy .env template (don't overwrite existing)
if [ ! -f "$HERMES_HOME/.env" ]; then
    cp "$REPO_DIR/config/.env.template" "$HERMES_HOME/.env"
    warn ".env created from template — fill in your API keys!"
else
    ok ".env already exists (not overwritten)"
    warn "Compare with config/.env.template for any new keys"
fi

# ---------------------------------------------------------------
# 3. Deploy profiles
# ---------------------------------------------------------------
info "Deploying agent profiles..."

for profile in research-agent email-marketing; do
    if [ -d "$REPO_DIR/profiles/$profile" ]; then
        PROFILE_DIR="$HERMES_HOME/profiles/$profile"
        if [ ! -d "$PROFILE_DIR" ]; then
            hermes profile create "$profile" --clone 2>/dev/null || true
        fi
        cp "$REPO_DIR/profiles/$profile/SOUL.md" "$PROFILE_DIR/SOUL.md" 2>/dev/null || true
        cp "$REPO_DIR/profiles/$profile/config.yaml" "$PROFILE_DIR/config.yaml" 2>/dev/null || true
        ok "Profile: $profile"
    fi
done

# ---------------------------------------------------------------
# 4. Deploy plugins
# ---------------------------------------------------------------
info "Deploying plugins..."

for plugin_dir in "$REPO_DIR/plugins"/*/; do
    plugin_name=$(basename "$plugin_dir")
    TARGET="$HERMES_HOME/plugins/$plugin_name"
    mkdir -p "$TARGET"
    cp -r "$plugin_dir"* "$TARGET/"
    ok "Plugin: $plugin_name"
done

# Mirror plugins into every existing profile.
# Hermes resolves HERMES_HOME to <profile_dir> when invoked with `-p <name>`,
# and plugin discovery only scans <HERMES_HOME>/plugins/ — NOT the global
# ~/.hermes/plugins/. Without this mirror, profile-scoped chats never load
# the plugin (no register(), no post_llm_call hook, no auto-capture).
# Symlinks (not copies) so a future re-run picks up updates atomically.
info "Mirroring plugins into profiles..."
shopt -s nullglob
for profile_dir in "$HERMES_HOME/profiles"/*/; do
    [ -d "$profile_dir" ] || continue
    profile_plugins="${profile_dir%/}/plugins"
    mkdir -p "$profile_plugins"
    for plugin_dir in "$HERMES_HOME/plugins"/*/; do
        plugin_name=$(basename "$plugin_dir")
        ln -sfn "$plugin_dir" "$profile_plugins/$plugin_name"
    done
    ok "Mirrored plugins into $(basename "$profile_dir")"
done
shopt -u nullglob

# ---------------------------------------------------------------
# 5. Clone shared skills repo
# ---------------------------------------------------------------
info "Setting up shared skills..."

SKILLS_REPO="$HOME/Coding/badass-skills"
if [ -d "$SKILLS_REPO" ]; then
    ok "badass-skills already cloned at $SKILLS_REPO"
    (cd "$SKILLS_REPO" && git pull --quiet 2>/dev/null) && ok "Pulled latest skills" || warn "Could not pull (offline?)"
else
    git clone https://github.com/sergiocoding96/badass-skills.git "$SKILLS_REPO" 2>/dev/null && \
        ok "Cloned badass-skills" || warn "Could not clone badass-skills (check GitHub access)"
fi

# ---------------------------------------------------------------
# 6. Web stack (Firecrawl + SearXNG + Camofox)
# ---------------------------------------------------------------
info "Setting up web stack..."
if [ -x "$REPO_DIR/scripts/setup-web-stack.sh" ]; then
    bash "$REPO_DIR/scripts/setup-web-stack.sh"
else
    warn "setup-web-stack.sh not found or not executable"
fi

# ---------------------------------------------------------------
# 7. Deploy SearXNG config
# ---------------------------------------------------------------
FIRECRAWL_DIR="$HOME/.openclaw/workspace/firecrawl"
if [ -d "$FIRECRAWL_DIR" ] && [ -f "$REPO_DIR/searxng/searxng-settings.yml" ]; then
    cp "$REPO_DIR/searxng/searxng-settings.yml" "$FIRECRAWL_DIR/searxng-settings.yml"
    ok "SearXNG settings deployed"
fi

# ---------------------------------------------------------------
# 8. MemOS agent key provisioning
# ---------------------------------------------------------------
info "Provisioning MemOS agent cubes + API keys..."

AUTH_FILE="$(dirname "$REPO_DIR")/agents-auth.json"
PROV_SCRIPT="$REPO_DIR/scripts/setup-memos-agents.py"

if [ -f "$AUTH_FILE" ]; then
    warn "agents-auth.json already exists — skipping provisioning (delete it to re-run)"
elif ! command -v python3 &>/dev/null; then
    warn "python3 not found — skipping provisioning. Run manually later:"
    echo "    python3 $PROV_SCRIPT"
elif ! curl -sf http://localhost:8001/health &>/dev/null; then
    warn "MemOS not reachable at localhost:8001 — skipping provisioning."
    echo "    Start MemOS (see sergiocoding96/memos), then run:"
    echo "    python3 $PROV_SCRIPT"
else
    if python3 "$PROV_SCRIPT"; then
        ok "Agents provisioned — agents-auth.json written to repo root"
        warn "Raw API keys were printed ONCE above. Save them securely — they won't be shown again."
    else
        fail "Provisioning failed. See scripts/setup-memos-agents.py"
    fi
fi

# ---------------------------------------------------------------
# 9. Final check
# ---------------------------------------------------------------
echo ""
echo "=== Final Status ==="
hermes status 2>/dev/null | head -15 || warn "Could not get hermes status"

echo ""
echo "=== Next Steps ==="
echo "1. Fill in API keys:    nano $HERMES_HOME/.env"
echo "2. Copy raw MEMOS keys (from step 8) into each profile's .env:"
echo "     nano $HERMES_HOME/profiles/research-agent/.env   # MEMOS_API_KEY=ak_..."
echo "     nano $HERMES_HOME/profiles/email-marketing/.env  # MEMOS_API_KEY=ak_..."
echo "3. Start gateway:       hermes gateway install && hermes gateway start"
echo "4. Test research:       hermes -p research-agent chat -q 'Research AI agents in real estate'"
echo "5. Test memory:         hermes -p research-agent chat -q 'Store: my favorite color is blue'"
echo ""
ok "Installation complete!"
