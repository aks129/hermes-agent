#!/usr/bin/env bash
# =============================================================================
# setup-local-stack-mac.sh
#
# One-shot installer for a fully local agent stack on an Apple Silicon Mac
# (tested target: Mac mini M4 / M4 Pro):
#
#   1. vLLM (vllm-metal plugin, MLX backend)  ->  OpenAI-compatible API on :8000
#   2. OpenClaw                                ->  pointed at vLLM as provider "vllm"
#   3. Hermes Agent                            ->  pointed at vLLM as a custom endpoint
#
# The model is chosen from unified-memory size unless --model is given.
# Everything is idempotent: re-running repairs a partial install instead of
# duplicating it. Nothing here needs sudo except (optionally) --raise-gpu-limit.
#
# Usage:
#   bash scripts/mac/setup-local-stack-mac.sh [options]
#
# Options:
#   --model <hf-repo>        HF checkpoint to serve (default: picked by RAM tier)
#   --served-name <name>     Short model id exposed by vLLM (default: derived)
#   --max-model-len <n>      Context window vLLM allocates (default: by RAM tier)
#   --port <n>               vLLM port (default: 8000)
#   --channel stable|dev     vllm-metal release channel (default: stable)
#   --tool-parser <name>     vLLM --tool-call-parser (default: qwen3_xml)
#   --reasoning-parser <n>   vLLM --reasoning-parser (default: qwen3; "none" disables)
#   --skip-openclaw          Do not install/configure OpenClaw
#   --skip-hermes            Do not install/configure Hermes
#   --no-launchagent         Write the serve script but do not install/start launchd job
#   --raise-gpu-limit        sudo sysctl iogpu.wired_limit_mb (85% of RAM, until reboot)
#   --dry-run                Print the plan and exit without changing anything
#   -y, --yes                Do not pause for confirmation
#   -h, --help               Show this help
#
# Bash 3.2 compatible (stock macOS /bin/bash). No arrays-of-maps, no ${var,,}.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
VLLM_PORT=8000
VLLM_HOST=127.0.0.1
VLLM_CHANNEL=stable
VLLM_VENV="$HOME/.venv-vllm-metal"
VLLM_STATE_DIR="$HOME/.vllm-metal"
VLLM_LOG_DIR="$HOME/Library/Logs/vllm-metal"
VLLM_LAUNCH_LABEL="ai.vllm.metal"
VLLM_PLIST="$HOME/Library/LaunchAgents/${VLLM_LAUNCH_LABEL}.plist"
VLLM_API_KEY="${VLLM_API_KEY:-vllm-local}"
TOOL_PARSER=qwen3_xml
REASONING_PARSER=qwen3
MODEL=""
SERVED_NAME=""
MAX_MODEL_LEN=""
SKIP_OPENCLAW=0
SKIP_HERMES=0
NO_LAUNCHAGENT=0
RAISE_GPU_LIMIT=0
DRY_RUN=0
ASSUME_YES=0
HERMES_MIN_CONTEXT=64000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-local-stack-mac.sh"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi
info()    { printf '%s[info]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()      { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
fail()    { printf '%s[fail]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step()    { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_RST"; }
run()     {
    # Echo then execute, unless --dry-run.
    printf '    $ %s\n' "$*"
    if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi
}

usage() { sed -n '2,/^# ====.*$/p' "$0" | sed -n '2,$p' | sed 's/^# \{0,1\}//' | sed '$d'; }

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --model)            MODEL="$2"; shift 2 ;;
        --served-name)      SERVED_NAME="$2"; shift 2 ;;
        --max-model-len)    MAX_MODEL_LEN="$2"; shift 2 ;;
        --port)             VLLM_PORT="$2"; shift 2 ;;
        --channel)          VLLM_CHANNEL="$2"; shift 2 ;;
        --tool-parser)      TOOL_PARSER="$2"; shift 2 ;;
        --reasoning-parser) REASONING_PARSER="$2"; shift 2 ;;
        --skip-openclaw)    SKIP_OPENCLAW=1; shift ;;
        --skip-hermes)      SKIP_HERMES=1; shift ;;
        --no-launchagent)   NO_LAUNCHAGENT=1; shift ;;
        --raise-gpu-limit)  RAISE_GPU_LIMIT=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        -y|--yes)           ASSUME_YES=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done

case "$VLLM_CHANNEL" in stable|dev) ;; *) fail "--channel must be stable or dev" ;; esac

VLLM_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}/v1"

# -----------------------------------------------------------------------------
# Platform guard
# -----------------------------------------------------------------------------
step "Platform check"
OS_NAME="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS_NAME" != "Darwin" ] || [ "$ARCH" != "arm64" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "Not an Apple Silicon Mac ($OS_NAME/$ARCH). Continuing in --dry-run only."
    else
        fail "This script targets Apple Silicon macOS. Detected $OS_NAME/$ARCH. Use --dry-run to preview."
    fi
fi

MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="${MACOS_VER%%.*}"
if [ "$OS_NAME" = "Darwin" ] && [ "${MACOS_MAJOR:-0}" -lt 15 ]; then
    fail "vllm-metal requires macOS 15 (Sequoia) or later. Detected $MACOS_VER."
fi
if [ "$OS_NAME" = "Darwin" ]; then ok "macOS $MACOS_VER on $ARCH"; else ok "$OS_NAME on $ARCH (dry-run only)"; fi

if [ "$OS_NAME" = "Darwin" ]; then
    MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
else
    MEM_BYTES="$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0) * 1024 ))"
fi
MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
ok "Unified memory: ${MEM_GB} GB"

CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
info "Chip: $CHIP"

# -----------------------------------------------------------------------------
# Model selection by RAM tier
#
# All picks are mlx-community MLX-native checkpoints on the vllm-metal
# supported list (Qwen3.5 / Qwen3.8 hybrid GDN architectures). Weights are
# approximate on-disk sizes; the KV cache for --max-model-len comes on top,
# plus macOS + OpenClaw + Hermes (~6-8 GB). macOS caps GPU-wired memory at
# roughly 65-75% of RAM by default; see --raise-gpu-limit.
# -----------------------------------------------------------------------------
step "Model selection"
if [ -z "$MODEL" ]; then
    if   [ "$MEM_GB" -lt 12 ]; then
        MODEL="mlx-community/Qwen3.5-4B-MLX-4bit";  DEFAULT_LEN=65536;  TIER_NOTE="<12 GB: 4B is the largest that leaves room for a 64K KV cache."
    elif [ "$MEM_GB" -lt 20 ]; then
        MODEL="mlx-community/Qwen3.5-9B-4bit";      DEFAULT_LEN=65536;  TIER_NOTE="16 GB: Qwen3.5-9B-4bit (~5.5 GB weights) is the best tool-calling model that fits with 64K context."
    elif [ "$MEM_GB" -lt 28 ]; then
        MODEL="mlx-community/Qwen3.5-9B-8bit";      DEFAULT_LEN=131072; TIER_NOTE="24 GB: 9B-8bit (~10 GB) with 128K context. Qwen3.8-27B-4bit (~17 GB) fits only if you run nothing else; use --model to opt in."
    elif [ "$MEM_GB" -lt 40 ]; then
        MODEL="mlx-community/Qwen3.8-27B-4bit";     DEFAULT_LEN=65536;  TIER_NOTE="32 GB: Qwen3.8-27B-4bit (~17 GB) is the strongest agentic model that fits; 64K context keeps ~8 GB free."
    elif [ "$MEM_GB" -lt 56 ]; then
        MODEL="mlx-community/Qwen3.8-27B-4bit";     DEFAULT_LEN=131072; TIER_NOTE="48 GB: Qwen3.8-27B-4bit with 128K context. 8-bit (~31 GB) is possible but leaves little headroom."
    else
        MODEL="mlx-community/Qwen3.8-27B-8bit";     DEFAULT_LEN=131072; TIER_NOTE="64 GB+: Qwen3.8-27B-8bit (~31 GB), the vllm-metal reference checkpoint, with 128K context."
    fi
    info "$TIER_NOTE"
else
    DEFAULT_LEN=65536
fi
[ -n "$MAX_MODEL_LEN" ] || MAX_MODEL_LEN="$DEFAULT_LEN"

if [ -z "$SERVED_NAME" ]; then
    # "mlx-community/Qwen3.8-27B-4bit" -> "qwen3.8-27b-4bit". No slash: OpenClaw
    # addresses models as "<provider>/<id>" and a slash inside <id> is ambiguous.
    SERVED_NAME="$(printf '%s' "${MODEL##*/}" | tr '[:upper:]' '[:lower:]')"
fi

if [ "$MAX_MODEL_LEN" -lt "$HERMES_MIN_CONTEXT" ]; then
    warn "--max-model-len $MAX_MODEL_LEN is below Hermes' $HERMES_MIN_CONTEXT minimum; Hermes will refuse agentic work."
fi

ok "Model:        $MODEL"
ok "Served as:    $SERVED_NAME"
ok "Context:      $MAX_MODEL_LEN tokens"
ok "Endpoint:     $VLLM_BASE_URL"
ok "Tool parser:  $TOOL_PARSER   Reasoning parser: $REASONING_PARSER"

printf '\nPlan:\n'
printf '  1. Homebrew + Node >= 22.22 (OpenClaw prerequisite)\n'
printf '  2. vllm-metal (%s channel) into %s\n' "$VLLM_CHANNEL" "$VLLM_VENV"
printf '  3. Download %s\n' "$MODEL"
printf '  4. launchd service %s -> %s\n' "$VLLM_LAUNCH_LABEL" "$VLLM_BASE_URL"
[ "$SKIP_OPENCLAW" -eq 1 ] || printf '  5. OpenClaw install/repair, provider "vllm", default model vllm/%s\n' "$SERVED_NAME"
[ "$SKIP_HERMES" -eq 1 ]   || printf '  6. Hermes install/repair, custom endpoint -> %s, model %s\n' "$VLLM_BASE_URL" "$SERVED_NAME"
printf '  7. End-to-end verification (%s)\n' "$(basename "$CHECK_SCRIPT")"

if [ "$DRY_RUN" -eq 1 ]; then
    info "--dry-run: exiting before any changes."
    exit 0
fi
if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\nProceed? [Y/n] '
    read -r answer
    case "$answer" in n|N|no|NO) echo "Aborted."; exit 1 ;; esac
fi

# -----------------------------------------------------------------------------
# 1. Homebrew + Node
# -----------------------------------------------------------------------------
step "1/7 Homebrew and Node"
# Homebrew on Apple Silicon lives in /opt/homebrew and is often missing from
# non-login shells.
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found. Installing (this prompts for your password once)."
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
ok "brew $(brew --version | head -1 | awk '{print $2}')"

node_ok() {
    command -v node >/dev/null 2>&1 || return 1
    local v; v="$(node -v | sed 's/^v//')"
    local major minor patch
    major="${v%%.*}"; minor="$(printf '%s' "$v" | cut -d. -f2)"; patch="$(printf '%s' "$v" | cut -d. -f3)"
    # OpenClaw: Node 22.22.3+, 24.15+, or 25.9+; 26 recommended.
    if [ "$major" -ge 26 ]; then return 0; fi
    if [ "$major" -eq 25 ] && [ "$minor" -ge 9 ]; then return 0; fi
    if [ "$major" -eq 24 ] && [ "$minor" -ge 15 ]; then return 0; fi
    if [ "$major" -eq 22 ] && { [ "$minor" -gt 22 ] || { [ "$minor" -eq 22 ] && [ "$patch" -ge 3 ]; }; }; then return 0; fi
    return 1
}
if node_ok; then
    ok "node $(node -v)"
else
    warn "Node missing or too old for OpenClaw ($(node -v 2>/dev/null || echo none)). Installing via Homebrew."
    run brew install node
    hash -r
    node_ok || fail "Node still below OpenClaw's minimum after install. Check 'which node' for a shadowing nvm/volta install."
    ok "node $(node -v)"
fi

# -----------------------------------------------------------------------------
# 2. vllm-metal
# -----------------------------------------------------------------------------
step "2/7 vllm-metal"
# Native arm64 Python 3.12 is required; a Rosetta Python silently breaks MLX.
# The upstream installer ensures uv and a venv at ~/.venv-vllm-metal.
if [ -x "$VLLM_VENV/bin/vllm" ] && "$VLLM_VENV/bin/python" -c 'import vllm_metal' >/dev/null 2>&1; then
    ok "vllm-metal already installed: $("$VLLM_VENV/bin/vllm" --version 2>/dev/null | tail -1)"
else
    if [ -d "$VLLM_VENV" ]; then
        warn "Existing $VLLM_VENV is incomplete; removing and reinstalling."
        rm -rf "$VLLM_VENV"
    fi
    if [ "$VLLM_CHANNEL" = "stable" ]; then
        run bash -c 'curl -fsSL https://raw.githubusercontent.com/vllm-project/vllm-metal/main/install.sh | bash -s -- --stable'
    else
        run bash -c 'curl -fsSL https://raw.githubusercontent.com/vllm-project/vllm-metal/main/install.sh | bash'
    fi
    [ -x "$VLLM_VENV/bin/vllm" ] || fail "vllm-metal installer finished but $VLLM_VENV/bin/vllm is missing."
    "$VLLM_VENV/bin/python" -c 'import vllm_metal' || fail "vllm_metal plugin not importable in $VLLM_VENV."
    ok "vllm-metal installed: $("$VLLM_VENV/bin/vllm" --version 2>/dev/null | tail -1)"
fi
PY_ARCH="$("$VLLM_VENV/bin/python" -c 'import platform; print(platform.machine())')"
[ "$PY_ARCH" = "arm64" ] || fail "venv Python is $PY_ARCH, not arm64. Remove $VLLM_VENV and install a native arm64 Python 3.12."

# -----------------------------------------------------------------------------
# 3. Model download (separate from serve so failures are obvious)
# -----------------------------------------------------------------------------
step "3/7 Model download"
info "Downloading $MODEL to the Hugging Face cache (~/.cache/huggingface). Resumable."
run "$VLLM_VENV/bin/python" - "$MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download
path = snapshot_download(sys.argv[1])
print(f"    cached at {path}")
PY
ok "Model present"

# -----------------------------------------------------------------------------
# 4. Serve script + launchd
# -----------------------------------------------------------------------------
step "4/7 vLLM service"
mkdir -p "$VLLM_STATE_DIR" "$VLLM_LOG_DIR"

SERVE_SH="$VLLM_STATE_DIR/serve.sh"
REASONING_FLAG=""
if [ "$REASONING_PARSER" != "none" ]; then
    REASONING_FLAG="--reasoning-parser $REASONING_PARSER"
fi
cat > "$SERVE_SH" <<EOF
#!/usr/bin/env bash
# Generated by setup-local-stack-mac.sh. Edit and run: launchctl kickstart -k gui/\$(id -u)/$VLLM_LAUNCH_LABEL
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HF_HUB_OFFLINE="\${HF_HUB_OFFLINE:-0}"
export VLLM_METAL_MEMORY_FRACTION="\${VLLM_METAL_MEMORY_FRACTION:-auto}"
exec "$VLLM_VENV/bin/vllm" serve "$MODEL" \\
  --served-model-name "$SERVED_NAME" \\
  --host "$VLLM_HOST" \\
  --port "$VLLM_PORT" \\
  --api-key "$VLLM_API_KEY" \\
  --max-model-len "$MAX_MODEL_LEN" \\
  --max-num-seqs 4 \\
  --enable-auto-tool-choice \\
  --tool-call-parser "$TOOL_PARSER" \\
  $REASONING_FLAG \\
  --trust-remote-code
EOF
chmod +x "$SERVE_SH"
ok "Wrote $SERVE_SH"

cat > "$VLLM_STATE_DIR/${VLLM_LAUNCH_LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$VLLM_LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SERVE_SH</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>WorkingDirectory</key><string>$VLLM_STATE_DIR</string>
  <key>StandardOutPath</key><string>$VLLM_LOG_DIR/vllm.log</string>
  <key>StandardErrorPath</key><string>$VLLM_LOG_DIR/vllm.err.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>HOME</key><string>$HOME</string></dict>
</dict>
</plist>
EOF

if [ "$RAISE_GPU_LIMIT" -eq 1 ]; then
    LIMIT_MB=$(( MEM_GB * 1024 * 85 / 100 ))
    info "Raising GPU wired-memory limit to ${LIMIT_MB} MB (resets at reboot)."
    run sudo sysctl "iogpu.wired_limit_mb=$LIMIT_MB"
fi

if [ "$NO_LAUNCHAGENT" -eq 1 ]; then
    warn "--no-launchagent: start manually with: bash $SERVE_SH"
else
    mkdir -p "$HOME/Library/LaunchAgents"
    cp "$VLLM_STATE_DIR/${VLLM_LAUNCH_LABEL}.plist" "$VLLM_PLIST"
    UID_NUM="$(id -u)"
    # Replace any prior registration so config edits take effect.
    launchctl bootout "gui/$UID_NUM/$VLLM_LAUNCH_LABEL" >/dev/null 2>&1 || true
    run launchctl bootstrap "gui/$UID_NUM" "$VLLM_PLIST"
    run launchctl kickstart -k "gui/$UID_NUM/$VLLM_LAUNCH_LABEL"
    ok "launchd job $VLLM_LAUNCH_LABEL registered (logs: $VLLM_LOG_DIR)"

    info "Waiting for vLLM to load the model (first start can take several minutes)..."
    deadline=$(( $(date +%s) + 900 ))
    until curl -fsS -m 3 "http://${VLLM_HOST}:${VLLM_PORT}/health" >/dev/null 2>&1; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            printf '\n'
            warn "vLLM not healthy after 15 minutes. Last log lines:"
            tail -n 40 "$VLLM_LOG_DIR/vllm.err.log" 2>/dev/null >&2 || true
            fail "See $VLLM_LOG_DIR/vllm.err.log. Common causes: model too large for memory (pick a smaller --model), port in use (lsof -i :$VLLM_PORT)."
        fi
        if ! launchctl print "gui/$UID_NUM/$VLLM_LAUNCH_LABEL" 2>/dev/null | grep -q 'state = running'; then
            # launchd will respawn; surface the crash reason early.
            if grep -qiE 'out of memory|Insufficient memory|No space|Address already in use' "$VLLM_LOG_DIR/vllm.err.log" 2>/dev/null; then
                grep -iE 'out of memory|Insufficient memory|No space|Address already in use' "$VLLM_LOG_DIR/vllm.err.log" | tail -3 >&2
                fail "vLLM is crash-looping. Fix the cause above, then: launchctl kickstart -k gui/$UID_NUM/$VLLM_LAUNCH_LABEL"
            fi
        fi
        printf '.'
        sleep 5
    done
    printf '\n'
    ok "vLLM healthy at $VLLM_BASE_URL"
fi

# -----------------------------------------------------------------------------
# 5. OpenClaw
# -----------------------------------------------------------------------------
if [ "$SKIP_OPENCLAW" -eq 0 ]; then
    step "5/7 OpenClaw"
    # npm global bin is frequently missing from PATH on macOS -> "command not found".
    NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
    case ":$PATH:" in *":$NPM_BIN:"*) ;; *) export PATH="$NPM_BIN:$PATH" ;; esac

    if command -v openclaw >/dev/null 2>&1; then
        ok "openclaw $(openclaw --version 2>/dev/null | head -1)"
    else
        info "Installing OpenClaw (no onboarding wizard; configured below)."
        run bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'
        hash -r
        NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
        case ":$PATH:" in *":$NPM_BIN:"*) ;; *) export PATH="$NPM_BIN:$PATH" ;; esac
        command -v openclaw >/dev/null 2>&1 || fail "openclaw not on PATH after install. Add $NPM_BIN to PATH in ~/.zshrc and re-run."
        ok "openclaw $(openclaw --version 2>/dev/null | head -1)"
    fi

    # Stale "node" service alongside the gateway causes launchd restart loops.
    if launchctl print "gui/$(id -u)/ai.openclaw.node" >/dev/null 2>&1; then
        warn "Found ai.openclaw.node LaunchAgent next to the gateway; removing (known supervisor-loop cause)."
        run openclaw node uninstall || true
    fi

    OC_CONFIG="$(openclaw config file 2>/dev/null | tail -1 || true)"
    if [ -z "$OC_CONFIG" ] || [ ! -f "$OC_CONFIG" ]; then
        info "No OpenClaw config yet; running non-interactive onboarding against vLLM."
        if ! run openclaw onboard --non-interactive --accept-risk --skip-health --mode local \
                --auth-choice vllm \
                --custom-base-url "$VLLM_BASE_URL" \
                --custom-api-key "$VLLM_API_KEY" \
                --custom-model-id "$SERVED_NAME"; then
            warn "--auth-choice vllm rejected by this OpenClaw version; retrying with custom-api-key."
            run openclaw onboard --non-interactive --accept-risk --skip-health --mode local \
                --auth-choice custom-api-key \
                --custom-base-url "$VLLM_BASE_URL" \
                --custom-api-key "$VLLM_API_KEY" \
                --custom-model-id "$SERVED_NAME"
        fi
        OC_CONFIG="$(openclaw config file 2>/dev/null | tail -1 || true)"
    fi
    ok "OpenClaw config: $OC_CONFIG"

    # Authoritative provider definition, applied on every run (repairs drift).
    OC_PATCH="$VLLM_STATE_DIR/openclaw-vllm.patch.json5"
    cat > "$OC_PATCH" <<EOF
{
  models: {
    mode: "merge",
    providers: {
      vllm: {
        baseUrl: "$VLLM_BASE_URL",
        apiKey: "$VLLM_API_KEY",
        api: "openai-completions",
        timeoutSeconds: 600,
        models: [
          {
            id: "$SERVED_NAME",
            name: "$MODEL (local vLLM)",
            reasoning: true,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: $MAX_MODEL_LEN,
            maxTokens: 8192,
            compat: { thinkingFormat: "qwen-chat-template" },
          },
        ],
      },
    },
  },
  agents: {
    defaults: {
      model: { primary: "vllm/$SERVED_NAME" },
    },
  },
}
EOF
    run openclaw config patch --file "$OC_PATCH"
    run openclaw config validate

    if ! openclaw gateway status >/dev/null 2>&1; then
        run openclaw gateway install || true
    fi
    if ! run openclaw gateway restart; then
        warn "gateway restart failed; reinstalling the LaunchAgent (documented fix for split-brain / stale service)."
        run openclaw gateway install --force
        run openclaw gateway restart
    fi
    sleep 3
    run openclaw gateway status
    info "openclaw doctor (read-only; run 'openclaw doctor --fix' yourself if it lists repairs):"
    openclaw doctor || warn "openclaw doctor reported issues; see above."
fi

# -----------------------------------------------------------------------------
# 6. Hermes
# -----------------------------------------------------------------------------
if [ "$SKIP_HERMES" -eq 0 ]; then
    step "6/7 Hermes Agent"
    HERMES_BIN_DIR="$HOME/.local/bin"
    case ":$PATH:" in *":$HERMES_BIN_DIR:"*) ;; *) export PATH="$HERMES_BIN_DIR:$PATH" ;; esac
    if command -v hermes >/dev/null 2>&1; then
        ok "hermes $(hermes version 2>/dev/null | head -1 || true)"
    else
        info "Installing Hermes Agent."
        run bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
        hash -r
        command -v hermes >/dev/null 2>&1 || fail "hermes not on PATH after install. Open a new shell (source ~/.zshrc) and re-run with --skip-openclaw."
    fi
    # Same keys `hermes model` -> Custom endpoint writes; done here non-interactively.
    run hermes config set model.provider custom
    run hermes config set model.base_url "$VLLM_BASE_URL"
    run hermes config set model.default "$SERVED_NAME"
    run hermes config set model.api_key "$VLLM_API_KEY"
    run hermes config set model.context_length "$MAX_MODEL_LEN"
    # Hermes relaxes stream timeouts for local endpoints automatically; pin the
    # socket read timeout anyway because Qwen prefill on a Mac can be silent for minutes.
    HERMES_ENV="${HERMES_HOME:-$HOME/.hermes}/.env"
    if [ -f "$HERMES_ENV" ] && grep -q '^HERMES_STREAM_READ_TIMEOUT=' "$HERMES_ENV"; then
        ok "HERMES_STREAM_READ_TIMEOUT already set in $HERMES_ENV"
    else
        printf 'HERMES_STREAM_READ_TIMEOUT=1800\n' >> "$HERMES_ENV"
        ok "Set HERMES_STREAM_READ_TIMEOUT=1800 in $HERMES_ENV"
    fi
    info "hermes doctor:"
    hermes doctor || warn "hermes doctor reported issues; see above."
fi

# -----------------------------------------------------------------------------
# 7. Verification
# -----------------------------------------------------------------------------
step "7/7 Verification"
CHECK_ARGS="--vllm-url $VLLM_BASE_URL --api-key $VLLM_API_KEY --model $SERVED_NAME"
[ "$SKIP_OPENCLAW" -eq 1 ] && CHECK_ARGS="$CHECK_ARGS --skip-openclaw"
[ "$SKIP_HERMES" -eq 1 ]   && CHECK_ARGS="$CHECK_ARGS --skip-hermes"
[ "$NO_LAUNCHAGENT" -eq 1 ] && CHECK_ARGS="$CHECK_ARGS --skip-launchd"
if [ -x "$CHECK_SCRIPT" ] || [ -f "$CHECK_SCRIPT" ]; then
    # shellcheck disable=SC2086
    bash "$CHECK_SCRIPT" $CHECK_ARGS
else
    warn "Verification script not found at $CHECK_SCRIPT; skipping."
fi

printf '\n'
ok "Done. Useful commands:"
printf '    vLLM logs:      tail -f %s/vllm.err.log\n' "$VLLM_LOG_DIR"
printf '    vLLM restart:   launchctl kickstart -k gui/%s/%s\n' "$(id -u)" "$VLLM_LAUNCH_LABEL"
printf '    vLLM stop:      launchctl bootout gui/%s/%s\n' "$(id -u)" "$VLLM_LAUNCH_LABEL"
printf '    Change model:   edit %s, then restart\n' "$SERVE_SH"
[ "$SKIP_OPENCLAW" -eq 1 ] || printf '    OpenClaw:       openclaw status; openclaw logs --follow; openclaw doctor\n'
[ "$SKIP_HERMES" -eq 1 ]   || printf '    Hermes:         hermes            (or: hermes -z "hello")\n'
