terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.1"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# =============================================================================
# Coder Workspace Template — Docker-in-Docker + devcontainer + VS Code Web
# =============================================================================
# Architecture:
#   Coder server (compose) → DinD sidecar → workspace container (privileged)
#                                             └─ inner dockerd
#                                             └─ devcontainer CLI
#                                             └─ code-server (VS Code Web)
# =============================================================================

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

provider "coder" {}

# The Docker provider connects to the DinD sidecar running alongside Coder.
# DOCKER_HOST is already set in the Coder container environment.
provider "docker" {}

# ---------------------------------------------------------------------------
# Coder data sources
# ---------------------------------------------------------------------------

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ---------------------------------------------------------------------------
# Parameters (user-facing inputs on workspace creation)
# ---------------------------------------------------------------------------

data "coder_parameter" "dotfiles_uri" {
  name         = "dotfiles_uri"
  display_name = "Dotfiles repository"
  description  = "Optional Git URL of your dotfiles repo (applied via coder dotfiles)."
  default      = ""
  mutable      = true
  order        = 1
}

data "coder_parameter" "devcontainer_repo" {
  name         = "devcontainer_repo"
  display_name = "Project repository"
  description  = "Git URL of the repository to clone. Must contain a .devcontainer/ folder."
  mutable      = true
  order        = 2
}

data "coder_parameter" "cpu_cores" {
  name         = "cpu_cores"
  display_name = "CPU cores"
  type         = "number"
  default      = "2"
  mutable      = true
  validation {
    min = 1
    max = 8
  }
  order = 3
}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "Memory (GB)"
  type         = "number"
  default      = "4"
  mutable      = true
  validation {
    min = 1
    max = 16
  }
  order = 4
}

# ---------------------------------------------------------------------------
# VS Code Web app
# ---------------------------------------------------------------------------

resource "coder_app" "vscode_web" {
  agent_id     = coder_agent.main.id
  slug         = "code"
  display_name = "VS Code Web"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337/?folder=/workspaces/${data.coder_workspace.me.name}"
  subdomain    = true   # requires CODER_WILDCARD_ACCESS_URL
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
}

# ---------------------------------------------------------------------------
# Coder agent
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  dir            = "/workspaces/${data.coder_workspace.me.name}"

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    DOTFILES_URI        = data.coder_parameter.dotfiles_uri.value
    REPO_URL            = data.coder_parameter.devcontainer_repo.value
  }

  startup_script = <<-EOT
    set -e

    # --- Wait for inner Docker daemon ---
    echo "Waiting for inner Docker daemon..."
    until docker info >/dev/null 2>&1; do sleep 1; done
    echo "Docker daemon ready."

    # --- Clone repository ---
    WORKSPACE_DIR="/workspaces/${data.coder_workspace.me.name}"
    mkdir -p "$(dirname "$WORKSPACE_DIR")"
    if [ ! -d "$WORKSPACE_DIR/.git" ]; then
      git clone "$REPO_URL" "$WORKSPACE_DIR"
    fi

    # --- Apply dotfiles ---
    if [ -n "$DOTFILES_URI" ]; then
      coder dotfiles -y "$DOTFILES_URI" || true
    fi

    # --- Install VS Code Server (code-server) ---
    if ! command -v code-server &>/dev/null; then
      curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone
    fi

    # --- Start VS Code Web ---
    code-server \
      --bind-addr 0.0.0.0:13337 \
      --auth none \
      --disable-telemetry \
      "$WORKSPACE_DIR" &

    # --- Open devcontainer (if .devcontainer/ exists) ---
    if [ -f "$WORKSPACE_DIR/.devcontainer/devcontainer.json" ] || [ -f "$WORKSPACE_DIR/.devcontainer.json" ]; then
      echo "devcontainer.json detected — starting devcontainer..."
      # Install devcontainer CLI if not present
      if ! command -v devcontainer &>/dev/null; then
        npm install -g @devcontainers/cli
      fi
      devcontainer up \
        --workspace-folder "$WORKSPACE_DIR" \
        --docker-path docker \
        --remove-existing-container \
        --update-remote-user-uid-default off
    fi
  EOT

  startup_script_behavior = "blocking"

  metadata {
    display_name = "CPU usage"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory usage"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Disk usage"
    key          = "disk"
    script       = "df -h /workspaces | awk 'NR==2{print $5}'"
    interval     = 60
    timeout      = 1
  }
}

# ---------------------------------------------------------------------------
# Docker volume — persistent workspace storage
# ---------------------------------------------------------------------------

resource "docker_volume" "workspaces" {
  name = "coder-${data.coder_workspace.me.id}-workspaces"

  lifecycle {
    ignore_changes = all
  }
}

# ---------------------------------------------------------------------------
# Workspace container image
# ---------------------------------------------------------------------------
# Uses a base image with:
#   - Docker CLI + daemon (for DinD)
#   - Node.js (for devcontainer CLI)
#   - Git, curl, and other essentials
# The Coder agent binary is injected at runtime by Coder itself.

resource "docker_image" "workspace" {
  name = "codercom/enterprise-base:ubuntu"
  # Replace with a custom image (see CONCEPT.md) once you have one built.
  keep_locally = true
}

# ---------------------------------------------------------------------------
# Workspace container
# ---------------------------------------------------------------------------

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count   # 0 = stopped, 1 = running

  image    = docker_image.workspace.image_id
  name     = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
  hostname = data.coder_workspace.me.name

  # --- DinD inside workspace (for devcontainer support) ---
  privileged = true                              # Required for inner Docker daemon

  # CPU / Memory limits
  cpu_set    = "0-${data.coder_parameter.cpu_cores.value - 1}"
  memory     = data.coder_parameter.memory_gb.value * 1024

  # Inject the Coder agent token
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "DOCKER_HOST=unix:///var/run/docker.sock",
  ]

  # Coder agent entrypoint
  command = ["sh", "-c", coder_agent.main.init_script]

  # Persistent workspace volume
  volumes {
    volume_name    = docker_volume.workspaces.name
    container_path = "/workspaces"
  }

  # Inner Docker daemon storage (ephemeral per workspace lifetime)
  tmpfs = {
    "/var/lib/docker" = "exec"
  }

  # Start inner dockerd as PID1 sidecar is not available inside the container.
  # The agent startup_script waits for dockerd to be ready.
  # Note: dockerd is started by the base image entrypoint or a supervisor.
  # Adjust if you use a custom image with a process manager (s6, supervisord).
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "workspace_container" {
  value = try(docker_container.workspace[0].name, "stopped")
}
