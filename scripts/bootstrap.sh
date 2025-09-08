#!/usr/bin/env bash
set -e

REPO_URL="https://github.com/iriusrisk/onprem-templates.git"
BRANCH="${BRANCH:-main}"
REPO_DIR="onprem-templates"
SCRIPTS_SUBDIR="scripts"

echo "== IriusRisk Bootstrap =="
echo "Repo:    $REPO_URL"
echo "Branch:  $BRANCH"

if command -v git &>/dev/null; then
	echo "git found."
else
	echo "git not found. Installing..."
	if command -v apt-get &>/dev/null; then
		sudo apt-get update
		sudo apt-get install -y git
	elif command -v dnf &>/dev/null; then
		sudo dnf install -y git
	else
		echo "Please install git manually." >&2
		exit 1
	fi
fi

# Clone if missing, otherwise update
if [[ ! -d "$REPO_DIR" ]]; then
	echo "Cloning repo $REPO_URL (branch: $BRANCH)..."
	git clone --branch "$BRANCH" --single-branch "$REPO_URL"
else
	echo "Repo already cloned. Updating to latest on branch $BRANCH..."
	cd "$REPO_DIR"
	git fetch origin "$BRANCH"
	git checkout "$BRANCH"
	git pull origin "$BRANCH"
	cd ..
fi

# Change to scripts directory
cd "$REPO_DIR/$SCRIPTS_SUBDIR"

# Run one-click (pass through any args)
./one-click.sh "$@"
