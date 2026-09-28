# Arma 3 Dedicated Server Manager

A production-oriented manager for an Arma 3 Dedicated Server on Linux. It installs SteamCMD and app `233780`, imports original Arma Launcher presets, manages Workshop content for app `107410`, handles Linux case sensitivity, creates symlinks and signature keys, and starts the server without unsafe string evaluation.

## Features

- No passwords or Steam Guard codes in configuration files, logs, or process arguments
- Atomic preset imports into `config/mods.json`
- Workshop status based on the local ACF file and Steam metadata
- Collision-safe lowercase conversion that never follows symlinks
- Idempotent symlinks separated by client and server type
- Local mods with a dedicated registry, safe links, and optional lowercase conversion
- Hash-based key synchronization that protects unmanaged files
- Bash arrays for launch arguments; no `eval`
- PID validation, update locking, storage and permission checks, and dry-run support
- A systemd service and conservative update timer

References: [Bohemia: Arma 3 Dedicated Server](https://community.bistudio.com/wiki/Arma_3:_Dedicated_Server), [Bohemia: Startup Parameters](https://community.bistudio.com/wiki/Arma_3_Startup_Parameters), and [Valve: SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD).

## Requirements

The intended targets are current Debian/Ubuntu-like and RHEL/Fedora-like distributions with Bash 5, systemd, and glibc. Required tools are `bash`, `curl`, `jq`, `python3`, `flock` from util-linux, GNU coreutils/findutils, `tar`, and `sha256sum`. On x86_64, SteamCMD additionally requires 32-bit runtime libraries.

Debian/Ubuntu:

```bash
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install curl jq python3 util-linux tar coreutils findutils lib32gcc-s1
```

Fedora/RHEL package names may vary by release:

```bash
sudo dnf install curl jq python3 util-linux tar coreutils findutils glibc.i686 libstdc++.i686
```

A working IPv4 connection and UDP ports `2302` through `2306` are normally required for the default port. Distribution-specific firewall rules are outside the scope of this project.

## User and installation

Do not run the production server as root. Perform the initial setup as an administrator:

```bash
sudo useradd --create-home --shell /bin/bash arma3
sudo install -d -o arma3 -g arma3 /opt/arma3 /opt/arma3-manager
sudo cp -a . /opt/arma3-manager/
sudo chown -R arma3:arma3 /opt/arma3 /opt/arma3-manager
sudo -iu arma3
cd /opt/arma3-manager
chmod +x arma3-server.sh helpers/*.py tests/test.sh
```

At minimum, set the Steam account in `config/arma3.conf`:

```bash
STEAM_USER="HereYourSteamUser"
ARMA_BASE="Insert Path"
```

Replace both placeholders before running installation commands. `ARMA_BASE` should be an absolute path such as `/opt/arma3`.

Then run:

```bash
./arma3-server.sh install
```

The manager downloads SteamCMD from Valve. During the first Steam operation, it starts a separate login directly on the TTY so password and Steam Guard prompts remain visible. This phase is intentionally neither piped nor logged. `STEAMCMD_HOME` gives SteamCMD an isolated home directory, preventing it from selecting a parallel desktop Steam library or exposing that library's Workshop files to lowercase conversion. SteamCMD internally uses `Steam/steamapps/workshop`; the manager links that path to `WORKSHOP_DIR` and safely migrates existing manager-owned data when possible.

After login, the logged download process uses the cached session. The manager never passes, stores, or logs the password. Before systemd updates can work, the `arma3` Linux user must have completed at least one successful interactive login. A separate Steam account without valuable purchases is recommended. Workshop downloads may require the account to own Arma 3.

## Directory layout

The default production layout is:

```text
/opt/arma3/
├── server/                  # App 233780
│   ├── mods/                # client/both symlinks
│   ├── servermods/          # server/both symlinks
│   └── keys/                # copied, managed .bikey files
├── steamcmd/
├── steam-home/              # isolated login session, not desktop Steam
├── workshop/
│   ├── appworkshop_107410.acf
│   └── content/107410/ID/
├── logs/
└── state/
```

The links intentionally live below the server directory. Bohemia's Linux documentation requires `-mod` paths to be relative paths within or below the Arma directory. The actual Workshop files remain under `/opt/arma3/workshop`.

## Importing a preset

```bash
./arma3-server.sh import-preset "/path/to/Arma 3 Preset Antistasi.html"
```

The parser uses Python's standard-library `html.parser`. It structurally reads `tr[data-type=ModContainer]`, `td[data-type=DisplayName]`, and the URL query parameter `id` instead of relying on line numbers. Link names are converted into ASCII-safe `@name` values; the Workshop ID is appended when names collide. Duplicate IDs are removed, and the destination file is replaced atomically only after the entire preset has parsed successfully.

The test suite includes a minimal Launcher preset fixture. You may also pass a real exported preset explicitly:

```bash
./tests/test.sh
./tests/test.sh "/path/to/Arma 3 Preset Antistasi.html"
```

## Mod types and overrides

A Launcher preset does not reliably state whether a mod is required only by the server or by clients as well. Every imported preset entry is therefore visibly classified as `client` with the classification `heuristic-launcher-preset`; the manager does not present this heuristic as a verified fact. Correct the type in `config/mod-overrides.conf` when necessary:

```text
450814997=client
123456789=server
987654321=both
```

- `client`: included in `-mod`
- `server`: included only in `-serverMod`
- `both`: included in both arguments

`mods list` shows the effective classification and marks manual overrides. A mod's correct semantics cannot be determined reliably from its files alone; the author's Workshop documentation remains authoritative.

## Adding local mods

A local mod is never downloaded through SteamCMD. It remains in its source directory; the manager records only the absolute path and creates safe symlinks inside the Arma server directory.

```bash
mkdir -p /opt/arma3/localmods
# Copy or check out the mod into /opt/arma3/localmods/@my_mod
./arma3-server.sh local-mod add client /opt/arma3/localmods/@my_mod
./arma3-server.sh local-mod list
```

Local mods support the same types as Workshop mods:

- `client`: link under `server/mods`, included in `-mod`
- `server`: link under `server/servermods`, included in `-serverMod`
- `both`: included in both directories and launch arguments

The link name is generated from the source directory, for example `My Mod` becomes `@my_mod`. Local `.bikey` files are included automatically during key synchronization. After changing source files manually, synchronize links, keys, and launch arguments again:

```bash
./arma3-server.sh local-mod sync
```

Arma mods on Linux often require lowercase file and directory names. The manager deliberately does not apply this automatically to local sources because it changes the original directory. Run it explicitly when required:

```bash
./arma3-server.sh local-mod lowercase @my_mod
```

Create a backup or Git commit first. Case collisions abort before the first mutation. Removing a local mod deletes only manager-owned links, launch arguments, and managed key copies; it never deletes the source directory:

```bash
./arma3-server.sh local-mod remove @my_mod
```

The registry is stored in `config/local-mods.json` and should be backed up with the rest of the configuration. After moving a source directory, update its absolute `source_path` and run `local-mod sync`.

Adding or removing a mod does not restart an already running server. Apply the changed mod list with `./arma3-server.sh restart`.

## Mod status and updates

```bash
./arma3-server.sh mods list
./arma3-server.sh mods check
./arma3-server.sh mods update
./arma3-server.sh mods update 450814997
```

The local installation timestamp comes from `appworkshop_107410.acf`. The remote `time_updated` value is queried through Steam's `ISteamRemoteStorage/GetPublishedFileDetails` endpoint. This is the cleanest check that does not download the mod, but the endpoint has no guaranteed availability SLA. During network or API failures, the manager reports `unknown` and does not silently download everything. A targeted `mods update ID --force` validates an item with unknown status through SteamCMD. Missing and demonstrably outdated mods are downloaded normally.

Each successful download is followed by lowercase conversion, link and key synchronization, and launch-argument generation. `workshop_download_item 107410 ID validate` may recreate original mixed-case files. To prevent artificial case collisions with an existing lowercased copy, the manager moves the old mod aside on the same filesystem before a confirmed download. It deletes the backup only after the download and lowercase preflight succeed. On failure, it restores the previous state, retains the failed state for diagnostics, and marks the mod for another attempt.

In an interactive terminal, SteamCMD percentage messages appear as a compact progress bar. This also covers preparation, server download, validation, unpacking, and installation of app `233780`. SteamCMD filter output is unbuffered. Mod batches additionally display a counter such as `[3/12]`. Set `SHOW_PROGRESS=false` in `config/arma3.conf` to disable this display. Under systemd or redirected output, the manager automatically uses regular log lines instead of ANSI or carriage-return output.

Manual repair commands:

```bash
./arma3-server.sh lowercase
./arma3-server.sh lowercase 450814997
./arma3-server.sh links rebuild
./arma3-server.sh keys sync
```

Lowercase conversion performs a complete collision preflight for each directory before mutating anything. `Foo.pbo` next to `foo.pbo` causes a clear failure and neither file is overwritten. Directory symlinks may be renamed but are never followed.

Keys are deduplicated by SHA-256. When two different keys have the same filename, the manager warns and adds the Workshop ID to the second filename. Keys not created by the manager are neither overwritten nor deleted. Managed state is stored in `/opt/arma3/state/managed-keys.json`.

## Configuring and managing the server

During the first installation, the manager copies `config/server.cfg.example` and `config/basic.cfg.example` into `/opt/arma3/server` if the corresponding files do not exist. Change `passwordAdmin` and configure missions before production use.

```bash
./arma3-server.sh start
./arma3-server.sh status
./arma3-server.sh console
./arma3-server.sh stop
./arma3-server.sh restart
```

Bohemia documents `-profiles` as broken on Linux, so the manager does not pass it. With `-name=server`, profiles normally appear under `~/.local/share/Arma 3 - Other Profiles/server/` for the Linux user. `PROFILE_DIR` is retained only as a documented target for possible future engine changes.

Direct updates:

```bash
./arma3-server.sh server update
./arma3-server.sh update
```

Updates never modify running server or mod files. Without `--force`, the manager aborts when the server is active. `--force` stops it cleanly; it restarts only when `AUTO_RESTART=true`. If a process does not exit within `STOP_TIMEOUT`, the manager deliberately refuses to send a blind SIGKILL.

Global options may appear anywhere on the command line:

```bash
./arma3-server.sh --verbose --dry-run update
```

## systemd

The units remain in the project until installed explicitly. Verify their paths first:

```bash
sudo install -m 0644 systemd/arma3-server.service /etc/systemd/system/
sudo install -m 0644 systemd/arma3-update.service /etc/systemd/system/
sudo install -m 0644 systemd/arma3-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arma3-server.service
sudo systemctl enable --now arma3-update.timer
```

The timer uses `--defer-if-running`. If the server is active, the check exits successfully without touching files or players. It never restarts the server automatically. For a maintenance window, stop the server and start `arma3-update.service` manually. The units assume `/opt/arma3-manager`, user and group `arma3`, and data under `/opt/arma3`. Adjust `WorkingDirectory`, `ExecStart`, and `ReadWritePaths` when using different paths.

## Troubleshooting

- **SteamCMD does not start:** Install the 32-bit libraries and inspect `ldd /opt/arma3/steamcmd/linux32/steamcmd`.
- **SteamCMD appears to stop after “started”:** Current versions separate login from the logged download so prompts have a real TTY. Run the command again; already downloaded SteamCMD files are reused. Enter the Steam password at `Password:` and then the Steam Guard code if requested.
- **Steam Guard under systemd:** Log in interactively once as the exact same Linux user. Never place a password in the unit.
- **Workshop `No subscription`:** Verify that the account can access Arma 3 and the Workshop item, and check the subscription on the Workshop page.
- **`unknown` in `mods check`:** Check network access, DNS, and the Steam API. Retry with `--verbose`; targeted validation is available with `--force`.
- **Case collision:** Inspect the reported files in the Workshop mod manually. The manager does not delete either version.
- **Broken link:** Run `links rebuild`. For safety, a real directory at a link destination is never replaced.
- **Server does not start:** Inspect `logs/server-console.log` and the Arma RPT under the Linux profile.
- **Update lock:** Use `ps` to check whether a manager process is active. The lock file alone does not hold a lock; do not terminate processes prematurely.

## Backups

Before updates, back up at least `server.cfg`, `basic.cfg`, `MPMissions/`, the Arma profiles under the user's home directory, `config/mods.json`, `config/local-mods.json`, `config/mod-overrides.conf`, local mod sources, and `/opt/arma3/state`. Workshop files and the server installation can be downloaded again and usually do not need to be backed up. Keep backups outside `/opt/arma3` and test restoration regularly.

## License

This project is licensed under the [MIT License](LICENSE).

## Project structure

```text
.
├── arma3-server.sh
├── LICENSE
├── config/
│   ├── arma3.conf
│   ├── basic.cfg.example
│   ├── local-mods.json
│   ├── mod-overrides.conf
│   ├── mods.json
│   └── server.cfg.example
├── helpers/
│   ├── lowercase_tree.py
│   ├── parse_preset.py
│   └── read_workshop_manifest.py
├── lib/
│   ├── common.sh
│   ├── keys.sh
│   ├── local_mods.sh
│   ├── lowercase.sh
│   ├── mods.sh
│   ├── preset.sh
│   ├── server.sh
│   └── steam.sh
├── runtime/                   # atomically generated launch arguments (not versioned)
├── systemd/
│   ├── arma3-server.service
│   ├── arma3-update.service
│   └── arma3-update.timer
└── tests/
    ├── fixtures/
    │   ├── empty-mods.json
    │   ├── fake-steamcmd.sh
    │   ├── launcher-preset.html
    │   └── two-mods.json
    └── test.sh
```
