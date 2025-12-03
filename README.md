# hikkoshi

Profile-based `HOME` / XDG environment runner written in Zig.

`hikkoshi` (引っ越し, “moving house”) lets you define multiple named profiles, each with its own virtual `HOME` and XDG directories, then run commands inside those environments via a small CLI wrapper (`hks`). It is designed to keep configuration for different tools or contexts neatly separated.

One concrete motivation for this tool is using multiple Codex (or other CLI-based) accounts on the same machine: each profile gets its own config directory and auth state, so you can switch accounts by switching profiles.

---

## Features

- Profile-specific virtual `HOME` and XDG directories
- Explicit, TOML-based configuration
- Simple CLI:
  - `hks <profile> <command> [args...]`
  - `hks <profile> --sh '<shell-command>'`
- Helper subcommands:
  - `hks list` – list all profiles
  - `hks add <home> [name]` – append a minimal profile to the config
  - `hks show <profile>` – show resolved paths and env for a profile
  - `hks config-path` – print the config file path in use
  - `hks example` – print an example TOML config

---

## Installation

You need a recent Zig toolchain (tested with Zig 0.15.2).

```bash
zig build
```

The resulting binary will be available as:

- `zig-out/bin/hks` – main binary 

The recommended way to use it as a stable CLI is to create a symlink from a directory on your `PATH` to the built binary, for example on macOS (run this inside the cloned repo):

```bash
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

ln -sf "$(pwd)/zig-out/bin/hks" "$HOME/.local/bin/hks"
```

After opening a new terminal, you can run `hks` from anywhere.

---

## Configuration

By default, `hikkoshi` looks for a TOML configuration at:

- `$HOME/.config/hikkoshi/config.toml`

You can override this with:

- `HIKKOSHI_CONFIG=/path/to/config.toml`
- `hks --config /path/to/config.toml ...`

The configuration schema is:

```toml
[profiles.work]
home   = "~/profiles/work"
config = "~/profiles/work/.config"        # optional
data   = "~/profiles/work/.local/share"   # optional
cache  = "~/profiles/work/.cache"         # optional
state  = "~/profiles/work/.local/state"   # optional

[profiles.work.env]
APP_ENV = "work"
EDITOR  = "nvim"
```

Rules:

- `home` is required for each profile and defines the virtual `HOME`.
- `config`, `data`, `cache`, `state` are optional shorthand fields:
  - map to `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`
  - default to standard subdirectories under the profile `HOME` when omitted
- The `[profiles.<name>.env]` table adds extra environment variables:
  - entries for `HOME` or any key starting with `XDG_` are ignored (to avoid conflicting with profile fields).

You can always generate a starter config:

```bash
hks example > ~/.config/hikkoshi/config.toml
```

If the config file is missing, commands that need it will print a helpful hint and can optionally create an example config for you interactively.

---

## Usage

Run a command under a given profile:

```bash
hks dev nvim
hks work node app.mjs
hks test python script.py
```

Run an entire shell command line under a profile:

```bash
hks work --sh 'codex login'            # log into Codex under the "work" profile
hks alt  --sh 'codex login'            # log into Codex under the "alt" profile
hks work --sh 'codex'                  # open the interactive Codex CLI in "work"
```

List profiles:

```bash
hks list
```

Show resolved paths and environment for a profile:

```bash
hks show work
```

Print the config file path:

```bash
hks config-path
```

---

## Special Thanks

This project uses the excellent TOML parsing library **[sam701/zig-toml](https://github.com/sam701/zig-toml)**.  
Special thanks to its author and contributors for making TOML handling in Zig straightforward and pleasant.

---

## License

This project is licensed under the **Apache License, Version 2.0**.  
See the `LICENSE` file in this repository for the full text.

SPDX-License-Identifier: Apache-2.0
