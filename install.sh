#!/usr/bin/env bash
#
# llm-server installer.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/levx-me/llm-server/main/install.sh | bash
#
# Overridable env vars:
#   REPO           GitHub slug (default levx-me/llm-server)
#   BRANCH         Git branch (default main)
#   TARGET         Install directory (default $HOME/llm-server)
#   DATA_ROOT      Persistent data path (auto-detected)
#   SITE_ADDRESS   Caddy site address (default :80)
#   SKIP_LAUNCH    Set to 1 to skip `llm-server up`

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

# ------------------------------------------------------------- distro --
. /etc/os-release 2>/dev/null || err "cannot read /etc/os-release"

if command -v apt-get >/dev/null; then
	PKG=apt
	pkg_update() { $SUDO apt-get update -qq; }
	pkg_install() { $SUDO apt-get install -y -qq "$@"; }
elif command -v dnf >/dev/null; then
	PKG=dnf
	pkg_update() { :; }
	pkg_install() { $SUDO dnf install -y -q "$@"; }
elif command -v yum >/dev/null; then
	PKG=yum
	pkg_update() { :; }
	pkg_install() { $SUDO yum install -y -q "$@"; }
else
	err "unsupported distro: no apt-get / dnf / yum"
fi
log "distro: ${PRETTY_NAME:-$ID} ($PKG)"

# ----------------------------------------------------------- platform --
if [[ -z "${DATA_ROOT:-}" ]]; then
	if [[ -d /runpod-volume ]] || [[ -n "${RUNPOD_POD_ID:-}" ]]; then
		export DATA_ROOT="/runpod-volume"
		log "platform: runpod"
	else
		export DATA_ROOT="$TARGET/data"
		log "platform: generic"
	fi
fi
export SITE_ADDRESS="${SITE_ADDRESS:-:80}"

# ----------------------------------------------------------- packages --
if ! command -v git >/dev/null || ! command -v curl >/dev/null; then
	log "installing base packages"
	pkg_update
	pkg_install git curl ca-certificates
fi

if ! command -v docker >/dev/null; then
	log "installing Docker Engine"
	curl -fsSL https://get.docker.com | $SUDO sh
	$SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start || true
	[[ -n "$SUDO" ]] && $SUDO usermod -aG docker "$(id -un)" || true
fi

$SUDO docker compose version >/dev/null 2>&1 ||
	err "Docker Compose v2 plugin missing. Update Docker Engine."

# ---------------------------------------------------------------- GPU --
if command -v nvidia-smi >/dev/null 2>&1; then
	log "NVIDIA GPU detected: $(nvidia-smi -L | head -1 | cut -c1-70)"
	if ! $SUDO docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
		log "installing NVIDIA Container Toolkit"
		case "$PKG" in
			apt)
				curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
					$SUDO gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
				curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
					sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
					$SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
				pkg_update
				pkg_install nvidia-container-toolkit
				;;
			dnf|yum)
				curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo |
					$SUDO tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
				pkg_install nvidia-container-toolkit
				;;
		esac
		$SUDO nvidia-ctk runtime configure --runtime=docker
		$SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart || true
	fi
else
	log "no NVIDIA GPU — containers will run on CPU (slow)"
fi

# -------------------------------------------------------------- clone --
if [[ -d "$TARGET/.git" ]]; then
	log "updating $TARGET"
	git -C "$TARGET" fetch --quiet origin "$BRANCH"
	git -C "$TARGET" checkout --quiet "$BRANCH"
	git -C "$TARGET" pull --ff-only --quiet
elif [[ -e "$TARGET" ]]; then
	err "$TARGET exists and is not a git checkout — remove it or set TARGET=<other path>"
else
	log "cloning https://github.com/$REPO.git -> $TARGET"
	git clone --quiet --branch "$BRANCH" "https://github.com/$REPO.git" "$TARGET"
fi

# ------------------------------------------------------------ CLI link --
log "installing llm-server CLI"
chmod +x "$TARGET/bin/llm-server"
$SUDO ln -sf "$TARGET/bin/llm-server" /usr/local/bin/llm-server

# ---------------------------------------------------- init + launch --
export LLM_HOME="$TARGET"
/usr/local/bin/llm-server init

if [[ "${SKIP_LAUNCH:-0}" != "1" ]]; then
	/usr/local/bin/llm-server up
	sleep 3
	/usr/local/bin/llm-server status
fi

# ------------------------------------------------------------- finish --
echo
log "installation complete"
echo "  CLI:   llm-server help"
echo "  Home:  $TARGET"
echo
if [[ -n "$SUDO" ]] && ! groups | grep -q '\bdocker\b'; then
	echo "NOTE: you were added to the 'docker' group."
	echo "      log out and back in so docker works without sudo."
fi
