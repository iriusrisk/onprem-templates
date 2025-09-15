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
			y | yes)
				echo "y"
				return 0
				;;
			n | no)
				echo "n"
				return 0
				;;
			*)
				echo "Invalid input: '$yn'. Please enter 'y' or 'n'." >&2
				;;
		esac
	done
}

function prompt_engine() {
	# If already set and valid, skip prompting
	if [[ $CONTAINER_ENGINE =~ ^(docker|podman)$ ]]; then
		echo "✅ Using container engine from environment: $CONTAINER_ENGINE"
		export CONTAINER_ENGINE
		return 0
	fi

	if is_amazon_linux; then
		CONTAINER_ENGINE="docker"
		export CONTAINER_ENGINE
		echo "✅ Detected Amazon Linux. Using Docker as container engine."
	elif is_rhel_like; then
		CONTAINER_ENGINE="podman"
		export CONTAINER_ENGINE
		echo "✅ Detected RHEL. Using Podman as container engine."
	else
		CONTAINER_ENGINE="docker"
		export CONTAINER_ENGINE
		echo "✅ Detected Ubuntu/Debian. Using Docker as container engine."
	fi
}

function prompt_postgres_option() {
	local mode="$1"
	if [[ $mode == "upgrade" || $mode == "migrate" ]]; then
		echo "How is your PostgreSQL configured?"
	else
		echo "How do you want to configure PostgreSQL?"
	fi

	echo "  1) Internal container Postgres"
	echo "  2) Existing Postgres (provide connection details)"

	while true; do
		read -rp "Enter 1 or 2: " pg_option
		case "$pg_option" in
			1 | 2) break ;;
			*) echo "Invalid input: '$pg_option'. Please enter 1 or 2." ;;
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
	if [[ -z $uname ]]; then
		uname="$USER"
	fi
	echo "$uname"
}

function prompt_nonempty() {
	local value
	while true; do
		read -rp "$1: " value
		if [[ -n $value ]]; then
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
	if is_amazon_linux; then
		sudo dnf install -y docker
		sudo systemctl enable --now docker

		# --- Install legacy docker-compose v1 in an isolated virtualenv ---
		echo "Installing legacy docker-compose v1.29.2 via virtualenv..."
		sudo dnf install -y python3 python3-virtualenv python3-pip || {
			echo "ERROR: python3 + venv are required." >&2
			return 1
		}

		# Create isolated venv (avoids RPM-managed Python conflicts)
		sudo python3 -m venv /opt/docker-compose-v1
		# Upgrade basics inside venv only (no RPM conflicts here)
		sudo /opt/docker-compose-v1/bin/pip install --upgrade "pip<24.1" "setuptools<70" wheel

		# Install compose v1 **and** compatible deps:
		# - docker SDK <6 (5.0.3 works well)
		# - urllib3 <2 (v1.x branch)
		# - requests <2.32 (2.31.0 works well)
		# - websocket-client <1.0 (0.59.0 typical)
		# - requests-unixsocket (required on some combos to support http+docker)
		sudo /opt/docker-compose-v1/bin/pip install \
			"docker-compose==1.29.2" \
			"docker<6" \
			"urllib3<2" \
			"requests<2.32" \
			"websocket-client<1.0" \
			"requests-unixsocket>=0.2,<0.4"

		# Ensure your shim points to the venv binary
		sudo ln -sf /opt/docker-compose-v1/bin/docker-compose /usr/local/bin/docker-compose

		# Sanity checks
		if ! /usr/local/bin/docker-compose version 2>/dev/null | grep -q '^docker-compose version 1\.'; then
			echo "ERROR: legacy docker-compose v1.x not found after install." >&2
			/usr/local/bin/docker-compose version 2>/dev/null | head -1 >&2 || true
			return 1
		fi

		echo "✅ Docker installed and legacy docker-compose v1 ready at /usr/local/bin/docker-compose"
	elif command -v apt-get &>/dev/null; then
		sudo apt-get update
		sudo apt-get install -y docker.io docker-compose
		sudo systemctl start docker
		sudo systemctl enable docker
	else
		echo "Please install Docker and Docker Compose manually." >&2
		exit 1
	fi
}

function install_podman() {
	echo "Installing Podman and podman-compose..."
	sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm || true
	sudo dnf install -y container-tools podman-compose python3-dotenv || {
		sudo dnf install -y podman python3-pip
		python3 -m pip install --upgrade --user podman-compose python-dotenv
	}
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
		# Amazon Linux 2023: uses Amazon Corretto packages instead of java-17-openjdk
		if is_amazon_linux; then
			sudo dnf install -y java-17-amazon-corretto-headless || sudo dnf install -y java-17-amazon-corretto
		else
			sudo dnf install -y java-17-openjdk
		fi
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
		if sudo dnf install -y postgresql; then
			:
		else
			# Amazon Linux / RHEL-like may use versioned client packages
			sudo dnf install -y postgresql15 || {
				echo "Could not find a suitable postgresql client package." >&2
				exit 1
			}
		fi
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
	PG_USER="iriusprod"
	PG_DB="iriusprod"
	PG_SUPERUSER="postgres"
	local postgres_file="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.postgres.yml"
	local container_path="../$CONTAINER_ENGINE"

	# Generate a single password for both Postgres superuser and app user
	DB_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"

	echo "Starting internal Postgres container..."
	cd "$container_path"

	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		# -------- Docker path: keep existing plaintext env-in-compose flow --------
		local compose_tool="docker-compose"
		# Write the password into the compose file
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
	elif [[ $CONTAINER_ENGINE == "podman" ]]; then
		local compose_tool="podman-compose"
		# Build/refresh a tiny postgres image that decrypts at runtime (no plaintext on disk)
		local base_image="docker.io/library/postgres:15.4"
		local patched_image="localhost/postgres-gpg:15.4"
		local tmp_name="temp-postgres"

		# Create and encrypt db pass secret
		encrypt_and_store_secret "$DB_PASS" "db_pwd" "db_privkey"

		podman rm -f "$tmp_name" 2>/dev/null || true

		podman run \
			--name "$tmp_name" \
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

		# --- Graceful down then hard teardown for a clean slate ---
		# Bring down anything that may be up for this project (best effort)
		podman-compose -f "$(basename "$postgres_file")" down --remove-orphans || true

		# Stop user units (rootless) and forcefully clean up the project
		stop_disable_user_units_for_project "$CONTAINER_ENGINE"
		teardown_rootless_project "$CONTAINER_ENGINE"
		sudo rm -rf ./postgres/data

		# Bring up just Postgres (with secrets override)
		eval "$compose_tool -f $(basename "$postgres_file") up -d postgres"
	else
		echo "ERROR: Unsupported CONTAINER_ENGINE=$CONTAINER_ENGINE" >&2
		exit 1
	fi

	# Wait for readiness
	echo "Waiting for Postgres container to be ready..."
	timeout=60

	while true; do
		if [[ $CONTAINER_ENGINE == "docker" ]]; then
			# Use sg docker -c to ensure group permissions are applied
			if sg docker -c "docker exec iriusrisk-postgres pg_isready -U \"$PG_SUPERUSER\"" >/dev/null 2>&1; then
				break
			fi
		else
			# Podman can be used directly
			if $CONTAINER_ENGINE exec iriusrisk-postgres pg_isready -U "$PG_SUPERUSER" >/dev/null 2>&1; then
				break
			fi
		fi

		sleep 2
		((timeout--))
		if [ $timeout -le 0 ]; then
			echo "ERROR: Postgres container did not become ready in time."
			if [[ $CONTAINER_ENGINE == "docker" ]]; then
				sg docker -c "docker logs iriusrisk-postgres"
			else
				$CONTAINER_ENGINE logs iriusrisk-postgres
			fi
			exit 1
		fi
	done
	echo "Postgres is ready!"

	# Create or update the app user/database (idempotent)
	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		# Docker path: superuser password is DB_PASS from compose
		sg docker -c "docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -tc \"SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'\" | grep -q 1 || docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -c \"CREATE USER $PG_USER WITH CREATEDB PASSWORD '$DB_PASS';\""
		sg docker -c "docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -tc \"SELECT 1 FROM pg_database WHERE datname = '$PG_DB'\" | grep -q 1 || docker exec -e PGPASSWORD='$DB_PASS' iriusrisk-postgres psql -U $PG_SUPERUSER -c \"CREATE DATABASE $PG_DB WITH OWNER $PG_USER;\""
	else
		# Podman path: wrapper set superuser password to DB_PASS in-memory
		podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -tc "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER'" | grep -q 1 ||
			podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -c "CREATE USER $PG_USER WITH CREATEDB PASSWORD '$DB_PASS';"
		podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -tc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1 ||
			podman exec -e PGPASSWORD="$DB_PASS" iriusrisk-postgres psql -U "$PG_SUPERUSER" -c "CREATE DATABASE $PG_DB WITH OWNER $PG_USER;"
	fi

	DB_IP="postgres" # service name on the compose network
	export DB_IP DB_PASS

	echo "Internal PostgreSQL (container) is ready:"
	echo "  Host: $DB_IP"
	echo "  User: $PG_USER"
	# (not echoing the password by policy)
	echo "  Database: $PG_DB"
	cd ../scripts
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
	if [[ -n ${IR_LOG_INITIALIZED:-} ]]; then
		return 0
	fi

	# Determine the "root" script name once (first caller wins)
	if [[ -z ${IR_ROOT_SCRIPT:-} ]]; then
		IR_ROOT_SCRIPT="$(basename "$caller")"
		IR_ROOT_SCRIPT="${IR_ROOT_SCRIPT%.sh}" # strip .sh
		export IR_ROOT_SCRIPT
	fi

	# Timestamp only once per run
	if [[ -z ${IR_LOG_TS:-} ]]; then
		IR_LOG_TS="$(date '+%Y-%m-%d_%H-%M-%S')"
		export IR_LOG_TS
	fi

	# Compute logs directory (prefer project root = parent of the script dir)
	local script_dir project_root
	script_dir="$(cd "$(dirname "$caller")" && pwd -P)"
	project_root="$(cd "$script_dir/.." 2>/dev/null && pwd -P)"
	if [[ -n $project_root && -d $project_root ]]; then
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
	[[ $ID != "amzn" ]] && (
		[[ $ID_LIKE == *rhel* ]] || [[ $ID_LIKE == *fedora* ]] ||
			[[ $ID == "fedora" ]] || [[ $ID == "centos" ]] ||
			[[ $ID == "rhel" ]] || [[ $ID == "rocky" ]] ||
			[[ $ID == "almalinux" ]]
	)
}

function is_amazon_linux() {
	source /etc/os-release
	[[ $ID == "amzn" ]]
}

function create_certificates() {
	CERT_DIR="../$CONTAINER_ENGINE"
	CERT_FILE="$CERT_DIR/cert.pem"
	KEY_FILE="$CERT_DIR/key.pem"
	EC_KEY_FILE="$CERT_DIR/ec_private.pem"
	local hostname="${1:-$(hostname -f)}"

	mkdir -p "$CERT_DIR"

	# RSA cert/key pair
	if [[ -f $CERT_FILE && -f $KEY_FILE ]]; then
		echo "✅ RSA certificate and key already exist at $CERT_DIR (skipping)."
	else
		echo "🔑 Generating RSA SSL certificate..."
		openssl req -newkey rsa:2048 -nodes \
			-keyout "$KEY_FILE" \
			-x509 -days 365 \
			-out "$CERT_FILE" \
			-subj "/CN=$hostname"
		chmod 644 "$CERT_FILE" "$KEY_FILE"
		echo "✅ RSA certificate and key created in $CERT_DIR."
	fi

	# EC private key
	if [[ -f $EC_KEY_FILE ]]; then
		echo "✅ EC private key already exists at $EC_KEY_FILE (skipping)."
	else
		echo "🔑 Generating EC private key..."
		openssl ecparam -genkey -name prime256v1 -noout -out "$EC_KEY_FILE"
		chmod 644 "$EC_KEY_FILE"
		echo "✅ EC private key created at $EC_KEY_FILE."
	fi

	echo "📄 Certificates present in $CERT_DIR"
}

function is_logged_in_as_iriusrisk() {
	local config_candidates=()
	local auth_key_dockerhub1="docker.io"
	local auth_key_dockerhub2="https://index.docker.io/v1/"
	local auth_base64=""
	local auth_user=""

	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		config_candidates+=("$HOME/.docker/config.json")
	elif [[ $CONTAINER_ENGINE == "podman" ]]; then
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
		[[ -f $cfg ]] || continue
		if [[ $cfg == "/run/containers/0/auth.json" ]]; then
			auth_base64=$(sudo jq -r ".auths[\"$auth_key_dockerhub1\"].auth // .auths[\"$auth_key_dockerhub2\"].auth // empty" "$cfg" 2>/dev/null)
		else
			auth_base64=$(jq -r ".auths[\"$auth_key_dockerhub1\"].auth // .auths[\"$auth_key_dockerhub2\"].auth // empty" "$cfg" 2>/dev/null)
		fi
		[[ -n $auth_base64 ]] && break
	done

	[[ -z $auth_base64 ]] && return 1
	auth_user=$(echo "$auth_base64" | base64 -d 2>/dev/null | cut -d: -f1)
	[[ $auth_user == "iriusrisk" ]]
}

function container_registry_login() {
	local registry_url="${1:-}"

	if is_logged_in_as_iriusrisk $CONTAINER_ENGINE; then
		echo "Already logged in to Docker Hub as 'iriusrisk', skipping login prompt."
		return 0
	fi

	prompt_registry_password

	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		echo "$REGISTRY_PASS" | docker login -u iriusrisk --password-stdin
	elif [[ $CONTAINER_ENGINE == "podman" ]]; then
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
	if [[ -z $actual ]]; then
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
	if [[ ! -f $1 ]]; then
		msg="ERROR: Required file '$1' not found."
		echo "$msg"
		ERRORS+=("$msg")
		return 1
	fi
	echo "Found file: $1"
	return 0
}

function build_compose_override() {
	local enable_saml="$1"
	local use_internal_pg="$2"
	local base_files="-f $CONTAINER_ENGINE-compose.yml -f $CONTAINER_ENGINE-compose.override.yml"
	local files="$base_files"

	if [[ ${enable_saml,,} == "y" ]]; then
		files="$files -f $CONTAINER_ENGINE-compose.saml.yml"
	fi
	if [[ ${use_internal_pg,,} == "y" ]]; then
		files="$files -f $CONTAINER_ENGINE-compose.postgres.yml"
	fi

	echo "$files"
}

# Build/refresh custom podman images used by podman-compose.yml
# Usage: build_podman_custom_images "<tomcat_version_or_empty>"
function build_podman_custom_images() {
	local tv="$1"
	[[ -z $tv ]] && tv="4" # default if not provided

	echo "Preparing custom images for version: tomcat-${tv}"

	# Clean any temp containers
	podman rm -f temp-nginx temp-tomcat 2>/dev/null || true

	echo "Pulling base images..."
	podman pull docker.io/continuumsecurity/iriusrisk-prod:nginx >/dev/null
	podman pull "docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" >/dev/null || {
		echo "ERROR: Unable to pull docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" >&2
		return 1
	}

	echo "Customizing nginx → localhost/nginx-rhel"
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
		localhost/nginx-rhel >/dev/null
	podman rm -f temp-nginx >/dev/null || true

	echo "Customizing tomcat (base tomcat-${tv}) → localhost/tomcat-rhel"
	podman run \
		--name temp-tomcat \
		--user root \
		--entrypoint /bin/sh \
		"docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" \
		-c '\
      set -eu; \
      if [ -f /etc/alpine-release ]; then \
          apk add --no-cache gnupg; \
      else \
          apt-get update && \
          apt-get install -y --no-install-recommends gnupg && \
          rm -rf /var/lib/apt/lists/*; \
      fi; \
      cat <<'"'"'EOF'"'"' > /usr/local/bin/expand-secrets.sh
#!/usr/bin/env sh
set -eu

export_from_secret() {
  var_name="$1"; cipher="$2"; priv="$3"
  if [ -r "$cipher" ] && [ -r "$priv" ]; then
    gpg --batch --import "$priv" >/dev/null 2>&1 || true
    value="$(gpg --batch --yes --decrypt "$cipher" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      export "$var_name=$value"
    fi
  fi
}

if [ -r /run/secrets/db_pwd ] && [ -r /run/secrets/db_privkey ]; then
  gpg --batch --import /run/secrets/db_privkey >/dev/null 2>&1 || true
  if dec="$(gpg --batch --yes --decrypt /run/secrets/db_pwd 2>/dev/null || true)"; then
    if [ -n "$dec" ]; then
      export IRIUS_DB_URL="${IRIUS_DB_URL}&password=${dec}"
    fi
  fi
fi

export_from_secret KEYSTORE_PASSWORD   /run/secrets/keystore_pwd   /run/secrets/keystore_privkey
export_from_secret KEY_ALIAS_PASSWORD  /run/secrets/key_alias_pwd  /run/secrets/key_alias_privkey

exec /entrypoint/dynamic-entrypoint.sh "$@"
EOF
      chmod +x /usr/local/bin/expand-secrets.sh; \
    '
	podman commit \
		--change='USER tomcat' \
		--change='ENTRYPOINT ["/usr/local/bin/expand-secrets.sh"]' \
		temp-tomcat \
		localhost/tomcat-rhel >/dev/null
	podman rm -f temp-tomcat >/dev/null || true

	echo "Custom images ready: localhost/nginx-rhel, localhost/tomcat-rhel"
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

	# User config dir for Podman
	mkdir -p "$confdir"
	chown -R "$user:$user" "/home/$user/.config" 2>/dev/null || true

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

	# ---- systemd cgroup delegation (FIX for crun 'cpu controller not available') ----
	echo "Configuring systemd delegation for rootless cgroups (requires sudo)..."
	sudo mkdir -p /etc/systemd/system/user@.service.d
	if ! sudo test -f /etc/systemd/system/user@.service.d/delegate.conf ||
		! sudo grep -q '^Delegate=.*cpu' /etc/systemd/system/user@.service.d/delegate.conf; then
		sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null <<'EOF'
[Service]
# Delegate controllers needed by rootless Podman/crun
Delegate=cpu io memory pids
EOF
	fi

	# Ensure controllers are activated on user.slice (parents must have +cpu/+io/+memory/+pids)
	sudo systemctl set-property user.slice CPUAccounting=yes IOAccounting=yes MemoryAccounting=yes TasksAccounting=yes >/dev/null

	# Make systemd (system) notice config
	sudo systemctl daemon-reload

	# ---- ensure a live user systemd + bus we can talk to, without killing the session ----
	export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${uid}}"
	export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

	# If the user manager/bus isn't up yet (fresh host or headless), start it
	if ! systemctl --user show-environment >/dev/null 2>&1; then
		sudo loginctl enable-linger "$user" >/dev/null 2>&1 || true
		sudo loginctl start-user "$user" >/dev/null 2>&1 || true
		for i in {1..10}; do
			if systemctl --user show-environment >/dev/null 2>&1; then break; fi
			sleep 0.2
		done
	fi

	# Re-exec the user manager in-place so it picks up delegation (no session kill)
	systemctl --user daemon-reexec 2>/dev/null || systemctl --user daemon-reload 2>/dev/null || true

	# Verify controllers; warn + offer fallback if still missing
	local ctrl_user
	ctrl_user="$(cat /sys/fs/cgroup/user.slice/user-${uid}.slice/cgroup.controllers 2>/dev/null || true)"
	if ! grep -qw cpu <<<"$ctrl_user" || ! grep -qw io <<<"$ctrl_user"; then
		echo "WARNING: cpu/io controllers are still missing in user-${uid}.slice: [$ctrl_user]"
		echo "Falling back to cgroups=disabled for rootless containers."
		cat >"$confdir/containers.conf" <<EOF
[engine]
cgroup_manager = "systemd"
tmp_dir="/run/user/${uid}/libpod/tmp"

[containers]
cgroups = "disabled"
EOF
	else
		cat >"$confdir/containers.conf" <<EOF
[engine]
cgroup_manager = "systemd"
tmp_dir="/run/user/${uid}/libpod/tmp"
EOF
	fi

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
	sudo ln -sfn "/run/user/$uid/containers" "/tmp/storage-run-$uid/containers"
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
	cat >"$confdir/storage.conf" <<EOF
[storage]
driver="overlay"
runroot="/run/user/${uid}/containers"
graphroot="$HOME/.local/share/containers/storage"
EOF

	chown -R "$user:$user" "$confdir" 2>/dev/null || true

	# Persist login environment (SSH, sudo -i) so systemctl --user/podman work in fresh sessions
	sudo tee /etc/profile.d/10-xdg-user-bus.sh >/dev/null <<'EOF'
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}
export TMPDIR=${TMPDIR:-$XDG_RUNTIME_DIR}
EOF
	echo 'Defaults env_keep += "XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS TMPDIR"' | sudo tee /etc/sudoers.d/keep-xdg >/dev/null
}

# Ask for a non-root, existing username
function prompt_for_nonroot_user() {
	local def=""
	[[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]] && def="$SUDO_USER"

	while true; do
		local prompt="Enter the non-root user to run Podman as"
		local u=""
		if [[ -n $def ]]; then
			read -rp "$prompt [${def}]: " u
			u="${u:-$def}"
		else
			read -rp "$prompt: " u
		fi

		if [[ -z $u ]]; then
			echo "Please enter a username." >&2
			continue
		fi
		if ! id "$u" &>/dev/null; then
			echo "User '$u' does not exist." >&2
			continue
		fi
		if [[ $u == "root" || "$(id -u "$u")" -eq 0 ]]; then
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
	if [[ $u == "root" && -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
		u="$SUDO_USER"
	fi

	# Prompt only if still empty or root
	if [[ -z $u || $u == "root" ]]; then
		u="$(prompt_for_nonroot_user)"
	fi

	# Ensure the shell user matches (rootless Podman must run as that user)
	local current="$(id -un)"
	if [[ $u != "$current" ]]; then
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

	# Ensure linger + start user manager (requires sudo once)
	if command -v loginctl >/dev/null 2>&1; then
		if ! loginctl show-user "$user" 2>/dev/null | grep -q '^Linger=yes'; then
			echo "Enabling linger for $user (requires sudo)..."
			sudo loginctl enable-linger "$user" || true
		fi
		sudo loginctl start-user "$user" 2>/dev/null || true
	fi

	# Ensure runtime env for systemctl --user
	export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
	export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

	# Wait briefly for user manager + D-Bus socket to appear
	# We check both the systemd control socket and the session bus.
	for _ in {1..30}; do
		if [[ -S "$XDG_RUNTIME_DIR/systemd/private" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
			break
		fi
		sleep 0.2
	done

	# Re-exec (or at least reload) the user manager so it sees any new units
	systemctl --user daemon-reexec 2>/dev/null || systemctl --user daemon-reload 2>/dev/null || true

	# Return success if we can talk to it now
	systemctl --user show-environment >/dev/null 2>&1
}

function encrypt_and_store_secret() {
	local secret_value="$1"
	local secret_name="$2"
	local privkey_secret_name="$3"
	local uid="${secret_name}@iriusrisk.local"

	# Make an isolated, temporary GNUPGHOME so we don't touch the user's keyring
	local homedir="$(mktemp -d "/tmp/${secret_name}.gnupg.XXXX")"
	chmod 700 "$homedir"

	# Batch file with %no-protection to avoid pinentry entirely
	local batch="$homedir/gpg_batch"
	cat >"$batch" <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: IriusRisk Secret: ${secret_name}
Name-Comment: autogenerated for ${secret_name}
Name-Email: ${uid}
Expire-Date: 0
EOF

	# Create the key (no passphrase, no pinentry needed)
	gpg --homedir "$homedir" --batch --generate-key "$batch"
	rm -f "$batch"

	# Get fingerprint for the new key
	local fp
	fp="$(gpg --homedir "$homedir" --list-keys --with-colons "$uid" | awk -F: '/^pub/ {print $5; exit}')"

	# Encrypt the secret value to this key
	local enc_file="$(mktemp "/tmp/${secret_name}.XXXX.gpg")"
	local priv_file="$(mktemp "/tmp/${secret_name}_privkey.XXXX.asc")"

	echo "$secret_value" |
		gpg --homedir "$homedir" --batch --yes --encrypt --recipient "$fp" --output "$enc_file"

	# Export the private key (ASCII-armored)
	gpg --homedir "$homedir" --batch --yes --export-secret-keys --armor "$fp" >"$priv_file"

	# Store in Podman secrets: <name> (encrypted payload) and <name>_privkey (private key)
	podman secret rm "${secret_name}" "${privkey_secret_name}" 2>/dev/null || true
	podman secret create --replace "${secret_name}" "$enc_file"
	podman secret create --replace "${privkey_secret_name}" "$priv_file"

	# Cleanup artifacts and the whole temporary keyring
	rm -f "$enc_file" "$priv_file"
	rm -rf "$homedir"
}

# Helper: update image line for a component that may be unversioned or versioned already
# Usage: update_component_tag startleft "$SL_VER"
function update_component_tag() {
	local comp="$1" ver="$2"
	[[ -z $ver ]] && {
		echo "NOTE: No version provided for $comp in JSON; skipping."
		return 0
	}

	# Match:
	#   image: docker.io/continuumsecurity/iriusrisk-prod:<comp>
	#   image: docker.io/continuumsecurity/iriusrisk-prod:<comp>-<digits[.digits...]>
	# (docker.io/ prefix optional; whitespace & comments preserved)
	if grep -qE "^[[:space:]]*image:[[:space:]]*(docker\.io/)?continuumsecurity/iriusrisk-prod:${comp}(-[0-9.]+)?([[:space:]]|$)" "$COMPOSE_YML"; then
		sed -i -E \
			"s@(^[[:space:]]*image:[[:space:]]*(docker\.io/)?continuumsecurity/iriusrisk-prod:${comp})(-[0-9.]+)?([[:space:]]*(#.*)?\$)@\\1-${ver}\\4@" \
			"$COMPOSE_YML"
		echo "Updated ${comp} image tag → docker.io/continuumsecurity/iriusrisk-prod:${comp}-${ver}"
	else
		echo "WARNING: No '${comp}' image line found in $COMPOSE_YML; skipping ${comp} update."
	fi
}

function deploy_stack() {
	container_registry_login

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

			# Build the custom rootless nginx and tomcat images
			build_podman_custom_images

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
}

# —————————————————————————————————————————————————————————————
# Migration + upgrade functions
# —————————————————————————————————————————————————————————————

function die() {
	echo "ERROR: $*" >&2
	exit 2
}

# Trim spaces
function trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

# Replace just the VALUE part of a YAML env list line:
#   "      - KEY=anything"  ->  "      - KEY=<value>"
# Preserves the indent and "- KEY=" prefix.
# args: file, key, value
replace_env_value() {
	local file="$1" key="$2" val="$3"

	# Escape chars that are special in sed replacement: \ & |
	local esc_val
	esc_val=$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')

	# Replace everything AFTER "KEY=" while preserving "  - KEY="
	sed -i -E "s|(^[[:space:]]*-[[:space:]]*${key}=).*|\1${esc_val}|" "$file"
}

function backup_db() {
	#Get version for backup filenames
	TS="${TS:-$(date +%s)}"
	HEALTH_URL="${HEALTH_URL:-https://localhost/health}"
	echo "Fetching version from $HEALTH_URL ..."
	RAW_HEALTH="$(curl -ksS --max-time 5 "$HEALTH_URL" || true)"

	# Extract first X.Y.Z from "version":"..." if present; else fallback to TS
	if [[ $RAW_HEALTH =~ \"version\":\"([0-9]+\.[0-9]+\.[0-9]+) ]]; then
		VERSION="${BASH_REMATCH[1]}"
		echo "Detected version: $VERSION"
	else
		VERSION="$TS"
		echo "WARNING: Could not parse version; using timestamp: $VERSION"
	fi
	echo

	cd ~
	BDIR="${BDIR:-/home/$USER/irius_backups}"
	TMP_DB="/tmp/irius.db.$TS.sql.gz"
	OUT_DB="$BDIR/irius.db.$VERSION.sql.gz"

	echo "Preparing backup directory at: $BDIR"
	mkdir -p "$BDIR"

	if [[ $USE_INTERNAL_PG == "y" ]]; then
		# Ensure the postgres container is running
		if ! $CONTAINER_ENGINE ps \
			--filter "name=^iriusrisk-postgres$" \
			--format '{{.Names}}' | grep -q .; then
			echo "ERROR: Container 'iriusrisk-postgres' is not running. Start it and retry." >&2
			exit 2
		fi

		echo "Backing up database iriusprod from container 'iriusrisk-postgres' ..."
		$CONTAINER_ENGINE exec -u postgres "iriusrisk-postgres" \
			pg_dump -d "iriusprod" | gzip >"$TMP_DB"
	else
		DB_IP=$(prompt_nonempty "Enter the Postgres IP address (DB host)")
		DB_PASS=$(prompt_nonempty "Enter the Postgres password")
		PGPASSWORD="$DB_PASS" pg_dump -h "$DB_IP" -U "iriusprod" -d "iriusprod" | gzip >"$TMP_DB"
	fi

	# Sanity check: non-empty output
	if [[ ! -s $TMP_DB ]]; then
		echo "ERROR: DB backup file is empty (pg_dump likely failed)." >&2
		exit 3
	fi

	# Keep only latest: remove old DB backups, then move new one in place
	rm -f "$BDIR"/irius.db.*.sql.gz || true
	mv -f "$TMP_DB" "$OUT_DB"

	DB_SIZE="$(du -h "$OUT_DB" | cut -f1)"
	echo "DB backup completed: $DB_SIZE -> $OUT_DB"
}
