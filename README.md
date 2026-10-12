# Stackarr 🍿

Stackarr is a self-hosted media-server stack distributed as a single Docker Compose deployment. Run the setup wizard, answer a few environment-specific questions, and receive a configured stack ready to start.

> 🎬 **One command. One stack. Your media, automated.**

## ✨ Highlights

- 🐳 One `docker-compose.yml` for the complete stack.
- 🪄 An interactive setup wizard for first-time configuration.
- ⚙️ Generated local settings for mount paths, IDs, time zone, ports, and PIA WireGuard.
- 🏠 Homepage dashboard with links, live container status, and resource widgets.
- 💾 Persistent application data stored on the host.
- 🔒 qBittorrent traffic routed through Gluetun's VPN tunnel.
- 🖥️ Optional GPU-accelerated Plex transcoding.
- 🔄 Predictable restarts and upgrades without deleting application data.

## 🧩 Included Services

| Service | Purpose |
| --- | --- |
| 🎛️ [Dockhand](https://github.com/Finsys/dockhand) | Web interface for managing Docker Compose applications. |
| 🏠 [Homepage](https://gethomepage.dev/) | Landing dashboard for every Stackarr application. |
| 🎞️ [Plex Media Server](https://www.plex.tv/) | Streams the completed media library to clients, with optional GPU transcoding. |
| 📺 [Sonarr](https://sonarr.tv/) | Automates TV-series discovery, downloads, and organization. |
| 🎥 [Radarr](https://radarr.video/) | Automates movie discovery, downloads, and organization. |
| 🛡️ [Gluetun](https://github.com/qdm12/gluetun) | PIA WireGuard client that routes downloader traffic through the VPN. |
| ⬇️ [qBittorrent](https://www.qbittorrent.org/) | BitTorrent download client routed through Gluetun. |
| 🙋 Seerr | Media-request interface for requesting movies and series. |
| 🔎 [Jackett](https://github.com/Jackett/Jackett) | Indexer proxy for Sonarr and Radarr. |

## 🗺️ Architecture

The download and library flow is:

```text
Seerr -> Sonarr / Radarr -> Jackett -> qBittorrent -> completed downloads
                              |              |
                              +--------------+ (via Gluetun VPN)

Sonarr / Radarr -> organized media library -> Plex
```

qBittorrent shares Gluetun's network namespace so download traffic cannot bypass the VPN. Sonarr, Radarr, Jackett, Seerr, Plex, and Dockhand remain reachable on the local network through explicitly mapped ports.

## 🪄 Setup Wizard

The setup wizard is the supported entry point for a first-time installation. It:

1. 🩺 Checks that Docker Engine and the Docker Compose plugin are available.
2. 📁 Collects host directories for application configuration, downloads, and the media library.
3. 🕒 Collects the host user ID, group ID, and time zone used by containers that write files.
4. 🛡️ Creates a PIA WireGuard profile for Gluetun, optionally in the PIA region you choose.
5. 🖥️ Offers optional NVIDIA GPU transcoding and verifies the host driver.
6. 🏠 Detects the local network, checks the required ports, and configures Homepage with the server address.
7. 🔐 Generates a private `.env` file and required initial configuration.
8. 🏗️ Creates required local host directories for settings, downloads, movies, and TV.
9. 🚀 Starts the stack with `docker compose up -d`.
10. 🌐 Prints local URLs and remaining first-run tasks, such as claiming Plex and connecting the media-request service.

> 🔐 The wizard sends your PIA username and password only to PIA to create the WireGuard profile. It never stores those credentials or authentication tokens in `.env`.

## 📂 Directory Layout

All persistent data lives outside containers and is visible in the Compose file:

```text
stackarr/                         # Repository
├── docker-compose.yml
├── .env                           # Generated locally; never committed
├── setup.sh                       # Interactive setup wizard
└── homepage/                      # Dashboard configuration
    ├── docker.yaml                 # Docker status integration
    ├── services.yaml               # Stackarr service cards
    ├── settings.yaml               # Appearance and layout
    └── widgets.yaml                # CPU, memory, network, and uptime

~/.local/share/stackarr/           # Default application settings
~/Downloads/{incomplete,complete}/ # Default qBittorrent downloads
~/Media/{movies,tv}/               # Default media library
```

- **App settings:** Small but important service databases and preferences. Keep this folder private and do not delete it.
- **Downloads:** qBittorrent's working area for incomplete and completed files. Sonarr and Radarr import from here.
- **Media library:** The permanent `movies` and `tv` folders that Plex streams.

Sonarr, Radarr, and qBittorrent must use consistent in-container paths for downloads. This allows Sonarr and Radarr to import completed downloads without unnecessary copies or fragile remote-path mappings.

## 🖥️ Plex GPU Transcoding

Plex uses CPU transcoding by default. During setup, choose optional hardware-accelerated transcoding to pass a compatible GPU through to the Plex container. This reduces CPU load when Plex needs to convert video for clients.

- 🟩 **NVIDIA:** Requires a supported NVIDIA driver and the NVIDIA Container Toolkit on the Docker host.
- 💳 **Plex Pass:** Required by Plex for hardware-accelerated transcoding.

Set `PLEX_GPU_COUNT=1` in `.env` to enable the NVIDIA GPU configuration. Set `PLEX_GPU_COUNT=0` to use standard CPU transcoding. GPU device access is only granted to the Plex container.

## ✅ Prerequisites

Target hosts need:

- A Linux host. The wizard installs Docker and Docker Compose when they are missing.
- A user account that can use `sudo` if Docker is not already installed.
- Sufficient persistent storage for downloads, media, and service configuration.
- An active Private Internet Access subscription for the required WireGuard tunnel.
- Local network access to the ports selected during setup.
- A compatible GPU and the applicable host driver/runtime when enabling Plex GPU transcoding.

## 🚀 Usage

A first installation looks like this:

```bash
git clone <repository-url> stackarr
cd stackarr
./setup.sh
```

The wizard detects your user ID, group ID, time zone, LAN subnet, and local server address automatically. It asks for storage locations, your PIA account while creating the WireGuard profile, an optional PIA region, the dashboard address confirmation, and whether to opt in to NVIDIA GPU transcoding. Optional choices default to **No**.

Preview the entire setup without installing Docker, creating files, or starting containers:

```bash
./setup.sh --dry-run
```

### Local addresses

| Application | Default address |
| --- | --- |
| 🏠 Homepage | `http://<host>:3001` |
| 🎛️ Dockhand | `http://<host>:3000` |
| 🎞️ Plex | `http://<host>:32400/web` |
| ⬇️ qBittorrent | `http://<host>:8080` |
| 📺 Sonarr | `http://<host>:8989` |
| 🎥 Radarr | `http://<host>:7878` |
| 🔎 Jackett | `http://<host>:9117` |
| 🙋 Seerr | `http://<host>:5055` |

All non-Plex ports can be changed in `.env`.

### Homepage Dashboard

Homepage is configured automatically with media, automation, download, and management sections. Service cards show Docker container state and resource statistics without requiring application API keys. The layout, background, icons, and widgets can be customized in the tracked `homepage/` directory.

### Everyday commands

```bash
docker compose up -d
docker compose ps
docker compose logs -f
docker compose down
```

> ⚠️ `docker compose down` stops and removes containers and networks. Do not use `-v`, as it can remove named volumes and discard persistent data.

## 🔒 Security Notes

- Treat `${APPDATA}/gluetun/wireguard/wg0.conf` as confidential. It contains the generated WireGuard private key, but never your PIA password or authentication token.
- Do not expose Dockhand, qBittorrent, Sonarr, Radarr, Jackett, or Seerr directly to the public internet.
- Use strong, unique credentials for service web interfaces.
- Dockhand and Homepage use the Docker socket. Any service with Docker-socket access effectively has high privilege over the Docker host, including when the socket is mounted read-only. Restrict dashboard access to trusted local users.
- Verify that qBittorrent only has network access through Gluetun before enabling automated downloads.

## 🤝 Contributing

Contributions must preserve the reliable Compose topology and idempotent setup-wizard behavior. Keep secrets out of version control, preserve existing persistent data during upgrades, and document any new required user input.
