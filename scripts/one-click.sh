#!/usr/bin/env bash
source functions.sh
set -e

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk One-Click Bootstrap Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_PATH"

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Pick your container engine
# —————————————————————————————————————————————————————————————
prompt_engine

# —————————————————————————————————————————————————————————————
# 2. SAML question early if needed (validate Y/N)
# —————————————————————————————————————————————————————————————
ENABLE_SAML_ONCLICK=$(prompt_yn "Enable SAML integration for this deployment?")
if [[ $ENABLE_SAML_ONCLICK == "n" ]]; then
	PRE_WARNS=$(
		printf '%s\n' "$PRE_WARNS" |
			grep -Ev "KEYSTORE_PASSWORD must be set|KEY_ALIAS_PASSWORD must be set" ||
			true
	)
fi

# —————————————————————————————————————————————————————————————
# 3. Run preflight and capture output
# —————————————————————————————————————————————————————————————
SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh" >preflight_output.txt 2>&1 || true
PRE_ERRS=$(grep 'ERROR:' preflight_output.txt | grep -v '^ERRORS:' || true)
PRE_WARNS=$(grep 'WARNING:' preflight_output.txt | grep -v '^WARNINGS:' || true)

# —————————————————————————————————————————————————————————————
# 4. Install missing dependencies
# —————————————————————————————————————————————————————————————
if echo "$PRE_ERRS" | grep -q "git is not installed"; then
	install_git
fi
if echo "$PRE_ERRS" | grep -q "Java not found"; then
	install_java
fi
if echo "$PRE_ERRS" | grep -q "psql is not installed"; then
	install_psql
fi
if echo "$PRE_ERRS" | grep -q "jq is not installed"; then
	install_jq
fi

if [[ $CONTAINER_ENGINE == "docker" ]]; then
	# Ensure Docker is installed
	if ! command -v docker &>/dev/null || ! command -v docker-compose &>/dev/null; then
		install_docker
	fi

	# Check if current user is in docker group
	if id -nG "$USER" | grep -qw docker; then
		DOCKER_USER="$USER"
	else
		# Not in group: prompt for username to add
		DOCKER_USER=$(prompt_for_docker_user)
		if ! id "$DOCKER_USER" &>/dev/null; then
			echo "User '$DOCKER_USER' does not exist."
			exit 1
		fi
		if ! id -nG "$DOCKER_USER" | grep -qw docker; then
			echo "Adding $DOCKER_USER to docker group..."
			sudo usermod -aG docker "$DOCKER_USER"
			echo "Added $DOCKER_USER to docker group."
			echo "You may need to log out and back in for the group change to take effect, "
			echo "or deployment steps will attempt to use the group automatically via 'sg docker'."
		fi
	fi
elif [[ $CONTAINER_ENGINE == "podman" ]]; then
	# Install podman if missing
	if ! command -v podman &>/dev/null; then
		install_podman
	fi
	if ! command -v podman-compose &>/dev/null; then
		install_podman
	fi

	# Ensure we will run podman rootless as the invoking user (no sudo anywhere)
	ROOTLESS_USER="$(resolve_rootless_user)"

	# Rootless pre-reqs (linger, config dirs, networking)
	setup_podman_rootless "${ROOTLESS_USER}"
else
	echo "Unknown container engine: $CONTAINER_ENGINE"
	exit 1
fi

prompt_postgres_option setup

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	install_and_configure_postgres
	export USE_INTERNAL_PG="y"
	export DB_PASS
elif [[ $POSTGRES_SETUP_OPTION == "2" ]]; then
	export USE_INTERNAL_PG="n"
fi

# —————————————————————————————————————————————————————————————
# 5. Run setup-wizard
# —————————————————————————————————————————————————————————————
echo
echo "Launching the setup wizard..."
set +e
if [[ $POSTGRES_SETUP_OPTION == "3" ]]; then
	# We want to prefill the external DB choice and details
	CONTAINER_ENGINE="$CONTAINER_ENGINE" \
		SAML_CHOICE="$ENABLE_SAML_ONCLICK" \
		USE_INTERNAL_PG="$USE_INTERNAL_PG" \
		DB_IP="$DB_IP" \
		DB_PASS="$DB_PASS" \
		./setup-wizard.sh
else
	# Let setup-wizard prompt for everything as usual (internal/external/etc)
	CONTAINER_ENGINE="$CONTAINER_ENGINE" \
		SAML_CHOICE="$ENABLE_SAML_ONCLICK" \
		USE_INTERNAL_PG="$USE_INTERNAL_PG" \
		./setup-wizard.sh
fi
set -e

echo
echo "Re-running preflight after setup..."
cd "$SCRIPT_PATH"
SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh"
PRE_ERR=$?

# —————————————————————————————————————————————————————————————
# 6. Block on critical errors
# —————————————————————————————————————————————————————————————
if [[ $PRE_ERR -ne 0 ]]; then
	echo
	echo "Preflight detected critical errors above."
	echo "Please resolve these before proceeding with deployment."
	exit 1
fi

# —————————————————————————————————————————————————————————————
# 7. Confirm deploy (validate Y/N)
# —————————————————————————————————————————————————————————————
DEPLOY_OK=$(prompt_yn "All checks complete. Proceed with deployment?")
if [[ $DEPLOY_OK == "n" ]]; then
	echo "Aborted by user."
	exit 0
fi

# ---- LOGIN TO CONTAINER REGISTRY ----
container_registry_login

# —————————————————————————————————————————————————————————————
# 8. Deploy based on selected engine
# —————————————————————————————————————————————————————————————
CONTAINER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../$CONTAINER_ENGINE && pwd)"

case "$CONTAINER_ENGINE" in
	docker)
		echo
		echo "Deploying with Docker Compose..."

		DOCKER_COMPOSE_PATH="$(which docker-compose 2>/dev/null)"
		cd "$CONTAINER_DIR"

		if [[ -z $DOCKER_USER ]]; then
			DOCKER_USER="$USER"
		fi

		# Build commands
		COMPOSE_OVERRIDE=$(build_compose_override "$ENABLE_SAML_ONCLICK" "$USE_INTERNAL_PG")
		CLEAN_CMD="sg docker -c \"docker-compose $COMPOSE_OVERRIDE down --remove-orphans\""
		PS_CMD="sg docker -c \"docker-compose $COMPOSE_OVERRIDE ps -q\""
		PS_OUTPUT=$(sg docker -c "cd $(pwd) && $PS_CMD")

		if [[ -n $PS_OUTPUT ]]; then
			echo "Cleaning up existing containers for this project..."
			sg docker -c "cd $(pwd) && $CLEAN_CMD"
			# Force-remove any leftover containers by their container_name
			for svc in iriusrisk-nginx iriusrisk-tomcat iriusrisk-startleft reporting-module iriusrisk-postgres; do
				sg docker -c "docker rm -f $svc 2>/dev/null || true"
			done
		fi

		# Dynamically write systemd unit file
		SERVICE_NAME="iriusrisk-docker.service"

		cat <<EOF | sudo tee /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=IriusRisk Docker Compose Stack
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=$CONTAINER_DIR
Environment=DOCKER_CONFIG=/etc/docker
Environment=COMPOSE_INTERACTIVE_NO_CLI=1
ExecStartPre=/usr/bin/sg docker -c "$DOCKER_COMPOSE_PATH $COMPOSE_OVERRIDE pull --quiet"
ExecStart=/usr/bin/sg docker -c "$DOCKER_COMPOSE_PATH $COMPOSE_OVERRIDE up -d"
ExecStop=/usr/bin/sg docker -c "$DOCKER_COMPOSE_PATH $COMPOSE_OVERRIDE down"

[Install]
WantedBy=multi-user.target
EOF

		# Ensure docker login works for service
		sudo mkdir -p /etc/docker
		sudo cp ~/.docker/config.json /etc/docker/config.json
		sudo chmod 600 /etc/docker/config.json
		sudo chown root:root /etc/docker/config.json

		# Start service
		sudo systemctl daemon-reload
		sudo systemctl enable $SERVICE_NAME
		sudo systemctl restart $SERVICE_NAME
		;;
	podman)
		echo
		echo "Deploying with Podman Compose (rootless)..."
		cd "$CONTAINER_DIR"

		# Build override flags once
		COMPOSE_OVERRIDE=$(build_compose_override "$ENABLE_SAML_ONCLICK" "$USE_INTERNAL_PG")

		# Decide compose up/ps commands (rootless, without sudo)
		UP_CMD="podman-compose $COMPOSE_OVERRIDE up -d"
		PS_CMD="podman-compose $COMPOSE_OVERRIDE ps -q"
		DOWN_CMD="podman-compose $COMPOSE_OVERRIDE down --remove-orphans"

		# --- Clean up any existing stack for this project (rootless) ---
		if [ "$($PS_CMD 2>/dev/null)" ]; then
			echo "Cleaning up existing containers for this project..."
			# Stop compose and make sure nothing lingers
			$DOWN_CMD || true
			stop_disable_user_units_for_project "$CONTAINER_ENGINE"
			teardown_rootless_project "$CONTAINER_ENGINE"
		fi

		# --- Image tweaks that used to run with sudo ---
		# You can still run root inside the container in rootless mode, so commits are fine.
		# (No host setcap calls here; we only modify the container image itself if needed.)
		echo "Preparing custom images (rootless)..."
		podman rm -f temp-nginx temp-tomcat 2>/dev/null || true

		# NGINX image: ensure it can bind <1024 inside the container.
		# NOTE: Binding privileged ports on the HOST in rootless requires either:
		#   - sysctl net.ipv4.ip_unprivileged_port_start=80  (your PoC), or
		#   - using 8080/8443 on the host and fronting with a host-level redirect/proxy.
		podman run --name temp-nginx --user root --entrypoint /bin/sh docker.io/continuumsecurity/iriusrisk-prod:nginx \
			-c "set -eu; \
                if [ -f /etc/alpine-release ]; then apk add --no-cache libcap; else \
                    (apt-get update && apt-get install -y --no-install-recommends libcap2-bin) || true; fi; \
                command -v setcap >/dev/null 2>&1 && setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx || true; \
                sleep 1"

		podman commit \
			--change='USER nginx' \
			--change='ENTRYPOINT ["nginx", "-g", "daemon off;"]' \
			temp-nginx \
			localhost/nginx-rhel

		podman rm -f temp-nginx || true
		echo "Custom Nginx image created as localhost/nginx-rhel"

		# TOMCAT wrapper to append decrypted secrets
		podman run \
			--name temp-tomcat \
			--user root \
			--entrypoint /bin/sh \
			docker.io/continuumsecurity/iriusrisk-prod:tomcat-4 \
			-c '\
            set -eu; \
            if [ -f /etc/alpine-release ]; then \
                apk add --no-cache gnupg; \
            else \
                apt-get update && \
                apt-get install -y --no-install-recommends gnupg && \
                rm -rf /var/lib/apt/lists/*; \
            fi; \
            cat <<'"'EOF'"' > /usr/local/bin/expand-secrets.sh
#!/usr/bin/env sh
set -eu

# Helper: decrypt into a shell var if both files exist
#   usage: export_from_secret VAR_NAME /run/secrets/<cipher> /run/secrets/<privkey>
export_from_secret() {
  var_name="$1"; cipher="$2"; priv="$3"
  if [ -r "$cipher" ] && [ -r "$priv" ]; then
    gpg --batch --import "$priv" >/dev/null 2>&1 || true
    value="$(gpg --batch --yes --decrypt "$cipher" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      # Export into environment for downstream process
      # shellcheck disable=SC2163
      export "$var_name=$value"
    fi
  fi
}

# DB password → append to IRIUS_DB_URL
if [ -r /run/secrets/db_pwd ] && [ -r /run/secrets/db_privkey ]; then
  gpg --batch --import /run/secrets/db_privkey >/dev/null 2>&1 || true
  if dec="$(gpg --batch --yes --decrypt /run/secrets/db_pwd 2>/dev/null || true)"; then
    if [ -n "$dec" ]; then
      export IRIUS_DB_URL="${IRIUS_DB_URL}&password=${dec}"
    fi
  fi
fi

# SAML keystore passwords (only if provided as secrets)
export_from_secret KEYSTORE_PASSWORD   /run/secrets/keystore_pwd   /run/secrets/keystore_privkey
export_from_secret KEY_ALIAS_PASSWORD  /run/secrets/key_alias_pwd  /run/secrets/key_alias_privkey

# Hand off to the real entrypoint
exec /entrypoint/dynamic-entrypoint.sh "$@"
EOF
            chmod +x /usr/local/bin/expand-secrets.sh; \
  '

		podman commit \
			--change='USER tomcat' \
			--change='ENTRYPOINT ["/usr/local/bin/expand-secrets.sh"]' \
			temp-tomcat \
			localhost/tomcat-rhel

		podman rm -f temp-tomcat || true
		echo "Custom Tomcat created as localhost/tomcat-rhel"

		# --- Bring up containers (rootless) ---
		eval "$UP_CMD"

		# Discover compose project label
		PROJECT_LABEL="$(podman ps -a --format '{{ index .Labels "io.podman.compose.project" }}' | head -n1)"
		if [[ -z $PROJECT_LABEL ]]; then
			PROJECT_LABEL="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"
		fi

		# Collect ALL containers in the project (running or not)
		mapfile -t containers < <(
			podman ps -a \
				--filter "label=io.podman.compose.project=${PROJECT_LABEL}" \
				--format "{{.Names}}"
		)

		# Bail out only if literally no containers exist for the project
		if [[ ${#containers[@]} -eq 0 ]]; then
			echo "No containers found for project '${PROJECT_LABEL}'."
			echo "Tip: check 'podman-compose $COMPOSE_OVERRIDE ps -a' output."
			exit 0
		fi

		echo "Generating user systemd unit files..."
		UNIT_DIR="$HOME/.config/systemd/user"
		mkdir -p "$UNIT_DIR"
		generated_any=0
		for cname in "${containers[@]}"; do
			podman generate systemd --files --name "$cname" \
				2> >(grep -v "DEPRECATED command" >&2)
			[[ -f "container-$cname.service" ]] && mv "container-$cname.service" "$UNIT_DIR"/ && generated_any=1
		done
		[[ $generated_any -eq 0 ]] && echo "No unit files generated; check project label: ${PROJECT_LABEL}"

		# Harden generated user units for rootless Podman/runtime dir
		for cname in "${containers[@]}"; do
			svc="$UNIT_DIR/container-$cname.service"
			[[ -f $svc ]] || continue
			grep -q '^Environment=XDG_RUNTIME_DIR=%t' "$svc" ||
				sed -i '/^\[Service\]/a Environment=XDG_RUNTIME_DIR=%t' "$svc"
			grep -q '^Environment=TMPDIR=%t' "$svc" ||
				sed -i '/^\[Service\]/a Environment=TMPDIR=%t' "$svc"
			grep -q '^ExecStartPre=.*/mkdir -p %t/containers %t/libpod/tmp' "$svc" ||
				sed -i '/^\[Service\]/a ExecStartPre=/usr/bin/mkdir -p %t/containers %t/libpod/tmp' "$svc"
		done

		# Ensure nginx waits for tomcat (order + requirement across reboots)
		svc="$UNIT_DIR/container-iriusrisk-nginx.service"
		if [[ -f $svc ]]; then
			grep -q '^After=container-iriusrisk-tomcat.service' "$svc" ||
				sed -i '/^\[Unit\]/a After=container-iriusrisk-tomcat.service' "$svc"
			grep -q '^Requires=container-iriusrisk-tomcat.service' "$svc" ||
				sed -i '/^\[Unit\]/a Requires=container-iriusrisk-tomcat.service' "$svc"
		fi

		# Ensure Podman uses per-boot runtime dir in interactive shells
		if ! grep -q 'XDG_RUNTIME_DIR=.*run/user' ~/.bash_profile 2>/dev/null; then
			cat <<'EOF' >>~/.bash_profile
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export TMPDIR="${TMPDIR:-$XDG_RUNTIME_DIR}"
EOF
		fi

		# Make sure we can talk to user systemd in this run (no start now; just enable)
		if ! ensure_user_systemd_ready "$(id -un)"; then
			echo "WARNING: user systemd not reachable; units placed in $UNIT_DIR."
			echo "They will start on next login/reboot (linger enabled). To enable manually later:"
			echo "  ensure_user_systemd_ready \"$(id -un)\" && systemctl --user enable container-*.service"
		else
			systemctl --user daemon-reload

			for cname in "${containers[@]}"; do
				svc="container-$cname.service"
				if [[ -f "$UNIT_DIR/$svc" ]]; then
					systemctl --user enable "$svc" || echo "WARNING: failed to enable $svc"
				else
					echo "WARNING: unit file missing: $UNIT_DIR/$svc"
				fi
			done
		fi
		echo "Podman rootless systemd user services created and enabled."
		;;
	*)
		echo "Unknown engine '$CONTAINER_ENGINE'. Cannot deploy." >&2
		exit 1
		;;
esac

echo
echo "IriusRisk deployment started."
