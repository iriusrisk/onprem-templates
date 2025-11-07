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

		if [[ $OFFLINE -eq 0 ]]; then
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
		fi

		# --- Graceful down then hard teardown for a clean slate ---
		# Bring down anything that may be up for this project (best effort)
		$compose_tool -f "$(basename "$postgres_file")" down --remove-orphans || true

		# Force-remove any leftover postgres container(s) by name
		ids="$(podman ps -aq --filter name=iriusrisk-postgres)"
		if [[ -n $ids ]]; then podman rm -f $ids || true; fi

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
	local enable_saml use_internal_pg
	enable_saml="${1:-}"
	use_internal_pg="${2:-}"

	local base_files="-f $CONTAINER_ENGINE-compose.yml -f $CONTAINER_ENGINE-compose.override.yml"
	local files="$base_files"

	# If only one arg is provided, interpret it as the Postgres flag (back-compat)
	if [[ -z $use_internal_pg && -n $enable_saml ]]; then
		use_internal_pg="$enable_saml"
		enable_saml=""
	fi

	# Normalize and include optional overrides
	shopt -s nocasematch
	case "$enable_saml" in
		y | yes | true | 1) files="$files -f $CONTAINER_ENGINE-compose.saml.yml" ;;
	esac
	case "$use_internal_pg" in
		y | yes | true | 1) files="$files -f $CONTAINER_ENGINE-compose.postgres.yml" ;;
	esac
	shopt -u nocasematch

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

	if [ "$OFFLINE" -eq 0 ]; then
		echo "Pulling base images..."
		podman pull docker.io/continuumsecurity/iriusrisk-prod:nginx >/dev/null
		podman pull "docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" >/dev/null || {
			echo "ERROR: Unable to pull docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" >&2
			return 1
		}
	fi

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

[network]
# Force Podman to use netavark + aardvark-dns (required for service-name DNS)
network_backend = "netavark"
EOF
	else
		cat >"$confdir/containers.conf" <<EOF
[engine]
cgroup_manager = "systemd"
tmp_dir="/run/user/${uid}/libpod/tmp"

[network]
network_backend = "netavark"
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

########################################
# Container-agnostic compose + systemd
# - Docker: system unit in /etc/systemd/system
# - Podman: user unit in ~/.config/systemd/user (rootless, linger enabled)
########################################

function detect_engine_ctx() {
	ENGINE="${CONTAINER_ENGINE:-docker}"
	SERVICE_NAME="iriusrisk-$CONTAINER_ENGINE.service"
	NEED_DOCKER_CFG=""

	case "$ENGINE" in
		docker)
			COMPOSE_INVOKE="docker-compose"
			COMPOSE_RUN='sg docker -c'
			UNIT_SCOPE="system"
			UNIT_DIR="/etc/systemd/system"
			SYSTEMCTL="sudo systemctl"
			UNIT_AFTER=$'After=network.target docker.service'
			UNIT_REQUIRES=$'Requires=docker.service'
			UNIT_ENV_LINES=$'Environment=DOCKER_CONFIG=/etc/docker\nEnvironment=COMPOSE_INTERACTIVE_NO_CLI=1'
			NEED_DOCKER_CFG="true"
			;;
		podman)
			COMPOSE_INVOKE="podman-compose"
			COMPOSE_RUN="" # no wrapper for podman
			UNIT_SCOPE="user"
			UNIT_DIR="$HOME/.config/systemd/user"
			SYSTEMCTL="systemctl --user"
			UNIT_AFTER=$'After=network-online.target\nWants=network-online.target'
			UNIT_REQUIRES=""
			UNIT_ENV_LINES=$'Environment=PODMAN_SYSTEMD_UNIT=%n'
			;;
		*)
			echo "Unknown engine '$ENGINE'." >&2
			exit 1
			;;
	esac
}

function deploy_stack() {
	if [ "$OFFLINE" -eq 0 ]; then
		container_registry_login
	fi

	echo
	echo "Deploying with $CONTAINER_ENGINE"

	cd "$CONTAINER_DIR"

	detect_engine_ctx
	ENABLE_SAML_ONCLICK=${ENABLE_SAML_ONCLICK:-n}
	COMPOSE_OVERRIDE=$(build_compose_override "$ENABLE_SAML_ONCLICK" "$USE_INTERNAL_PG")

	# Clean current stack
	if [[ -n $COMPOSE_RUN ]]; then
		PS_OUTPUT="$(eval "$COMPOSE_RUN \"cd $CONTAINER_DIR && $COMPOSE_INVOKE $COMPOSE_OVERRIDE ps -q\"")"
	else
		PS_OUTPUT="$(cd "$CONTAINER_DIR" && $COMPOSE_INVOKE $COMPOSE_OVERRIDE ps -q)"
	fi

	if [[ -n $PS_OUTPUT ]]; then
		echo "Cleaning up existing containers for this project..."
		if [[ -n $COMPOSE_RUN ]]; then
			eval "$COMPOSE_RUN \"cd $CONTAINER_DIR && $COMPOSE_INVOKE $COMPOSE_OVERRIDE down --remove-orphans\"" || true
			for svc in iriusrisk-nginx iriusrisk-tomcat iriusrisk-startleft reporting-module iriusrisk-postgres; do
				eval "$COMPOSE_RUN \"$CONTAINER_ENGINE rm -f $svc 2>/dev/null || true\""
			done
		else
			(cd "$CONTAINER_DIR" && $COMPOSE_INVOKE $COMPOSE_OVERRIDE down --remove-orphans) || true
		fi
	fi

	if [[ $ENGINE == "podman" && $OFFLINE -eq 0 ]]; then
		# Build custom images for Podman
		build_podman_custom_images
	fi

	# Unit dir
	if [[ $UNIT_SCOPE == "user" ]]; then
		mkdir -p "$UNIT_DIR"
	fi

	# Unit contents
	UNIT_PATH="$UNIT_DIR/$SERVICE_NAME"
	if [[ $UNIT_SCOPE == "system" ]]; then
		sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=IriusRisk ${ENGINE^} Compose Stack
$UNIT_AFTER
$UNIT_REQUIRES

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=$CONTAINER_DIR
$UNIT_ENV_LINES
ExecStart=/usr/bin/env bash -lc '$COMPOSE_INVOKE $COMPOSE_OVERRIDE up -d'
ExecStop=/usr/bin/env bash -lc '$COMPOSE_INVOKE $COMPOSE_OVERRIDE down'

[Install]
WantedBy=multi-user.target
EOF
	else
		tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=IriusRisk ${ENGINE^} Compose Stack
$UNIT_AFTER
$UNIT_REQUIRES

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=$CONTAINER_DIR
$UNIT_ENV_LINES
ExecStart=/usr/bin/env bash -lc '$COMPOSE_INVOKE $COMPOSE_OVERRIDE up -d'
ExecStop=/usr/bin/env bash -lc '$COMPOSE_INVOKE $COMPOSE_OVERRIDE down'

[Install]
WantedBy=default.target
EOF
	fi

	# Docker: make registry login available
	if [[ $NEED_DOCKER_CFG == "true" ]]; then
		sudo mkdir -p /etc/docker
		if [[ -f "$HOME/.docker/config.json" ]]; then
			sudo cp "$HOME/.docker/config.json" /etc/docker/config.json
			sudo chmod 600 /etc/docker/config.json
			sudo chown root:root /etc/docker/config.json
		fi
	fi

	# Enable + start
	$SYSTEMCTL daemon-reload
	$SYSTEMCTL enable "$SERVICE_NAME"
	$SYSTEMCTL restart "$SERVICE_NAME"
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

# If given a relative path, anchor it to LEGACY_DIR. If empty, prints nothing.
function normalize_src() {
	local p="${1:-}"
	[[ -z $p ]] && return 0
	case "$p" in
		/*) printf '%s\n' "$p" ;;
		./*) printf '%s\n' "$LEGACY_DIR/${p#./}" ;;
		*) printf '%s\n' "$LEGACY_DIR/$p" ;;
	esac
}

# Find the first existing file among candidates; searches LEGACY_DIR if needed.
function find_first_file() {
	local cand
	for cand in "$@"; do
		cand="$(normalize_src "$cand")"
		[[ -n $cand && -f $cand ]] && {
			printf '%s\n' "$cand"
			return 0
		}
	done
	# Fallback: if the last arg looks like a bare filename, try locating it under LEGACY_DIR
	local last="${*: -1}"
	if [[ $last != */* ]]; then
		# search up to a few levels; quiet errors if perms block
		local hit
		hit="$(find "$LEGACY_DIR" -maxdepth 4 -type f -name "$last" 2>/dev/null | head -n1)"
		[[ -n $hit ]] && {
			printf '%s\n' "$hit"
			return 0
		}
	fi
	return 1
}

# Ensure the destination path is not a directory placeholder
function ensure_dest_file_slot() {
	local dst="$1"
	if [[ -d $dst ]]; then
		echo "WARNING: '$dst' is a directory; removing so a file can be placed there."
		rm -rf -- "$dst"
	fi
}

# Copy one required artifact; dies if not found
function copy_required() {
	local display="$1" dest="$2"
	shift 2
	local src
	if ! src="$(find_first_file "$@")"; then
		die "could not locate required file for $display (looked for: $*)"
	fi
	ensure_dest_file_slot "$dest"
	cp -f -- "$src" "$dest" || die "copy failed: $src -> $dest"
	echo "Copied $(basename "$src") -> $dest"
}

function parse_major_minor() {
	# Usage: parse_major_minor "4.48.9" -> echoes "4 48"
	local v="$1" maj min
	maj="$(awk -F. '{print $1+0}' <<<"$v" 2>/dev/null || echo 0)"
	min="$(awk -F. '{print ($2==""?0:$2)+0}' <<<"$v" 2>/dev/null || echo 0)"
	echo "$maj $min"
}

function version_ge_4_48() {
	# returns 0 (true) if $1 >= 4.48
	local v="$1" maj min
	read -r maj min < <(parse_major_minor "$v")
	if ((maj > 4)); then return 0; fi
	if ((maj == 4 && min >= 48)); then return 0; fi
	return 1
}

function version_lt_4_48() {
	# returns 0 (true) if $1 < 4.48
	local v="$1" maj min
	read -r maj min < <(parse_major_minor "$v")
	if ((maj < 4)); then return 0; fi
	if ((maj == 4 && min < 48)); then return 0; fi
	return 1
}

function saml_files_exist() {
	# Legacy SAML files must be in COMPOSE_DIR
	[[ -f "$COMPOSE_DIR/SAMLv2-config.groovy" ]] || [[ -f "$COMPOSE_DIR/idp.xml" ]] || [[ -f "$COMPOSE_DIR/iriusrisk-sp.jks" ]]
}

function fetch_health() {
	# Prints: "<http_code> <json>"
	local code json
	code="$(curl -sk -w "%{http_code}" -o /tmp/irius_health.json https://localhost/health || true)"
	json="$(cat /tmp/irius_health.json 2>/dev/null || true)"
	printf '%s %s\n' "$code" "$json"
}

function extract_version_from_json() {
	# Reads JSON from stdin and outputs .version if present
	if command -v jq >/dev/null 2>&1; then
		jq -r '.version // empty' 2>/dev/null
	else
		sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
	fi
}

function wait_for_health() {
	# Wait up to 60 minutes (60 retries x 60s) for HTTP 200; args: retries delay
	local retries="${1:-60}" delay="${2:-60}" i=0 code json
	while ((i < retries)); do
		read -r code json < <(fetch_health)
		if [[ $code == "200" ]]; then
			printf '%s' "$json" >/tmp/irius_health.json
			return 0
		fi
		sleep "$delay"
		i=$((i + 1))
	done
	return 1
}

# —————————————————————————————————————————————————————————————
# Legacy Podman service cleanup + single-unit generation helpers
# —————————————————————————————————————————————————————————————

function cleanup_legacy_podman_units() {
	# Stop/disable known legacy units if they exist
	local LEGACY_UNITS=(
		"container-iriusrisk-tomcat.service"
		"container-iriusrisk-startleft.service"
		"container-iriusrisk-nginx.service"
		"container-iriusrisk-postgres.service"
		"container-reporting-module.service"
	)
	for u in "${LEGACY_UNITS[@]}"; do
		if systemctl --user list-unit-files "$u" --no-legend 2>/dev/null | grep -q "$u"; then
			systemctl --user stop "$u" 2>/dev/null || true
			systemctl --user disable "$u" 2>/dev/null || true
		fi
	done

	# Remove leftover unit files
	rm -f "$HOME/.config/systemd/user/container-"*.service 2>/dev/null || true
	systemctl --user daemon-reload || true

	echo "Legacy Podman units cleaned."
}

function ensure_single_podman_unit_created() {
	local UNIT_DIR="$HOME/.config/systemd/user"
	local UNIT_PATH="$UNIT_DIR/iriusrisk-podman.service"
	local COMPOSE_INVOKE="podman-compose"
	local UNIT_COMPOSE_OVERRIDE="$COMPOSE_OVERRIDE"
	local UNIT_WORKDIR="$(realpath "${CONTAINER_DIR:-$COMPOSE_DIR}")"

	mkdir -p "$UNIT_DIR"

	# Create/update oneshot unit that brings the stack up/down using the **computed** override
	tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=IriusRisk Podman Compose Stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=${UNIT_WORKDIR}
Environment=PODMAN_SYSTEMD_UNIT=%n
ExecStart=/usr/bin/env bash -lc '${COMPOSE_INVOKE} ${UNIT_COMPOSE_OVERRIDE} up -d'
ExecStop=/usr/bin/env bash -lc '${COMPOSE_INVOKE} ${UNIT_COMPOSE_OVERRIDE} down'

[Install]
WantedBy=default.target
EOF

	# Reload, enable and start the unit now (with the current compose files),
	# then wait for the stack to become healthy before proceeding.
	systemctl --user daemon-reload
	systemctl --user enable iriusrisk-podman.service || true
	systemctl --user restart iriusrisk-podman.service

	echo "Waiting for IriusRisk to become healthy under the new single unit (up to 60 minutes)..."
	if ! wait_for_health 60 60; then
		echo "ERROR: IriusRisk did not become healthy after migrating to single Podman unit. Aborting." >&2
		exit 12
	fi
}

# —————————————————————————————————————————————————————————————
# Offline mode functions
# —————————————————————————————————————————————————————————————

# ====== RHEL detection ======
function require_rhel() {
	if [[ ! -f /etc/redhat-release ]]; then
		echo "This offline mode expects RHEL-compatible host." >&2
		exit 1
	fi
}

# ====== Offline repo from bundled RPMs ======
# Expect: $OFFLINE_BUNDLE_DIR/rpms/ with repodata already generated on the builder.
function offline_setup_local_repos() {
	local repo_dir="$OFFLINE_BUNDLE_DIR/rpms"
	if [[ ! -d "$repo_dir/repodata" ]]; then
		echo "[offline] ERROR: $repo_dir missing repodata. Build-side script must run createrepo_c." >&2
		exit 1
	fi

	sudo mkdir -p /opt/offline-rpms
	sudo rsync -a "$repo_dir/" /opt/offline-rpms/

	sudo tee /etc/yum.repos.d/offline-local.repo >/dev/null <<'EOF'
[offline-local]
name=Offline Local Repo
baseurl=file:///opt/offline-rpms
enabled=1
gpgcheck=0
EOF

	# Keep network repos disabled during offline mode
	sudo dnf clean all -y
}

# ====== Install required packages offline ======
function offline_install_dependencies() {
	# Install/upgrade SELinux policy + container-selinux + passt first (quiet + robust)
	sudo dnf --disablerepo='*' --enablerepo=offline-local -y install \
		--best --allowerasing \
		selinux-policy selinux-policy-base selinux-policy-targeted \
		container-selinux \
		passt passt-selinux

	# Core runtimes & container stack (explicit RPMs, not the 'container-tools' module)
	local base_pkgs=(
		# runtimes/tools
		java-17-openjdk postgresql jq
		podman buildah skopeo
		# rootless/container runtime bits
		conmon crun fuse-overlayfs
		# podman networking stack
		nftables iptables-nft slirp4netns netavark aardvark-dns
		# python base in case we need wheels
		python3 python3-pip
	)

	echo "==> Installing container stack and runtime packages"
	sudo dnf --disablerepo='*' --enablerepo=offline-local -y install "${base_pkgs[@]}"

	# podman-compose & python-dotenv:
	#    try RPMs first; if absent in repo, fall back to wheels shipped in bundle
	echo "==> Installing podman-compose & python-dotenv"
	if sudo dnf --disablerepo='*' --enablerepo=offline-local -y install podman-compose python3-dotenv; then
		echo "==> Installed podman-compose / python3-dotenv from RPMs"
	else
		echo "==> RPMs not present; installing wheels from ./wheels"
		if command -v python3 >/dev/null 2>&1; then
			# use only local wheels, no internet
			python3 -m pip install --no-index --find-links "$(pwd)/wheels" podman-compose python-dotenv
		else
			echo "WARNING: python3 not present; cannot install wheel fallbacks" >&2
			return 1
		fi
	fi

	echo "==> Offline dependency installation complete."
}

# ====== Block external registries (safety) ======
function offline_block_external_registries() {
	sudo mkdir -p /etc/containers/registries.conf.d
	sudo tee /etc/containers/registries.conf.d/00-airgap.conf >/dev/null <<'CONF'
unqualified-search-registries = ["localhost"]
[[registry]]
location = "docker.io"
blocked = true
CONF
}

# ====== Load images from bundle ======
# Expect: $OFFLINE_BUNDLE_DIR/images/*.oci.tar created by builder.
function offline_load_images() {
	local bundle="$OFFLINE_BUNDLE_DIR"
	local img_dir="$bundle/images"
	[[ -d $img_dir ]] || {
		echo "[offline] images dir missing: $img_dir"
		exit 1
	}

	# Verify checksums (normalize paths just in case)
	local csum="$bundle/checksums.sha256"
	if [[ -f $csum ]]; then
		echo "[offline] Verifying bundle checksums"
		local tmp="$bundle/.checksums.normalized"
		awk '{
      hash=$1; file=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", hash)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
      gsub(/^.*\//, "", file)
      print hash "  images/" file
    }' "$csum" >"$tmp"
		(cd "$bundle" && sha256sum -c "$tmp")
	fi

	# filename -> desired repo:tag
	_ref_from_filename() {
		local base="$1"              # e.g. docker.io_continuumsecurity_iriusrisk-prod_tomcat-4
		local registry="${base%%_*}" # docker.io | ghcr.io | quay.io | localhost
		local rest="${base#*_}"      # continuumsecurity_iriusrisk-prod_tomcat-4  | nginx-rhel
		IFS='_' read -r -a parts <<<"$rest"
		local tag="latest"
		if ((${#parts[@]} >= 2)); then
			tag="${parts[-1]}"
			unset 'parts[-1]'
		fi
		local repo_path=""
		if ((${#parts[@]} > 0)); then
			repo_path="$(printf "/%s" "${parts[@]}")"
			repo_path="${repo_path#/}"
		fi
		echo "${registry}/${repo_path}:${tag}"
	}

	# read first OCI manifest digest from index.json (no jq)
	_oci_manifest_digest() {
		local tarball="$1"
		tar -xOf "$tarball" index.json 2>/dev/null |
			tr -d '\n' |
			sed -n 's/.*"manifests"[[:space:]]*:[[:space:]]*\[[[:space:]]*{[^}]*"digest"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' |
			head -n1
	}

	echo "[offline] Loading images (via skopeo -> containers-storage)…"
	shopt -s nullglob
	for tarball in "$img_dir"/*.oci.tar; do
		base="$(basename "$tarball" .oci.tar)"
		ref="$(_ref_from_filename "$base")" # e.g. docker.io/continuumsecurity/...:reporting-module
		echo "  - $tarball -> $ref"

		# Import directly into local storage under the target name
		# (avoid --all to sidestep multi-arch manifest issues; host arch will be picked)
		if skopeo copy --insecure-policy "oci-archive:$tarball" "containers-storage:$ref" >/dev/null 2>&1; then
			echo "    -> imported to containers-storage:$ref"
		else
			echo "    !! skopeo copy failed for $tarball, trying podman load + tag"
			out="$(podman load -i "$tarball" 2>&1 || true)"
			loaded_name="$(awk '/^Loaded image: /{print $3}' <<<"$out")"
			loaded_id="$(awk '/^Loaded image ID: /{print $5}' <<<"$out")"
			if [[ -n $loaded_name && $loaded_name != sha256:* ]]; then
				echo "    -> embedded name preserved: $loaded_name"
			elif [[ -n $loaded_id ]]; then
				echo "    -> tagging $loaded_id as $ref"
				podman tag "$loaded_id" "$ref"
			else
				echo "    !! could not determine image ID for $tarball; skipping tag"
			fi
		fi
	done

	echo "[offline] Done. Current images:"
	podman images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Created}}\t{{.Size}}"
}

function ensure_subids_for_user() {
	local u="$1"
	if ! grep -q "^${u}:" /etc/subuid 2>/dev/null; then
		echo "${u}:100000:65536" | sudo tee -a /etc/subuid >/dev/null
	fi
	if ! grep -q "^${u}:" /etc/subgid 2>/dev/null; then
		echo "${u}:100000:65536" | sudo tee -a /etc/subgid >/dev/null
	fi
	podman system migrate
}
