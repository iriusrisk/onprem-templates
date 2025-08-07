#!/usr/bin/env bash

# —————————————————————————————————————————————————————————————
# Prompt functions
# —————————————————————————————————————————————————————————————
function prompt_yn() {
    # $1 = prompt
    while true; do
        read -rp "$1 (y/n): " yn
        yn=${yn,,}
        case "$yn" in
            y|yes) echo "y"; return 0 ;;
            n|no)  echo "n"; return 0 ;;
            *)
                echo "Invalid input: '$yn'. Please enter 'y' or 'n'." >&2
                ;;
        esac
    done
}

function prompt_engine() {
    # Helper to lowercase a string (Bash 4+)
    to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

    # If already set and valid, use it
    if [[ "$CONTAINER_ENGINE" =~ ^(docker|podman)$ ]]; then
        CONTAINER_ENGINE="$CONTAINER_ENGINE"
        echo "Using container engine: $CONTAINER_ENGINE"
    else
        if is_rhel_like; then
            echo "Only Podman is supported on your system. Using Podman."
            CONTAINER_ENGINE="podman"
        else
            echo "Only Docker is supported on your system. Using Docker."
            CONTAINER_ENGINE="docker"
        fi
    fi
    export CONTAINER_ENGINE
}

function prompt_postgres_option() {
    echo "How do you want to configure PostgreSQL?"
    echo "  1) Internal container Postgres"
    echo "  2) Existing Postgres (provide connection details)"
    echo "  3) Install and configure Postgres on this machine"
    while true; do
        read -rp "Enter 1, 2, or 3: " pg_option
        case "$pg_option" in
            1|2|3) break ;;
            *) echo "Invalid input: '$pg_option'. Please enter 1, 2, or 3." ;;
        esac
    done
    POSTGRES_SETUP_OPTION="$pg_option"
}

function prompt_registry_password() {
    read -srp "Enter the container registry password for user 'iriusrisk': " REGISTRY_PASS
    echo
}

function prompt_for_docker_user() {
    local uname
    read -rp "Enter the username to add to the docker group (default: $USER): " uname
    if [[ -z "$uname" ]]; then
        uname="$USER"
    fi
    echo "$uname"
}

function prompt_nonempty() {
    # $1 = prompt
    local value
    while true; do
        read -rp "$1: " value
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        else
            echo "Invalid input: value cannot be empty. Please enter a value." >&2
        fi
    done
}

# —————————————————————————————————————————————————————————————
# Dependency install functions
# —————————————————————————————————————————————————————————————
function install_docker() {
    echo "Installing Docker..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y docker.io docker-compose
        sudo systemctl start docker
        sudo systemctl enable docker
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y docker docker-compose
        sudo systemctl start docker
        sudo systemctl enable docker
    else
        echo "Please install Docker and Docker Compose manually." >&2
        exit 1
    fi
}

function install_podman() {
    echo "Installing Podman and podman-compose..."
    sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
    sudo dnf install -y container-tools podman-compose python3-dotenv
}

function install_git() {
    echo "Installing git..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y git
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git
    else
        echo "Please install git manually." >&2
        exit 1
    fi
}

function install_java() {
    echo "Installing Java 17..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y openjdk-17-jre-headless
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y java-17-openjdk
    else
        echo "Please install Java 17 manually." >&2
        exit 1
    fi
}

function install_psql() {
    echo "Installing PostgreSQL client..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y postgresql-client
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y postgresql
    else
        echo "Please install PostgreSQL client manually." >&2
        exit 1
    fi
}

function install_and_configure_postgres() {
    local mode="$1"      # "container" or "host"
    PG_USER="iriusprod"
    PG_DB="iriusprod"
    PG_SUPERUSER="postgres"
    POSTGRES_FILE="../container-compose/container-compose.postgres.yml"
    CONTAINER_PATH="../container-compose"

    # Generate a password for the DB user
    DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)

    if [[ "$mode" == "container" ]]; then
        # --- Containerized Postgres ---
        echo "Starting internal Postgres container..."
        if [[ $CONTAINER_ENGINE == "docker" ]]; then
            COMPOSE_TOOL="docker-compose"
        elif [[ $CONTAINER_ENGINE == "podman" ]]; then
            COMPOSE_TOOL="podman-compose"
        fi

        # Replace or insert POSTGRES_PASSWORD in override:
        sed -i "s|POSTGRES_PASSWORD:.*|POSTGRES_PASSWORD: $DB_PASS|g" "$POSTGRES_FILE"
        echo "Updated $POSTGRES_FILE"
        cd $CONTAINER_PATH

        # Teardown & cleanup Postgres container + data
            if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
                sg docker -c "$COMPOSE_TOOL -f $(basename "$POSTGRES_FILE") down --remove-orphans"
                sg docker -c '
                ids=$(docker ps -aq --filter name=iriusrisk-postgres)
                if [ -n "$ids" ]; then
                    echo "Removing containers: $ids"
                    docker rm -f $ids
                fi
                '
                sudo rm -rf ./postgres/data
                sg docker -c "$COMPOSE_TOOL -f $(basename "$POSTGRES_FILE") up -d"
            elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
                sudo $COMPOSE_TOOL -f $(basename "$POSTGRES_FILE") down --remove-orphans
                sudo podman ps -aq --filter name=iriusrisk-postgres | xargs -r podman rm -f
                sudo rm -rf ./postgres/data
                sudo $COMPOSE_TOOL -f $(basename "$POSTGRES_FILE") up -d
            fi

        # Wait for the container to be ready
        echo "Waiting for Postgres container to be ready..."
        timeout=60
        until $CONTAINER_ENGINE exec iriusrisk-postgres pg_isready -U postgres; do
            sleep 2
            ((timeout--))
            if [ $timeout -le 0 ]; then
                echo "ERROR: Postgres container did not become ready in time."
                $CONTAINER_ENGINE logs iriusrisk-postgres
            exit 1
        fi
        done
        echo "Postgres is ready!"

        # Drop DB and user if exist, then create them
        if [[ $CONTAINER_ENGINE == "docker" ]]; then
            sg docker -c "docker exec iriusrisk-postgres psql -U $PG_SUPERUSER -c \"CREATE USER $PG_USER WITH CREATEDB PASSWORD '$DB_PASS';\""
            sg docker -c "docker exec iriusrisk-postgres psql -U $PG_SUPERUSER -c \"CREATE DATABASE $PG_DB WITH OWNER $PG_USER;\""
        elif [[ $CONTAINER_ENGINE == "podman" ]]; then
            sudo podman exec iriusrisk-postgres psql -U $PG_SUPERUSER -c "CREATE USER $PG_USER WITH CREATEDB PASSWORD '$DB_PASS';"
            sudo podman exec iriusrisk-postgres psql -U $PG_SUPERUSER -c "CREATE DATABASE $PG_DB WITH OWNER $PG_USER;"
        fi

        DB_IP="postgres" # Service name in Compose network
        export DB_IP DB_PASS

        echo "Internal PostgreSQL (container) is ready:"
        echo "  Host: $DB_IP"
        echo "  User: $PG_USER"
        echo "  Password: $DB_PASS"
        echo "  Database: $PG_DB"

        cd ../scripts
    elif [[ "$mode" == "host" ]]; then
        # --- Host/OS Postgres (non-container) ---
        # Terminate connections to the DB, if any
        echo "Terminating any existing connections to $PG_DB..."
        sudo -u $PG_SUPERUSER psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_DB';" 2>/dev/null || true

        # Drop the database if it exists
        echo "Dropping database $PG_DB if it exists..."
        sudo -u $PG_SUPERUSER psql -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB';" 2>/dev/null | grep -q 1 \
        && sudo -u $PG_SUPERUSER psql -d postgres -c "DROP DATABASE \"$PG_DB\";" 2>/dev/null \
        || echo "Database $PG_DB does not exist, skipping drop."

        # Drop the user if it exists
        sudo -u $PG_SUPERUSER psql -d postgres -tc "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER';" 2>/dev/null | grep -q 1 \
        && sudo -u $PG_SUPERUSER psql -d postgres -c "DROP ROLE \"$PG_USER\";" 2>/dev/null \
        || echo "Role $PG_USER does not exist, skipping drop."

        if [[ $CONTAINER_ENGINE == "docker" ]]; then
            sudo apt-get update
            sudo apt-get install dirmngr ca-certificates software-properties-common apt-transport-https lsb-release curl -y
            # Add PGDG repo
            curl -fSsL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /usr/share/keyrings/postgresql.gpg > /dev/null
            echo deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main | sudo tee /etc/apt/sources.list.d/postgresql.list
            sudo apt update
            sudo apt-get install -y postgresql-15 postgresql-client-15 postgresql-contrib
            PG_CONF="/etc/postgresql/15/main/postgresql.conf"
            PG_HBA="/etc/postgresql/15/main/pg_hba.conf"
            if [[ ! -f "$PG_CONF" ]]; then
                echo "ERROR: Postgres 15 config not found at $PG_CONF! Install may have failed." >&2
                exit 1
            fi
            sudo systemctl enable postgresql
            sudo systemctl start postgresql
        elif [[ $CONTAINER_ENGINE == "podman" ]]; then
            sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
            sudo dnf -qy module disable postgresql
            sudo dnf install -y postgresql15-server
            PG_CONF="/var/lib/pgsql/15/data/postgresql.conf"
            PG_HBA="/var/lib/pgsql/15/data/pg_hba.conf"
            # Only run initdb if data directory is empty
            if ! sudo test -f "$PG_CONF"; then
                echo "Initializing PostgreSQL database (initdb)..."
                sudo /usr/pgsql-15/bin/postgresql-15-setup initdb
            else
                echo "PostgreSQL already initialized at $PG_CONF"
            fi
            sudo systemctl enable postgresql-15
            sudo systemctl start postgresql-15
        else
            echo "ERROR: Unsupported OS for PostgreSQL install." >&2
            exit 1
        fi

        sudo cp "$PG_CONF" "$PG_CONF.bak"
        sudo sed -i "s/^#listen_addresses = .*/listen_addresses = '*'/" "$PG_CONF"

        sudo cp "$PG_HBA" "$PG_HBA.bak"
        sudo grep -q "host all all 0.0.0.0/0 scram-sha-256" "$PG_HBA" || \
            echo "host all all 0.0.0.0/0 scram-sha-256" | sudo tee -a "$PG_HBA"

        if command -v apt-get &>/dev/null; then
            sudo systemctl restart postgresql
        else
            sudo systemctl restart postgresql-15
        fi

        (cd /tmp && sudo -u postgres psql -c "CREATE USER $PG_USER WITH CREATEDB PASSWORD '${DB_PASS}';")
        (cd /tmp && sudo -u postgres psql -c "CREATE DATABASE $PG_DB WITH OWNER $PG_USER;")

        DB_IP=$(hostname -I | awk '{print $1}')
        export DB_IP DB_PASS
        echo "Local PostgreSQL is ready:"
        echo "  IP: $DB_IP"
        echo "  User: $PG_USER"
        echo "  Password: $DB_PASS"
        echo "  Database: $PG_DB"
    fi
}

function install_jq() {
    echo "Installing jq (for JSON parsing)..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y jq
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y jq
    else
        echo "Please install jq manually." >&2
        exit 1
    fi
}

# —————————————————————————————————————————————————————————————
# Helper functions
# —————————————————————————————————————————————————————————————

function is_rhel_like() {
    source /etc/os-release
    [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID_LIKE" == *fedora* ]] || [[ "$ID" == "fedora" ]] || [[ "$ID" == "centos" ]] || [[ "$ID" == "rhel" ]] || [[ "$ID" == "rocky" ]] || [[ "$ID" == "almalinux" ]]
}


function ensure_certificates() {
    CERT_DIR="${CERT_DIR:-../container-compose}"
    CERT_FILE="$CERT_DIR/cert.pem"
    KEY_FILE="$CERT_DIR/key.pem"
    EC_KEY_FILE="$CERT_DIR/ec_private.pem"
    local hostname="${1:-$(hostname -f)}"

    echo "🔑 Generating RSA SSL certificate..."
    openssl req -newkey rsa:2048 -nodes -keyout "$KEY_FILE" -x509 -days 365 -out "$CERT_FILE" -subj "/CN=$hostname"
    chmod 644 "$CERT_FILE" "$KEY_FILE"

    echo "🔑 Generating EC private key..."
    openssl ecparam -genkey -name prime256v1 -noout -out "$EC_KEY_FILE"
    chmod 644 "$EC_KEY_FILE"
    
    echo "Certificates generated at $CERT_DIR"
}

function is_logged_in_as_iriusrisk() {
    local config=""
    local auth_key=""
    local auth_base64=""
    local auth_user=""

    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
        config="$HOME/.docker/config.json"
        auth_key="https://index.docker.io/v1/"
    elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
        # For root, Podman stores auth at /run/containers/0/auth.json
        if sudo test -f /run/containers/0/auth.json; then
            config="/run/containers/0/auth.json"
            auth_key="docker.io"
        else
            # Non-root Podman: uses ~/.docker/config.json
            config="$HOME/.docker/config.json"
            auth_key="https://index.docker.io/v1/"
        fi
    else
        echo "Unknown container engine: $CONTAINER_ENGINE" >&2
        return 2
    fi

    if [[ ! -f "$config" ]]; then
        return 1
    fi

    # Use sudo if needed
    if [[ "$config" == "/run/containers/0/auth.json" ]]; then
        auth_base64=$(sudo jq -r ".auths[\"$auth_key\"].auth // empty" "$config" 2>/dev/null)
    else
        auth_base64=$(jq -r ".auths[\"$auth_key\"].auth // empty" "$config" 2>/dev/null)
    fi

    if [[ -z "$auth_base64" ]]; then
        return 1
    fi

    # Decode base64 and extract username
    auth_user=$(echo "$auth_base64" | base64 -d 2>/dev/null | cut -d: -f1)
    [[ "$auth_user" == "iriusrisk" ]]
}

function container_registry_login() {
    local registry_url="${1:-}"

    if is_logged_in_as_iriusrisk $CONTAINER_ENGINE; then
        echo "Already logged in to Docker Hub as 'iriusrisk', skipping login prompt."
        return 0
    fi

    prompt_registry_password

    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
        echo "$REGISTRY_PASS" | docker login -u iriusrisk --password-stdin
    elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
        echo "$REGISTRY_PASS" | sudo podman login -u iriusrisk docker.io --password-stdin
    else
        echo "Unknown container engine: $CONTAINER_ENGINE" >&2
        return 1
    fi
}

function trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

function check_command() {
    if ! command -v "$1" &>/dev/null; then
        msg="ERROR: '$1' is not installed."
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    return 0
}

function check_version() {
    local cmd=$1
    local required=$2
    local actual=$($cmd --version | grep -oE "[0-9]+(\.[0-9]+)+" | head -1)
    if [[ -z "$actual" ]]; then
        msg="ERROR: Could not detect version for $cmd"
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    if [[ "$(printf '%s\n' "$required" "$actual" | sort -V | head -n1)" != "$required" ]]; then
        msg="ERROR: $cmd version $required+ required, found $actual"
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    echo "$cmd version $actual OK"
    return 0
}

function check_file() {
    if [[ ! -f "$1" ]]; then
        msg="ERROR: Required file '$1' not found."
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    echo "Found file: $1"
    return 0
}

function build_compose_override() {
    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
        OVERRIDE_FILE="container-compose.docker.yml"
    elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
        OVERRIDE_FILE="container-compose.podman.yml"
    fi

    local enable_saml="$1"
    local use_internal_pg="$2"
    local base_files="-f container-compose.yml -f $OVERRIDE_FILE -f container-compose.nginx.yml"
    local files="$base_files"

    if [[ "${enable_saml,,}" == "y" ]]; then
        files="$files -f container-compose.saml.yml"
    fi
    if [[ "${use_internal_pg,,}" == "y" ]]; then
        files="$files -f container-compose.postgres.yml"
    fi

    echo "$files"
}
