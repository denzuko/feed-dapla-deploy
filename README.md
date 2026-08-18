# feed-dapla-deploy

Roswell/Consfigurator deploy of the service at `feed.dapla.net`.

## Repository Layout

```
feed-dapla-deploy.ros   Thin Roswell entry point
feed-dapla-deploy.asd   Umbrella ASDF system definition
qlfile         Qlot dependency pins
src/deploy.lisp  Consfigurator properties and DEFHOST
src/docs.lisp    40ants-doc sections
t/e2e.lisp       Post-deploy FiveAM smoke tests
docs.ros         Documentation generator
Makefile         build / test / doc / dist / clean
```

## Installation

```sh
ros install qlot
qlot install
./feed-dapla-deploy.ros
```

## Runbook

```sh
machinectl shell feed@ -- systemctl --user status
machinectl shell feed@ -- journalctl --user -f
machinectl shell feed@ -- podman auto-update
```

Redeploy by re-running `./feed-dapla-deploy.ros`. Idempotent.

## Playbook

### ZFS replication (rsync.net)

```sh
zfs snapshot storage/containers/feed@$(date +%Y%m%d)
zfs send -w storage/containers/feed@$(date +%Y%m%d) | \
  ssh user@rsync.net zfs receive backup/feed
```

Key files under `/etc/zfs-keys/` must be backed up separately.

## Decommission

```sh
machinectl shell feed@ -- systemctl --user stop feed
machinectl shell feed@ -- systemctl --user disable feed
zfs destroy -r storage/users/feed
zfs destroy -r storage/containers/feed
```

## License

BSD 3-Clause. See [LICENSE](LICENSE).
