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

function install_and_configure_postgres() {
    local mode="$1"      # "container" or "host"
    PG_USER="iriusprod"
    PG_DB="iriusprod"
    PG_SUPERUSER="postgres"
    local postgres_file="../container-compose/container-compose.postgres.yml"
    local container_path="../container-compose"

    # Generate a single password for both Postgres superuser and app user
    DB_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"

    if [[ "$mode" == "container" ]]; then
        echo "Starting internal Postgres container..."
        cd "$container_path"

        if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
            # -------- Docker path: keep existing plaintext env-in-compose flow --------
            local compose_tool="docker-compose"
            # Write the password into the compose file (as you do today)
            sed -i "s|POSTGRES_PASSWORD:.*|POSTGRES_PASSWORD: $DB_PASS|g" "$postgres_file"
            echo "Updated $postgres_file"
            # Teardown & clean data
            sg docker -c "$compose_tool -f $(basename "$postgres_file") down --remove-orphans"
            sg docker -c '
              ids=$(docker ps -aq --filter name=iriusrisk-postgres)
              if [ -n "$ids" ]; then docker rm -f $ids; fi
            '
            sudo rm -rf ./postgres/data
            # Bring up just Postgres
            sg docker -c "$compose_tool -f $(basename "$postgres_file") up -d postgres"

        elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
            local compose_tool="podman-compose"
            # Ensure a GPG key exists for encryption
            local gpg_email="db-secrets@iriusrisk.local"
            if ! gpg --list-keys "$gpg_email" >/dev/null 2>&1; then
                cat > /tmp/gpg_batch <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: IriusRisk DB Secret Key
Name-Comment: autogenerated for DB encryption
Name-Email: ${gpg_email}
Expire-Date: 0
EOF
                gpg --batch --generate-key /tmp/gpg_batch
                rm /tmp/gpg_batch
            fi
            local gpg_fp
            gpg_fp="$(gpg --list-keys --with-colons "$gpg_email" | awk -F: '/^pub/ {print $5; exit}')"

            # Encrypt DB_PASS -> secret db_pwd; export private key -> secret db_privkey
            echo -n "$DB_PASS" | gpg --batch --yes --encrypt --recipient "$gpg_fp" --output db_pwd.gpg
            gpg --export-secret-keys --armor "$gpg_fp" > db_privkey.asc

            podman secret rm db_pwd db_privkey 2>/dev/null || true
            podman secret create --replace db_pwd db_pwd.gpg
            podman secret create --replace db_privkey db_privkey.asc
            rm -f db_pwd.gpg db_privkey.asc

            # Build/refresh a tiny postgres image that decrypts at runtime (no plaintext on disk)
            local base_image="docker.io/library/postgres:15.4"
            local patched_image="localhost/postgres-gpg:15.4"
            local tmp_name="temp-postgres"

            podman rm -f "$tmp_name" 2>/dev/null || true

            podman run \
            --name  "$tmp_name" \
            --user root \
            --entrypoint /bin/sh \
            "$base_image" \
            -c "\
                set -eu; \
                # install gnupg
                if [ -f /etc/alpine-release ]; then \
                    apk add --no-cache gnupg; \
                else \
                    apt-get update && \
                    apt-get install -y --no-install-recommends gnupg && \
                    rm -rf /var/lib/apt/lists/*; \
                fi; \
                # write our expand-db-url script
                cat << 'EOF' > /usr/local/bin/pg-expand-secret.sh
#!/usr/bin/env sh
set -eu
# Import the private key and decrypt the DB password
gpg --batch --import /run/secrets/db_privkey
DECRYPTED=\$(gpg --batch --yes --decrypt /run/secrets/db_pwd)

# Append it to the URL and hand off to the real entrypoint
export POSTGRES_PASSWORD=\"\${DECRYPTED}\"
exec docker-entrypoint.sh \"\$@\"
EOF
            chmod +x /usr/local/bin/pg-expand-secret.sh; \
"

            podman commit \
            --change='ENTRYPOINT ["/usr/local/bin/pg-expand-secret.sh"]' \
            --change='CMD ["postgres"]' \
            "$tmp_name" "$patched_image"

            podman rm "$tmp_name"

            # Create a tiny override that mounts secrets and uses the patched image
            # (no plaintext in YAML; secrets are external)
            local pg_override="container-compose.postgres.podman.yml"
            cat > "$pg_override" <<'EOF'
version: '3.7'
services:
  postgres:
    image: localhost/postgres-gpg:15.4
    environment: {}   # wipes the inherited env map
    secrets:
      - db_pwd
      - db_privkey
    # Keep data volume from base file; use tmpfs for init dir (good hygiene)
    tmpfs:
      - /docker-entrypoint-initdb.d

secrets:
  db_pwd:
    external: true
  db_privkey:
    external: true
EOF

            # --- Graceful down then hard teardown for a clean slate ---
            # Bring down anything that may be up for this project (best effort)
            podman-compose -f "$(basename "$postgres_file")" -f "$pg_override" down --remove-orphans || true

            # Stop user units (rootless) and forcefully clean up the project
            stop_disable_user_units_for_project "container-compose"
            teardown_rootless_project "container-compose"
            sudo rm -rf ./postgres/data

            # Bring up just Postgres (with secrets override)
            eval "$compose_tool -f $(basename "$postgres_file") -f \"$pg_override\" up -d postgres"
        else
            echo "ERROR: Unsupported CONTAINER_ENGINE=$CONTAINER_ENGINE" >&2
            exit 1
        fi

        # Wait for readiness
        echo "Waiting for Postgres container to be ready..."
        timeout=60
        until $CONTAINER_ENGINE exec iriusrisk-postgres pg_isready -U "$PG_SUPERUSER" >/dev/null 2>&1; do
            sleep 2
            ((timeout--))
            if [ $timeout -le 0 ]; then
                echo "ERROR: Postgres container did not become ready in time."
                $CONTAINER_ENGINE logs iriusrisk-postgres
                exit 1
            fi
        done
        echo "Postgres is ready!"

        # Create or update the app user/database (idempotent)
        if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
            # Docker path: superuser password is DB_PASS from compose
            sg docker -c "docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -tc \"SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'\" | grep -q 1 || docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -c \"CREATE USER $PG_USER WITH CREATEDB PASSWORD '$DB_PASS';\""
            sg docker -c "docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -tc \"SELECT 1 FROM pg_database WHERE datname = '$PG_DB'\" | grep -q 1 || docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -c \"CREATE DATABASE $PG_DB WITH OWNER $PG_USER;\""
        else
            # Podman path: wrapper set superuser password to DB_PASS in-memory
            podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -tc "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'" | grep -q 1 \
              || podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -c "CREATE USER $PG_USER WITH CREATEDB PASSWORD '$DB_PASS';"
            podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -tc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1 \
              || podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -c "CREATE DATABASE $PG_DB WITH OWNER $PG_USER;"
        fi

        DB_IP="postgres" # service name on the compose network
        export DB_IP DB_PASS

        echo "Internal PostgreSQL (container) is ready:"
        echo "  Host: $DB_IP"
        echo "  User: $PG_USER"
        # (not echoing the password by policy)
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

# —————————————————————————————————————————————————————————————
# Logging (parent-aware)
# —————————————————————————————————————————————————————————————
# Effect:
#  - Creates ../logs (relative to the calling script) or ./logs as fallback
#  - Top-level script decides the log name once: <script>_YYYY-MM-DD_HH-MM-SS.log
#  - Child scripts inherit FDs so they write into the same log
#  - Subsequent init_logging calls no-op if a log is already active

function init_logging() {
  local caller="${1:-$0}"

  # If logging already initialized in this process tree, do nothing
  if [[ -n "${IR_LOG_INITIALIZED:-}" ]]; then
    return 0
  fi

  # Determine the "root" script name once (first caller wins)
  if [[ -z "${IR_ROOT_SCRIPT:-}" ]]; then
    IR_ROOT_SCRIPT="$(basename "$caller")"
    IR_ROOT_SCRIPT="${IR_ROOT_SCRIPT%.sh}"    # strip .sh
    export IR_ROOT_SCRIPT
  fi

  # Timestamp only once per run
  if [[ -z "${IR_LOG_TS:-}" ]]; then
    IR_LOG_TS="$(date '+%Y-%m-%d_%H-%M-%S')"
    export IR_LOG_TS
  fi

  # Compute logs directory (prefer project root = parent of the script dir)
  local script_dir project_root
  script_dir="$(cd "$(dirname "$caller")" && pwd -P)"
  project_root="$(cd "$script_dir/.." 2>/dev/null && pwd -P)"
  if [[ -n "$project_root" && -d "$project_root" ]]; then
    IR_LOG_DIR="$project_root/logs"
  else
    IR_LOG_DIR="$script_dir/logs"
  fi
  mkdir -p "$IR_LOG_DIR"

  # Final logfile path
  IR_LOG_FILE="$IR_LOG_DIR/${IR_ROOT_SCRIPT}_${IR_LOG_TS}.log"
  export IR_LOG_DIR IR_LOG_FILE

  # Header (before redirect) in case anything prints very early
  {
    printf '==== %s | %s starting (pid %s) ====\n' "$(date -Iseconds)" "$IR_ROOT_SCRIPT" "$$"
  } >>"$IR_LOG_FILE"

  # Redirect current shell's stdout/stderr to tee (append) -> file + console
  # Child processes inherit these FDs, so they write to the same log.
  exec > >(tee -a "$IR_LOG_FILE") 2>&1

  IR_LOG_INITIALIZED=1
  export IR_LOG_INITIALIZED
}

# Convenience: timestamped line logger (still goes through the same redirection)
log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

# —————————————————————————————————————————————————————————————
# Helper functions
# —————————————————————————————————————————————————————————————

function is_rhel_like() {
    source /etc/os-release
    [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID_LIKE" == *fedora* ]] || [[ "$ID" == "fedora" ]] || [[ "$ID" == "centos" ]] || [[ "$ID" == "rhel" ]] || [[ "$ID" == "rocky" ]] || [[ "$ID" == "almalinux" ]]
}


function create_certificates() {
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
    local config_candidates=()
    local auth_key_dockerhub1="docker.io"
    local auth_key_dockerhub2="https://index.docker.io/v1/"
    local auth_base64=""
    local auth_user=""

    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
        config_candidates+=("$HOME/.docker/config.json")
    elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
        # Rootful Podman (rare in our flow)
        if sudo test -f /run/containers/0/auth.json 2>/dev/null; then
            config_candidates+=("/run/containers/0/auth.json")
        fi
        # Rootless Podman commonly uses this, but it can also use ~/.docker/config.json
        config_candidates+=("$HOME/.config/containers/auth.json" "$HOME/.docker/config.json")
    else
        return 2
    fi

    for cfg in "${config_candidates[@]}"; do
        [[ -f "$cfg" ]] || continue
        if [[ "$cfg" == "/run/containers/0/auth.json" ]]; then
            auth_base64=$(sudo jq -r ".auths[\"$auth_key_dockerhub1\"].auth // .auths[\"$auth_key_dockerhub2\"].auth // empty" "$cfg" 2>/dev/null)
        else
            auth_base64=$(jq -r ".auths[\"$auth_key_dockerhub1\"].auth // .auths[\"$auth_key_dockerhub2\"].auth // empty" "$cfg" 2>/dev/null)
        fi
        [[ -n "$auth_base64" ]] && break
    done

    [[ -z "$auth_base64" ]] && return 1
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
        if [[ "$(id -u)" -eq 0 ]]; then
            echo "$REGISTRY_PASS" | sudo podman login -u iriusrisk docker.io --password-stdin
        else
            echo "$REGISTRY_PASS" | podman login -u iriusrisk docker.io --password-stdin
        fi
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
    local override_file
    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
        override_file="container-compose.docker.yml"
    elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
        override_file="container-compose.podman.yml"
    fi

    local enable_saml="$1"
    local use_internal_pg="$2"
    local base_files="-f container-compose.yml -f container-compose.tomcat.yml -f container-compose.nginx.yml -f $override_file"
    local files="$base_files"

    if [[ "${enable_saml,,}" == "y" ]]; then
        files="$files -f container-compose.saml.yml"
    fi
    if [[ "${use_internal_pg,,}" == "y" ]]; then
        files="$files -f container-compose.postgres.yml"
    fi

    echo "$files"
}

function stop_disable_user_units_for_project() {
  local proj="$1"

  # Derive container names for the compose project, then map to user unit names
  mapfile -t _units < <(
    podman ps -a --filter "label=io.podman.compose.project=${proj}" --format '{{.Names}}' |
    awk '{print "container-" $1 ".service"}'
  )

  for u in "${_units[@]}"; do
    # Best-effort; units may or may not exist yet
    systemctl --user stop "$u" 2>/dev/null || true
    systemctl --user disable "$u" 2>/dev/null || true
    systemctl --user reset-failed "$u" 2>/dev/null || true
  done
}

# Teardown lingering resources for the project (rootless), including networks
function teardown_rootless_project() {
  local project="$1"

  # Remove pods (and their infra containers)
  mapfile -t pods < <(podman pod ps -q --filter "label=io.podman.compose.project=${project}")
  if ((${#pods[@]})); then
    podman pod rm -f "${pods[@]}" 2>/dev/null || true
  fi

  # Remove any leftover containers for the project
  mapfile -t ctrs < <(podman ps -aq --filter "label=io.podman.compose.project=${project}")
  if ((${#ctrs[@]})); then
    podman rm -f "${ctrs[@]}" 2>/dev/null || true
  fi

  # Now handle project networks: detach any stragglers then rm -f
  mapfile -t nets < <(
    podman network ls --format '{{.Name}} {{.Labels}}' |
    awk -v p="io.podman.compose.project=${project}" '$0 ~ p {print $1}'
  )
  for net in "${nets[@]}"; do
    # If anything (even unlabeled) is still attached, remove it first
    mapfile -t onnet < <(podman ps -aq --filter "network=${net}")
    if ((${#onnet[@]})); then
      podman rm -f "${onnet[@]}" 2>/dev/null || true
    fi
    podman network rm -f "$net" 2>/dev/null || true
  done
}

# Rootless Podman prerequisites + per-boot runtime hardening
# - enable linger so user services keep running
# - ensure user config dirs exist
# - allow low ports (80/443) unless you map 8080/8443
# - create /run/user/<uid> subdirs + tmpfiles rules + symlinks from /tmp/storage-run-<uid>
# - pin Podman runroot/tmp_dir under /run/user/<uid>
# - persist shell env so systemctl --user & podman work in new sessions
function setup_podman_rootless() {
  local user="$1"
  local uid="$(id -u "$user")"
  local confdir="/home/$user/.config/containers"

  # Must run as the actual non-root user
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "Please run this script as a normal user for rootless Podman."
    exit 1
  fi

  # Linger (requires sudo once)
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$user" 2>/dev/null | grep -q '^Linger=yes'; then
      echo "Enabling linger for $user (requires sudo)..."
      sudo loginctl enable-linger "$user" || true
    fi
  fi

  # User config dir for Podman
  mkdir -p $confdir
  chown -R "$user:$user" "/home/$user/.config" 2>/dev/null || true

  # Optional: allow unprivileged to bind :80/:443 (host-wide)
  if ! sysctl net.ipv4.ip_unprivileged_port_start | awk '{print $3}' | grep -qx '80'; then
    echo "Configuring net.ipv4.ip_unprivileged_port_start=80 (requires sudo)..."
    echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee -a /etc/sysctl.conf >/dev/null
    sudo sysctl -p >/dev/null
  fi

  # Ensure /run/user/<uid> tree exists now and at every boot; link legacy /tmp paths
  sudo mkdir -p "/run/user/$uid/containers" "/run/user/$uid/libpod/tmp"
  sudo chown -R "$user:$user" "/run/user/$uid"
  sudo chmod 700 "/run/user/$uid" "/run/user/$uid/libpod" "/run/user/$uid/libpod/tmp" "/run/user/$uid/containers" 2>/dev/null || true

  # Replace any old real dirs with symlinks to /run/user/<uid>/...
  sudo rm -rf "/tmp/storage-run-$uid/containers" "/tmp/storage-run-$uid/libpod/tmp" 2>/dev/null || true
  sudo mkdir -p "/tmp/storage-run-$uid/libpod"
  sudo ln -sfn "/run/user/$uid/containers"  "/tmp/storage-run-$uid/containers"
  sudo ln -sfn "/run/user/$uid/libpod/tmp" "/tmp/storage-run-$uid/libpod/tmp"

  # Persist across reboots via tmpfiles
  sudo tee "/etc/tmpfiles.d/podman-rootless-${uid}.conf" >/dev/null <<EOF
# Ensure the per-user runtime dir exists on boot
d /run/user/${uid} 0700 ${user} ${user} -
d /run/user/${uid}/containers 0700 ${user} ${user} -
d /run/user/${uid}/libpod 0700 ${user} ${user} -
d /run/user/${uid}/libpod/tmp 0700 ${user} ${user} -

# Ensure /tmp parents exist on boot (needed for symlink creation)
d /tmp/storage-run-${uid} 0755 root root -
d /tmp/storage-run-${uid}/libpod 0755 root root -

# Redirect legacy tmp paths used by older Podman fallbacks
L /tmp/storage-run-${uid}/containers - - - - /run/user/${uid}/containers
L /tmp/storage-run-${uid}/libpod/tmp - - - - /run/user/${uid}/libpod/tmp
EOF

  sudo systemd-tmpfiles --create "/etc/tmpfiles.d/podman-rootless-${uid}.conf"

  # Pin Podman to /run/user/<uid> (not /tmp)
  cat > "$confdir/storage.conf" <<EOF
[storage]
driver="overlay"
runroot="/run/user/${uid}/containers"
graphroot="$HOME/.local/share/containers/storage"
EOF

  cat > "$confdir/containers.conf" <<EOF
[engine]
tmp_dir="/run/user/${uid}/libpod/tmp"
EOF

  chown -R "$user:$user" "$confdir" 2>/dev/null || true

  # Persist login environment (SSH, sudo -i) so systemctl --user/podman work in fresh sessions
  sudo tee /etc/profile.d/10-xdg-user-bus.sh >/dev/null <<'EOF'
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}
export TMPDIR=${TMPDIR:-$XDG_RUNTIME_DIR}
EOF
  # keep vars across sudo
  echo 'Defaults env_keep += "XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS TMPDIR"' | sudo tee /etc/sudoers.d/keep-xdg >/dev/null
}

# Ask for a non-root, existing username
function prompt_for_nonroot_user() {
  local def=""
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && def="$SUDO_USER"

  while true; do
    local prompt="Enter the non-root user to run Podman as"
    local u=""
    if [[ -n "$def" ]]; then
      read -rp "$prompt [${def}]: " u
      u="${u:-$def}"
    else
      read -rp "$prompt: " u
    fi

    if [[ -z "$u" ]]; then
      echo "Please enter a username." >&2
      continue
    fi
    if ! id "$u" &>/dev/null; then
      echo "User '$u' does not exist." >&2
      continue
    fi
    if [[ "$u" == "root" || "$(id -u "$u")" -eq 0 ]]; then
      echo "Root is not allowed for rootless Podman." >&2
      continue
    fi
    echo "$u"
    return 0
  done
}

# Resolve the non-root user for rootless Podman.
# Uses $USER if set, otherwise falls back to id -un. Prompts only if still root/unknown.
function resolve_rootless_user() {
  local u="${USER:-$(id -un)}"

  # If running via sudo, prefer the invoking user
  if [[ "$u" == "root" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    u="$SUDO_USER"
  fi

  # Prompt only if still empty or root
  if [[ -z "$u" || "$u" == "root" ]]; then
    u="$(prompt_for_nonroot_user)"
  fi

  # Ensure the shell user matches (rootless Podman must run as that user)
  local current="$(id -un)"
  if [[ "$u" != "$current" ]]; then
    echo "Selected user '$u' does not match current shell user '$current'." >&2
    echo "Please re-run this script as '$u' (e.g., 'su - $u' or SSH as that user)." >&2
    exit 1
  fi

  echo "$u"
}

# Ensure a user systemd instance is running and accessible from this shell
function ensure_user_systemd_ready() {
  local user="${1:-$(id -un)}"
  local uid="$(id -u "$user")"

  # Make sure linger is on and the user manager is started (needs sudo once)
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$user" 2>/dev/null | grep -q '^Linger=yes'; then
      echo "Enabling linger for $user (requires sudo)..."
      sudo loginctl enable-linger "$user" || true
    fi
    # Start the user manager now (so we don't need a relogin)
    sudo loginctl start-user "$user" 2>/dev/null || true
  fi

  # Ensure XDG_RUNTIME_DIR points to the user runtime dir
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"

  # Wait briefly for the user bus socket to appear
  for _ in {1..20}; do
    [[ -S "$XDG_RUNTIME_DIR/systemd/private" ]] && break
    sleep 0.2
  done

  # Test a no-op command; return success if it works
  systemctl --user show-environment >/dev/null 2>&1
}