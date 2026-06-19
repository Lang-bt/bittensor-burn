# **Bittensor Burn Monitor**

[![Python 3.9+](https://img.shields.io/badge/python-3.9+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

Monitor **Bittensor subnet owner burn rates** and receive **Telegram alerts** when burn changes beyond your threshold. Runs as a background daemon on **Windows, Linux, and macOS** with optional login auto-start.

[Taostats](https://taostats.io/) • [Bittensor docs](https://docs.learnbittensor.org)

---

## Table of contents

- [Overview](#overview)
- [Features](#features)
- [Install](#install)
  - [Install from cloned repo](#install-from-cloned-repo)
  - [Install from wheel folder](#install-from-wheel-folder)
  - [Install from source](#install-from-source)
- [Quick start](#quick-start)
- [Auto-start](#auto-start)
- [Configuration](#configuration)
- [Releases](#releases)
- [License](#license)

---

## Overview

Subnet **burn rate** (owner burn) affects emissions and economics on the Bittensor network. This tool polls the [Taostats](https://taostats.io/) API on a schedule, compares burn rates to your last snapshot, and sends a Telegram message when any subnet moves by more than your configured threshold.

All credentials live in **your** local config file (`~/.config/bittensor-burn-message/.env` on Linux, or the platform equivalent). Nothing is bundled in the package wheel.

---

## Features

- Poll Taostats for subnet owner burn rates on a configurable interval (default 30 minutes)
- Telegram alerts when burn delta exceeds a threshold (default 0.1)
- Cross-platform daemon: Windows, Linux, macOS
- Optional auto-start on login (Task Scheduler / systemd / LaunchAgent)
- Pre-built wheels for Python 3.9–3.14 (no compiler required for end users)

---

## Install


### Install from cloned repo

Recommended when installing offline from CI-built wheels.

1. Clone this repository:

   ```bash
   git clone https://github.com/Lang-bt/bittensor-burn.git
   cd bittensor-burn
   ```

2. Copy downloaded `.whl` files into `dist/` (OS-specific CI artifact: `wheels-windows-latest`, `wheels-ubuntu-latest`, or `wheels-macos-latest`).

3. From the **repo root**, install (do not move `dist/`):

   ```bash
   python scripts/install.py
   ```

   Or:

   ```bash
   pip install bittensor-burn-message --no-index --find-links dist
   ```

Build wheels locally, then install the same way:

```bash
python scripts/build_wheel.py --local
python scripts/install.py
```

### Install from wheel folder

If you only have a folder of `.whl` files (not a full clone), `cd` into that folder:

```bash
pip install bittensor-burn-message --no-index --find-links .
```

`pip` selects the wheel for your OS, CPU, and Python version automatically.

### Install from source

Requires a C compiler and Cython:

```bash
pip install .
# or editable:
pip install -e .
```

**Linux:** if `command not found` after install, add `~/.local/bin` to `PATH`, or run:

```bash
python3 -m bittensor_burn_message status
```

---

## Quick start

```bash
bittensor-burn-message install \
  --telegram_token TOKEN \
  --telegram_chat_id CHAT_ID \
  --interval MINUTES \
  --threshold DELTA
bittensor-burn-message wake                # start daemon when auto-start is installed but not running
bittensor-burn-message status
bittensor-burn-message stop                # pause burn monitoring
bittensor-burn-message resume              # resume burn monitoring
bittensor-burn-message burn-snapshot       # send all subnet burn rates (test)
bittensor-burn-message burn-watch-once     # single burn poll
```

Optional flags on `install`: `--interval MINUTES` (default 30), `--threshold DELTA` (default 0.1).

---

## Auto-start

Auto-start runs only the burn-monitoring daemon. After login or reboot, it waits for network, retries startup, and runs a watchdog `wake`. If the daemon does not come up, run `bittensor-burn-message wake`.

---

## Configuration

### Telegram (burn alerts)

1. Message **@BotFather** on Telegram → `/newbot` → copy the bot token.
2. Send your bot a message.
3. Open `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates` and copy `"chat":{"id": ...}`.

## Releases

Version **1.0.2** is defined in `pyproject.toml`.
---

## License

The MIT License (MIT). See [LICENSE](LICENSE).
