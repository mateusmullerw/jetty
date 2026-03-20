# Jetty

A lightweight macOS menu bar app that shows all TCP processes listening on your machine — grouped by project, with one-click kill.

---

## Features

- **Live port monitoring** — scans all listening TCP ports via `lsof` on every menu open and every 60 seconds
- **Project grouping** — processes that share a working directory are grouped under their project name, detected from `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, and `mix.exs`
- **Human-readable names** — maps raw process commands to friendly labels (e.g. `bun` → Bun, `beam.smp` → Elixir/Erlang)
- **HMR detection** — identifies Hot Module Reload ports (local-only ports on processes that also expose a public port)
- **Interface binding** — shows whether each port is bound to all interfaces or local only
- **Kill processes** — red Kill button per process; Kill all button for multi-process projects; graceful `SIGTERM` then `SIGKILL` fallback
- **Others section** — system and tool processes (VS Code, Docker, Proxyman, etc.) are collapsed into a separate group to reduce noise
- **Refresh controls** — manual refresh button and last-updated timestamp in the header
- **Light & dark mode** — full support via native macOS colors

## Requirements

- macOS 12.0 or later
- Xcode 15 or later (for building from source)

## Building

**From Xcode** — open `Package.swift`, select the Jetty scheme, and press Run. The shared scheme automatically packages the binary as `Jetty.app` in the project root and launches it as a proper app bundle (no terminal window).

**From the command line:**

```bash
swift build -c release
```

The binary will be at `.build/release/Jetty`.

## Supported runtimes

| Runtime | Detected as |
|---|---|
| Node.js / Bun / Deno | Node.js, Bun, Deno |
| Python / Gunicorn / Uvicorn | Python, Python/Gunicorn, Python/Uvicorn |
| Ruby / Puma / Unicorn | Ruby, Ruby/Puma, Ruby/Unicorn |
| Elixir / Erlang | Elixir, Elixir/Erlang |
| Go / Java / PHP | Go, Java, PHP, PHP-FPM |
| Nginx / Apache / Caddy | Nginx, Apache, Caddy |
| PostgreSQL / MySQL / Redis / MongoDB | PostgreSQL, MySQL, Redis, MongoDB |
| Elasticsearch / ClickHouse / Memcached | Elasticsearch, ClickHouse, Memcached |
| Docker | Docker, Docker Proxy |

## Architecture

```
Sources/Jetty/
├── main.swift          Entry point — creates NSApplication and AppDelegate
├── AppDelegate.swift   Status bar setup, menu construction, kill logic, custom views
├── PortScanner.swift   lsof execution, parsing, HMR detection, project grouping
└── Models.swift        PortProcess, ProjectEntry, Project
```

**Data flow:**

1. `/usr/sbin/lsof -iTCP -sTCP:LISTEN -nP -F pcn` enumerates all listening TCP sockets
2. Each entry is parsed into a `PortProcess` (PID, command, port, address)
3. `proc_pidinfo()` resolves the working directory for each PID
4. Project manifests in each working directory are read to get a project name
5. Processes are grouped by shared working directory into `Project` objects
6. Developer processes and system/tool processes are separated — system ones go into the Others section

No third-party dependencies — only Foundation, AppKit, and Darwin.
