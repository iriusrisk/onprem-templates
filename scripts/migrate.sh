#!/usr/bin/env bash
# Migrate an existing manual IriusRisk install (single compose in ~/docker or ~/podman)
# into the automation repo layout (onprem-templates/<engine>/...),
# carrying over config (NG_SERVER_NAME, IRIUS_DB_URL, IRIUS_EXT_URL),
# SAML passwords (if present), and copying cert/SAML files.

set -e -o pipefail
trap 'echo "ERROR: Script failed at line $LINENO"; exit 1' ERR

source functions.sh

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"
echo "IriusRisk Migration to Automation Repo"
echo "---------------------------------------"
# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_PATH/.." && pwd)"
cd "$SCRIPT_PATH"
echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Detect container engine & Postgres option
# —————————————————————————————————————————————————————————————
prompt_engine
COMPOSE_TOOL="$CONTAINER_ENGINE-compose"
prompt_postgres_option migrate

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	USE_INTERNAL_PG="y"
else
	USE_INTERNAL_PG="n"
fi

SAML_ENABLED="n"

# —————————————————————————————————————————————————————————————
# 2. Locate legacy install (~/docker or ~/podman)
# —————————————————————————————————————————————————————————————
LEGACY_DIR_DEFAULT1="$HOME/docker"
LEGACY_DIR_DEFAULT2="$HOME/podman"
LEGACY_DIR=""
if [[ -f "$LEGACY_DIR_DEFAULT1/docker-compose.yml" ]]; then
	LEGACY_DIR="$LEGACY_DIR_DEFAULT1"
elif [[ -f "$LEGACY_DIR_DEFAULT2/container-compose.yml" ]]; then
	LEGACY_DIR="$LEGACY_DIR_DEFAULT2"
else
	echo "Could not auto-detect legacy install in ~/docker or ~/podman."
	LEGACY_DIR="$(prompt_nonempty "Enter the full path to the legacy install directory")"
fi
[[ -d $LEGACY_DIR ]] || die "Legacy directory not found: $LEGACY_DIR"

# Compose filename depends on client’s engine
LEGACY_COMPOSE_FILE=""
if [[ -f "$LEGACY_DIR/docker-compose.yml" ]]; then
	LEGACY_COMPOSE_FILE="$LEGACY_DIR/docker-compose.yml"
elif [[ -f "$LEGACY_DIR/container-compose.yml" ]]; then
	LEGACY_COMPOSE_FILE="$LEGACY_DIR/container-compose.yml"
else
	die "No docker-compose.yml or container-compose.yml found in $LEGACY_DIR"
fi

echo "Legacy compose: $LEGACY_COMPOSE_FILE"
echo

# —————————————————————————————————————————————————————————————
# 3. Backups — reuse shared helper (sets TS, VERSION, BDIR, OUT_DB)
# —————————————————————————————————————————————————————————————
backup_db

# Compose backup (legacy)
TMP_COMPOSE_TAR="/tmp/irius.compose.$TS.tar.gz"
OUT_COMPOSE_TAR="$BDIR/irius.compose.$VERSION.tar.gz"
(
	cd "$LEGACY_DIR"
	tar -czf "$TMP_COMPOSE_TAR" "$(basename "$LEGACY_COMPOSE_FILE")" ./*.pem ./*.crt ./*.cer ./*.key 2>/dev/null || true
)
rm -f "$BDIR"/irius.compose.*.tar.gz || true
mv -f "$TMP_COMPOSE_TAR" "$OUT_COMPOSE_TAR"
echo "Compose backup saved to: $OUT_COMPOSE_TAR"
echo

# —————————————————————————————————————————————————————————————
# 4. Parse legacy compose for required values (yq if present; awk fallback)
# —————————————————————————————————————————————————————————————
FILE="$LEGACY_COMPOSE_FILE"
have_yq=0
command -v yq >/dev/null 2>&1 && have_yq=1

NG_SERVER_NAME=""
IRIUS_DB_URL=""
IRIUS_EXT_URL=""
KEYSTORE_PASSWORD=""
KEY_ALIAS_PASSWORD=""

if [[ $have_yq -eq 1 ]]; then
	# yq path handles list-form OR map-form environment
	NG_SERVER_NAME="$(yq -r '
    .services.nginx.environment as $e |
    ( $e.NG_SERVER_NAME // ( $e[]? | select(type=="string") | select(test("^NG_SERVER_NAME=")) | sub("^NG_SERVER_NAME=";"") ) )
  ' "$FILE" 2>/dev/null | head -n1 || true)"

	IRIUS_DB_URL="$(yq -r '
    .services.tomcat.environment as $e |
    ( $e.IRIUS_DB_URL // ( $e[]? | select(type=="string") | select(test("^IRIUS_DB_URL=")) | sub("^IRIUS_DB_URL=";"") ) )
  ' "$FILE" 2>/dev/null | head -n1 || true)"

	IRIUS_EXT_URL="$(yq -r '
    .services.tomcat.environment as $e |
    ( $e.IRIUS_EXT_URL // ( $e[]? | select(type=="string") | select(test("^IRIUS_EXT_URL=")) | sub("^IRIUS_EXT_URL=";"") ) )
  ' "$FILE" 2>/dev/null | head -n1 || true)"

	KEYSTORE_PASSWORD="$(yq -r '
    .services.tomcat.environment as $e |
    ( $e.KEYSTORE_PASSWORD // ( $e[]? | select(type=="string") | select(test("^KEYSTORE_PASSWORD=")) | sub("^KEYSTORE_PASSWORD=";"") ) )
  ' "$FILE" 2>/dev/null | head -n1 || true)"

	KEY_ALIAS_PASSWORD="$(yq -r '
    .services.tomcat.environment as $e |
    ( $e.KEY_ALIAS_PASSWORD // ( $e[]? | select(type=="string") | select(test("^KEY_ALIAS_PASSWORD=")) | sub("^KEY_ALIAS_PASSWORD=";"") ) )
  ' "$FILE" 2>/dev/null | head -n1 || true)"
else
	# awk fallback (list-form environment only)
	get_env_val() { # SVC KEY
		local svc="$1" key="$2"
		awk -v SVC="$svc" -v KEY="$key" '
      BEGIN{in_services=0; in_svc=0; in_env=0; svc_indent=-1}
      /^[[:space:]]*services:[[:space:]]*$/ {in_services=1; next}
      in_services {
        # detect service header and its indent
        if (match($0, /^([[:space:]]*)([A-Za-z0-9_-]+):[[:space:]]*$/, m)) {
          curr=m[2]; curr_indent=length(m[1])
          # leaving previous service?
          if (in_svc && curr_indent<=svc_indent) { in_svc=0; in_env=0 }
          # entering target service?
          if (curr==SVC) { in_svc=1; in_env=0; svc_indent=curr_indent; next }
        }
        # inside target service: environment list
        if (in_svc && /^[[:space:]]*environment:[[:space:]]*$/) { in_env=1; next }
        # exit env list on next key at same level
        if (in_env && /^[[:space:]]*[A-Za-z0-9_-]+:/) { in_env=0 }
        # parse "- KEY=VALUE"
        if (in_svc && in_env && match($0, /^[[:space:]]*-[[:space:]]*([^=[:space:]]+)=([^\r\n]*)$/, m)) {
          if (m[1]==KEY) { print m[2]; exit }
        }
      }
    ' "$FILE"
	}

	NG_SERVER_NAME="$(get_env_val nginx NG_SERVER_NAME || true)"
	IRIUS_DB_URL="$(get_env_val tomcat IRIUS_DB_URL || true)"
	IRIUS_EXT_URL="$(get_env_val tomcat IRIUS_EXT_URL || true)"
	KEYSTORE_PASSWORD="$(get_env_val tomcat KEYSTORE_PASSWORD || true)"
	KEY_ALIAS_PASSWORD="$(get_env_val tomcat KEY_ALIAS_PASSWORD || true)"
fi

# Unescape legacy DB URL if backslashes were used (e.g., jdbc\:postgresql\:// -> jdbc:postgresql://)
if declare -F unescape >/dev/null 2>&1; then
	IRIUS_DB_URL="$(printf '%s' "$IRIUS_DB_URL" | unescape)"
else
	IRIUS_DB_URL="$(printf '%s' "$IRIUS_DB_URL" | sed -E 's/\\:/:/g; s/\\=/=/g; s/\\\?/?/g')"
fi

# Create DB secrets if using podman
if [[ $CONTAINER_ENGINE == "podman" ]]; then
	DB_PASS="$(printf '%s' "$IRIUS_DB_URL" | awk -F'password=' '{print $2}')"
	encrypt_and_store_secret "$DB_PASS" "db_pwd" "db_privkey"
fi

# Remove password from legacy DB URL for Podman (assumes it's the last param)
if [[ $CONTAINER_ENGINE == "podman" ]]; then
	IRIUS_DB_URL="${IRIUS_DB_URL%%&password=*}"
fi

# SAML detection
if [[ -n ${KEYSTORE_PASSWORD:-} || -n ${KEY_ALIAS_PASSWORD:-} ]]; then
	SAML_ENABLED="y"
fi

echo "Parsing legacy compose for config values ..."
echo "  NG_SERVER_NAME   : ${NG_SERVER_NAME:-<not found>}"
echo "  IRIUS_DB_URL     : ${IRIUS_DB_URL:-<not found>}"
echo "  IRIUS_EXT_URL    : ${IRIUS_EXT_URL:-<not found>}"
if [[ $SAML_ENABLED == "y" ]]; then
	echo "  SAML detected    : yes"
	echo "  KEYSTORE_PASSWORD: ${KEYSTORE_PASSWORD:-<empty>}"
	echo "  KEY_ALIAS_PASSWORD: ${KEY_ALIAS_PASSWORD:-<empty>}"
else
	echo "  SAML detected    : no"
fi
echo

# ------------------------------------------------------------
# 5. Copy certs + SAML files from legacy into the new engine dir
# ------------------------------------------------------------
CONTAINER_DIR="$REPO_ROOT/$CONTAINER_ENGINE"

# --- Certificates (nginx + tomcat) ---
copy_required "cert.pem" "$CONTAINER_DIR/cert.pem" \
	"$LEGACY_DIR/cert.pem" "cert.pem"
copy_required "key.pem" "$CONTAINER_DIR/key.pem" \
	"$LEGACY_DIR/key.pem" "ec_private.pem" "key.pem"
copy_required "ec_private.pem" "$CONTAINER_DIR/ec_private.pem" \
	"$LEGACY_DIR/ec_private.pem" "ec_private.pem"

# --- SAML files (only if enabled) ---
if [[ $SAML_ENABLED == "y" ]]; then
	echo "SAML enabled: copying SAML artifacts..."

	# All three are usually required when SAML is on
	copy_required "SAMLv2-config.groovy" "$CONTAINER_DIR/SAMLv2-config.groovy" \
		"$LEGACY_DIR/SAMLv2-config.groovy" "SAMLv2-config.groovy"

	copy_required "idp.xml" "$CONTAINER_DIR/idp.xml" \
		"$LEGACY_DIR/idp.xml" "idp.xml"

	copy_required "iriusrisk-sp.jks" "$CONTAINER_DIR/iriusrisk-sp.jks" \
		"$LEGACY_DIR/iriusrisk-sp.jks" "iriusrisk-sp.jks"
fi

# Final sanity: ensure the files that MUST be files are indeed files
for must in "$CONTAINER_DIR/cert.pem" "$CONTAINER_DIR/key.pem"; do
	[[ -f $must ]] || die "required file missing: $must"
done

if [[ $SAML_ENABLED == "y" ]]; then
	for must in "$CONTAINER_DIR/SAMLv2-config.groovy" "$CONTAINER_DIR/idp.xml" "$CONTAINER_DIR/iriusrisk-sp.jks"; do
		[[ -f $must ]] || die "required SAML file missing: $must"
	done
fi

echo "Copy step completed."

# —————————————————————————————————————————————————————————————
# 6. Update automation compose overrides with extracted values
# —————————————————————————————————————————————————————————————
OVR="$CONTAINER_DIR/$CONTAINER_ENGINE-compose.override.yml"
SAML_OVR="$CONTAINER_DIR/$CONTAINER_ENGINE-compose.saml.yml"

[[ -f $OVR ]] || die "Expected override file not found: $OVR"

echo "Updating overrides in: $OVR"

# Replace full lines for safety; falls back to generic if placeholders differ
if [[ -n ${NG_SERVER_NAME:-} ]]; then
	replace_env_value "$OVR" "NG_SERVER_NAME" $NG_SERVER_NAME
fi

if [[ -n ${IRIUS_DB_URL:-} ]]; then
	replace_env_value "$OVR" "IRIUS_DB_URL" $IRIUS_DB_URL
fi

if [[ -n ${IRIUS_EXT_URL:-} ]]; then
	replace_env_value "$OVR" "IRIUS_EXT_URL" $IRIUS_EXT_URL
fi

echo "Override updates complete."
echo

# SAML override updates (only if passwords detected AND file exists)
if [[ $SAML_ENABLED == "y" && -f $SAML_OVR ]]; then
	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		echo "Updating SAML override: $SAML_OVR"
		if [[ -n ${KEYSTORE_PASSWORD:-} ]]; then
			replace_env_value "$SAML_OVR" "KEYSTORE_PASSWORD" $KEYSTORE_PASSWORD
		fi
		if [[ -n ${KEY_ALIAS_PASSWORD:-} ]]; then
			replace_env_value "$SAML_OVR" "KEY_ALIAS_PASSWORD" $KEY_ALIAS_PASSWORD
		fi
	elif [[ $CONTAINER_ENGINE == "podman" ]]; then
		podman secret rm keystore_pwd keystore_privkey key_alias_pwd key_alias_privkey 2>/dev/null || true
		encrypt_and_store_secret "$KEYSTORE_PASSWORD" "keystore_pwd" "keystore_privkey"
		encrypt_and_store_secret "$KEY_ALIAS_PASSWORD" "key_alias_pwd" "key_alias_privkey"
	fi
	echo "SAML override updates complete."
	echo
fi

# —————————————————————————————————————————————————————————————
# 7. Switch over: stop legacy stack, start new stack, create systemd service
# —————————————————————————————————————————————————————————————

echo "Switching stacks ..."

cd "$LEGACY_DIR"
$COMPOSE_TOOL -f $LEGACY_COMPOSE_FILE down --remove-orphans

echo
echo "Deploying new Docker Compose stack from: $CONTAINER_DIR"

deploy_stack
