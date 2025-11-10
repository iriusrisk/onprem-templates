#!/usr/bin/env bash
# Roll back IriusRisk using previously created compose + DB backups.
# Order: restore compose -> restore DB -> restart stack.
source functions.sh

set -e -o pipefail
trap 'echo "ERROR: Script failed at line $LINENO"; exit 1' ERR

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"

# Offline mode setup

OFFLINE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--offline)
			OFFLINE=1
			shift
			;;
		*)
			ARGS+=("$1")
			shift
			;;
	esac
done
set -- "${ARGS[@]:-}"

export OFFLINE

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk Rollback Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_PATH"

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Set engine and Postgres options
# —————————————————————————————————————————————————————————————
prompt_engine
COMPOSE_TOOL="$CONTAINER_ENGINE-compose"
prompt_postgres_option upgrade

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	USE_INTERNAL_PG="y"
else
	USE_INTERNAL_PG="n"
fi

# —————————————————————————————————————————————————————————————
# 2. Locate backup directory and discover available versions
# —————————————————————————————————————————————————————————————
BDIR="${BDIR:-/home/$USER/irius_backups}"
OFFLINE_BUNDLE_DIR=$BDIR

echo "Looking for backups under: $BDIR"
[[ -d $BDIR ]] || {
	echo "ERROR: Backup directory not found: $BDIR"
	exit 2
}

mapfile -t COMPOSE_BACKUPS < <(ls -1t "$BDIR"/irius.compose.*.tar.gz 2>/dev/null || true)
mapfile -t DB_BACKUPS < <(ls -1t "$BDIR"/irius.db.*.sql.gz 2>/dev/null || true)

[[ ${#COMPOSE_BACKUPS[@]} -gt 0 ]] || {
	echo "ERROR: No compose backups found in $BDIR"
	exit 3
}
[[ ${#DB_BACKUPS[@]} -gt 0 ]] || {
	echo "ERROR: No DB backups found in $BDIR"
	exit 4
}

# Extract versions and choose a default that exists for BOTH backups
extract_version() { # e.g. /path/irius.compose.4.46.9.tar.gz -> 4.46.9
	local n="$(basename "$1")"
	printf '%s\n' "$n" | sed -E 's/^irius\.(compose|db)\.([0-9]+(\.[0-9]+){0,2})\..*$/\2/'
}

declare -A HAVE_COMPOSE HAVE_DB
for f in "${COMPOSE_BACKUPS[@]}"; do
	v="$(extract_version "$f")"
	[[ -n $v ]] && HAVE_COMPOSE["$v"]=1
done
for f in "${DB_BACKUPS[@]}"; do
	v="$(extract_version "$f")"
	[[ -n $v ]] && HAVE_DB["$v"]=1
done

# Compute intersection, prefer newest by file mtime (driven by ls -t order from compose list, then db list)
CANDIDATES=()
for f in "${COMPOSE_BACKUPS[@]}"; do
	v="$(extract_version "$f")"
	if [[ -n $v && -n ${HAVE_DB[$v]:-} ]]; then
		CANDIDATES+=("$v")
	fi
done
if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
	echo "ERROR: Found compose and DB backups, but no matching versions between them."
	echo "Compose backups:"
	printf '  - %s\n' "${COMPOSE_BACKUPS[@]}"
	echo "DB backups:"
	printf '  - %s\n' "${DB_BACKUPS[@]}"
	exit 5
fi

DEFAULT_VERSION="${CANDIDATES[0]}"
read -r -p "Version to roll back to [${DEFAULT_VERSION}]: " CHOSEN_VERSION
[[ -z $CHOSEN_VERSION ]] && CHOSEN_VERSION="$DEFAULT_VERSION"

COMPOSE_TAR="$BDIR/irius.compose.$CHOSEN_VERSION.tar.gz"
DB_DUMP="$BDIR/irius.db.$CHOSEN_VERSION.sql.gz"

[[ -f $COMPOSE_TAR ]] || {
	echo "ERROR: Compose backup not found: $COMPOSE_TAR"
	exit 6
}
[[ -f $DB_DUMP ]] || {
	echo "ERROR: DB backup not found: $DB_DUMP"
	exit 7
}

echo
echo "Selected backups:"
echo "  Compose: $COMPOSE_TAR"
echo "  DB     : $DB_DUMP"
echo

# —————————————————————————————————————————————————————————————
# 3. Compute compose context and stop the stack cleanly
# —————————————————————————————————————————————————————————————
COMPOSE_OVERRIDE=$(build_compose_override "$USE_INTERNAL_PG")
COMPOSE_DIR="$SCRIPT_PATH/../$CONTAINER_ENGINE"
COMPOSE_YML="$COMPOSE_DIR/$CONTAINER_ENGINE-compose.yml"

echo "Using compose dir: $COMPOSE_DIR"
[[ -d $COMPOSE_DIR ]] || {
	echo "ERROR: Compose directory not found: $COMPOSE_DIR"
	exit 8
}
[[ -f $COMPOSE_YML ]] || echo "WARNING: $COMPOSE_YML not found yet (will be restored from tar)."

cd "$COMPOSE_DIR"

echo "Stopping current stack ..."
$COMPOSE_TOOL $COMPOSE_OVERRIDE down

# —————————————————————————————————————————————————————————————
# 4. Restore compose files from backup
# —————————————————————————————————————————————————————————————
echo "Restoring compose files from $COMPOSE_TAR -> $COMPOSE_DIR"
tar -xzf "$COMPOSE_TAR" -C "$COMPOSE_DIR"
echo "Compose restore complete."
echo

# —————————————————————————————————————————————————————————————
# 5. Ensure DB service available for restore
# —————————————————————————————————————————————————————————————
if [[ $USE_INTERNAL_PG == "y" ]]; then
	echo "Starting internal Postgres for restore ..."
	# Try via compose first (service commonly named 'postgres'); if unknown, start container directly.
	if ! $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Fxq "iriusrisk-postgres"; then
		# Best effort: try compose service 'postgres', otherwise fall back to starting by name after up
		$COMPOSE_TOOL $COMPOSE_OVERRIDE up -d postgres || true
		# If still not running, try starting the container directly (in case it exists but was stopped)
		$CONTAINER_ENGINE start iriusrisk-postgres >/dev/null 2>&1 || true
		# Final check
		if ! $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Fxq "iriusrisk-postgres"; then
			echo "ERROR: Could not start internal Postgres container 'iriusrisk-postgres'." >&2
			exit 9
		fi
	fi
	echo "Internal Postgres is running."
else
	echo "External Postgres selected; will connect directly."
fi
echo

# —————————————————————————————————————————————————————————————
# 6. Restore database
# —————————————————————————————————————————————————————————————
echo "Restoring database from $DB_DUMP ..."
if [[ $USE_INTERNAL_PG == "y" ]]; then
	# Drop and recreate schema to ensure clean restore
	$CONTAINER_ENGINE exec -u postgres "iriusrisk-postgres" \
		psql -d "iriusprod" -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO postgres; GRANT ALL ON SCHEMA public TO iriusprod;" >/dev/null

	# Stream restore
	gzip -dc "$DB_DUMP" | $CONTAINER_ENGINE exec -i -u postgres "iriusrisk-postgres" psql -d "iriusprod"

else
	DB_IP=$(prompt_nonempty "Enter the Postgres IP address (DB host)")
	DB_PASS=$(prompt_nonempty "Enter the Postgres password")
	export PGPASSWORD="$DB_PASS"

	psql -h "$DB_IP" -U "iriusprod" -d "iriusprod" -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO iriusprod;" >/dev/null
	gzip -dc "$DB_DUMP" | psql -h "$DB_IP" -U "iriusprod" -d "iriusprod"
fi
echo "Database restore complete."
echo

# —————————————————————————————————————————————————————————————
# 7. Rebuild local custom images for podman based on rollback version
# —————————————————————————————————————————————————————————————
if [[ $CONTAINER_ENGINE == "podman" && $OFFLINE -eq 0 ]]; then
	# Try to derive version from the chosen backup filenames
	# First look at compose tar name, then DB dump name
	NAME_VER=""
	for candidate in "$COMPOSE_TAR" "$DB_DUMP"; do
		b="$(basename "$candidate")"
		if [[ $b =~ ^irius\.(compose|db)\.([0-9]+(\.[0-9]+){0,2})\..*$ ]]; then
			NAME_VER="${BASH_REMATCH[2]}"
			break
		fi
	done

	# Prefer existing CHOSEN_VERSION (if set earlier), else pick from filename, else prompt
	if [[ -z ${CHOSEN_VERSION:-} ]]; then
		CHOSEN_VERSION="$NAME_VER"
	fi

	if [[ -z $CHOSEN_VERSION ]]; then
		# No version embedded in filenames; ask the user
		read -r -p "Version to rebuild custom Podman images (e.g., 4 or 4.46.9): " CHOSEN_VERSION
		if [[ -z $CHOSEN_VERSION ]]; then
			echo "ERROR: A version is required to rebuild custom images for Podman." >&2
			exit 10
		fi
	fi

	echo "Rebuilding Podman custom images for version: $CHOSEN_VERSION"
	container_registry_login
	build_podman_custom_images "$CHOSEN_VERSION"
	echo "Podman custom images rebuilt."
	echo
fi

# —————————————————————————————————————————————————————————————
# 8. Pull images referenced by restored compose and restart full stack
# —————————————————————————————————————————————————————————————
echo "Cleaning up current stack and loading rollback images"
$CONTAINER_ENGINE system prune -f

# Destroy whole IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE down

if [ "$OFFLINE" -eq 0 ]; then
	# Force download latest images
	$COMPOSE_TOOL $COMPOSE_OVERRIDE pull
else
	offline_load_images
fi

echo "Restarting stack to complete rollback"

# Spin up IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE up -d

echo
echo "Waiting for IriusRisk to become healthy (up to 60 minutes)..."
if wait_for_health 60 60; then
	POST_JSON="$(cat /tmp/irius_health.json 2>/dev/null || true)"
	POST_VERSION="$(printf '%s' "$POST_JSON" | extract_version_from_json)"
	echo "Rollback successful: IriusRisk is healthy. Detected version: ${POST_VERSION:-unknown}"
else
	die "IriusRisk did not become healthy within 60 minutes after rollback."
fi

echo
echo "Rollback complete."
echo " - Compose restored from: $COMPOSE_TAR"
echo " - DB restored from:      $DB_DUMP"
echo " - Stack is up:           $($CONTAINER_ENGINE ps --format '{{.Names}}' | wc -l) containers running"
