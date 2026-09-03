---
sidebar_position: 3
title: "vLLM + OpenClaw + Hermes on a Mac mini"
description: "Install vLLM (vllm-metal) on Apple Silicon, pick a model that fits your unified memory, point OpenClaw and Hermes at it, and verify the whole stack end to end"
---

# vLLM + OpenClaw + Hermes on a Mac mini

This guide sets up one local model server and two agents that share it:

| Layer | What runs | Endpoint |
|-------|-----------|----------|
| Inference | vLLM with the [vllm-metal](https://github.com/vllm-project/vllm-metal) plugin (MLX backend) | `http://127.0.0.1:8000/v1` |
| Agent 1 | [OpenClaw](https://docs.openclaw.ai) gateway, provider `vllm` | `http://127.0.0.1:18789` |
| Agent 2 | Hermes, custom endpoint | CLI / gateway |

Two scripts in the repo do the work:

- `scripts/mac/setup-local-stack-mac.sh` installs and configures everything. It is idempotent, so re-running it repairs a partial install.
- `scripts/mac/check-local-stack-mac.sh` verifies each layer and prints PASS/WARN/FAIL with a fix hint per failure.

:::info Requirements
Apple Silicon Mac (M1 or later), macOS 15 Sequoia or later, native arm64 Python 3.12 (the vllm-metal installer provides it via `uv`). Intel Macs and Rosetta Python are not supported by vllm-metal.
:::

## Should you use vLLM on a Mac at all?

vLLM's CUDA-era strengths (PagedAttention, continuous batching across many users) matter less on a single-user Mac. What you get from vllm-metal is the standard vLLM OpenAI server with its tool-call and reasoning parsers, running on MLX. Paged attention on Metal is still marked experimental upstream.

If you only need Hermes and want the lowest memory footprint, `llama.cpp` with a quantized KV cache is still the leaner choice; see [Run Local LLMs on Mac](./local-llm-on-mac.md). Use vllm-metal when you want one server that OpenClaw and Hermes both address as a first-class vLLM provider, or when you need vLLM-specific features such as `--tool-call-parser` and `--reasoning-parser`.

## Quick start

```bash
git clone https://github.com/aks129/hermes-agent.git ~/hermes-agent   # or your fork/checkout
cd ~/hermes-agent
bash scripts/mac/setup-local-stack-mac.sh --dry-run   # shows the RAM tier, model, and plan
bash scripts/mac/setup-local-stack-mac.sh             # runs it
```

The first run downloads the model (5 to 31 GB depending on tier) and then waits up to 15 minutes for vLLM to load it. Subsequent starts are much faster.

Useful flags:

| Flag | Purpose |
|------|---------|
| `--model <hf-repo>` | Override the RAM-tier pick with any checkpoint on the [vllm-metal supported list](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md) |
| `--max-model-len <n>` | Context window vLLM allocates. Hermes needs at least 64,000. |
| `--channel dev` | Track vllm-metal main instead of the last tagged release |
| `--skip-openclaw` / `--skip-hermes` | Configure only one agent |
| `--raise-gpu-limit` | `sudo sysctl iogpu.wired_limit_mb` to 85% of RAM until reboot (helps 16 GB and 24 GB machines) |
| `--no-launchagent` | Write the serve script but do not register it with launchd |

## Model selection by unified memory

The script reads `hw.memsize` and picks a checkpoint from `mlx-community` that is on the vllm-metal support matrix. All are Qwen3.5 or Qwen3.8 hybrid-attention models, which have a small KV cache per token and reliable tool calling.

| Unified memory | Default model | Weights on disk | Context | Notes |
|---------------:|---------------|----------------:|--------:|-------|
| 8 GB | `mlx-community/Qwen3.5-4B-MLX-4bit` | ~2.5 GB | 64K | Marginal for agent work. Expect retries. |
| 16 GB | `mlx-community/Qwen3.5-9B-4bit` | ~5.5 GB | 64K | Best fit for the base Mac mini M4. |
| 24 GB | `mlx-community/Qwen3.5-9B-8bit` | ~10 GB | 128K | `Qwen3.8-27B-4bit` (~17 GB) fits only with nothing else running. |
| 32 GB | `mlx-community/Qwen3.8-27B-4bit` | ~17 GB | 64K | Strongest agentic model that fits with headroom. |
| 48 GB | `mlx-community/Qwen3.8-27B-4bit` | ~17 GB | 128K | 8-bit (~31 GB) is possible but tight. |
| 64 GB+ | `mlx-community/Qwen3.8-27B-8bit` | ~31 GB | 128K | The vllm-metal reference checkpoint. |

Why these and not the MoE models: `Qwen3.6-35B-A3B-4bit` generates faster but needs ~23 GB for weights alone, so it only makes sense at 48 GB and up, where the dense 27B scores higher on agentic benchmarks. Pass `--model mlx-community/Qwen3.6-35B-A3B-4bit` if you prefer speed over quality on a 48 GB or 64 GB machine.

Memory rule of thumb: weights + KV cache + roughly 6 to 8 GB for macOS, OpenClaw, Hermes, and a browser. macOS also caps GPU-wired memory at about two thirds of RAM on 16 GB and 24 GB machines, which is why the tiers above are conservative. `--raise-gpu-limit` lifts that cap for the current boot.

OpenClaw's own guidance is to run the largest model you can host, because small or heavily quantized checkpoints raise prompt-injection risk. On a Mac mini that means the 27B tier if you have the memory.

## What the setup script does

1. **Homebrew and Node.** OpenClaw needs Node 22.22.3+, 24.15+, or 25.9+. `brew install node` gives a current release.
2. **vllm-metal.** Runs the upstream installer (`--stable` by default), which creates `~/.venv-vllm-metal` with prebuilt wheels. Nothing compiles locally. `pip install vllm-metal` is not supported upstream.
3. **Model download.** `snapshot_download` into the Hugging Face cache so a failed download is distinguishable from a failed server start.
4. **launchd service.** Writes `~/.vllm-metal/serve.sh` and registers `ai.vllm.metal` with `KeepAlive`, logging to `~/Library/Logs/vllm-metal/`. The serve command is:

   ```bash
   vllm serve mlx-community/Qwen3.8-27B-4bit \
     --served-model-name qwen3.8-27b-4bit \
     --host 127.0.0.1 --port 8000 --api-key vllm-local \
     --max-model-len 65536 --max-num-seqs 4 \
     --enable-auto-tool-choice --tool-call-parser qwen3_xml \
     --reasoning-parser qwen3 --trust-remote-code
   ```

   `--served-model-name` matters: OpenClaw addresses models as `provider/id`, so an id containing a slash (`mlx-community/...`) is ambiguous.
5. **OpenClaw.** Installs with `--no-onboard` if missing, runs non-interactive onboarding against vLLM if there is no config yet, then applies a config patch that defines `models.providers.vllm` and sets `agents.defaults.model.primary` to `vllm/<id>`. Installs the gateway LaunchAgent and restarts it. Removes a stale `ai.openclaw.node` service if one is present, which is a documented cause of launchd restart loops.
6. **Hermes.** Installs if missing, then writes the same keys `hermes model` would write for a custom endpoint:

   ```bash
   hermes config set model.provider custom
   hermes config set model.base_url http://127.0.0.1:8000/v1
   hermes config set model.default qwen3.8-27b-4bit
   hermes config set model.api_key vllm-local
   hermes config set model.context_length 65536
   ```
7. **Verification.** Runs `check-local-stack-mac.sh`.

## Verifying the stack

```bash
bash scripts/mac/check-local-stack-mac.sh
```

The check script exercises:

- launchd state of `ai.vllm.metal` and OOM lines in its log
- `/health`, `/v1/models` (id match, `max_model_len` against Hermes' 64K minimum, API key)
- a non-streaming completion, a streaming completion that ends with `[DONE]`, and a tool call that must come back as parsed `tool_calls`
- OpenClaw: version, Node version, `config validate`, provider `baseUrl`, default model, `models list --provider vllm`, gateway status, and `openclaw infer model run --model vllm/<id>`
- Hermes: `config.yaml` provider, base URL, model, context length, `hermes doctor`, and a `hermes -z` round trip

Run it with `--no-inference` for a fast config-only pass.

## Troubleshooting

### vLLM

| Symptom | Cause | Fix |
|---------|-------|-----|
| `launchctl` shows the job restarting every 15 s | Model does not fit, or port in use | `tail -50 ~/Library/Logs/vllm-metal/vllm.err.log`. Pick a smaller `--model` or lower `--max-model-len`; `lsof -i :8000`. |
| `/health` never comes up on first run | Still downloading or compiling MLX kernels | Wait; the script waits 15 minutes. Check the log for progress. |
| Installer says Python is not arm64 | Rosetta Python 3.12 on PATH | `rm -rf ~/.venv-vllm-metal`, install a native arm64 Python 3.12 (`brew install python@3.12`), re-run. |
| Tool calls come back as plain text | Wrong `--tool-call-parser` for the model | Qwen3.5/3.6/3.8: `qwen3_xml`. Qwen3 (original), Llama 3, Hermes-format models: `hermes`. Edit `~/.vllm-metal/serve.sh`, then `launchctl kickstart -k gui/$(id -u)/ai.vllm.metal`. |
| Very slow first token on long prompts | Prefill on Apple GPU | Expected. Hermes relaxes its stream timeout for local endpoints automatically. |
| Want more of RAM for the model | macOS GPU wired limit | `sudo sysctl iogpu.wired_limit_mb=$((RAM_GB*1024*85/100))` (resets on reboot). |

Streaming tool calls with the `hermes` parser had an upstream vLLM bug where streamed chunks were not parsed; the check script tests non-streaming tool calls, so if streaming tool calls fail in an agent but the check passes, switch parsers or update vllm-metal with `rm -rf ~/.venv-vllm-metal` and re-run the installer.

### OpenClaw

Diagnostic order recommended by the OpenClaw docs:

```bash
openclaw status
openclaw gateway status --deep
openclaw logs --follow
openclaw doctor
openclaw config validate
```

| Symptom | Fix |
|---------|-----|
| `openclaw: command not found` after install | npm's global bin is not on PATH. `echo "export PATH=\"$(npm prefix -g)/bin:\$PATH\"" >> ~/.zshrc` and open a new shell. |
| Gateway won't stay up, `EADDRINUSE` | `lsof -i :18789`; another gateway or an old LaunchAgent. `openclaw gateway install --force && openclaw gateway restart`. |
| Service restarts every few seconds | Stale `ai.openclaw.node` next to the gateway. `openclaw node uninstall`, then reinstall the gateway. |
| Binary older than config (`lastTouchedVersion`) | `which openclaw`, `openclaw --version`, `openclaw config get meta.lastTouchedVersion`; remove the older install. |
| `model_not_found` | `baseUrl` must end in `/v1`; model id must match `/v1/models` exactly. |
| `messages[].content: invalid type: sequence` | Set `compat.requiresStringContent: true` on the model entry. |
| Backend crashes on large prompts | Lower `contextWindow` in the provider entry, or as a last resort `compat.supportsTools: false`. |
| Channels go quiet for hours | Mac slept. `sudo pmset -a sleep 0 disksleep 0 standby 0 powernap 0`. |
| Dashboard unreachable | `openclaw gateway restart`; check `gateway.controlUi.allowedOrigins`. |
| `Invalid config` at startup | `openclaw config validate`, then `openclaw doctor --fix`; look for `.rejected.*` backups. |

Set OpenClaw to use the model explicitly if a later onboarding changed it:

```bash
openclaw config set agents.defaults.model.primary "vllm/qwen3.8-27b-4bit"
openclaw gateway restart
```

### Hermes

| Symptom | Fix |
|---------|-----|
| Hermes refuses to start agentic work, mentions context | `model.context_length` or vLLM's `max_model_len` is below 64,000. Raise `--max-model-len`. |
| Stream timeout during long prefill | `HERMES_STREAM_READ_TIMEOUT=1800` in `~/.hermes/.env` (the script sets it). |
| Wrong provider picked | `hermes config show`; `model.provider` must be `custom` and `model.base_url` must end in `/v1`. |
| Want thinking off for speed | In `config.yaml` under `model:` add `extra_body: {chat_template_kwargs: {enable_thinking: false}}`. |

Check the whole chain at any time:

```bash
bash ~/hermes-agent/scripts/mac/check-local-stack-mac.sh
```

## Migrating from OpenClaw to Hermes

If you decide to run only Hermes, `hermes claw migrate --dry-run` previews what can be imported from `~/.openclaw` (persona, memory, skills, messaging settings). This guide keeps both agents running against the same vLLM server, so migration is optional.

## Operations cheat sheet

```bash
# vLLM
tail -f ~/Library/Logs/vllm-metal/vllm.err.log
launchctl kickstart -k gui/$(id -u)/ai.vllm.metal     # restart
launchctl bootout gui/$(id -u)/ai.vllm.metal          # stop
$EDITOR ~/.vllm-metal/serve.sh                        # change model/flags, then restart

# OpenClaw
openclaw status; openclaw logs --follow; openclaw gateway restart

# Hermes
hermes                 # interactive
hermes -z "hello"      # one-shot
hermes doctor
```

## Sources

- [vllm-metal installation](https://docs.vllm.ai/projects/vllm-metal/en/latest/installation/) and [supported models](https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md)
- [vllm-metal configuration variables](https://github.com/vllm-project/vllm-metal/blob/main/docs/configuration.md)
- [OpenClaw install](https://docs.openclaw.ai/install), [vLLM provider](https://docs.openclaw.ai/providers/vllm), [local models](https://docs.openclaw.ai/gateway/local-models), [gateway troubleshooting](https://docs.openclaw.ai/gateway/troubleshooting), [gateway on macOS](https://docs.openclaw.ai/platforms/mac/bundled-gateway)
- [Qwen3.8 hardware and sampling guidance](https://unsloth.ai/docs/models/qwen3.8), [Qwen3.6](https://unsloth.ai/docs/models/qwen3.6)
