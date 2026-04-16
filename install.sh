#!/usr/bin/env bash
#
# llm-server installer.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/levx-me/llm-server/main/install.sh | bash
#
# Overridable env vars:
#   REPO        GitHub slug (default levx-me/llm-server)
#   BRANCH      Git branch (default main)
#   TARGET      Install directory (default $HOME/llm-server)
#   DATA_ROOT   Persistent data path (auto-detected)
#   SITE_ADDRESS Caddy site address (default :80)
#   SKIP_LAUNCH Set to 1 to skip `docker compose up`

set -euo pipefail

REPO="${REPO:-levx-me/llm-server}"
BRANCH="${BRANCH:-main}"
TARGET="${TARGET:-$HOME/llm-server}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $(id -u) -eq 0 ]]; then
	SUDO=""
else
	command -v sudo >/dev/null || err "sudo required when running as non-root"
	SUDO="sudo"
fi

# ---------------------------------------------------------------- platform --
PLATFORM="bare-metal"
AUTO_DATA_ROOT="$TARGET/data"
AUTO_SITE_ADDRESS=":80"

if [[ -d /runpod-volume ]] || [[ -n "${RUNPOD_POD_ID:-}" ]]; then
	PLATFORM="runpod"
	AUTO_DATA_ROOT="/runpod-volume"
	AUTO_SITE_ADDRESS=":80"
elif curl -fsS --max-time 1 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
	PLATFORM="aws"
fi
log "platform detected: $PLATFORM"

# ---------------------------------------------------------------- packages --
if ! command -v git >/dev/null; then
	log "installing git"
	$SUDO apt-get update -qq
	$SUDO apt-get install -y -qq git ca-certificates curl
fi

if ! command -v docker >/dev/null; then
	log "installing Docker Engine"
	curl -fsSL https://get.docker.com | $SUDO sh
	$SUDO systemctl enable --now docker || true
	if [[ -n "$SUDO" ]]; then
		$SUDO usermod -aG docker "$(id -un)" || true
	fi
fi

if ! docker compose version >/dev/null 2>&1; then
	err "Docker Compose v2 plugin missing. Update Docker Engine."
fi

# -------------------------------------------------------------------- GPU --
if command -v nvidia-smi >/dev/null 2>&1; then
	log "NVIDIA GPU detected"
	if ! $SUDO docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
		log "installing NVIDIA Container Toolkit"
		. /etc/os-release
		DIST="${ID}${VERSION_ID}"
		curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
			$SUDO gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
		curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
			sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
			$SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
		$SUDO apt-get update -qq
		$SUDO apt-get install -y -qq nvidia-container-toolkit
		$SUDO nvidia-ctk runtime configure --runtime=docker
		$SUDO systemctl restart docker
	fi
else
	log "no NVIDIA GPU detected — containers will run on CPU (slow)"
fi

# -------------------------------------------------------------------- clone --
if [[ -d "$TARGET/.git" ]]; then
	log "updating $TARGET"
	git -C "$TARGET" fetch --quiet origin "$BRANCH"
	git -C "$TARGET" checkout --quiet "$BRANCH"
	git -C "$TARGET" pull --ff-only --quiet
elif [[ -e "$TARGET" ]]; then
	err "$TARGET exists and is not a git checkout — remove or set TARGET=<other path>"
else
	log "cloning https://github.com/$REPO.git -> $TARGET"
	git clone --quiet --branch "$BRANCH" "https://github.com/$REPO.git" "$TARGET"
fi

cd "$TARGET"

# ---------------------------------------------------------------------- .env --
if [[ ! -f .env ]]; then
	log "generating .env"
	[[ -f .env.example ]] || err ".env.example missing in repo"
	cp .env.example .env

	KEY="sk-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))' 2>/dev/null || openssl rand -base64 32 | tr -d '=+/' | cut -c1-43)"
	sed -i "s|sk-CHANGE-ME|$KEY|" .env

	DATA_ROOT_VAL="${DATA_ROOT:-$AUTO_DATA_ROOT}"
	sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$DATA_ROOT_VAL|" .env

	SITE_ADDRESS_VAL="${SITE_ADDRESS:-$AUTO_SITE_ADDRESS}"
	sed -i "s|^SITE_ADDRESS=.*|SITE_ADDRESS=$SITE_ADDRESS_VAL|" .env
else
	log ".env already exists — leaving untouched"
fi

mkdir -p "$(grep '^DATA_ROOT=' .env | cut -d= -f2-)"/{ollama,openwebui,caddy/data,caddy/config} 2>/dev/null || true

# ------------------------------------------------------------------ launch --
if [[ "${SKIP_LAUNCH:-0}" == "1" ]]; then
	log "SKIP_LAUNCH=1 — configuration only"
else
	log "pulling images"
	$SUDO docker compose pull --quiet
	log "starting containers"
	$SUDO docker compose up -d
fi

# ------------------------------------------------------------------ summary --
echo
log "done."
echo
echo "Install directory: $TARGET"
echo "Platform:          $PLATFORM"
grep -E '^(LITELLM_MASTER_KEY|SITE_ADDRESS|DATA_ROOT|MODELS)=' .env | sed 's/^/  /'
echo
echo "Next steps:"
echo "  cd $TARGET"
echo "  docker compose ps"
echo "  docker compose logs -f model-init   # watch model download"
echo
echo "If added to the 'docker' group for the first time, log out and back in"
echo "to run docker without sudo."
