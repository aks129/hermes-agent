#!/usr/bin/env bash
# =============================================================================
# check-local-stack-mac.sh
#
# End-to-end health check for the local stack installed by
# setup-local-stack-mac.sh: vLLM (vllm-metal) -> OpenClaw -> Hermes.
#
# Each check prints PASS / WARN / FAIL / SKIP. Exit code is 1 if any FAIL.
# Runs on any machine with bash + curl + python3; launchd/OpenClaw/Hermes
# checks are skipped automatically when the binaries are absent.
#
# Usage:
#   bash scripts/mac/check-local-stack-mac.sh [options]
#
# Options:
#   --vllm-url <url>     OpenAI base URL (default: http://127.0.0.1:8000/v1)
#   --api-key <key>      Bearer key for vLLM (default: $VLLM_API_KEY or vllm-local)
#   --model <id>         Served model id (default: first id from /v1/models)
#   --skip-launchd       Skip launchd service checks
#   --skip-openclaw      Skip OpenClaw checks
#   --skip-hermes        Skip Hermes checks
#   --no-inference       Only probe endpoints; do not generate tokens
#   -h, --help           Show this help
# =============================================================================
set -uo pipefail

VLLM_URL="http://127.0.0.1:8000/v1"
API_KEY="${VLLM_API_KEY:-vllm-local}"
MODEL=""
SKIP_LAUNCHD=0
SKIP_OPENCLAW=0
SKIP_HERMES=0
NO_INFERENCE=0
LAUNCH_LABEL="ai.vllm.metal"
HERMES_MIN_CONTEXT=64000
FAILS=0
WARNS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --vllm-url)      VLLM_URL="$2"; shift 2 ;;
        --api-key)       API_KEY="$2"; shift 2 ;;
        --model)         MODEL="$2"; shift 2 ;;
        --skip-launchd)  SKIP_LAUNCHD=1; shift ;;
        --skip-openclaw) SKIP_OPENCLAW=1; shift ;;
        --skip-hermes)   SKIP_HERMES=1; shift ;;
        --no-inference)  NO_INFERENCE=1; shift ;;
        -h|--help)       sed -n '2,/^# ====.*$/p' "$0" | sed -n '2,$p' | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
VLLM_URL="${VLLM_URL%/}"

if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi
pass() { printf '%sPASS%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%sWARN%s  %s\n' "$C_YEL" "$C_RST" "$*"; WARNS=$((WARNS+1)); }
fail() { printf '%sFAIL%s  %s\n' "$C_RED" "$C_RST" "$*"; FAILS=$((FAILS+1)); }
skip() { printf '%sSKIP%s  %s\n' "$C_DIM" "$C_RST" "$*"; }
hint() { printf '      %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
section() { printf '\n%s\n' "== $* =="; }

# Prefer the vllm-metal venv Python (guaranteed to exist after setup), else system.
PY="python3"
[ -x "$HOME/.venv-vllm-metal/bin/python" ] && PY="$HOME/.venv-vllm-metal/bin/python"
command -v "$PY" >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

# json_get <json-string> <python-expr-over-d>
json_get() {
    printf '%s' "$1" | "$PY" -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception as e:
    print(''); sys.exit(0)
try:
    v=$2
    print(v if isinstance(v,str) else json.dumps(v))
except Exception:
    print('')" 2>/dev/null
}

api() {
    # api <method> <path> [json-body]  -> sets API_BODY and HTTP_CODE (no subshell,
    # so both survive; a $(...) wrapper would lose HTTP_CODE).
    local method="$1" path="$2" body="${3:-}"
    local out
    if [ -n "$body" ]; then
        out="$(curl -sS -m 600 -w '\n%{http_code}' -X "$method" "$VLLM_URL$path" \
            -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' -d "$body" 2>&1)"
    else
        out="$(curl -sS -m 30 -w '\n%{http_code}' -X "$method" "$VLLM_URL$path" \
            -H "Authorization: Bearer $API_KEY" 2>&1)"
    fi
    HTTP_CODE="${out##*$'\n'}"
    API_BODY="${out%$'\n'*}"
    case "$HTTP_CODE" in [0-9][0-9][0-9]) ;; *) HTTP_CODE="000" ;; esac
}
HTTP_CODE="000"
API_BODY=""

# -----------------------------------------------------------------------------
section "Platform"
if [ "$(uname -s)" = "Darwin" ]; then
    pass "macOS $(sw_vers -productVersion 2>/dev/null) on $(uname -m), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB unified memory"
    if [ "$(uname -m)" != "arm64" ]; then fail "Not Apple Silicon; vllm-metal will not run"; fi
    LIMIT_MB="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
    if [ "${LIMIT_MB:-0}" -gt 0 ]; then hint "GPU wired limit override: ${LIMIT_MB} MB (sysctl iogpu.wired_limit_mb)"; fi
else
    warn "Not macOS ($(uname -s)); only the HTTP-level checks are meaningful here"
fi

# -----------------------------------------------------------------------------
section "vLLM service (launchd)"
if [ "$SKIP_LAUNCHD" -eq 1 ] || [ "$(uname -s)" != "Darwin" ]; then
    skip "launchd checks"
else
    if launchctl print "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1; then
        state="$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null | awk -F'= ' '/^\tstate = /{print $2}')"
        if [ "$state" = "running" ]; then pass "$LAUNCH_LABEL is running"; else
            fail "$LAUNCH_LABEL state: ${state:-unknown}"
            hint "tail -n 50 ~/Library/Logs/vllm-metal/vllm.err.log ; launchctl kickstart -k gui/$(id -u)/$LAUNCH_LABEL"
        fi
    else
        warn "$LAUNCH_LABEL not registered with launchd (vLLM may be running manually)"
    fi
    if [ -f "$HOME/Library/Logs/vllm-metal/vllm.err.log" ]; then
        if grep -qiE 'out of memory|insufficient memory' "$HOME/Library/Logs/vllm-metal/vllm.err.log" 2>/dev/null; then
            warn "vLLM log contains out-of-memory messages; consider a smaller model or --max-model-len"
        fi
    fi
fi

# -----------------------------------------------------------------------------
section "vLLM HTTP API ($VLLM_URL)"
ROOT="${VLLM_URL%/v1}"
if curl -fsS -m 5 "$ROOT/health" >/dev/null 2>&1; then
    pass "/health responds"
else
    fail "/health not responding at $ROOT/health"
    hint "Is vLLM up? lsof -i :${ROOT##*:} ; tail ~/Library/Logs/vllm-metal/vllm.err.log"
fi

api GET /models; MODELS_JSON="$API_BODY"
if [ "$HTTP_CODE" = "200" ]; then
    IDS="$(json_get "$MODELS_JSON" "[m['id'] for m in d['data']]")"
    pass "/v1/models -> $IDS"
    if [ -z "$MODEL" ]; then MODEL="$(json_get "$MODELS_JSON" "d['data'][0]['id']")"; fi
    if ! printf '%s' "$IDS" | grep -q "\"$MODEL\""; then
        fail "Expected model id '$MODEL' not served (served: $IDS)"
        hint "Model ids must match exactly in OpenClaw (vllm/<id>) and Hermes (model.default)."
    fi
    if printf '%s' "$MODEL" | grep -q '/'; then
        warn "Model id '$MODEL' contains '/'; OpenClaw addresses models as provider/<id>, so use --served-model-name without a slash"
    fi
    MAXLEN="$(json_get "$MODELS_JSON" "[m for m in d['data'] if m['id']=='$MODEL'][0].get('max_model_len')")"
    if [ -n "$MAXLEN" ] && [ "$MAXLEN" != "null" ]; then
        if [ "$MAXLEN" -ge "$HERMES_MIN_CONTEXT" ]; then pass "max_model_len=$MAXLEN (>= Hermes minimum $HERMES_MIN_CONTEXT)"; else
            fail "max_model_len=$MAXLEN is below Hermes' $HERMES_MIN_CONTEXT minimum"
            hint "Raise --max-model-len in ~/.vllm-metal/serve.sh (needs memory) or pick a smaller model."
        fi
    else
        warn "max_model_len not reported by /v1/models; cannot verify Hermes' 64K minimum"
    fi
elif [ "$HTTP_CODE" = "401" ]; then
    fail "/v1/models -> 401: API key mismatch (using '$API_KEY')"
    hint "Key must match --api-key in ~/.vllm-metal/serve.sh, OpenClaw models.providers.vllm.apiKey and Hermes model.api_key."
else
    fail "/v1/models -> HTTP ${HTTP_CODE:-none}: $(printf '%s' "$MODELS_JSON" | head -c 200)"
fi

if [ "$NO_INFERENCE" -eq 1 ]; then
    skip "inference checks (--no-inference)"
elif [ -n "$MODEL" ]; then
    # Plain completion. Thinking disabled so this is quick and deterministic.
    REQ="$(cat <<EOF
{"model":"$MODEL","messages":[{"role":"user","content":"Reply with the single word OK."}],
 "max_tokens":16,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}
EOF
)"
    t0=$(date +%s)
    api POST /chat/completions "$REQ"; RESP="$API_BODY"
    t1=$(date +%s)
    if [ "$HTTP_CODE" = "200" ]; then
        CONTENT="$(json_get "$RESP" "d['choices'][0]['message']['content']")"
        if printf '%s' "$CONTENT" | grep -qi 'ok'; then pass "chat completion in $((t1-t0))s -> '$(printf '%s' "$CONTENT" | tr -d '\n' | head -c 60)'"; else
            warn "chat completion returned unexpected text: '$(printf '%s' "$CONTENT" | tr -d '\n' | head -c 80)'"
        fi
    else
        fail "chat completion -> HTTP ${HTTP_CODE:-none}: $(printf '%s' "$RESP" | head -c 300)"
        if printf '%s' "$RESP" | grep -q 'chat_template_kwargs'; then hint "Server rejected chat_template_kwargs; harmless for non-Qwen models."; fi
    fi

    # Streaming: both OpenClaw and Hermes stream by default.
    STREAM="$(curl -sS -m 300 -N "$VLLM_URL/chat/completions" -H "Authorization: Bearer $API_KEY" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 5.\"}],\"max_tokens\":40,\"stream\":true,\"chat_template_kwargs\":{\"enable_thinking\":false}}" 2>&1)"
    if printf '%s' "$STREAM" | grep -q '^data: \[DONE\]'; then
        pass "streaming (SSE) terminates with [DONE]"
    else
        fail "streaming did not complete: $(printf '%s' "$STREAM" | head -c 200)"
    fi

    # Tool calling: the whole point of the agent stack.
    TOOL_REQ="$(cat <<EOF
{"model":"$MODEL","temperature":0,"max_tokens":256,
 "messages":[{"role":"user","content":"What is the weather in Boston right now? Use the tool."}],
 "tools":[{"type":"function","function":{"name":"get_weather","description":"Get current weather for a city",
   "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
 "tool_choice":"auto","chat_template_kwargs":{"enable_thinking":false}}
EOF
)"
    api POST /chat/completions "$TOOL_REQ"; RESP="$API_BODY"
    if [ "$HTTP_CODE" = "200" ]; then
        FN="$(json_get "$RESP" "d['choices'][0]['message']['tool_calls'][0]['function']['name']")"
        ARGS="$(json_get "$RESP" "d['choices'][0]['message']['tool_calls'][0]['function']['arguments']")"
        if [ "$FN" = "get_weather" ]; then
            pass "tool call parsed: get_weather($ARGS)"
        else
            warn "no parsed tool_calls in response (tools will not work in OpenClaw/Hermes)"
            hint "Check --enable-auto-tool-choice and --tool-call-parser in ~/.vllm-metal/serve.sh (qwen3_xml for Qwen3.5+, hermes for Qwen3/Llama)."
            hint "Raw content: $(json_get "$RESP" "d['choices'][0]['message']['content']" | tr -d '\n' | head -c 120)"
        fi
    else
        fail "tool-call request -> HTTP ${HTTP_CODE:-none}: $(printf '%s' "$RESP" | head -c 300)"
        hint "If the error mentions tools, restart vLLM with --enable-auto-tool-choice --tool-call-parser <parser>."
    fi
else
    skip "inference checks (no model id)"
fi

# -----------------------------------------------------------------------------
section "OpenClaw"
NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
case ":$PATH:" in *":$NPM_BIN:"*) ;; *) export PATH="$NPM_BIN:$PATH" ;; esac
if [ "$SKIP_OPENCLAW" -eq 1 ]; then
    skip "OpenClaw checks"
elif ! command -v openclaw >/dev/null 2>&1; then
    fail "openclaw not on PATH"
    hint "Install: curl -fsSL https://openclaw.ai/install.sh | bash ; ensure $NPM_BIN is in PATH"
else
    pass "openclaw $(openclaw --version 2>/dev/null | head -1)"
    if node_v="$(node -v 2>/dev/null)"; then
        major="${node_v#v}"; major="${major%%.*}"
        if [ "$major" -lt 22 ]; then fail "Node $node_v is below OpenClaw's minimum (22.22.3+)"; else pass "node $node_v"; fi
    fi
    if openclaw config validate >/dev/null 2>&1; then pass "openclaw config validate"; else
        fail "openclaw config validate reports errors"; hint "openclaw config validate ; openclaw doctor --fix"
    fi
    OC_BASE="$(openclaw config get models.providers.vllm.baseUrl 2>/dev/null | tail -1 | tr -d '"')"
    if [ "${OC_BASE%/}" = "$VLLM_URL" ]; then pass "providers.vllm.baseUrl = $OC_BASE"; else
        fail "providers.vllm.baseUrl is '${OC_BASE:-unset}', expected $VLLM_URL"
        hint "openclaw config set models.providers.vllm.baseUrl \"$VLLM_URL\""
    fi
    OC_PRIMARY="$(openclaw config get agents.defaults.model.primary 2>/dev/null | tail -1 | tr -d '"')"
    if [ -n "$MODEL" ] && [ "$OC_PRIMARY" = "vllm/$MODEL" ]; then pass "agents.defaults.model.primary = $OC_PRIMARY"; else
        fail "agents.defaults.model.primary is '${OC_PRIMARY:-unset}', expected vllm/$MODEL"
        hint "openclaw config set agents.defaults.model.primary \"vllm/$MODEL\""
    fi
    if openclaw models list --provider vllm 2>/dev/null | grep -q -- "$MODEL"; then pass "openclaw models list --provider vllm shows $MODEL"; else
        warn "openclaw models list --provider vllm does not show $MODEL"
    fi
    GW="$(openclaw gateway status 2>&1 || true)"
    if printf '%s' "$GW" | grep -qi 'running'; then pass "gateway running"; else
        fail "gateway not running"; hint "openclaw gateway install ; openclaw gateway restart ; openclaw logs --follow"
        if printf '%s' "$GW" | grep -q 'EADDRINUSE'; then hint "Port conflict: lsof -i :18789"; fi
    fi
    if launchctl print "gui/$(id -u)/ai.openclaw.node" >/dev/null 2>&1; then
        warn "ai.openclaw.node LaunchAgent present alongside gateway (restart-loop cause): openclaw node uninstall"
    fi
    if [ "$NO_INFERENCE" -eq 0 ] && [ -n "$MODEL" ]; then
        OUT="$(openclaw infer model run --model "vllm/$MODEL" --prompt "Reply with the single word OK." --json 2>&1 || true)"
        if printf '%s' "$OUT" | grep -qi '"text"\|"output"\|"content"\|OK'; then pass "openclaw infer via vllm/$MODEL"; else
            fail "openclaw infer model run failed: $(printf '%s' "$OUT" | tr -d '\n' | head -c 200)"
            hint "model_not_found -> baseUrl must end in /v1 and id must match. 'invalid type: sequence' -> compat.requiresStringContent: true"
        fi
    fi
fi

# -----------------------------------------------------------------------------
section "Hermes"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
if [ "$SKIP_HERMES" -eq 1 ]; then
    skip "Hermes checks"
elif ! command -v hermes >/dev/null 2>&1; then
    fail "hermes not on PATH"
    hint "Install: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
else
    pass "$(hermes version 2>/dev/null | head -1 || echo "hermes present")"
    HCFG="${HERMES_HOME:-$HOME/.hermes}/config.yaml"
    if [ -f "$HCFG" ]; then
        read -r H_PROV H_URL H_MODEL H_CTX <<EOF
$("$PY" - "$HCFG" <<'PY'
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    # Minimal fallback parser for the flat model: block when PyYAML is absent.
    d = {"model": {}}
    cur = None
    for line in open(sys.argv[1]):
        if line.startswith("model:"): cur = d["model"]; continue
        if cur is not None and line.startswith("  ") and ":" in line:
            k, v = line.strip().split(":", 1); cur[k.strip()] = v.strip().strip('"\'')
        elif cur is not None and line.strip() and not line.startswith(" "): cur = None
m = d.get("model") or {}
if isinstance(m, str): m = {"default": m}
print(m.get("provider",""), m.get("base_url",""), m.get("default") or m.get("model",""), m.get("context_length",""))
PY
)
EOF
        if [ "$H_PROV" = "custom" ]; then pass "model.provider = custom"; else
            fail "model.provider is '${H_PROV:-unset}', expected custom"; hint "hermes config set model.provider custom"
        fi
        if [ "${H_URL%/}" = "$VLLM_URL" ]; then pass "model.base_url = $H_URL"; else
            fail "model.base_url is '${H_URL:-unset}', expected $VLLM_URL"; hint "hermes config set model.base_url $VLLM_URL"
        fi
        if [ -n "$MODEL" ] && [ "$H_MODEL" = "$MODEL" ]; then pass "model.default = $H_MODEL"; else
            fail "model.default is '${H_MODEL:-unset}', expected $MODEL"; hint "hermes config set model.default $MODEL"
        fi
        if [ -n "$H_CTX" ] && [ "$H_CTX" -lt "$HERMES_MIN_CONTEXT" ] 2>/dev/null; then
            fail "model.context_length=$H_CTX is below Hermes' $HERMES_MIN_CONTEXT minimum"
        fi
    else
        fail "Hermes config not found at $HCFG"; hint "Run: hermes model  (Custom endpoint) or the setup script"
    fi
    if hermes doctor >/dev/null 2>&1; then pass "hermes doctor"; else warn "hermes doctor reported issues (run it for details)"; fi
    if [ "$NO_INFERENCE" -eq 0 ]; then
        OUT="$(hermes -z "Reply with the single word OK." 2>&1 || true)"
        if printf '%s' "$OUT" | grep -qi 'ok'; then pass "hermes -z round-trip -> '$(printf '%s' "$OUT" | tr -d '\n' | head -c 60)'"; else
            fail "hermes -z round-trip failed: $(printf '%s' "$OUT" | tr -d '\n' | head -c 200)"
            hint "hermes chat -q 'hello' for the full transcript; check ~/.hermes/logs"
        fi
    fi
fi

# -----------------------------------------------------------------------------
printf '\n'
if [ "$FAILS" -eq 0 ]; then
    printf '%sALL CHECKS PASSED%s (%d warnings)\n' "$C_GRN" "$C_RST" "$WARNS"
    exit 0
else
    printf '%s%d CHECK(S) FAILED%s, %d warnings\n' "$C_RED" "$FAILS" "$C_RST" "$WARNS"
    exit 1
fi
