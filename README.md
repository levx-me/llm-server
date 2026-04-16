# llm-server

Self-hosted LLM API stack: **Ollama** (GPU inference) + **LiteLLM** (OpenAI /
Anthropic compatible proxy) + **Caddy** (TLS + routing).

Single `docker compose` deployable on AWS, RunPod, or bare metal, managed via
the `llm-server` CLI.

## Stack

| Service | Container port | Role |
|---|---|---|
| ollama | 11434 | LLM inference (GPU) |
| litellm | 4000 | OpenAI / Anthropic compatible proxy |
| caddy | 80 / 443 | Reverse proxy, TLS, path routing |

## Routing (Caddy)

```
/                       → litellm   (OpenAI format, Swagger, Admin UI)
/anthropic/*            → litellm   (Anthropic format; /anthropic stripped)
```

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/levx-me/llm-server/main/install.sh | bash
```

Auto-detects RunPod vs bare-metal, installs Docker + NVIDIA Container Toolkit
as needed, clones this repo to `~/llm-server`, generates a random
`LITELLM_MASTER_KEY`, and starts all containers.

Override defaults via env:
```bash
DATA_ROOT=/mnt/ssd SITE_ADDRESS=llm.example.com \
  curl -fsSL https://raw.githubusercontent.com/levx-me/llm-server/main/install.sh | bash
```

After install, manage via the `llm-server` CLI (symlinked to `/usr/local/bin`).

## The `llm-server` CLI

```
llm-server up                     start the stack
llm-server down                   stop the stack
llm-server restart [service]      restart all or one service
llm-server status                 container state + endpoints + master key
llm-server logs [service]         tail logs
llm-server update                 git pull + docker compose pull + up -d

llm-server config [show|edit]     view / edit .env
llm-server key [show|rotate]      show / rotate LITELLM_MASTER_KEY

llm-server models [list]          list installed Ollama models
llm-server models pull <name>     download a model
llm-server models rm <name>       remove a model

llm-server exec <svc> [cmd...]    run a command inside a container
llm-server test                   curl /v1/models to verify
llm-server backup [path]          tar.gz the DATA_ROOT
llm-server reset                  down + delete DATA_ROOT (confirmation)

llm-server version                CLI + image versions
llm-server help [command]         detailed help
```

Detailed help for any command: `llm-server help <command>` or
`llm-server <command> --help`.

## Manual install

```bash
git clone https://github.com/levx-me/llm-server.git
cd llm-server
bin/llm-server init              # generates .env + data dirs
bin/llm-server up
```

## Platform profiles

### AWS EC2 / bare metal with a public domain

```env
DATA_ROOT=./data
SITE_ADDRESS=llm.example.com
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
```

- Point DNS A record at the host IP
- Open security group ports 80 + 443
- Caddy auto-issues a Let's Encrypt cert

### RunPod

```env
DATA_ROOT=/runpod-volume
SITE_ADDRESS=:80
CADDY_HTTP_PORT=80
```

1. Create a Network Volume (persists models / certs)
2. Launch a GPU pod, mount the volume at `/runpod-volume`
3. Expose HTTP port `80` in the pod template
4. SSH in and run the one-liner above
5. Access at `https://{pod-id}-80.proxy.runpod.net`

RunPod proxy terminates TLS for you, so `SITE_ADDRESS=:80` is correct.

## API usage

**OpenAI SDK**
```python
from openai import OpenAI
client = OpenAI(
    base_url="https://your-host/v1",
    api_key="<LITELLM_MASTER_KEY>",
)
client.chat.completions.create(model="gemma4", messages=[...])
```

**Anthropic / Claude Code**
```bash
export ANTHROPIC_BASE_URL="https://your-host"
export ANTHROPIC_AUTH_TOKEN="<LITELLM_MASTER_KEY>"
export ANTHROPIC_MODEL="claude-opus-4-5"
export ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4-5"
```

All `claude-*` model names are aliased to `gemma4:e4b` in
`configs/litellm-config.yaml`. Add / modify mappings there and restart
LiteLLM: `llm-server restart litellm`.

## Certificate management

Caddy handles Let's Encrypt automatically when `SITE_ADDRESS` is a domain.
Things to keep in mind:

- **Keep port 80 open** — ACME HTTP-01 challenge uses it even for HTTPS-only
  sites. If 80 is closed, renewals fail.
- **Preserve `DATA_ROOT`** — certs and ACME account key live in
  `$DATA_ROOT/caddy/data`. Wiping it triggers re-issuance and can hit
  Let's Encrypt rate limits on repeated cycles.
- **DNS must point at the host** — Caddy fails if the record is stale.
- **Auto-renewal** runs ~30 days before expiry. No cron needed.

## Data layout

Everything persistent lives under `${DATA_ROOT}`:

```
${DATA_ROOT}/
├── ollama/         # pulled models (GB)
└── caddy/
    ├── data/       # Let's Encrypt certs, account key, runtime state
    └── config/     # runtime config
```

Back up the whole `DATA_ROOT` to preserve everything:

```bash
llm-server backup /mnt/backups/llm.tar.gz
```

## Security notes

- Admin UI (`/ui/`) and Swagger (`/docs/`) are exposed — access is gated by
  `LITELLM_MASTER_KEY` but still leak the spec. Restrict at the proxy layer
  if that matters (e.g. IP allowlist in Caddy).
- Rotate the key periodically: `llm-server key rotate`.
- The master key grants full API access; distribute LiteLLM *virtual keys*
  (via Admin UI) to end users instead.
