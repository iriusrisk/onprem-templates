# IriusRisk On-Prem Automation Setup

This repository includes **automation scripts** to fully set up an IriusRisk on-prem deployment on a fresh server.  
They install dependencies, configure PostgreSQL, generate certificates, and deploy containers via Docker or Podman in rootless mode.

⚠️ **Important Warning**  
These scripts are intended to be run on a **completely fresh machine**.  
If an existing PostgreSQL installation (standalone, containerized, or otherwise) is present on the **same machine**, and you choose to set up PostgreSQL on the same machine, these scripts will either:

- Fail with errors, **or**
- Wipe the existing PostgreSQL setup, including its databases.

Do **not** run these scripts on a machine that already has a PostgreSQL database you care about.

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
- The main **end-to-end installer**.
- Ensures you’re in the right directory, detects the Linux distribution, selects the appropriate container engine automatically, sets up PostgreSQL (internal container or external DB), and then deploys IriusRisk.
- Calls other helper scripts (`preflight.sh`, `setup-wizard.sh`) as needed.
- Recommended if you’ve already cloned the repo and are inside the `scripts/` directory.

### `setup-wizard.sh`
- Runs interactively and asks questions about:
  - PostgreSQL setup (internal or external)
  - Hostname and external URLs
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
   - Decide how to set up PostgreSQL (internal container or external DB)
   - Provide hostname
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

4. **Upgrade process**:
   - The script backs up your PostgreSQL database and compose files to the `irius_backups/` directory inside the current user's home folder.
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
| **OS**               | Linux (RHEL 9+, CentOS-based, Debian-based, AWS Linux-based) |
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

## 📎 Support & Docs

- [Hardware and Software Requirements for IriusRisk](https://enterprise-support.iriusrisk.com/s/article/Hardware-and-Software-Requirements-for-IriusRisk)  