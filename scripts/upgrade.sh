#!/usr/bin/env bash
source functions.sh

# Fail fast and propagate failures from pipelines, unset vars, and traps.
set -e -o pipefail

# Helpful error message
trap 'echo "ERROR: Script failed at line $LINENO"; exit 1' ERR

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk Upgrade Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_PATH"

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Set engine, SAML and Postgres options
# —————————————————————————————————————————————————————————————
prompt_engine
COMPOSE_TOOL="$CONTAINER_ENGINE-compose"
prompt_postgres_option upgrade

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	USE_INTERNAL_PG="y"
else
	USE_INTERNAL_PG="n"
fi

SAML_ENABLED=$(prompt_yn "Are you using SAML?")

# —————————————————————————————————————————————————————————————
# 2. Get version for backup filenames
# —————————————————————————————————————————————————————————————
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

# —————————————————————————————————————————————————————————————
# 3. Backup DB
# —————————————————————————————————————————————————————————————
cd ~
BDIR="${BDIR:-/home/$USER/irius_backups}"
TMP_DB="/tmp/irius.db.$TS.sql.gz"
OUT_DB="$BDIR/irius.db.$VERSION.sql.gz"

echo "Preparing backup directory at: $BDIR"
mkdir -p "$BDIR"

if [[ $USE_INTERNAL_PG == "y" ]]; then
	# Ensure the postgres container is running
	if ! $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Fxq "iriusrisk-postgres"; then
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

# Keep only latest: remove old DB backups, then move new one in place and update 'latest'
rm -f "$BDIR"/irius.db.*.sql.gz || true
mv -f "$TMP_DB" "$OUT_DB"

DB_SIZE="$(du -h "$OUT_DB" | cut -f1)"
echo "DB backup completed: $DB_SIZE -> $OUT_DB"
echo

# —————————————————————————————————————————————————————————————
# 4. Backup compose files
# —————————————————————————————————————————————————————————————
COMPOSE_OVERRIDE=$(build_compose_override "$SAML_ENABLED" "$USE_INTERNAL_PG")
COMPOSE_DIR="$SCRIPT_PATH/../$CONTAINER_ENGINE"
TMP_COMPOSE_TAR="/tmp/irius.compose.$TS.tar.gz"
OUT_COMPOSE_TAR="$BDIR/irius.compose.$VERSION.tar.gz"

echo "Backing up compose files referenced in COMPOSE_OVERRIDE from: $COMPOSE_DIR"
# Parse -f arguments safely
read -r -a _parts <<<"$COMPOSE_OVERRIDE"

compose_files=()
i=0
while [[ $i -lt ${#_parts[@]} ]]; do
	if [[ ${_parts[i]} == "-f" && -n ${_parts[i + 1]:-} ]]; then
		compose_files+=("${_parts[i + 1]}")
		i=$((i + 2)) # skip the filename we just consumed
	else
		i=$((i + 1))
	fi
done

# De-duplicate
declare -A seen
uniq_files=()
for f in "${compose_files[@]}"; do
	if [[ -n $f && -z ${seen[$f]:-} ]]; then
		seen[$f]=1
		uniq_files+=("$f")
	fi
done

pushd "$COMPOSE_DIR" >/dev/null
valid_files=()
missing_files=()
for f in "${uniq_files[@]}"; do
	if [[ -f $f ]]; then
		valid_files+=("$f")
	elif [[ -f "./$f" ]]; then
		valid_files+=("./$f")
	elif [[ -f "$(basename "$f")" ]]; then
		valid_files+=("$(basename "$f")")
	elif [[ $f == /* && -f $f ]]; then
		valid_files+=("$f")
	else
		missing_files+=("$f")
	fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
	echo "WARNING: The following compose files were referenced but not found and won't be backed up:"
	for m in "${missing_files[@]}"; do echo " - $m"; done
fi

if [[ ${#valid_files[@]} -gt 0 ]]; then
	# Create tar in /tmp first
	tar -czf "$TMP_COMPOSE_TAR" "${valid_files[@]}"
	# Keep only latest compose backup
	rm -f "$BDIR"/irius.compose.*.tar.gz || true
	mv -f "$TMP_COMPOSE_TAR" "$OUT_COMPOSE_TAR"
	C_TAR_SIZE="$(du -h "$OUT_COMPOSE_TAR" | cut -f1)"
	echo "Compose files backed up: $C_TAR_SIZE -> $OUT_COMPOSE_TAR"
else
	echo "WARNING: No valid compose files found to back up."
fi
popd >/dev/null

# —————————————————————————————————————————————————————————————
# 5. Discover highest tomcat tag (Hub API v2, private repo) & update compose
# —————————————————————————————————————————————————————————————

REPO_NS="continuumsecurity"
REPO_NAME="iriusrisk-prod"
HUB_LOGIN_URL="https://hub.docker.com/v2/users/login/"
TAGS_URL_BASE="https://hub.docker.com/v2/repositories/${REPO_NS}/${REPO_NAME}/tags"
echo "Discovering tomcat tags on Docker Hub for ${REPO_NS}/${REPO_NAME} ..."

# Ensure we have a password; your helper already sets REGISTRY_PASS
[[ -z ${REGISTRY_PASS:-} ]] && prompt_registry_password

# Obtain Hub JWT (separate from docker login credential store)
HUB_TOKEN="$(
	curl -fsSL -H 'Content-Type: application/json' \
		-d "{\"username\":\"iriusrisk\",\"password\":\"${REGISTRY_PASS}\"}" \
		"${HUB_LOGIN_URL}" 2>/dev/null |
		sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
)" || true

if [[ -z $HUB_TOKEN || $HUB_TOKEN == "null" ]]; then
	echo "WARNING: Hub login failed; you can still type the version manually."
fi

# Gather tomcat-* tags from Hub API (paginate via .next)
versions=()
if [[ -n $HUB_TOKEN ]]; then
	url="${TAGS_URL_BASE}?page_size=100&name=tomcat"
	while [[ -n $url ]]; do
		page="$(curl -fsSL -H "Authorization: JWT ${HUB_TOKEN}" "$url" 2>/dev/null || true)"
		[[ -z $page ]] && break

		if command -v jq >/dev/null 2>&1; then
			# names: "tomcat-4" or "tomcat-4.46.9"
			while IFS= read -r tag; do
				[[ $tag =~ ^tomcat-([0-9]+(\.[0-9]+){0,2})$ ]] && versions+=("${tag#tomcat-}")
			done < <(printf '%s' "$page" | jq -r '.results[].name' 2>/dev/null)
			next="$(printf '%s' "$page" | jq -r '.next // empty')"
		else
			while IFS= read -r tag; do
				tag="${tag#\"}"
				tag="${tag%\"}"
				[[ $tag =~ ^tomcat-([0-9]+(\.[0-9]+){0,2})$ ]] && versions+=("${tag#tomcat-}")
			done < <(printf '%s' "$page" | grep -o '"name"[[:space:]]*:[[:space:]]*"tomcat-[^"]*"' | sed -E 's/.*"tomcat-/tomcat-/' | sed -E 's/"$//')
			next="$(printf '%s' "$page" | grep -o '"next"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:"(.*)"/\1/')"
			[[ $next == "null" ]] && next=""
		fi

		url="$next"
	done
fi

# Choose default: prefer full semver X.Y.Z; else highest major
DEFAULT_VERSION=""
if [[ ${#versions[@]} -gt 0 ]]; then
	full=() majors=()
	for v in "${versions[@]}"; do
		[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && full+=("$v") || majors+=("$v")
	done
	if [[ ${#full[@]} -gt 0 ]]; then
		mapfile -t sorted_full < <(printf '%s\n' "${full[@]}" | sort -uV)
		DEFAULT_VERSION="${sorted_full[-1]}"
	elif [[ ${#majors[@]} -gt 0 ]]; then
		mapfile -t sorted_maj < <(printf '%s\n' "${majors[@]}" | sort -u)
		DEFAULT_VERSION="${sorted_maj[-1]}"
	fi
fi
[[ -z $DEFAULT_VERSION ]] && DEFAULT_VERSION="4"
echo "Highest available tomcat version (Hub): $DEFAULT_VERSION"

read -r -p "Version to upgrade to [${DEFAULT_VERSION}]: " CHOSEN_VERSION
[[ -z $CHOSEN_VERSION ]] && CHOSEN_VERSION="$DEFAULT_VERSION"
if [[ ! $CHOSEN_VERSION =~ ^[0-9]+$ && ! $CHOSEN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "ERROR: Version must be 'N' or 'N.N.N' (e.g., 4 or 4.46.9). You entered: $CHOSEN_VERSION" >&2
	exit 6
fi

TARGET_TAG="tomcat-$CHOSEN_VERSION"
COMPOSE_YML="$COMPOSE_DIR/$CONTAINER_ENGINE-compose.yml"
[[ -f $COMPOSE_YML ]] || {
	echo "ERROR: Compose file not found: $COMPOSE_YML" >&2
	exit 4
}

if [[ $CONTAINER_ENGINE == "docker" ]]; then
	# Update ONLY Tomcat line (matches major-only or full semver; docker.io prefix optional)
	if grep -qE '^[[:space:]]*image:[[:space:]]*(docker\.io/)?continuumsecurity/iriusrisk-prod:tomcat-[0-9.]+([[:space:]]|$)' "$COMPOSE_YML"; then
		sed -i -E \
			"s@(^[[:space:]]*image:[[:space:]]*(docker\.io/)?continuumsecurity/iriusrisk-prod:tomcat-)[0-9]+([.][0-9]+){0,2}([[:space:]]*(#.*)?\$)@\\1${CHOSEN_VERSION}\\4@" \
			"$COMPOSE_YML"
		echo "Updated tomcat image tag → docker.io/continuumsecurity/iriusrisk-prod:tomcat-${CHOSEN_VERSION}"
	else
		echo "ERROR: No tomcat image line found in $COMPOSE_YML (expected ':tomcat-<major>' or ':tomcat-<X.Y.Z>')." >&2
		exit 5
	fi
else
	echo "Compose uses localhost/tomcat-rhel; will rebuild the local image instead of sed."
fi

# —————————————————————————————————————————————————————————————
# 6. Update Startleft & Reporting Module tags from /versions/<ver>.json
# —————————————————————————————————————————————————————————————
VERSIONS_DIR="$SCRIPT_PATH/../versions"
VER_FILE="$VERSIONS_DIR/$CHOSEN_VERSION.json"

echo "Looking for version metadata: $VER_FILE"
if [[ -f $VER_FILE ]]; then
	# Extract Startleft.S and ReportingModule.S
	SL_VER="$(jq -r '.Startleft.S // empty' "$VER_FILE")"
	RM_VER="$(jq -r '.ReportingModule.S // empty' "$VER_FILE")"

	update_component_tag "startleft" "$SL_VER"
	update_component_tag "reporting-module" "$RM_VER"
else
	echo "WARNING: Version metadata file not found: $VER_FILE — skipping Startleft/Reporting Module updates."
fi

# —————————————————————————————————————————————————————————————
# 7. Rebuild local base images for podman
# —————————————————————————————————————————————————————————————

if [[ $CONTAINER_ENGINE == "podman" ]]; then
	# Rebuild local images based on the chosen version (default 4)
	build_podman_custom_images "$CHOSEN_VERSION"
fi

# —————————————————————————————————————————————————————————————
# 8. Update the stack
# —————————————————————————————————————————————————————————————

echo "Cleaning up current stack and pulling latest images"
$CONTAINER_ENGINE system prune -f

cd "$COMPOSE_DIR"

# Destroy whole IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE down

# Force download latest images
$COMPOSE_TOOL $COMPOSE_OVERRIDE pull

echo "Restarting stack to complete upgrade"

# Spin up IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE up -d

echo "Stack restarted with latest images"
