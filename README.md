# wslc-remote

Use `wslc` inside a WSL distro — fast.

`wslc` runs your containers in a separate VM, so a `-v /host/dir:/ctr` bind mount has to cross
that VM boundary over virtiofs. That is slow for trees with lots of small files (git checkouts,
`node_modules`, build output). wslc-remote is a transparent drop-in that serves those binds over
NFS instead. Run it exactly like `wslc`; everything it doesn't accelerate is forwarded untouched.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/craigloewen-msft/WSLc-remote/main/install.sh | bash
```

Prefer to read it first (you should):

```sh
curl -fsSL https://raw.githubusercontent.com/craigloewen-msft/WSLc-remote/main/install.sh -o install.sh
less install.sh
bash install.sh
```

This installs a single script to `~/.local/bin/wslc`. It shadows the Windows `wslc` CLI on your
PATH, which is the point — wslc-remote calls the real `wslc.exe` for you.

Then check your setup:

```sh
wslc _check
```

## Requirements

- WSL with container support (provides `wslc.exe`)
- **WSL mirrored networking** — required. Add this to `%USERPROFILE%\.wslconfig` on Windows:

  ```ini
  [wsl2]
  networkingMode=mirrored
  ```

  then run `wsl --shutdown`. Without it the runtime VM can't reach your distro and every
  bind mount fails with `Connection refused`.
- bash 4+
- **`unfsd`** — the [UNFS3](https://github.com/unfs3/unfs3) userspace NFSv3 server. This is the
  only extra dependency. The installer gets it for you where the distro packages it:

  | Distro | |
  |---|---|
  | Debian / Ubuntu | `sudo apt-get install unfs3` |
  | openSUSE | `sudo zypper install unfs3` |
  | Arch | AUR only: `yay -S unfs3` |
  | Fedora / others | no package — build from source (below) |

  Building from source takes about a minute:

  ```sh
  git clone https://github.com/unfs3/unfs3
  cd unfs3
  ./bootstrap && ./configure && make && sudo make install
  ```

  Already have a binary? `export WSLC_REMOTE_UNFSD=/path/to/unfsd`.

## Usage

Anything you'd run with `wslc`:

```sh
# host bind mounts are transparently served over NFS
wslc run -v $(pwd):/work -w /work --rm debian:trixie-slim bash

# read-only binds stay read-only (the NFS export is read-only too)
wslc run -v $(pwd):/src:ro -v /home/me/data:/data --rm alpine sh

# --mount works as well
wslc run --mount type=bind,source=$(pwd),target=/work --rm alpine sh

# everything else is forwarded straight to the real wslc
wslc images
wslc inspect my-container
```

`wslc volume remove` / `wslc volume prune` also tear down the matching NFS share. All other
`volume` subcommands pass straight through.

wslc-remote adds exactly two commands of its own, both `_`-prefixed so they can never collide
with a current or future `wslc` subcommand: `wslc _check` and `wslc _help`.

## How it works

For each host bind mount, wslc-remote:

1. starts a `unfsd` NFSv3 server in your distro, exporting that directory on loopback only,
2. creates a `wslc` guest volume and NFS-mounts that server onto the volume's backing store
   inside the runtime VM,
3. rewrites your `-v /host/dir:/ctr` into `-v <volume>:/ctr` and execs the real `wslc`.

The container sees an ordinary bind mount. Traffic goes over NFS on `127.0.0.1` (via WSL mirrored
networking) instead of virtiofs. Shares are reused across runs and torn down with their volume.

## Configuration

| Variable | Default | |
|---|---|---|
| `WSLC` | `wslc.exe` on PATH, else `/mnt/c/Program Files/WSL/wslc.exe` | path to the real wslc CLI |
| `WSLC_REMOTE_UNFSD` | `unfsd` | path to the unfsd binary |
| `WSLC_REMOTE_BASE_PORT` | `12049` | first port in the range used for NFS servers |
| `WSLC_REMOTE_STATE` | `~/.local/state/wslc-remote` | share state, logs, exports |

The installer also takes `--dir DIR`, `--ref REF` and `--skip-deps`.

## Troubleshooting

Run `wslc _check` first — it verifies every dependency and finishes with a live test that the
container runtime VM can actually reach your distro over loopback.

| Symptom | Fix |
|---|---|
| `failed to NFS-mount volume backing store` / `Connection refused` | Mirrored networking is off. See [Requirements](#requirements). |
| `unfsd not found on PATH` | Install UNFS3, or `export WSLC_REMOTE_UNFSD=/path/to/unfsd`. |
| `wslc: command not found` after install | `~/.local/bin` isn't on your `PATH`. |

Per-share logs live in `~/.local/state/wslc-remote/`.

## Uninstall

```sh
wslc volume prune           # tear down any remaining NFS shares first
rm -f ~/.local/bin/wslc ~/.local/bin/unfsd
rm -rf ~/.local/state/wslc-remote
```

`unfsd` was installed separately — remove it with your package manager if you don't want it.

## License

MIT. See [LICENSE](LICENSE).
