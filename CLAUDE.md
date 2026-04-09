# CLAUDE.md — tailnet-stack

## Project Overview

This repository contains container stacks deployed on personal VPS infrastructure connected via Tailscale (Tailnet). Each stack is self-contained and designed for production use within the private network.

## Repository Structure

```
tailnet-stack/
├── stacks/
│   └── coder/          # Coder workspace stack (Docker-in-Docker devcontainers)
├── CLAUDE.md
└── README.md
```

As the project grows, new stacks will be added under `stacks/`.

## Active Stacks

### Coder Stack (`stacks/coder/`)

A self-hosted [Coder](https://coder.com/) deployment enabling browser-based development environments.

**Key characteristics:**
- Runs on Docker via Docker Compose
- Workspaces use the **Docker-in-Docker (DinD)** template, allowing devcontainers to run inside Coder workspaces
- Exposed within the Tailnet (not public internet)
- Designed for VPS deployment

**Core components:**
- `coder` — The Coder server (manages workspaces, templates, users)
- `postgres` — Backend database for Coder
- `docker` (DinD) — Docker daemon running inside a container, used by Coder workspace agents to build and run devcontainers

## Development Guidelines

### General

- All stacks live under `stacks/<stack-name>/`
- Each stack has its own `docker-compose.yml` and a `README.md` explaining its purpose, configuration, and deployment steps
- Use `.env` files for secrets/config — never commit secrets to the repo; provide `.env.example` files instead
- Prefer named Docker volumes over bind mounts for persistent data
- Services should only be reachable within the Tailnet unless explicitly intended otherwise

### Docker Compose conventions

- Pin image tags — avoid `latest` in production compose files
- Define explicit `restart: unless-stopped` policies on long-running services
- Use a dedicated Docker network per stack
- Health checks should be defined for services that other services depend on

### Coder / DinD specifics

- The DinD container requires `privileged: true` — document this clearly wherever it appears
- Coder workspace templates are stored under `stacks/coder/templates/`
- The Coder agent inside a workspace communicates back to the Coder server — ensure `CODER_ACCESS_URL` is set to the Tailnet address

### Secrets & Environment

- Never commit `.env` files
- Always provide an `.env.example` with all required variable names and example/placeholder values
- Document each variable in the stack's `README.md`

## Tailnet / Networking Notes

- All VPS nodes are joined to the same Tailscale network
- Services bind to the Tailscale interface (`tailscale0`) or to `0.0.0.0` with firewall rules restricting access to Tailnet CIDR (`100.64.0.0/10`)
- Use Tailscale MagicDNS hostnames in configuration where possible

## Commit Style

- Use short imperative commit messages (`Add coder compose file`, `Fix postgres health check`)
- Group related changes in a single commit
- Do not commit generated files, secrets, or build artifacts
