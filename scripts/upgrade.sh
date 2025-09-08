#!/usr/bin/env bash
source functions.sh

# Fail fast and propagate failures from pipelines, unset vars, and traps.
set -e

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

SAML_ENABLED=$(prompt_yn "Are you using SAML?")

# —————————————————————————————————————————————————————————————
# 2. Backup DB
# —————————————————————————————————————————————————————————————

cd ~
BDIR="${BDIR:-/home/$USER/irius_backups}"
TS="${TS:-$(date +%s)}"
TMP="/tmp/irius.$TS.sql.gz"
OUT="$BDIR/irius.$TS.sql.gz"
LATEST_LINK="$BDIR/irius.latest.sql.gz"

echo "Preparing backup directory at: $BDIR"
mkdir -p "$BDIR"

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	USE_INTERNAL_PG="y"
	# Ensure the postgres container is running
	if ! $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Fxq "iriusrisk-postgres"; then
		echo "ERROR: Container 'iriusrisk-postgres' is not running. Start it and retry." >&2
		exit 2
	fi

	echo "Backing up database iriusprod from container 'iriusrisk-postgres' to $OUT ..."

	# Dump INSIDE the container; pipefail ensures any stage failure aborts
	$CONTAINER_ENGINE exec -u postgres "iriusrisk-postgres" \
		pg_dump -d "iriusprod" |
		gzip >"$TMP"
else
	USE_INTERNAL_PG="n"
	DB_IP=$(prompt_nonempty "Enter the Postgres IP address (DB host)")
	DB_PASS=$(prompt_nonempty "Enter the Postgres password")
	PGPASSWORD="$DB_PASS" pg_dump -h "$DB_IP" -U "iriusprod" -d "iriusprod" |
		gzip >"$TMP"
fi
# Sanity check: non-empty output
if [[ ! -s $TMP ]]; then
	echo "ERROR: Backup file is empty (pg_dump likely failed)." >&2
	exit 3
fi

# Move into place and update 'latest' atomically
mv -f "$TMP" "$OUT"
ln -sfn "irius.$TS.sql.gz" "$LATEST_LINK"

# Confirmation with size
SIZE="$(du -h "$OUT" | cut -f1)"
echo "Backup completed: $SIZE -> $OUT"
echo

# —————————————————————————————————————————————————————————————
# 3. Restart stack
# —————————————————————————————————————————————————————————————

echo "Cleaning up current stack and pulling latest images"

# Remove all unused containers, networks, images (both dangling and unreferenced)
docker system prune -f

COMPOSE_OVERRIDE=$(build_compose_override "$SAML_ENABLED" "$USE_INTERNAL_PG")

cd "$SCRIPT_PATH/../$CONTAINER_ENGINE"

# Destroy whole IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE down

# Force download latest images
$COMPOSE_TOOL $COMPOSE_OVERRIDE pull

# Spin up IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE up -d

echo "Stack restarted with latest images"
