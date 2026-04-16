# llm-server

Self-hosted LLM stack: **Ollama + Open WebUI + LiteLLM** behind **Caddy**.
Same `docker compose` works on AWS, RunPod, or bare metal.

## Stack

| Service | Container port | Role |
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

- Linux host with `apt-get`, `dnf`, or `yum` (Ubuntu / Debian / AL2023 / RHEL / Fedora)
- For GPU: NVIDIA driver installed on host (`nvidia-smi` works)
- Docker Engine + Compose plugin and NVIDIA Container Toolkit — **the one-line installer handles these automatically**

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/levx-me/llm-server/main/install.sh | bash
```

Auto-detects RunPod vs AWS vs bare-metal, installs Docker + NVIDIA Container
Toolkit as needed, clones this repo to `~/llm-server`, generates a random
`LITELLM_MASTER_KEY`, and starts all containers. Override defaults via env:

```bash
DATA_ROOT=/mnt/big-disk SITE_ADDRESS=llm.example.com \
  curl -fsSL https://raw.githubusercontent.com/levx-me/llm-server/main/install.sh | bash
```

## Quick start (manual)

```bash
git clone https://github.com/levx-me/llm-server.git
cd llm-server
cp .env.example .env
# edit .env: LITELLM_MASTER_KEY, SITE_ADDRESS, MODELS, DATA_ROOT

docker compose up -d
docker compose logs -f model-init   # watch model downloads
```

## Platform notes

### AWS EC2 (or any bare metal with public IP + domain)

```env
DATA_ROOT=./data
SITE_ADDRESS=llm.example.com
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
```

- Point DNS `A` record at the EC2 public IP
- Open security group ports 80 + 443
- Caddy auto-issues a Let's Encrypt cert (no manual TLS work)
- Install `nvidia-container-toolkit` first: see https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

### RunPod (GPU pod)

```env
DATA_ROOT=/runpod-volume
SITE_ADDRESS=:80
CADDY_HTTP_PORT=80
```

1. Create a **Network Volume** in RunPod (persists across pod rebuilds)
2. Launch a GPU pod with the volume mounted at `/runpod-volume`
3. In the pod template, expose HTTP port `80`
4. SSH into the pod:
   ```bash
   git clone <this repo>
   cd llm-server
   cp .env.example .env   # edit as above
   docker compose up -d
   ```
5. Access at `https://{pod-id}-80.proxy.runpod.net` (RunPod terminates TLS)

> RunPod proxy handles HTTPS — Caddy only needs to serve plain HTTP. Set
> `SITE_ADDRESS=:80`. If you want your own domain with TCP public IP instead
> of the proxy, use `SITE_ADDRESS=llm.example.com` like the AWS case.

## Configuration

- **Models** — edit `configs/litellm-config.yaml` to add / alias models
- **Routing** — edit `configs/Caddyfile`
- **Pre-pulled models** — set `MODELS="gemma4:e4b qwen3.5:9b ..."` in `.env`

Restart after config changes:

```bash
docker compose restart litellm    # after litellm-config.yaml change
docker compose restart caddy      # after Caddyfile change
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
docker compose down -v     # stop + drop named volumes (DATA_ROOT bind mounts stay)
```

### Update

Pull the latest config + images:

```bash
cd ~/llm-server
git pull --ff-only
docker compose pull
docker compose up -d
```

Or re-run the one-liner — idempotent, it git-pulls and restarts.

### Pull additional models

```bash
docker compose exec ollama ollama pull qwen3.5:27b
# or add to MODELS in .env and: docker compose run --rm model-init
```

### Reset

```bash
docker compose down
rm -rf "$DATA_ROOT"       # wipes all models + chat history + TLS certs
```

## Data layout (under `DATA_ROOT`)

```
${DATA_ROOT}/
├── ollama/        # pulled models (GB)
├── openwebui/     # Open WebUI users, chats, uploads
└── caddy/
    ├── data/      # Let's Encrypt certs, state
    └── config/    # runtime config
```

Back up the whole `DATA_ROOT` to preserve everything.
