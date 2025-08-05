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
# 1. Pick your container engine and generate certificates
# —————————————————————————————————————————————————————————————
prompt_engine
ensure_certificates

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
    export USE_INTERNAL_PG="y"
elif [[ "$POSTGRES_SETUP_OPTION" == "2" ]]; then
    export USE_INTERNAL_PG="n"
elif [[ "$POSTGRES_SETUP_OPTION" == "3" ]]; then
    install_and_configure_postgres
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
container_registry_login "$CONTAINER_ENGINE"

# —————————————————————————————————————————————————————————————
# 8. Deploy based on selected engine
# —————————————————————————————————————————————————————————————
case "$CONTAINER_ENGINE" in
    docker)
        echo
        echo "Deploying with Docker Compose..."
        cd ../docker

        if [[ -z "$DOCKER_USER" ]]; then
            DOCKER_USER="$USER"
        fi

        # Compose override logic for SAML
        if [[ "${ENABLE_SAML_ONCLICK,,}" == "y" ]]; then
            COMPOSE_OVERRIDE="-f docker-compose.yml -f docker-compose.override.yml -f docker-compose.saml.yml"
        else
            COMPOSE_OVERRIDE="-f docker-compose.yml -f docker-compose.override.yml"
        fi

        CLEAN_CMD="docker-compose $COMPOSE_OVERRIDE down --volumes --remove-orphans"
        UP_CMD="docker-compose $COMPOSE_OVERRIDE up -d"
        PS_CMD="docker-compose $COMPOSE_OVERRIDE ps -q"
        PS_OUTPUT=$(sg docker -c "cd $(pwd) && $PS_CMD")

        if [[ -n "$PS_OUTPUT" ]]; then
            echo "Cleaning up existing containers for this project..."
            sg docker -c "cd $(pwd) && $CLEAN_CMD"
        fi

        sg docker -c "cd $(pwd) && $UP_CMD"
        ;;
    podman)
        echo
        echo "Deploying with Podman Compose..."
        cd ../podman

        # Compose override logic for SAML
        if [[ "${ENABLE_SAML_ONCLICK,,}" == "y" ]]; then
            COMPOSE_OVERRIDE="-f container-compose.yml -f container-compose.override.yml -f container-compose.saml.yml"
        else
            COMPOSE_OVERRIDE="-f container-compose.yml -f container-compose.override.yml"
        fi

        # Always use the known pod name from podman-compose
        POD_NAME="pod_podman"
        CLEAN_CMD="sudo podman-compose $COMPOSE_OVERRIDE down --volumes --remove-orphans"
        UP_CMD="sudo podman-compose $COMPOSE_OVERRIDE up -d"
        PS_CMD="sudo podman-compose $COMPOSE_OVERRIDE ps -q"

        if [ "$($PS_CMD)" ]; then
            echo "Cleaning up existing containers for this project..."
            eval "$CLEAN_CMD"
        fi

        # Run the temporary container to perform modifications (nginx capabilities fix)
        sudo podman run --name temp-nginx --user root --entrypoint /bin/sh docker.io/continuumsecurity/iriusrisk-prod:nginx -c "apk add libcap && setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx && sleep 1"

        # Commit the changes to a new image
        sudo podman commit \
            --change='USER nginx' \
            --change='ENTRYPOINT ["nginx", "-g", "daemon off;"]' \
            temp-nginx \
            localhost/nginx-rhel

        sudo podman rm temp-nginx
        echo "Custom Nginx image created as localhost/nginx-rhel"

        eval "$UP_CMD"

        echo "Creating Quadlet file to enable pod autostart..."
        sudo tee /etc/containers/systemd/${POD_NAME}.pod > /dev/null <<EOF
[Pod]
Name=${POD_NAME}
Restart=always
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable pod-${POD_NAME}.service
        sudo systemctl start pod-${POD_NAME}.service

        echo "Podman pod Quadlet systemd service created and enabled: pod-${POD_NAME}.service"
        ;;
esac

echo
echo "IriusRisk deployment started."
