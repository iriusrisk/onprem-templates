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
if echo "$PRE_ERRS" | grep -q "psql' client is not installed"; then
    install_psql
fi
if ! command -v jq &>/dev/null; then
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
    if ! command -v podman &>/dev/null; then
        install_podman
    fi
    if ! command -v podman-compose &>/dev/null; then
        install_podman
    fi
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
        echo "Deploying with Podman Compose..."
        cd "$CONTAINER_DIR"

        # Build commands
        COMPOSE_OVERRIDE=$(build_compose_override "$ENABLE_SAML_ONCLICK" "$USE_INTERNAL_PG")
        CLEAN_CMD="sudo podman-compose $COMPOSE_OVERRIDE down --remove-orphans"
        UP_CMD="sudo podman-compose $COMPOSE_OVERRIDE up -d"
        PS_CMD="sudo podman-compose $COMPOSE_OVERRIDE ps -q"

        # Clean up any existing containers and pod
        if [ "$($PS_CMD)" ]; then
            echo "Cleaning up existing containers for this project..."
            eval "$CLEAN_CMD"
            # Force‐remove any leftover containers by their container_name
            for svc in iriusrisk-nginx iriusrisk-tomcat iriusrisk-startleft reporting-module iriusrisk-postgres; do
                sudo podman rm -f "$svc" 2>/dev/null || true
            done
        fi

        # Run the temporary container to perform modifications (nginx capabilities fix)
        sudo podman run --name temp-nginx --user root --entrypoint /bin/sh docker.io/continuumsecurity/iriusrisk-prod:nginx \
            -c "apk add libcap && setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx && sleep 1"

        # Commit the changes to a new image
        sudo podman commit \
            --change='USER nginx' \
            --change='ENTRYPOINT ["nginx", "-g", "daemon off;"]' \
            temp-nginx \
            localhost/nginx-rhel

        sudo podman rm temp-nginx
        echo "Custom Nginx image created as localhost/nginx-rhel"

        # Bring up containers
        eval "$UP_CMD"

        containers=(iriusrisk-nginx iriusrisk-tomcat iriusrisk-startleft reporting-module)

        # Generate systemd unit files
        for cname in "${containers[@]}"; do
            sudo podman generate systemd --name "$cname" --files --restart-policy=always
        done

        # Move, relabel, and modify service files as needed
        for cname in "${containers[@]}"; do
            svc="container-$cname.service"

            # If nginx, add dependency on tomcat before moving
            if [[ "$cname" == "iriusrisk-nginx" ]]; then
                # Insert After= dependency if not already present
                if ! grep -q '^After=container-iriusrisk-tomcat.service' "$svc"; then
                    sudo sed -i '/^\[Unit\]/a After=container-iriusrisk-tomcat.service' "$svc"
                fi
            fi

            # Move and relabel
            sudo mv "$svc" /etc/systemd/system/
            sudo /sbin/restorecon -v /etc/systemd/system/"$svc"
        done

        # Now reload systemd units
        sudo systemctl daemon-reload

        # Enable and start services
        for cname in "${containers[@]}"; do
            svc="container-$cname.service"
            sudo systemctl enable "$svc"
            sudo systemctl restart "$svc"
        done
        echo "Podman systemd services created and enabled"
        ;;
    *)
        echo "Unknown engine '$CONTAINER_ENGINE'. Cannot deploy." >&2
        exit 1
        ;;
esac

echo
echo "IriusRisk deployment started."
