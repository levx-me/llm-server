# llm-server

Self-hosted LLM stack: Ollama + Open WebUI + LiteLLM proxy behind Caddy.

## Stack

| Service | Port (container) | Role |
|---|---|---|
| ollama | 11434 | LLM inference (GPU) |
| open-webui | 8080 | Chat UI |
| litellm | 4000 | OpenAI / Anthropic compatible proxy |
| caddy | 80 / 443 | Reverse proxy, TLS |

## Routing (via Caddy)

```
/                      → open-webui
/v1/*                  → litellm  (OpenAI format)
/anthropic/*           → litellm  (Anthropic format; /anthropic stripped)
/docs/, /ui/, /swagger → litellm  (Swagger, admin UI, assets)
```

## Prerequisites

- Docker + Docker Compose
- NVIDIA Container Toolkit (`nvidia-container-toolkit`) for GPU
- GPU-enabled host with recent NVIDIA driver

## Setup

```bash
cp .env.example .env
# edit .env: set LITELLM_MASTER_KEY, SITE_ADDRESS, MODELS

docker compose up -d
```

First boot will pull the Ollama models listed in `MODELS` (default: `gemma4:e4b`). Watch progress:

```bash
docker compose logs -f model-init
```

## Configuration

- **Models** — edit `configs/litellm-config.yaml` to add/alias models
- **Routing** — edit `configs/Caddyfile`
- **Pre-pulled models** — set `MODELS="gemma4:e4b qwen3.5:9b ..."` in `.env`

Restart the affected service after config changes:

```bash
docker compose restart litellm    # after litellm-config.yaml change
docker compose restart caddy      # after Caddyfile change
```

## Public HTTPS (AWS / bare metal with real domain)

Set in `.env`:
```
SITE_ADDRESS=llm.example.com
```

Caddy auto-issues a Let's Encrypt cert. DNS A record must point to the host and ports 80/443 must be open.

## HTTP only (local / behind another proxy)

```
SITE_ADDRESS=:80
```

## Usage

**OpenAI SDK:**
```python
from openai import OpenAI
client = OpenAI(
    base_url="https://your-domain/v1",
    api_key="<LITELLM_MASTER_KEY>",
)
client.chat.completions.create(model="gemma4", messages=[...])
```

**Anthropic / Claude Code:**
```bash
export ANTHROPIC_BASE_URL="https://your-domain"
export ANTHROPIC_AUTH_TOKEN="<LITELLM_MASTER_KEY>"
export ANTHROPIC_MODEL="claude-opus-4-5"
export ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4-5"
```

## Operations

```bash
docker compose ps
docker compose logs -f <service>
docker compose restart <service>
docker compose down        # stop all
docker compose down -v     # stop all + drop volumes (wipes models + webui data)
```

## Data locations (volumes)

- `ollama_data` — pulled models (~GB per model)
- `openwebui_data` — Open WebUI users, chats, uploads
- `caddy_data`, `caddy_config` — TLS certs and runtime state
