#!/usr/bin/env bash
source functions.sh
set -e

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk One-Click Bootstrap Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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
if [[ "$ENABLE_SAML_ONCLICK" == "n" ]]; then
    PRE_WARNS=$(
        printf '%s\n' "$PRE_WARNS" \
        | grep -Ev "KEYSTORE_PASSWORD must be set|KEY_ALIAS_PASSWORD must be set" \
        || true
    )
fi

# —————————————————————————————————————————————————————————————
# 3. Run preflight and capture output
# —————————————————————————————————————————————————————————————
SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh" > preflight_output.txt 2>&1 || true
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

if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
    # Ensure Docker is installed
    if ! command -v docker &>/dev/null; then
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
elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
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

prompt_postgres_option

if [[ "$POSTGRES_SETUP_OPTION" == "1" ]]; then
    install_and_configure_postgres "container"
    export USE_INTERNAL_PG="y"
    export DB_PASS
elif [[ "$POSTGRES_SETUP_OPTION" == "2" ]]; then
    export USE_INTERNAL_PG="n"
elif [[ "$POSTGRES_SETUP_OPTION" == "3" ]]; then
    install_and_configure_postgres "host"
    export USE_INTERNAL_PG="n"
    export DB_IP DB_PASS
fi

# —————————————————————————————————————————————————————————————
# 5. Run setup-wizard
# —————————————————————————————————————————————————————————————
echo
echo "Launching the setup wizard..."
set +e
if [[ "$POSTGRES_SETUP_OPTION" == "3" ]]; then
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
if [[ "$DEPLOY_OK" == "n" ]]; then
    echo "Aborted by user."
    exit 0
fi

# ---- LOGIN TO CONTAINER REGISTRY ----
container_registry_login

# —————————————————————————————————————————————————————————————
# 8. Deploy based on selected engine
# —————————————————————————————————————————————————————————————
CONTAINER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../container-compose && pwd)"

case "$CONTAINER_ENGINE" in
    docker)
        echo
        echo "Deploying with Docker Compose..."

        DOCKER_COMPOSE_PATH="$(which docker-compose 2>/dev/null || true)"
        if [[ -z "$DOCKER_COMPOSE_PATH" ]]; then
            # If not found, try docker's builtin compose (for Docker 20.10+)
            if docker compose version &>/dev/null; then
                DOCKER_COMPOSE_PATH="docker compose"
            else
                echo "docker-compose not found!"
                exit 1
            fi
        fi
        cd "$CONTAINER_DIR"

        if [[ -z "$DOCKER_USER" ]]; then
            DOCKER_USER="$USER"
        fi

        # Build commands
        COMPOSE_OVERRIDE=$(build_compose_override "$ENABLE_SAML_ONCLICK" "$USE_INTERNAL_PG")
        CLEAN_CMD="docker-compose $COMPOSE_OVERRIDE down --remove-orphans"
        PS_CMD="docker-compose $COMPOSE_OVERRIDE ps -q"
        PS_OUTPUT=$(sg docker -c "cd $(pwd) && $PS_CMD")

        if [[ -n "$PS_OUTPUT" ]]; then
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
ExecStart=/usr/bin/sg docker -c "$DOCKER_COMPOSE_PATH $COMPOSE_OVERRIDE up -d"
ExecStop=/usr/bin/sg docker -c "$DOCKER_COMPOSE_PATH $COMPOSE_OVERRIDE down"

[Install]
WantedBy=multi-user.target
EOF

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
            stop_disable_user_units_for_project "container-compose"
            teardown_rootless_project "container-compose"
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

        # TOMCAT wrapper to append decrypted DB pwd (unchanged logic, but rootless-safe)
        podman run \
            --name temp-tomcat \
            --user root \
            --entrypoint /bin/sh \
            docker.io/continuumsecurity/iriusrisk-prod:tomcat-4 \
            -c "\
                set -eu; \
                if [ -f /etc/alpine-release ]; then \
                    apk add --no-cache gnupg; \
                else \
                    apt-get update && \
                    apt-get install -y --no-install-recommends gnupg && \
                    rm -rf /var/lib/apt/lists/*; \
                fi; \
                cat << 'EOF' > /usr/local/bin/expand-db-url.sh
#!/usr/bin/env sh
set -eu
gpg --batch --import /run/secrets/db_privkey
DECRYPTED=\$(gpg --batch --yes --decrypt /run/secrets/db_pwd)
export IRIUS_DB_URL=\"\$IRIUS_DB_URL&password=\$DECRYPTED\"
exec /entrypoint/dynamic-entrypoint.sh \"\$@\"
EOF
                chmod +x /usr/local/bin/expand-db-url.sh; \
            "

        podman commit \
            --change='USER tomcat' \
            --change='ENTRYPOINT ["/usr/local/bin/expand-db-url.sh"]' \
            temp-tomcat \
            localhost/tomcat-rhel

        podman rm -f temp-tomcat || true
        echo "Custom Tomcat created as localhost/tomcat-rhel"

        # --- Bring up containers (rootless) ---
        eval "$UP_CMD"

        # List running container names for this project (rootless)
        mapfile -t containers < <(
            podman ps --filter "label=io.podman.compose.project=container-compose" \
                      --format "{{.Names}}"
        )

        # Generate user systemd units per container
        echo "Generating user systemd unit files..."
        UNIT_DIR="$HOME/.config/systemd/user"
        mkdir -p "$UNIT_DIR"
        for cname in "${containers[@]}"; do
            podman generate systemd --files --new --name "$cname" \
                2> >(grep -v "DEPRECATED command" >&2)
            [[ -f "container-$cname.service" ]] && mv "container-$cname.service" "$UNIT_DIR"/
        done

        # Add dependency: nginx after tomcat (edit user unit if present)
        if [[ -f "$UNIT_DIR/container-iriusrisk-nginx.service" ]]; then
            if ! grep -q '^After=container-iriusrisk-tomcat.service' "$UNIT_DIR/container-iriusrisk-nginx.service"; then
                sed -i '/^\[Unit\]/a After=container-iriusrisk-tomcat.service' "$UNIT_DIR/container-iriusrisk-nginx.service"
            fi
        fi

        # Ensure user systemd is up, then enable
        if ! ensure_user_systemd_ready "$(id -un)"; then
            echo "WARNING: Could not talk to user systemd right now."
            echo "Units are at $UNIT_DIR. Enable later with:"
            echo "  systemctl --user daemon-reload"
            for cname in "${containers[@]}"; do
                echo "  systemctl --user enable --now container-$cname.service"
            done
        else
            systemctl --user daemon-reload
            for cname in "${containers[@]}"; do
                svc="container-$cname.service"
                [[ -f "$UNIT_DIR/$svc" ]] && systemctl --user enable "$svc" --now || \
                echo "Skipping enable for $cname (no unit file)."
            done
        fi

        echo "Podman rootless systemd user services created and enabled"
        ;;

    *)
        echo "Unknown engine '$CONTAINER_ENGINE'. Cannot deploy." >&2
        exit 1
        ;;
esac

echo
echo "IriusRisk deployment started."
