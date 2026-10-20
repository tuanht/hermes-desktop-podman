# Migrating to another machine

Back up the three volumes and the env file on the old machine, then restore them over a fresh `./install.sh` on the new one. This procedure has not been tested end to end; try the restore before decommissioning the old machine.

## What holds state

| Item | Where | In git? |
|---|---|---|
| Hermes data: memories, sessions, auth, profile `.env` files, SSH keys | volume `hermes-data` (`/opt/data`) | No |
| Sandbox home and workspace (including any Claude Code login) | volume `hermes-sandbox-home` | No |
| Sandbox SSH host keys (keeps the host fingerprint stable) | volume `hermes-sandbox-hostkeys` | No |
| Dashboard credentials and API keys | `~/.config/hermes/hermes.env` | No |
| Quadlets, `install.sh`, profile distributions | this repo | Yes |

Confirm the volume names with `podman volume ls`.

## Quick path: scripts

```bash
./backup.sh [DEST_DIR]        # old machine; default DEST is ~/hermes-backup-<timestamp>
./restore.sh BACKUP_DIR       # new machine, after cloning the repo
```

`restore.sh` places `hermes.env` first. If the volumes don't exist yet, it asks you to fix the `PublishPort` IP (step 2.3), run `./install.sh`, and rerun it. The manual steps below do the same thing.

## 1. Back up (old machine)

```bash
git push                                   # make sure the repo is up to date
systemctl --user stop hermes-sandbox.service hermes.service   # stop writers for a consistent copy
mkdir -p ~/hermes-migrate
for v in hermes-data hermes-sandbox-home hermes-sandbox-hostkeys; do
    podman volume export "$v" -o ~/hermes-migrate/"$v".tar
done
cp ~/.config/hermes/hermes.env ~/hermes-migrate/
```

The folder contains auth tokens and SSH keys. Transfer it over Tailscale and delete it afterwards:

```bash
scp -r ~/hermes-migrate NEW_HOST:~/
shred -u ~/hermes-migrate/* && rmdir ~/hermes-migrate   # when done, on both machines
```

## 2. Restore (new machine)

1. Install Podman and Tailscale, then clone this repo.
2. Put the env file in place **before** installing. `install.sh` never overwrites it, so the existing dashboard credentials are kept:
   ```bash
   mkdir -p ~/.config/hermes
   install -m 600 ~/hermes-migrate/hermes.env ~/.config/hermes/hermes.env
   ```
3. In `quadlet/hermes.pod`, set the Tailscale `PublishPort=<ip>:9119:9119` line to the new machine's Tailscale IP (or remove it). A stale IP fails to bind and the service restart-loops.
4. Run `./install.sh`. It creates the volumes, installs the units and applies the profiles.
5. Stop the services and import the data:
   ```bash
   systemctl --user stop hermes-sandbox.service hermes.service
   for v in hermes-data hermes-sandbox-home hermes-sandbox-hostkeys; do
       podman volume import "$v" ~/hermes-migrate/"$v".tar
   done
   systemctl --user start hermes.service hermes-sandbox.service
   ```
   If Podman refuses to import into a non-empty volume, `podman volume rm` it first (stop the units, and remove the services' containers if needed), then re-import.

## 3. Verify

```bash
podman exec hermes hermes profile list    # coder-remote and code-reviewer should be listed
journalctl --user -u hermes.service -n 50
```

Open the dashboard and check that memories and sessions are present.

## Gotchas

- **Never run both instances at once.** Two gateways on the same bot tokens conflict. Stop the old one once the new one works.
- **Tailscale name/IP changes.** Update bookmarks and integrations pointing at the old host.
- **Image version.** `install.sh` pulls the latest image, which may be newer than the one that wrote the data. To be careful, pin the same tag on both machines for the first start.
- **Linger.** `install.sh` enables it; it is what starts the units at boot.
