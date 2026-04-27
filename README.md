# IriusRisk On-Prem Automation Setup

This repository includes **automation scripts** to fully set up an IriusRisk on-prem deployment on a fresh server.  
They install dependencies, configure PostgreSQL, generate certificates, and deploy containers via Docker or Podman in rootless mode.

⚠️ **Important Warnings**  
These scripts are intended to be run on a **completely fresh machine**.  
If an existing PostgreSQL installation (standalone, containerized, or otherwise) is present on the **same machine**, and you choose to set up PostgreSQL on the same machine, these scripts will either:

- Fail with errors, **or**
- Wipe the existing PostgreSQL setup, including its databases.

Do **not** run these scripts on a machine that already has a PostgreSQL database you care about.

⚠️ **First upgrade after 20/03/2026? Read the note under the Upgrading IriusRisk section before running `git pull`.**

---

## 🔀 Quickstart Flow

```text
   Fresh server
        │
        ▼
   bootstrap.sh   (or one-click.sh if repo already cloned)
        │
        ├──► preflight.sh    (checks dependencies & environment)
        │
        ├──► setup-wizard.sh (asks questions, updates configs)
        │
        └──► full deployment (DB + services + containers)
```

- **Use `bootstrap.sh`** on a brand-new machine.  
- **Use `one-click.sh`** if you’ve already cloned the repo and are in `scripts/`.  
- `preflight.sh` and `setup-wizard.sh` can be run standalone for checks/configuration.

---

## 📂 Automation Scripts Overview

### `bootstrap.sh`
- Simplest entrypoint for a brand-new server.
- Installs `git` if missing, clones this repository, and launches `one-click.sh`.
- Best for **remote installations** where nothing is pre-installed.

### `one-click.sh`

-   The main **end-to-end installer**.
-   Ensures you're in the right directory, detects the Linux
    distribution, selects the appropriate container engine
    automatically, sets up PostgreSQL (internal container or external
    DB), and then deploys IriusRisk.
-   Calls other helper scripts (`preflight.sh`, `setup-wizard.sh`) as
    needed.
-   **Optionally installs Jeff (AI assistant)** during setup via an
    interactive prompt.
-   Recommended if you've already cloned the repo and are inside the
    `scripts/` directory.

### `setup-wizard.sh`
- Runs interactively and asks questions about:
  - PostgreSQL setup (internal or external)
  - Hostname and external URLs
  - Azure and Gemini endpoints and API keys if installing Jeff
- Updates configuration files accordingly.
- Can be run standalone if you want to just configure and not deploy.

### `preflight.sh`
- Runs environment checks.
- Detects missing dependencies (git, Java, psql, jq, container engine).
- Reports warnings (e.g., missing passwords).
- Exits with error if critical requirements are unmet.
- Safe to run standalone for validation before a real install.

---

## 🚀 Typical Workflow (Fresh Setup)

1. **Provision a new Linux VM** (RHEL 9+, CentOS-based, Debian-based, or AWS Linux-based).  
   Ensure you have sudo privileges.

2. **Run the bootstrap installer**:
   ```bash
    curl -fsSL https://raw.githubusercontent.com/iriusrisk/onprem-templates/main/scripts/bootstrap.sh -o bootstrap.sh
    chmod +x bootstrap.sh
    ./bootstrap.sh
   ```

   This will:
   - Install `git` if needed
   - Clone this repository
   - Launch `one-click.sh`

3. **Answer interactive prompts**:
   - Select container registry (default or custom)
   - Decide how to set up PostgreSQL (internal container or external DB)
   - Choose whether to install Jeff (AI assistant)
   - Provide hostname
   - Provide Azure and Gemini endpoints and API keys if installing Jeff
   - Confirm deployment

4. **Deployment starts**:
   - Dependencies are installed
   - PostgreSQL is set up
   - Configuration is applied
   - Containers are deployed (via the detected container engine)
   - Systemd services are created (so containers restart automatically on reboot)

5. **Post-deployment (Docker only)**:  
   If your distribution uses Docker as the container engine, the installer will add your user to the `docker` group.  
   ⚠️ You must **log out and log back in** (or start a new shell session) before running Docker commands manually.  
   Until you do, manual Docker commands will fail with `permission denied` errors.

---

## 🧰 Advanced / Standalone Usage

- **Check environment before running full install**:
  ```bash
  ./scripts/preflight.sh
  ```

- **Run configuration wizard only**:
  ```bash
  ./scripts/setup-wizard.sh
  ```

- **Run one-click manually (if repo already cloned)**:
  ```bash
  cd onprem-templates/scripts
  ./one-click.sh
  ```

---

## 📘 Container Engine Mapping

The container engine is selected automatically based on the detected Linux distribution:

| Distribution                  | Container Engine |
|-------------------------------|------------------|
| RHEL / Fedora / similar       | Podman           |
| Amazon Linux                  | Docker           |
| Ubuntu / Debian / similar     | Docker           |

---

## 🤖 Jeff (AI Assistant)

Jeff is the IriusRisk AI assistant and can be installed either:

-   During initial setup (`one-click.sh`)
-   During an upgrade (`upgrade.sh`)

### Installation (Fresh Setup)

During setup, you will be prompted to enable Jeff.

If enabled: 
   - Jeff services are included in deployment 
   - Configuration is applied automatically

### Installation During Upgrade

During upgrade, you can: 

- Enable Jeff if not already installed

If enabled: 

- Compose file is created from template 
- Systemd service is updated 
- Stack is restarted with Jeff enabled

### Notes

-   Jeff is deployed as an additional compose layer
-   Existing installations are preserved during upgrades

---

## 🧩 Managing the Stack

You can control the IriusRisk stack directly through `systemctl`.

**Podman (rootless):**
```bash
# Start stack
systemctl --user start iriusrisk-podman

# Stop stack
systemctl --user stop iriusrisk-podman

# Restart stack
systemctl --user restart iriusrisk-podman
```

**Docker:**
```bash
# Start stack
sudo systemctl start iriusrisk-docker

# Stop stack
sudo systemctl stop iriusrisk-docker

# Restart stack
sudo systemctl restart iriusrisk-docker
```


## 🔄 Upgrading IriusRisk

### ⚠️ Important: First Upgrade After 20/03/2026

If you are upgrading an existing installation **for the first time after 20/03/2026**, you must perform a one-time manual step before running `git pull`.

This change introduces a new **template-based compose system** designed to prevent configuration drift and merge conflicts.

### 🔧 Required One-Time Step

Before pulling the latest changes, you must temporarily move your existing **compose files** out of the repository.

#### 1. Locate your compose files

Depending on your setup, the files will be:

**Docker:**

```bash

docker/docker-compose.yml
docker/docker-compose.override.yml
docker/docker-compose.postgres.yml
docker/docker-compose.jeff.yml
```

**Podman:**

```bash
podman/podman-compose.yml
podman/podman-compose.override.yml
podman/podman-compose.postgres.yml
podman/podman-compose.jeff.yml
```

#### 2. Move compose files outside the repository

Move **only the compose files** (not the directory) to a temporary location such as `/tmp`:

```bash
# Docker
mv docker/docker-compose*.yml /tmp/ 2>/dev/null || true

# Podman
mv podman/podman-compose*.yml /tmp/ 2>/dev/null || true
```

#### 3. Pull the latest changes

```bash
git pull
```

#### 4. Move the compose files back

```bash
# Docker
mv /tmp/docker-compose*.yml docker/ 2>/dev/null || true

# Podman
mv /tmp/podman-compose*.yml podman/ 2>/dev/null || true
```

#### 5. Continue with the upgrade

```bash
./upgrade.sh
```

### 📌 Notes

- This step is **only required once**.
- It ensures a clean transition to the new template-based system.
- Skipping this step may result in:
  - Merge conflicts during `git pull`
  - Broken or overwritten compose configurations
  - Deployment failures

To upgrade an existing IriusRisk on-prem installation:

1. **Navigate to the scripts folder**:
   ```bash
   cd onprem-templates/scripts
   ```

2. **Run the upgrade script**:
   ```bash
   git pull
   ./upgrade.sh
   ```

3. **Answer interactive prompts**:
   - **"How is your PostgreSQL configured?"** (internal or external)
   - Whether you are currently using Jeff
   - Option to enable Jeff during upgrade (if not already enabled)

4. **Upgrade process**:
   - The script backs up your PostgreSQL database, IriusRisk service and compose files to the `irius_backups/` directory inside the current user's home folder.
   - Unused containers, networks, and images are cleaned up automatically.
   - The running containers are stopped.
   - The latest images are pulled from the repository (or rebuilt locally if using Podman).
   - Containers are started again with the updated images and configuration.

After completion, your deployment will be running on the latest available IriusRisk version.

---

## ↩️ Rolling Back IriusRisk

If an upgrade fails or you need to return to a previous version, you can roll back using the backups created during the upgrade.

1. **Navigate to the scripts folder**:
   ```bash
   cd onprem-templates/scripts
   ```

2. **Run the rollback script**:
   ```bash
   ./rollback.sh
   ```

3. **Answer interactive prompts**:
   - Choose the PostgreSQL configuration (internal container or external host).
   - Select the version you want to roll back to (detected automatically from backup file names when available).

4. **Rollback process**:
   - The compose files are restored from the matching backup archive.
   - The previous IriusRisk service is restored from the backup.
   - The database is restored from the matching `.sql.gz` dump.
   - If running under **Podman**, custom images are rebuilt for the chosen version (`build_podman_custom_images`).
   - The stack is restarted with the restored configuration and data.

When finished, your deployment will be running the restored version of IriusRisk with the database and compose configuration as they were at the time of the backup.

---

## 🔀 Migrating to the New Stack

To migrate an existing IriusRisk on-prem installation to the new template-based setup:

1. **Navigate to the scripts folder**:
   ```bash
   cd onprem-templates/scripts
   ```

2. **Run the migration script**:
   ```bash
   ./migrate.sh
   ```

3. **Answer interactive prompts**:
   - Confirm your PostgreSQL setup (internal container or external host).
   - The script will attempt to locate your existing Docker or Podman installation. If it cannot, you will be asked to provide the location.

4. **Migration process** (high-level overview):
   - A full backup of the database and legacy configuration directory is created.
   - Existing configuration details (from your compose file) are extracted.
   - Certificates and SAML configuration (if present) are migrated into the new template structure.
   - For Podman users, required secrets are created automatically.
   - Old containers are stopped and the new stack is deployed.

5. **After migration**:
   - Verify that your deployment is working as expected.
   - Once confirmed, you may safely delete the legacy directory if you no longer need it.

---

## 📘 Additional Notes

- **Certificates**: Self-signed certs are generated automatically if not provided.  
  Place your `cert.pem`, `key.pem`, and `ec_private.pem` in `docker/` or `podman/` depending on the detected engine, if using custom ones. For production environments, it is **highly recommended** to provide your own securely signed certificates.
- **Systemd integration**: Docker and Podman services are wrapped as systemd units so the stack comes up automatically after a reboot.
- **Rootless Podman**: The automation configures rootless Podman correctly (including `/run/user/<uid>` handling, tmpfiles rules, and environment exports).
- **Logs**: All scripts log their output under `logs/` with filenames like  
  `one-click_2025-08-29_12-34-56.log`. Child scripts append to the same log automatically.

---

## ⚙️ Requirements (handled automatically if missing)

| Component            | Requirement                                    |
|----------------------|------------------------------------------------|
| **OS**               | Linux (RHEL 9, CentOS 9 based, Debian-based, AWS Linux-based) |
| **PostgreSQL**       | 15+ (installed automatically if chosen)        |
| **Java**             | 17+                                            |
| **Docker**           | 20.10+                                         |
| **Podman** _(alt.)_  | 5.x+ with `podman-compose` & rootless support  |
| **jq**               | Installed automatically                        |
| **git**              | Installed automatically                        |

---

## 🛠️ Troubleshooting

### Docker "Permission Denied" Errors
- **Error**: `Got permission denied while trying to connect to the Docker daemon socket`  
- **Cause**: Your user has just been added to the `docker` group, but the session hasn’t refreshed.  
- **Fix**:  
  Log out and log back in, or run:  
  ```bash
  newgrp docker
  ```  
  After this, manual Docker commands should work without `sudo`.

---

### PostgreSQL Port Already in Use
- **Error**: `rootlessport listen tcp 0.0.0.0:5432: bind: address already in use`  
- **Cause**: Another PostgreSQL instance (container or host) is already using port 5432.  
- **Fix**:
  ```bash
  podman ps | grep postgres
  systemctl status postgresql
  ```
  Stop or remove any conflicting instance before re-running.

---

### Boot ID Mismatch Error (Podman)
- **Error**:  
  ```
  Error: current system boot ID differs from cached boot ID;
  Please delete directories "/tmp/storage-run-1000/containers" ...
  ```
- **Cause**: Podman falling back to `/tmp` for runtime dirs, which resets on reboot.  
- **Fix**: The automation now creates **symlinks** so `/tmp/storage-run-<uid>` always maps into `/run/user/<uid>`.  
  If you still see this:
  ```bash
  rm -rf /tmp/storage-run-$(id -u)/*
  podman ps
  ```

---

### Missing `/run/user/<uid>` After Reboot
- **Error**: `Failed to obtain podman configuration: lstat /run/user/1000: no such file or directory`  
- **Cause**: User systemd session not running or linger not enabled.  
- **Fix**:
  ```bash
  sudo loginctl enable-linger $(id -un)
  sudo loginctl start-user $(id -un) || true
  ```
  Then re-login or reboot.

---

### Systemd "No medium found"
- **When seen**: Running `systemctl --user ...` inside a fresh SSH session.  
- **Cause**: Session bus env vars not exported.  
- **Fix**: The automation installs `/etc/profile.d/10-xdg-user-bus.sh`, which exports:
  ```bash
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus
  export TMPDIR=${XDG_RUNTIME_DIR}
  ```
  Log out and back in to pick this up.

---

## Container Registry Configuration

The deployment supports both the default IriusRisk container registry and custom container registries.

During installation you will be prompted to select the image source:

1) Default IriusRisk registry
2) Custom registry

### Default Registry

If the default registry is selected, images are pulled from:

docker.io/continuumsecurity/iriusrisk-prod

Example images:

docker.io/continuumsecurity/iriusrisk-prod:nginx
docker.io/continuumsecurity/iriusrisk-prod:tomcat-4
docker.io/continuumsecurity/iriusrisk-prod:startleft
docker.io/continuumsecurity/iriusrisk-prod:reporting-module

### Custom Registry

If a custom registry is selected, the installer will ask for:

- Registry URL
- Image repository path
- Registry username
- Registry password/token

Example configuration:

Registry URL:
docker.io

Repository path:
myorg/iriusrisk-prod

Images will then be resolved as:

docker.io/myorg/iriusrisk-prod:nginx
docker.io/myorg/iriusrisk-prod:tomcat-4
docker.io/myorg/iriusrisk-prod:startleft
docker.io/myorg/iriusrisk-prod:reporting-module

This allows organizations to mirror or host IriusRisk images in their own container registry.

### 🐘 PostgreSQL (Internal Container)

If using the **internal PostgreSQL option**, the image must be available with the following tag:

```text
postgres-15.4
```

### 🤖 Jeff (AI Assistant) Dependencies

If installing **Jeff**, the following image must be available:

```text
redis-stack-latest
```

### 📌 Summary

| Component        | Required Tag Format     |
|------------------|------------------------|
| PostgreSQL       | `postgres-15.4`        |
| Redis (Jeff)     | `redis-stack-latest`   |
| IriusRisk images | `<registry>/<path>:tag` |


## Network Requirements

For fully automated installation, the server must be able to access several external services.

If your environment restricts outbound internet traffic, the following destinations must be allowed.

### Git Repository

Required to download the deployment templates.

https://github.com
https://raw.githubusercontent.com

Example usage:

curl https://raw.githubusercontent.com/iriusrisk/onprem-templates/...
git clone https://github.com/iriusrisk/onprem-templates.git

---

### Container Registry

Required to download IriusRisk container images.

Default registry:

docker.io
registry-1.docker.io
auth.docker.io

Example images:

docker.io/continuumsecurity/iriusrisk-prod:nginx
docker.io/continuumsecurity/iriusrisk-prod:tomcat-*
docker.io/continuumsecurity/iriusrisk-prod:startleft
docker.io/continuumsecurity/iriusrisk-prod:reporting-module

If a custom registry is used, access must be allowed to that registry instead.

---

### OS Package Repositories

The installer automatically installs required packages depending on the distribution.

Typical repositories include:

**Ubuntu / Debian**

archive.ubuntu.com
security.ubuntu.com

**RHEL / Rocky / AlmaLinux**

dl.fedoraproject.org
mirrorlist.centos.org

**Amazon Linux**

amazonlinux.*.amazonaws.com

For Podman-based installations on RHEL-compatible systems, the installer also downloads the EPEL release package from:

https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

---

### PostgreSQL Image

If internal PostgreSQL is used, the default base image is:

docker.io/library/postgres:15.4

If a custom PostgreSQL image is selected during setup, access must be allowed to that image registry as well.

---

### Additional Package Sources Used During Podman Image Customization

For Podman deployments, the script customizes local `nginx` and `tomcat` images in `build_podman_custom_images()`.

During that step, additional packages may be installed **inside the container image** depending on the base image being used. This can require outbound access to upstream package repositories such as:

**Alpine-based images**

https://dl-cdn.alpinelinux.org
http://nginx.org

**Debian / Ubuntu-based images**

http://deb.debian.org
http://security.debian.org
http://apt.postgresql.org

The exact repositories contacted depend on the base image contents and package manager used by the source image.

---

### Optional External Services

If you configure external PostgreSQL or custom container registries, network access must be allowed accordingly.

---


## 🌐 Proxy Configuration (Optional)

If your environment requires outbound traffic to go through an HTTP/HTTPS proxy, the deployment scripts support proxy configuration via standard environment variables.

This applies to:

- Downloading dependencies (packages, images)
- Podman image customization steps
- Container runtime behavior
- Systemd-managed services (Docker and Podman)

---

### 🔧 How to Configure a Proxy

Before running the installer (`bootstrap.sh`, `one-click.sh`, or `upgrade.sh`), export the required proxy environment variables in your shell.

Example:

```bash
export HTTP_PROXY=http://proxy.example.com:3128
export HTTPS_PROXY=http://proxy.example.com:3128
export NO_PROXY=localhost,127.0.0.1
```

Lowercase variants are also supported:

```bash
export http_proxy=http://proxy.example.com:3128
export https_proxy=http://proxy.example.com:3128
export no_proxy=localhost,127.0.0.1
```

Additional optional variables:

```bash
export FTP_PROXY=http://proxy.example.com:3128
export ALL_PROXY=http://proxy.example.com:3128
```

---

### ▶️ Running the Installer with Proxy

Once the variables are set, run the installer as normal:

```bash
./bootstrap.sh
```

or:

```bash
./one-click.sh
```

No additional flags or configuration are required.

---

### ⚙️ What the Scripts Do Automatically

If proxy variables are detected, the automation will:

- Pass proxy settings into Podman build containers during image customization
- Inject proxy variables into systemd service definitions
- Ensure all runtime containers inherit the proxy configuration

If no proxy variables are set, the scripts behave exactly as normal with no changes to the deployment flow.

---

### 🔍 Verifying Proxy Configuration

Podman (rootless):

```bash
systemctl --user show-environment | grep -i proxy
```

Docker:

```bash
sudo systemctl show iriusrisk-docker | grep -i proxy
```

Check inside containers:

```bash
podman exec -it <container> env | grep -i proxy
```

or:

```bash
docker exec -it <container> env | grep -i proxy
```

---

### ⚠️ Notes and Best Practices

- Ensure your proxy allows access to:
  - GitHub (github.com, raw.githubusercontent.com)
  - Container registries (docker.io or your custom registry)
  - OS package repositories
- Include internal services in NO_PROXY:
  localhost,127.0.0.1,postgres,jeff,redis
- If using an external PostgreSQL database, include its host in NO_PROXY.

---

### 📌 Summary

| Scenario | Action |
|----------|--------|
| No proxy | No action needed |
| Proxy required | Export variables before running scripts |
| Already deployed | Restart systemd service after updating env vars |

---


### Fully Air-Gapped Environments

If outbound internet access is not allowed, deployment can still be performed using offline mode. 
To use offline mode, request the offline bundle from the support team and copy it to the target host.

### Install using offline bundle

Assuming the bundle file is named `iriusrisk-offline-bundle-4-install.tar.gz` and will be copied to the user home directory:

```bash
scp iriusrisk-offline-bundle-4-install.tar.gz user@your-instance:/home/user/
ssh user@your-instance

tar -xf iriusrisk-offline-bundle-4-install.tar.gz
cd ~/irius-offline-bundle/onprem-templates/scripts

./one-click.sh --offline --bundle "$HOME/irius-offline-bundle"

```

### Upgrade using offline bundle

```bash

scp iriusrisk-offline-bundle-4-install.tar.gz user@your-instance:/home/user/
ssh user@your-instance

tar -xf iriusrisk-offline-bundle-4-install.tar.gz
cd ~/irius-offline-bundle/onprem-templates/scripts

./upgrade.sh --offline --bundle "$HOME/irius-offline-bundle"

```

---

## Supported Operating Systems

The deployment scripts have been tested on the following Linux distributions:

- **RHEL 9**
- **Rocky Linux 9.7**
- **Amazon Linux 2023**
- **Ubuntu 22.04**

Other RHEL 9 compatible distributions (such as AlmaLinux 9) may also work but have not been explicitly tested.

> ⚠️ RHEL/Rocky **10 and newer releases are not currently supported**.

The installation automatically detects the container engine and will use:

- **Podman** on RHEL-based systems
- **Docker** on Ubuntu and Amazon Linux systems

---

## 📎 Support & Docs

- [Hardware and Software Requirements for IriusRisk](https://enterprise-support.iriusrisk.com/s/article/Hardware-and-Software-Requirements-for-IriusRisk)  
