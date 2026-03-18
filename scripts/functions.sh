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

	configure_ip_pass

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

		# Create and encrypt db pass secret
		encrypt_and_store_secret "$DB_PASS" "db_pwd" "db_privkey"

		if [[ $OFFLINE -eq 0 ]]; then
			build_podman_secret_image "docker.io/library/postgres:15.4" "temp-postgres" "localhost/postgres-gpg:15.4" 'export_from_secret_env POSTGRES_PASSWORD DB_PWD_GPG DB_PRIVKEY_ASC' 'docker-entrypoint.sh "$@"'
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
	local enable_saml=""
	local use_internal_pg=""
	local enable_jeff="${JEFF_ENABLED:-n}"

	case $# in
		0) ;;
		1)
			# Back-compat: a single argument means the internal Postgres flag.
			use_internal_pg="$1"
			;;
		2)
			enable_saml="$1"
			use_internal_pg="$2"
			;;
		*)
			enable_saml="$1"
			use_internal_pg="$2"
			enable_jeff="$3"
			;;
	esac

	local base_files="-f $CONTAINER_ENGINE-compose.yml -f $CONTAINER_ENGINE-compose.override.yml"
	local files="$base_files"

	shopt -s nocasematch
	case "$enable_saml" in
		y | yes | true | 1) files="$files -f $CONTAINER_ENGINE-compose.saml.yml" ;;
	esac
	case "$use_internal_pg" in
		y | yes | true | 1) files="$files -f $CONTAINER_ENGINE-compose.postgres.yml" ;;
	esac
	case "$enable_jeff" in
		y | yes | true | 1) files="$files -f $CONTAINER_ENGINE-compose.jeff.yml" ;;
	esac
	shopt -u nocasematch

	echo "$files"
}

function podman_secret_to_env_snippet() {
	local var_name="$1"
	local cipher_env="$2"
	local priv_env="$3"
	printf 'export_from_secret_env %s %s %s' "$var_name" "$cipher_env" "$priv_env"
}

function build_podman_secret_image() {
	local base_image="$1"
	local tmp_name="$2"
	local target_image="$3"
	local secret_snippet="${4:-}"
	local final_exec="${5:-}"
	local setup_snippet="${6:-}"
	local run_as_user="${7:-}"
	local commit_cmd="${8:-}"
	local wrapper_file final_exec_file

	local original_entrypoint_json original_cmd_json original_entrypoint_exec
	original_entrypoint_json="$(podman image inspect --format '{{json .Config.Entrypoint}}' "$base_image" 2>/dev/null || echo null)"
	original_cmd_json="$(podman image inspect --format '{{json .Config.Cmd}}' "$base_image" 2>/dev/null || echo null)"

	if command -v python3 >/dev/null 2>&1; then
		original_entrypoint_exec="$(
			python3 - "$original_entrypoint_json" <<'PY2'
import json, shlex, sys
raw = sys.argv[1]
if raw in ('', 'null', 'None'):
    print('')
else:
    arr = json.loads(raw)
    print(' '.join(shlex.quote(str(x)) for x in arr))
PY2
		)"
	else
		echo "ERROR: python3 is required to inspect and preserve Podman image entrypoints." >&2
		return 1
	fi

	wrapper_file="$(mktemp)"
	cat >"$wrapper_file" <<EOF
#!/usr/bin/env sh
set -eu

export_from_secret_env() {
  var_name="\$1"
  cipher_env="\$2"
  priv_env="\$3"

  cipher_value="\$(printenv "\$cipher_env" 2>/dev/null || true)"
  priv_value="\$(printenv "\$priv_env" 2>/dev/null || true)"

  if [ -n "\$cipher_value" ] && [ -n "\$priv_value" ]; then
    tmpdir="\$(mktemp -d)"
    cipher_file="\$tmpdir/cipher.gpg"
    priv_file="\$tmpdir/private.asc"

    printf '%s' "\$cipher_value" >"\$cipher_file"
    printf '%s' "\$priv_value" >"\$priv_file"

    gpg --batch --import "\$priv_file" >/dev/null 2>&1 || true
    value="\$(gpg --batch --yes --decrypt "\$cipher_file" 2>/dev/null || true)"

    rm -rf "\$tmpdir"

    if [ -n "\$value" ]; then
      export "\$var_name=\$value"
    fi
  fi
}

${secret_snippet}
EOF
	if [[ -n $final_exec ]]; then
		cat >>"$wrapper_file" <<'EOF'

if [ -r /usr/local/bin/podman-secret-final-exec ]; then
  exec /bin/sh -c "$(cat /usr/local/bin/podman-secret-final-exec)" -- "$@"
fi
EOF
	elif [[ -n $original_entrypoint_exec ]]; then
		printf '
exec %s "$@"
' "$original_entrypoint_exec" >>"$wrapper_file"
	else
		printf '
exec "$@"
' >>"$wrapper_file"
	fi

	podman rm -f "$tmp_name" 2>/dev/null || true
	podman create \
		--name "$tmp_name" \
		--user root \
		--entrypoint /bin/sh \
		"$base_image" \
		-c 'sleep infinity' >/dev/null
	podman start "$tmp_name" >/dev/null
	podman exec "$tmp_name" /bin/sh -c "set -eu; \
		if [ -f /etc/alpine-release ]; then \
			apk add --no-cache gnupg python3; \
		else \
			apt-get update && \
			apt-get install -y --no-install-recommends gnupg python3 && \
			rm -rf /var/lib/apt/lists/*; \
		fi; \
		${setup_snippet:-:}; \
		mkdir -p /usr/local/bin"
	podman cp "$wrapper_file" "$tmp_name:/usr/local/bin/podman-secret-wrapper.sh"
	if [[ -n $final_exec ]]; then
		final_exec_file="$(mktemp)"
		printf '%s\n' "$final_exec" >"$final_exec_file"
		podman cp "$final_exec_file" "$tmp_name:/usr/local/bin/podman-secret-final-exec"
		podman exec "$tmp_name" chmod 755 /usr/local/bin/podman-secret-final-exec
		rm -f "$final_exec_file"
	fi
	podman exec "$tmp_name" chmod 755 /usr/local/bin/podman-secret-wrapper.sh
	podman stop "$tmp_name" >/dev/null
	rm -f "$wrapper_file"

	local commit_args=(--change='ENTRYPOINT ["/usr/local/bin/podman-secret-wrapper.sh"]')
	if [[ -n $run_as_user ]]; then
		commit_args+=(--change="USER ${run_as_user}")
	fi
	if [[ $original_cmd_json != "null" && -n $original_cmd_json ]]; then
		commit_args+=(--change="CMD ${original_cmd_json}")
	fi
	if [[ -n $commit_cmd ]]; then
		commit_args+=(--change="CMD ${commit_cmd}")
	fi

	podman commit "${commit_args[@]}" "$tmp_name" "$target_image" >/dev/null
	podman rm -f "$tmp_name" >/dev/null || true
}

# Build/refresh custom podman images used by podman-compose.yml
# Usage: build_podman_custom_images "<tomcat_version_or_empty>"
function build_podman_custom_images() {
	local tv="$1"
	[[ -z $tv ]] && tv="4" # default if not provided

	echo "Preparing custom images for version: tomcat-${tv}"

	podman rm -f temp-nginx temp-tomcat temp-postgres temp-jeff temp-rag temp-ash temp-haven temp-redis 2>/dev/null || true

	if [ "$OFFLINE" -eq 0 ]; then
		echo "Pulling base images..."
		podman pull docker.io/continuumsecurity/iriusrisk-prod:nginx >/dev/null
		podman pull "docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" >/dev/null || {
			echo "ERROR: Unable to pull docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" >&2
			return 1
		}
		podman pull docker.io/library/postgres:15.4 >/dev/null
		if [[ ${JEFF_ENABLED:-n} == "y" ]]; then
			podman pull docker.io/continuumsecurity/iriusrisk-prod:ai-jeff-4.6.2 >/dev/null
			podman pull docker.io/continuumsecurity/iriusrisk-prod:ai-rag-1.2.2 >/dev/null
			podman pull docker.io/continuumsecurity/iriusrisk-prod:ai-ash-1.7.0 >/dev/null
			podman pull docker.io/continuumsecurity/iriusrisk-prod:ai-haven-1.0.1 >/dev/null
			podman pull docker.io/redis/redis-stack:latest >/dev/null
		fi
	fi

	echo "Customizing nginx → localhost/nginx-rhel"
	build_podman_secret_image \
		"docker.io/continuumsecurity/iriusrisk-prod:nginx" \
		"temp-nginx" \
		"localhost/nginx-rhel" \
		"" \
		'nginx -g "daemon off;"' \
		'if [ -f /etc/alpine-release ]; then
		   apk add --no-cache libcap;
		 else
		   (apt-get update && apt-get install -y --no-install-recommends libcap2-bin && rm -rf /var/lib/apt/lists/*) || true;
		 fi;
		 command -v setcap >/dev/null 2>&1 && setcap "cap_net_bind_service=+ep" /usr/sbin/nginx || true' \
		"nginx"

	echo "Customizing tomcat (base tomcat-${tv}) → localhost/tomcat-rhel"
	build_podman_secret_image \
		"docker.io/continuumsecurity/iriusrisk-prod:tomcat-${tv}" \
		"temp-tomcat" \
		"localhost/tomcat-rhel" \
		$'if [ -n "$(printenv DB_PWD_GPG 2>/dev/null || true)" ] && [ -n "$(printenv DB_PRIVKEY_ASC 2>/dev/null || true)" ]; then
  tmpdir="$(mktemp -d)"
  cipher_file="$tmpdir/db_pwd.gpg"
  priv_file="$tmpdir/db_privkey.asc"
  printf '%s' "$DB_PWD_GPG" >"$cipher_file"
  printf '%s' "$DB_PRIVKEY_ASC" >"$priv_file"
  gpg --batch --import "$priv_file" >/dev/null 2>&1 || true
  dec="$(gpg --batch --yes --decrypt "$cipher_file" 2>/dev/null || true)"
  rm -rf "$tmpdir"
  if [ -n "$dec" ]; then
    export IRIUS_DB_URL="${IRIUS_DB_URL}&password=${dec}"
  fi
fi
export_from_secret_env KEYSTORE_PASSWORD KEYSTORE_PWD_GPG KEYSTORE_PRIVKEY_ASC
export_from_secret_env KEY_ALIAS_PASSWORD KEY_ALIAS_PWD_GPG KEY_ALIAS_PRIVKEY_ASC' \
		'/entrypoint/dynamic-entrypoint.sh "$@"' \
		"" \
		"tomcat"

	echo "Customizing postgres → localhost/postgres-gpg:15.4"
	build_podman_secret_image \
		"docker.io/library/postgres:15.4" \
		"temp-postgres" \
		"localhost/postgres-gpg:15.4" \
		'export_from_secret_env POSTGRES_PASSWORD DB_PWD_GPG DB_PRIVKEY_ASC' \
		'docker-entrypoint.sh "$@"'

	if [[ ${JEFF_ENABLED:-n} == "y" ]]; then
		echo "Customizing Jeff-related images with Podman secrets"
		build_podman_secret_image \
			"docker.io/continuumsecurity/iriusrisk-prod:ai-jeff-4.6.2" \
			"temp-jeff" \
			"localhost/ai-jeff-4.6.2" \
			"$(podman_secret_to_env_snippet AZURE_API_KEY AZURE_API_KEY_GPG AZURE_API_PRIVKEY_ASC)"

		build_podman_secret_image \
			"docker.io/continuumsecurity/iriusrisk-prod:ai-rag-1.2.2" \
			"temp-rag" \
			"localhost/ai-rag-1.2.2" \
			"$(podman_secret_to_env_snippet AZURE_API_KEY AZURE_API_KEY_GPG AZURE_API_PRIVKEY_ASC)"

		build_podman_secret_image \
			"docker.io/continuumsecurity/iriusrisk-prod:ai-ash-1.7.0" \
			"temp-ash" \
			"localhost/ai-ash-1.7.0" \
			$'export_from_secret_env GEMINI_API_KEY GEMINI_API_KEY_GPG GEMINI_API_PRIVKEY_ASC\nexport_from_secret_env AZURE_OPENAI_API_KEY AZURE_API_KEY_GPG AZURE_API_PRIVKEY_ASC'

		build_podman_secret_image \
			"docker.io/continuumsecurity/iriusrisk-prod:ai-haven-1.0.1" \
			"temp-haven" \
			"localhost/ai-haven-1.0.1" \
			$'export_from_secret_env AZURE_API_KEY AZURE_API_KEY_GPG AZURE_API_PRIVKEY_ASC\nexport_from_secret_env REDIS_PASSWORD REDIS_PASSWORD_GPG REDIS_PRIVKEY_ASC'

		build_podman_secret_image \
			"docker.io/redis/redis-stack:latest" \
			"temp-redis" \
			"localhost/redis-stack-gpg:latest" \
			'export_from_secret_env REDIS_PASSWORD REDIS_PASSWORD_GPG REDIS_PRIVKEY_ASC' \
			'redis-stack-server --requirepass "$REDIS_PASSWORD"'
	fi

	echo "Custom images ready for Podman deployment"
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

	if [[ -z $secret_name || -z $privkey_secret_name ]]; then
		echo "encrypt_and_store_secret: missing secret name(s)" >&2
		return 1
	fi

	local uid="${secret_name}@iriusrisk.local"
	local homedir batch enc_file priv_file plaintext_file fp
	homedir="$(mktemp -d "/tmp/${secret_name}.gnupg.XXXXXX")" || return 1
	chmod 700 "$homedir" || {
		rm -rf "$homedir"
		return 1
	}

	batch="$homedir/gpg_batch"
	cat >"$batch" <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: IriusRisk Secret: ${secret_name}
Name-Comment: autogenerated for ${secret_name}
Name-Email: ${uid}
Expire-Date: 0
EOF

	if ! gpg --homedir "$homedir" --batch --generate-key "$batch" >/dev/null 2>&1; then
		rm -f "$batch"
		rm -rf "$homedir"
		echo "encrypt_and_store_secret: failed to generate GPG key" >&2
		return 1
	fi
	rm -f "$batch"

	fp="$(
		gpg --homedir "$homedir" --list-keys --with-colons "$uid" 2>/dev/null |
			awk -F: '/^fpr:/ {print $10; exit}'
	)"
	if [[ -z $fp ]]; then
		rm -rf "$homedir"
		echo "encrypt_and_store_secret: failed to determine key fingerprint" >&2
		return 1
	fi

	plaintext_file="$(mktemp "/tmp/${secret_name}.plaintext.XXXXXX")" || {
		rm -rf "$homedir"
		return 1
	}
	enc_file="$(mktemp "/tmp/${secret_name}.enc.XXXXXX.gpg")" || {
		rm -f "$plaintext_file"
		rm -rf "$homedir"
		return 1
	}
	priv_file="$(mktemp "/tmp/${secret_name}_privkey.XXXXXX.asc")" || {
		rm -f "$plaintext_file" "$enc_file"
		rm -rf "$homedir"
		return 1
	}

	# Preserve the exact secret bytes except Bash cannot carry NUL bytes in variables.
	printf '%s' "$secret_value" >"$plaintext_file"

	if ! gpg --homedir "$homedir" --batch --yes \
		--armor \
		--trust-model always \
		--recipient "$fp" \
		--output "$enc_file" \
		--encrypt "$plaintext_file" >/dev/null 2>&1; then
		rm -f "$plaintext_file" "$enc_file" "$priv_file"
		rm -rf "$homedir"
		echo "encrypt_and_store_secret: failed to encrypt secret" >&2
		return 1
	fi

	if ! gpg --homedir "$homedir" --batch --yes \
		--armor --export-secret-keys "$fp" >"$priv_file" 2>/dev/null; then
		rm -f "$plaintext_file" "$enc_file" "$priv_file"
		rm -rf "$homedir"
		echo "encrypt_and_store_secret: failed to export private key" >&2
		return 1
	fi

	# Remove any existing versions first. Ignore failures.
	podman secret rm "$secret_name" "$privkey_secret_name" >/dev/null 2>&1 || true

	if ! podman secret create --replace "$secret_name" "$enc_file" >/dev/null; then
		rm -f "$plaintext_file" "$enc_file" "$priv_file"
		rm -rf "$homedir"
		echo "encrypt_and_store_secret: failed to create podman secret $secret_name" >&2
		return 1
	fi

	if ! podman secret create --replace "$privkey_secret_name" "$priv_file" >/dev/null; then
		podman secret rm "$secret_name" >/dev/null 2>&1 || true
		rm -f "$plaintext_file" "$enc_file" "$priv_file"
		rm -rf "$homedir"
		echo "encrypt_and_store_secret: failed to create podman secret $privkey_secret_name" >&2
		return 1
	fi

	rm -f "$plaintext_file" "$enc_file" "$priv_file"
	rm -rf "$homedir"
	return 0
}

function read_podman_secret_plaintext() {
	local secret_name="$1"
	local privkey_secret_name="$2"

	if [[ -z $secret_name || -z $privkey_secret_name ]]; then
		echo "read_podman_secret_plaintext: missing secret name(s)" >&2
		return 1
	fi

	if ! command -v gpg >/dev/null 2>&1; then
		echo "read_podman_secret_plaintext: gpg is required" >&2
		return 1
	fi

	local probe_image="localhost/postgres-gpg:15.4"
	if ! podman image exists "$probe_image" >/dev/null 2>&1; then
		probe_image="docker.io/library/postgres:15.4"
	fi

	local tmpdir gnupghome enc_file key_file plaintext_file
	tmpdir="$(mktemp -d "/tmp/${secret_name}.read.XXXXXX")" || return 1
	gnupghome="$tmpdir/gnupg"
	enc_file="$tmpdir/secret.gpg"
	key_file="$tmpdir/private.asc"
	plaintext_file="$tmpdir/plaintext"

	mkdir -m 700 "$gnupghome" || {
		rm -rf "$tmpdir"
		return 1
	}

	# Read the encrypted payload from the podman secret into a file.
	if ! podman run --rm --entrypoint /bin/sh \
		--secret "$secret_name" \
		"$probe_image" \
		-c "cat '/run/secrets/$secret_name'" >"$enc_file" 2>/dev/null; then
		rm -rf "$tmpdir"
		echo "read_podman_secret_plaintext: failed to read encrypted secret $secret_name" >&2
		return 1
	fi

	# Read the armored private key from the companion secret into a file.
	if ! podman run --rm --entrypoint /bin/sh \
		--secret "$privkey_secret_name" \
		"$probe_image" \
		-c "cat '/run/secrets/$privkey_secret_name'" >"$key_file" 2>/dev/null; then
		rm -rf "$tmpdir"
		echo "read_podman_secret_plaintext: failed to read private key secret $privkey_secret_name" >&2
		return 1
	fi

	# Import the private key into an isolated temporary keyring.
	if ! gpg --homedir "$gnupghome" --batch --import "$key_file" >/dev/null 2>&1; then
		rm -rf "$tmpdir"
		echo "read_podman_secret_plaintext: failed to import private key" >&2
		return 1
	fi

	# Decrypt to a file first so we never store potentially problematic bytes in a shell variable.
	if ! gpg --homedir "$gnupghome" --batch --yes \
		--output "$plaintext_file" \
		--decrypt "$enc_file" >/dev/null 2>&1; then
		rm -rf "$tmpdir"
		echo "read_podman_secret_plaintext: failed to decrypt secret" >&2
		return 1
	fi

	# Print exact plaintext bytes to stdout.
	cat "$plaintext_file"

	rm -rf "$tmpdir"
	return 0
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

function configure_ip_pass() {
	# USE_INTERNAL_PG and CONTAINER_ENGINE should already be set before calling this

	if [[ ${USE_INTERNAL_PG:-n} == "y" ]]; then
		# Internal Postgres via compose service
		DB_IP="postgres"

		# Use DB_PASS from env if set, otherwise generate one
		if [[ -n ${DB_PASS:-} ]]; then
			echo "Using Postgres password from environment for internal Postgres."
		else
			echo "Generating random Postgres password for internal Postgres."
			DB_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
		fi
	else
		# External Postgres

		# Use DB_IP from env if set (for local install), otherwise prompt
		if [[ -n ${DB_IP:-} ]]; then
			echo "Using Postgres IP address from environment: $DB_IP"
		else
			DB_IP=$(prompt_nonempty "Enter the Postgres IP address (DB host)")
		fi

		# Use DB_PASS from env if set (for local install), otherwise prompt
		if [[ -n ${DB_PASS:-} ]]; then
			echo "Using Postgres password from environment."
		else
			DB_PASS=$(prompt_nonempty "Enter the Postgres password")
			if [[ ${CONTAINER_ENGINE:-} == "podman" ]]; then
				encrypt_and_store_secret "$DB_PASS" "db_pwd" "db_privkey"
			fi
		fi
	fi

	export DB_IP DB_PASS
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

function podman_secret_exists() {
	local name="$1"
	podman secret inspect "$name" >/dev/null 2>&1
}

function podman_secret_to_tmpfile() {
	local name="$1"
	local outfile="$2"

	# Read the secret content by mounting it into a temporary container
	# and streaming it back to the host.
	if ! podman run --rm \
		--secret "$name" \
		--entrypoint /bin/sh \
		docker.io/library/alpine:3.20 \
		-c "cat /run/secrets/$name" >"$outfile"; then
		rm -f "$outfile"
		return 1
	fi

	return 0
}

function is_ascii_armored_gpg_file() {
	local file="$1"
	grep -q '^-----BEGIN PGP MESSAGE-----' "$file"
}

function migrate_podman_secret_to_armored_if_needed() {
	local secret_name="$1"
	local privkey_secret_name="$2"

	if ! podman_secret_exists "$secret_name"; then
		echo "Secret $secret_name not present; skipping migration"
		return 0
	fi

	if ! podman_secret_exists "$privkey_secret_name"; then
		echo "WARNING: Secret $secret_name exists but $privkey_secret_name is missing; cannot migrate" >&2
		return 1
	fi

	local workdir cipher_file priv_file plaintext_file gpg_home
	workdir="$(mktemp -d "/tmp/secret-migrate.${secret_name}.XXXXXX")" || return 1
	gpg_home="$workdir/gnupg"
	mkdir -p "$gpg_home"
	chmod 700 "$gpg_home"

	cipher_file="$workdir/${secret_name}.gpg"
	priv_file="$workdir/${privkey_secret_name}.asc"
	plaintext_file="$workdir/${secret_name}.plain"

	if ! podman_secret_to_tmpfile "$secret_name" "$cipher_file"; then
		rm -rf "$workdir"
		echo "WARNING: Failed to read secret payload for $secret_name" >&2
		return 1
	fi

	if ! podman_secret_to_tmpfile "$privkey_secret_name" "$priv_file"; then
		rm -rf "$workdir"
		echo "WARNING: Failed to read private key secret for $privkey_secret_name" >&2
		return 1
	fi

	# If already armored, nothing to do.
	if is_ascii_armored_gpg_file "$cipher_file"; then
		echo "Secret $secret_name is already ASCII-armored; no migration needed"
		rm -rf "$workdir"
		return 0
	fi

	if ! gpg --homedir "$gpg_home" --batch --import "$priv_file" >/dev/null 2>&1; then
		rm -rf "$workdir"
		echo "WARNING: Failed to import private key for $secret_name" >&2
		return 1
	fi

	if ! gpg --homedir "$gpg_home" --batch --yes --output "$plaintext_file" --decrypt "$cipher_file" >/dev/null 2>&1; then
		rm -rf "$workdir"
		echo "WARNING: Failed to decrypt existing secret $secret_name" >&2
		return 1
	fi

	local plaintext
	plaintext="$(cat "$plaintext_file")"

	# Re-encrypt and replace both secrets using the new implementation
	if ! encrypt_and_store_secret "$plaintext" "$secret_name" "$privkey_secret_name"; then
		rm -rf "$workdir"
		echo "WARNING: Failed to re-encrypt and store migrated secret $secret_name" >&2
		return 1
	fi

	rm -rf "$workdir"
	echo "Migrated secret $secret_name to armored env-compatible format"
	return 0
}

function migrate_existing_podman_secrets_if_needed() {
	echo "Checking Podman secrets for old binary-encrypted payloads..."

	migrate_podman_secret_to_armored_if_needed "db_pwd" "db_privkey"

	migrate_podman_secret_to_armored_if_needed "keystore_pwd" "keystore_privkey"
	migrate_podman_secret_to_armored_if_needed "key_alias_pwd" "key_alias_privkey"

	migrate_podman_secret_to_armored_if_needed "azure_api_key" "azure_api_privkey"
	migrate_podman_secret_to_armored_if_needed "gemini_api_key" "gemini_api_privkey"
	migrate_podman_secret_to_armored_if_needed "redis_password" "redis_privkey"
}

# ----------------------------
# Template refresh helpers
# ----------------------------

declare -A PRESERVED_VALUES=()

function require_preserved_value() {
	local key="$1"

	if [[ -z ${PRESERVED_VALUES[$key]:-} ]]; then
		echo "ERROR: Required client value could not be extracted: $key" >&2
		exit 1
	fi
}

function validate_preserved_values() {
	# Always required
	require_preserved_value "HOST_NAME"
	require_preserved_value "POSTGRES_IP"

	# Docker requires plaintext postgres password preserved
	if [[ ${CONTAINER_ENGINE:-} == "docker" ]]; then
		require_preserved_value "POSTGRES_PASSWORD"
	fi

	# Jeff-specific values required only when Jeff is enabled
	if [[ ${JEFF_ENABLED:-n} == "y" ]]; then
		require_preserved_value "AZURE_ENDPOINT"
		require_preserved_value "AZURE_API_KEY"
		require_preserved_value "AZURE_OPENAI_API_KEY"
		require_preserved_value "AZURE_OPENAI_ENDPOINT"
		require_preserved_value "GEMINI_ENDPOINT"
		require_preserved_value "GEMINI_API_KEY"
	fi
}

function extract_env_value() {
	local key="$1"
	local file="$2"

	[[ -f $file ]] || return 1

	awk -v key="$key" '
		$0 ~ "^[[:space:]]*-[[:space:]]*" key "=" {
			sub("^[[:space:]]*-[[:space:]]*" key "=", "", $0)
			print $0
			exit
		}
	' "$file"
}

function extract_host_name() {
	local file="$1"
	local val=""

	[[ -f $file ]] || return 1

	# Prefer NG_SERVER_NAME
	val="$(extract_env_value "NG_SERVER_NAME" "$file" || true)"
	if [[ -n $val ]]; then
		printf '%s' "$(trim "$val")"
		return 0
	fi

	# Fallback: derive from IRIUS_EXT_URL=https://host
	val="$(extract_env_value "IRIUS_EXT_URL" "$file" || true)"
	if [[ $val =~ ^https://(.+)$ ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 1
}

function extract_postgres_ip() {
	local file="$1"
	local db_url=""

	[[ -f $file ]] || return 1

	db_url="$(extract_env_value "IRIUS_DB_URL" "$file" || true)"
	[[ -n $db_url ]] || return 1

	# docker:
	# jdbc:postgresql://10.0.0.5:5432/iriusprod?user=iriusprod&password=secret
	# podman:
	# jdbc:postgresql://10.0.0.5:5432/iriusprod?user=iriusprod
	if [[ $db_url =~ ^jdbc:postgresql://([^:/?]+):5432/iriusprod ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 1
}

function extract_postgres_password() {
	local override_file="$1"
	local postgres_file="$2"
	local db_url=""
	local val=""

	# First try the tomcat DB URL
	if [[ -f $override_file ]]; then
		db_url="$(extract_env_value "IRIUS_DB_URL" "$override_file" || true)"
		if [[ $db_url =~ [\?\&]password=([^&]+)$ ]]; then
			printf '%s' "${BASH_REMATCH[1]}"
			return 0
		fi
	fi

	# Fallback: internal postgres compose file
	if [[ -f $postgres_file ]]; then
		val="$(awk '
			$0 ~ "^[[:space:]]*POSTGRES_PASSWORD:[[:space:]]*" {
				sub("^[[:space:]]*POSTGRES_PASSWORD:[[:space:]]*", "", $0)
				print $0
				exit
			}
		' "$postgres_file")"
		if [[ -n $val ]]; then
			printf '%s' "$(trim "$val")"
			return 0
		fi
	fi

	return 1
}

function discover_placeholders() {
	local file="$1"
	[[ -f $file ]] || return 0
	grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$file" 2>/dev/null | sed -E 's/^\$\{|\}$//g' | sort -u || true
}

function capture_preserved_values() {
	local compose_file="$1"
	local override_file="$2"
	local jeff_file="$3"
	local postgres_file="$4"
	local override_template="$5"
	local jeff_template="$6"
	local postgres_template="$7"

	local all_placeholders=()
	local p

	mapfile -t all_placeholders < <(
		{
			[[ -n $override_template ]] && discover_placeholders "$override_template"
			[[ -n $jeff_template ]] && discover_placeholders "$jeff_template"
			[[ -n $postgres_template ]] && discover_placeholders "$postgres_template"
		} | sort -u
	)

	if [[ ${#all_placeholders[@]} -eq 0 ]]; then
		echo "ERROR: No placeholders discovered from templates." >&2
		echo "  override_template=$override_template" >&2
		echo "  jeff_template=$jeff_template" >&2
		echo "  postgres_template=$postgres_template" >&2
		exit 1
	fi

	echo "Preserving client-specific values from current compose files..."

	for p in "${all_placeholders[@]}"; do
		case "$p" in
			HOST_NAME)
				PRESERVED_VALUES["$p"]="$(extract_host_name "$override_file" || true)"
				;;
			POSTGRES_IP)
				PRESERVED_VALUES["$p"]="$(extract_postgres_ip "$override_file" || true)"
				;;
			POSTGRES_PASSWORD)
				PRESERVED_VALUES["$p"]="$(extract_postgres_password "$override_file" "$postgres_file" || true)"
				;;
			GEMINI_ENDPOINT)
				[[ -n $jeff_file ]] && PRESERVED_VALUES["$p"]="$(extract_env_value "GEMINI_API_BASE" "$jeff_file" || true)"
				;;
			AZURE_ENDPOINT | AZURE_API_KEY | AZURE_OPENAI_API_KEY | AZURE_OPENAI_ENDPOINT | GEMINI_API_KEY | REDIS_PASSWORD)
				[[ -n $jeff_file ]] && PRESERVED_VALUES["$p"]="$(extract_env_value "$p" "$jeff_file" || true)"
				;;
			*)
				PRESERVED_VALUES["$p"]="$(extract_env_value "$p" "$override_file" || true)"
				[[ -z ${PRESERVED_VALUES[$p]} ]] && [[ -n $jeff_file ]] && PRESERVED_VALUES["$p"]="$(extract_env_value "$p" "$jeff_file" || true)"
				[[ -z ${PRESERVED_VALUES[$p]} ]] && PRESERVED_VALUES["$p"]="$(extract_env_value "$p" "$compose_file" || true)"

				if [[ -z ${PRESERVED_VALUES[$p]} ]]; then
					echo "WARNING: No value found for placeholder: $p"
				fi
				;;
		esac
	done

	echo "Captured values:"
	for p in "${all_placeholders[@]}"; do
		if [[ -n ${PRESERVED_VALUES[$p]:-} ]]; then
			echo "  - $p=[set]"
		else
			echo "  - $p=[empty/not found]"
		fi
	done
}

function copy_templates_to_final_locations() {
	local override_template="$1"
	local override_file="$2"
	local jeff_template="$3"
	local jeff_file="$4"
	local compose_template="$5"
	local compose_file="$6"
	local postgres_template="$7"
	local postgres_file="$8"

	mkdir -p "$(dirname "$override_file")"

	cp "$override_template" "$override_file"
	cp "$compose_template" "$compose_file"

	if [[ -n $jeff_template && -f $jeff_template ]]; then
		cp "$jeff_template" "$jeff_file"
	fi

	if [[ -f $postgres_template ]]; then
		cp "$postgres_template" "$postgres_file"
	fi

	echo "Copied fresh templates into place."
}

function replace_placeholder_in_file() {
	local file="$1"
	local var_name="$2"
	local var_value="$3"

	[[ -f $file ]] || return 0

	VAR_NAME="$var_name" VAR_VALUE="$var_value" perl -0pi -e '
		s/\$\{\Q$ENV{VAR_NAME}\E\}/$ENV{VAR_VALUE}/g
	' "$file"
}

function restore_preserved_values() {
	local override_file="$1"
	local jeff_file="$2"
	local postgres_file="$3"

	local p
	for p in "${!PRESERVED_VALUES[@]}"; do
		[[ -n ${PRESERVED_VALUES[$p]} ]] || continue

		replace_placeholder_in_file "$override_file" "$p" "${PRESERVED_VALUES[$p]}"
		replace_placeholder_in_file "$jeff_file" "$p" "${PRESERVED_VALUES[$p]}"
		replace_placeholder_in_file "$postgres_file" "$p" "${PRESERVED_VALUES[$p]}"
	done

	echo "Re-applied preserved client values to refreshed compose files."
}

function refresh_generated_compose_files_from_templates() {
	PRESERVED_VALUES=()

	local compose_dir="$1"
	local engine="$2"

	local override_template="../templates/$engine/$engine-compose.override.tpl"
	local override_file="../$engine/$engine-compose.override.yml"
	local compose_template="../templates/$engine/$engine-compose.tpl"
	local compose_file="../$engine/$engine-compose.yml"
	local postgres_template="../templates/$engine/$engine-compose.postgres.tpl"
	local postgres_file="../$engine/$engine-compose.postgres.yml"

	local jeff_template=""
	local jeff_file=""

	if [[ ${JEFF_ENABLED:-n} == "y" ]]; then
		jeff_template="../templates/$engine/$engine-compose.jeff.tpl"
		jeff_file="../$engine/$engine-compose.jeff.yml"
	fi

	capture_preserved_values \
		"$compose_file" \
		"$override_file" \
		"$jeff_file" \
		"$postgres_file" \
		"$override_template" \
		"$jeff_template" \
		"$postgres_template"

	validate_preserved_values

	copy_templates_to_final_locations \
		"$override_template" \
		"$override_file" \
		"$jeff_template" \
		"$jeff_file" \
		"$compose_template" \
		"$compose_file" \
		"$postgres_template" \
		"$postgres_file"

	restore_preserved_values \
		"$override_file" \
		"$jeff_file" \
		"$postgres_file"
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

function copy_with_fullref() {
	local src_ref="$1"  # e.g. docker.io/continuumsecurity/iriusrisk-prod:startleft
	local out_name="$2" # e.g. docker.io_continuumsecurity_iriusrisk-prod_startleft.oci.tar

	local src_transport=""
	if podman image exists "$src_ref"; then
		src_transport="containers-storage:$src_ref"
	else
		src_transport="docker://$src_ref"
	fi

	mkdir -p "$BDIR/images"

	echo "Saving $src_transport -> images/$out_name (embed full ref)"
	if [[ $src_transport == docker://* ]]; then
		# hitting the registry: include auth explicitly
		skopeo copy --all --insecure-policy "${AUTHARGS[@]}" \
			"$src_transport" \
			"oci-archive:$BDIR/images/$out_name:$src_ref"
	else
		# from local storage: no auth needed
		skopeo copy --insecure-policy \
			"$src_transport" \
			"oci-archive:$BDIR/images/$out_name:$src_ref"
	fi
}

function save_local_with_fullref() {
	local ref="$1" fname="$2"
	echo "Saving local: $ref -> images/$fname (embed full ref)"
	skopeo copy --insecure-policy \
		"containers-storage:$ref" \
		"oci-archive:$BDIR/images/$fname:$ref"
}

# —————————————————————————————————————————————————————————————
# Jeff functions
# —————————————————————————————————————————————————————————————

function check_gemini_api() {
	local endpoint="$1"
	local api_key="$2"
	local tmp_out status

	tmp_out=$(mktemp)

	status=$(curl -sS -o "$tmp_out" -w "%{http_code}" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $api_key" \
		-X POST \
		-d '{
			"model": "gemini-2.5-flash",
			"messages": [
				{"role": "user", "content": "Reply with exactly OK"}
			],
			"max_tokens": 5
		}' \
		"${endpoint%/}/chat/completions")

	if [[ $status == "200" ]]; then
		echo "Gemini API connectivity OK"
	else
		msg="ERROR: Gemini API check failed (HTTP $status). Check GEMINI_ENDPOINT and GEMINI_API_KEY"
		echo "$msg"
		ERRORS+=("$msg")
		echo "Gemini response snippet:"
		head -c 300 "$tmp_out"
		echo
	fi

	rm -f "$tmp_out"
}

function check_azure_endpoint() {
	local endpoint="$1"
	local api_key="$2"
	local tmp_out status

	tmp_out=$(mktemp)

	status=$(curl -sS -o "$tmp_out" -w "%{http_code}" \
		-H "api-key: $api_key" \
		-I \
		"${endpoint%/}/")

	case "$status" in
		200 | 204 | 301 | 302 | 401 | 403 | 404)
			echo "Azure endpoint reachable at $endpoint"
			echo "Azure check is partial only: deployment-level inference cannot be tested without deployment name"
			;;
		000)
			msg="ERROR: Could not reach Azure endpoint at $endpoint (DNS/TLS/network failure)"
			echo "$msg"
			ERRORS+=("$msg")
			;;
		*)
			msg="WARNING: Azure endpoint probe returned HTTP $status at $endpoint"
			echo "$msg"
			WARNINGS+=("$msg")
			;;
	esac

	rm -f "$tmp_out"
}

function prompt_jeff_config() {
	if [[ ${JEFF_ENABLED:-n} != "y" ]]; then
		return 0
	fi

	AZURE_ENDPOINT=$(prompt_nonempty "Enter the Azure endpoint for Jeff AI assistant")
	AZURE_API_KEY=$(prompt_nonempty "Enter the Azure API key for Jeff AI assistant")
	GEMINI_ENDPOINT=$(prompt_nonempty "Enter the Gemini endpoint for Jeff AI assistant")
	GEMINI_API_KEY=$(prompt_nonempty "Enter the Gemini API key for Jeff AI assistant")

	export AZURE_ENDPOINT AZURE_API_KEY GEMINI_ENDPOINT GEMINI_API_KEY
}

function update_base_override_env() {
	local override_file="$1"
	local host_name="$2"
	local irius_ext_url="$3"
	local jdbc_url="$4"

	if [[ ! -f $override_file ]]; then
		echo "ERROR: $override_file not found. Please ensure you have cloned the repo and have the override template."
		exit 1
	fi

	sed -i "s|NG_SERVER_NAME=.*|NG_SERVER_NAME=$host_name|g" "$override_file"
	sed -i "s|IRIUS_EXT_URL=.*|IRIUS_EXT_URL=$irius_ext_url|g" "$override_file"

	# remove any existing DB URL line before re-inserting
	sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_DB_URL=/d' "$override_file"

	awk -v db_url="      - IRIUS_DB_URL=$jdbc_url" '
	  BEGIN {tomcat=0}
	  /tomcat:/ {print; tomcat=1; next}
	  tomcat && /environment:/ {
	      print
	      print db_url
	      tomcat=0
	      next
	  }
	  {print}
	' "$override_file" >"${override_file}.tmp" && mv "${override_file}.tmp" "$override_file"

	echo "Updated base settings in $override_file"
}

function enable_jeff_override_env() {
	local override_file="$1"

	if [[ ! -f $override_file ]]; then
		echo "ERROR: $override_file not found. Please ensure you have cloned the repo and have the override template."
		exit 1
	fi

	# remove existing Jeff lines first
	sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_AI_URL=/d' "$override_file"
	sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_AI_ASH_URL=/d' "$override_file"
	sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_AI_HAVEN_URL=/d' "$override_file"

	awk '
	  BEGIN {tomcat=0}
	  /tomcat:/ {print; tomcat=1; next}
	  tomcat && /environment:/ {
	      print
	      print "      - IRIUS_AI_URL=http://jeff:8008"
	      print "      - IRIUS_AI_ASH_URL=http://ash:8009"
	      print "      - IRIUS_AI_HAVEN_URL=http://haven:8012"
	      tomcat=0
	      next
	  }
	  {print}
	' "$override_file" >"${override_file}.tmp" && mv "${override_file}.tmp" "$override_file"

	echo "Enabled Jeff settings in $override_file"
}

function configure_jeff_file() {
	local jeff_file="$1"

	if [[ ! -f $jeff_file ]]; then
		echo "ERROR: $jeff_file not found. Please ensure you have cloned the repo and have the Jeff template."
		exit 1
	fi

	echo "Generating random Redis password for Jeff setup."
	REDIS_PASSWORD="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
	export REDIS_PASSWORD

	echo "Updating $jeff_file"

	sed -i "s|AZURE_ENDPOINT=.*|AZURE_ENDPOINT=$AZURE_ENDPOINT|g" "$jeff_file"
	sed -i "s|AZURE_OPENAI_ENDPOINT=.*|AZURE_OPENAI_ENDPOINT=$AZURE_ENDPOINT|g" "$jeff_file"
	sed -i "s|GEMINI_API_BASE=.*|GEMINI_API_BASE=$GEMINI_ENDPOINT|g" "$jeff_file"

	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		sed -i "s|AZURE_API_KEY=.*|AZURE_API_KEY=$AZURE_API_KEY|g" "$jeff_file"
		sed -i "s|AZURE_OPENAI_API_KEY=.*|AZURE_OPENAI_API_KEY=$AZURE_API_KEY|g" "$jeff_file"
		sed -i "s|GEMINI_API_KEY=.*|GEMINI_API_KEY=$GEMINI_API_KEY|g" "$jeff_file"

		escaped_redis_password=$(printf '%s\n' "$REDIS_PASSWORD" | sed 's/[&/\]/\\&/g')
		sed -i "s|\"\${REDIS_PASSWORD}\"|\"$escaped_redis_password\"|g" "$jeff_file"
		sed -i "s|\${REDIS_PASSWORD}|$escaped_redis_password|g" "$jeff_file"
	else
		sed -i '/AZURE_API_KEY=/d' "$jeff_file"
		sed -i '/AZURE_OPENAI_API_KEY=/d' "$jeff_file"
		sed -i '/GEMINI_API_KEY=/d' "$jeff_file"
		sed -i '/REDIS_PASSWORD=/d' "$jeff_file"

		encrypt_and_store_secret "$AZURE_API_KEY" "azure_api_key" "azure_api_privkey"
		encrypt_and_store_secret "$GEMINI_API_KEY" "gemini_api_key" "gemini_api_privkey"
		encrypt_and_store_secret "$REDIS_PASSWORD" "redis_password" "redis_privkey"
	fi

	echo "Updated $jeff_file"
}
