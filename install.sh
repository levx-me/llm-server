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
#   VERBOSE        Set to 1 for extra debug output

set -euo pipefail

REPO="${REPO:-levx-me/llm-server}"
BRANCH="${BRANCH:-main}"
TARGET="${TARGET:-$HOME/llm-server}"

# -------------------------------------------------------------- logging --
STEP=0
step() {
	STEP=$((STEP + 1))
	printf '\n\033[1;36m[%d/%s] %s\033[0m\n' "$STEP" "$TOTAL_STEPS" "$*"
}
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '    \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
TOTAL_STEPS=11

check() {
	local what="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$what"
		return 0
	else
		err "$what — check failed"
	fi
}

# -------------------------------------------------------------- 1. prep --
step "prepare"
if [[ $(id -u) -eq 0 ]]; then
	SUDO=""
	info "running as root"
else
	command -v sudo >/dev/null || err "sudo required when running as non-root"
	SUDO="sudo"
	info "running as $(id -un), using sudo for privileged ops"
fi
info "target directory:  $TARGET"
info "repo:              $REPO @ $BRANCH"

# -------------------------------------------------------------- 2. distro --
step "detect distro"
. /etc/os-release 2>/dev/null || err "cannot read /etc/os-release"
info "OS: ${PRETTY_NAME:-$ID}"

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
ok "package manager: $PKG"

# -------------------------------------------------------------- 3. platform --
step "detect platform + resolve DATA_ROOT / SITE_ADDRESS"
if [[ -z "${DATA_ROOT:-}" ]]; then
	if [[ -d /runpod-volume ]] || [[ -n "${RUNPOD_POD_ID:-}" ]]; then
		export DATA_ROOT="/runpod-volume"
		PLATFORM="runpod"
	else
		export DATA_ROOT="$TARGET/data"
		PLATFORM="generic"
	fi
else
	PLATFORM="user-specified"
fi
export SITE_ADDRESS="${SITE_ADDRESS:-:80}"
info "platform:      $PLATFORM"
info "DATA_ROOT:     $DATA_ROOT"
info "SITE_ADDRESS:  $SITE_ADDRESS"
ok "configuration resolved"

# -------------------------------------------------------------- 4. base packages --
step "install base packages (git, curl, ca-certificates)"
if command -v git >/dev/null && command -v curl >/dev/null; then
	info "git $(git --version | awk '{print $3}'), curl $(curl --version | head -1 | awk '{print $2}')"
	ok "already present"
else
	pkg_update
	pkg_install git curl ca-certificates
	check "git installed"  command -v git
	check "curl installed" command -v curl
fi

# -------------------------------------------------------------- 5. docker --
step "install Docker Engine"
if command -v docker >/dev/null; then
	info "$(docker --version)"
	ok "docker already installed"
else
	info "downloading get.docker.com installer..."
	curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
	info "running installer (this takes 1-2 min)..."
	$SUDO sh /tmp/get-docker.sh >/tmp/docker-install.log 2>&1 ||
		err "docker install failed — see /tmp/docker-install.log"
	rm -f /tmp/get-docker.sh
	check "docker binary"   command -v docker
	$SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start 2>/dev/null || true
	check "docker running"  $SUDO docker info
	info "$(docker --version)"
	if [[ -n "$SUDO" ]]; then
		$SUDO usermod -aG docker "$(id -un)" && ok "user $(id -un) added to 'docker' group (re-login required)"
	fi
fi

step "verify Docker Compose v2 plugin"
if $SUDO docker compose version >/dev/null 2>&1; then
	info "$($SUDO docker compose version | head -1)"
	ok "compose available"
else
	err "docker compose v2 plugin missing"
fi

# -------------------------------------------------------------- 6. GPU --
step "install NVIDIA Container Toolkit (if GPU)"
if command -v nvidia-smi >/dev/null 2>&1; then
	info "GPU: $(nvidia-smi -L | head -1 | cut -c1-70)"
	if $SUDO docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
		ok "NVIDIA runtime already registered with docker"
	else
		info "installing nvidia-container-toolkit via $PKG..."
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
		check "nvidia-ctk binary" command -v nvidia-ctk
		$SUDO nvidia-ctk runtime configure --runtime=docker >/dev/null
		$SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart || true
		sleep 2
		check "NVIDIA runtime registered" sh -c "$SUDO docker info | grep -qi 'Runtimes:.*nvidia'"
	fi
else
	warn "no NVIDIA GPU detected — containers will run on CPU (slow)"
fi

# -------------------------------------------------------------- 7. clone --
step "clone / update repository"
if [[ -d "$TARGET/.git" ]]; then
	info "existing checkout at $TARGET"
	git -C "$TARGET" fetch --quiet origin "$BRANCH"
	BEFORE=$(git -C "$TARGET" rev-parse --short HEAD)
	git -C "$TARGET" checkout --quiet "$BRANCH"
	git -C "$TARGET" pull --ff-only --quiet
	AFTER=$(git -C "$TARGET" rev-parse --short HEAD)
	if [[ "$BEFORE" == "$AFTER" ]]; then
		ok "already at $AFTER"
	else
		ok "updated $BEFORE → $AFTER"
	fi
elif [[ -e "$TARGET" ]]; then
	err "$TARGET exists and is not a git checkout — remove it or set TARGET=<other path>"
else
	info "cloning https://github.com/$REPO.git -> $TARGET"
	git clone --quiet --branch "$BRANCH" "https://github.com/$REPO.git" "$TARGET"
	ok "cloned @ $(git -C "$TARGET" rev-parse --short HEAD)"
fi
check "docker-compose.yml present" test -f "$TARGET/docker-compose.yml"
check "bin/llm-server present"     test -f "$TARGET/bin/llm-server"

# -------------------------------------------------------------- 8. CLI --
step "install llm-server CLI"
chmod +x "$TARGET/bin/llm-server"
$SUDO ln -sf "$TARGET/bin/llm-server" /usr/local/bin/llm-server
check "/usr/local/bin/llm-server"  test -L /usr/local/bin/llm-server
info "CLI: $(readlink /usr/local/bin/llm-server)"

# -------------------------------------------------------------- 9. init --
step "llm-server init (create .env and data dirs)"
export LLM_HOME="$TARGET"
/usr/local/bin/llm-server init
check ".env exists"       test -f "$TARGET/.env"
check "data dir exists"   test -d "$DATA_ROOT/ollama"

# -------------------------------------------------------------- 10. launch --
step "llm-server up (pull images, start stack)"
if [[ "${SKIP_LAUNCH:-0}" == "1" ]]; then
	warn "SKIP_LAUNCH=1 set — skipping"
else
	/usr/local/bin/llm-server up
	sleep 3
	/usr/local/bin/llm-server status
fi

# ------------------------------------------------------------- finish --
echo
printf '\033[1;32m==> installation complete\033[0m\n'
echo "   home:  $TARGET"
echo "   CLI:   run 'llm-server help' (or 'llm-server help <command>' for details)"
echo
if [[ -n "$SUDO" ]] && ! groups | grep -q '\bdocker\b'; then
	printf '\033[1;33mNOTE:\033[0m you were added to the '\''docker'\'' group.\n'
	echo "      log out and back in, or run 'newgrp docker', to use docker without sudo."
fi
