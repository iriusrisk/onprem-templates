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
        ENGINE="$CONTAINER_ENGINE"
        echo "Using container engine: $ENGINE"
    else
        if is_rhel_like; then
            # Loop until a valid engine is chosen
            while true; do
                read -rp "Which container engine do you want to use for deployment? (docker/podman): " engine
                engine=$(to_lower "$engine")
                case "$engine" in
                    docker|podman)
                        ENGINE="$engine"
                        echo "→ Selected container engine: $ENGINE"
                        break
                        ;;
                    *)
                        echo "Invalid input: '$engine'. Please enter 'docker' or 'podman'." >&2
                        ;;
                esac
            done
        else
            echo "Only Docker is supported on your system. Using Docker."
            ENGINE="docker"
        fi
    fi
    export CONTAINER_ENGINE="$ENGINE"
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

function install_and_configure_postgres() {
    PG_USER="iriusprod"
    PG_DB="iriusprod"
    PG_SUPERUSER="postgres"

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

    if command -v apt-get &>/dev/null; then
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
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
        sudo dnf -qy module disable postgresql
        sudo dnf install -y postgresql15-server
        PG_CONF="/var/lib/pgsql/15/data/postgresql.conf"
        PG_HBA="/var/lib/pgsql/15/data/pg_hba.conf"
        # Only run initdb if data directory is empty
        if [ ! -f "$PG_CONF" ]; then
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

    DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    (cd /tmp && sudo -u postgres psql -c "CREATE USER iriusprod WITH CREATEDB PASSWORD '${DB_PASS}';")
    (cd /tmp && sudo -u postgres psql -c "CREATE DATABASE iriusprod WITH OWNER iriusprod;")

    DB_IP=$(hostname -I | awk '{print $1}')
    export DB_IP DB_PASS
    echo "Local PostgreSQL is ready:"
    echo "  IP: $DB_IP"
    echo "  User: iriusprod"
    echo "  Password: $DB_PASS"
    echo "  Database: iriusprod"
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
    CERT_DIR="${CERT_DIR:-../$CONTAINER_ENGINE}"
    CERT_FILE="$CERT_DIR/cert.pem"
    KEY_FILE="$CERT_DIR/key.pem"
    EC_KEY_FILE="$CERT_DIR/ec_private.pem"

    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        echo "🔑 Generating RSA SSL certificate..."
        openssl req -newkey rsa:2048 -nodes -keyout "$KEY_FILE" -x509 -days 365 -out "$CERT_FILE" -subj "/CN=$(hostname -f)"
        chmod 644 "$CERT_FILE" "$KEY_FILE"
    else
        echo "🔑 SSL certificates already exist."
    fi

    if [[ ! -f "$EC_KEY_FILE" ]]; then
        echo "🔑 Generating EC private key..."
        openssl ecparam -genkey -name prime256v1 -noout -out "$EC_KEY_FILE"
        chmod 644 "$EC_KEY_FILE"
    else
        echo "🔑 EC private key already exists."
    fi
}

function is_logged_in_as_iriusrisk() {
    local config="$HOME/.docker/config.json"
    if [[ ! -f "$config" ]]; then
        return 1
    fi
    local auth_user
    auth_user=$(jq -r '.auths["https://index.docker.io/v1/"].auth // empty' "$config" 2>/dev/null | base64 -d 2>/dev/null | cut -d: -f1)
    [[ "$auth_user" == "iriusrisk" ]]
}

function container_registry_login() {
    local engine="$1"
    local registry_url="${2:-}"

    if is_logged_in_as_iriusrisk; then
        echo "Already logged in to Docker Hub as 'iriusrisk', skipping login prompt."
        return 0
    fi

    prompt_registry_password

    if [[ "$engine" == "docker" ]]; then
        echo "$REGISTRY_PASS" | docker login -u iriusrisk --password-stdin
    elif [[ "$engine" == "podman" ]]; then
        echo "$REGISTRY_PASS" | podman login -u iriusrisk --password-stdin
    else
        echo "Unknown container engine: $engine" >&2
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