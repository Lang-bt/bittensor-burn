"""bittensor_burn_message — Bittensor subnet burn monitoring."""

from __future__ import annotations

import argparse
import contextlib
import plistlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from importlib import resources

from bittensor_burn_message.subnet_metrics import (
    run_burn_poll_loop,
    run_burn_startup_snapshot,
    run_burn_watch_once,
    send_burn_telegram,
)


CLI_NAME = "bittensor-burn-message"
WINDOWS_TASK_NAME = "bittensor-burn-message"
WINDOWS_WATCHDOG_TASK_NAME = "bittensor-burn-message-watchdog"
WINDOWS_WATCHDOG_INTERVAL_MINUTES = 5
SYSTEMD_SERVICE_NAME = "bittensor-burn-message.service"
LINUX_WATCHDOG_SERVICE_NAME = "bittensor-burn-message-watchdog.service"
MACOS_LAUNCH_AGENT_LABEL = "com.bittensor.burn-message"
MACOS_LAUNCH_AGENT_PLIST = "com.bittensor.burn-message.plist"
MACOS_WATCHDOG_LAUNCH_AGENT_LABEL = "com.bittensor.burn-message-watchdog"
MACOS_WATCHDOG_LAUNCH_AGENT_PLIST = "com.bittensor.burn-message-watchdog.plist"
MACOS_WATCHDOG_INTERVAL_SECONDS = 900
AUTOSTART_INITIAL_DELAY_SECONDS = 10.0
AUTOSTART_NETWORK_POLL_SECONDS = 5.0
AUTOSTART_NETWORK_WAIT_MAX_SECONDS = 120.0
AUTOSTART_MAX_ATTEMPTS = 12
AUTOSTART_RETRY_BASE_SECONDS = 10.0
AUTOSTART_RETRY_MAX_SECONDS = 120.0
AUTOSTART_BURN_NETWORK_WAIT_MAX_SECONDS = 180.0
LINUX_WATCHDOG_TIMER_NAME = "bittensor-burn-message-watchdog.timer"
DAEMON_POLL_SECONDS = 30.0
BURN_STARTUP_HTTP_TIMEOUT_SECONDS = 25.0
BURN_STARTUP_HTTP_MAX_RETRIES = 3
_PKG_DIR = os.path.dirname(os.path.abspath(__file__))


def _is_pip_install() -> bool:
    path = _PKG_DIR.replace("\\", "/")
    return "site-packages" in path or "dist-packages" in path


def _pip_data_dir() -> str:
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(base, "bittensor-burn-message")
    cfg = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(cfg, "bittensor-burn-message")


def data_dir() -> str:
    """Config, logs, and pid files — user dir when pip-installed, else repo root."""
    override = os.environ.get("BITTENSOR_BURN_MESSAGE_DATA_DIR", "").strip()
    if override:
        root = os.path.abspath(override)
    elif _is_pip_install():
        root = _pip_data_dir()
    else:
        repo = os.path.dirname(_PKG_DIR)
        root = repo if os.path.exists(os.path.join(repo, "pyproject.toml")) else _PKG_DIR
    os.makedirs(root, exist_ok=True)
    return root


def env_file_path() -> str:
    override = os.environ.get("BITTENSOR_BURN_MESSAGE_ENV_FILE", "").strip()
    if override:
        return os.path.abspath(override)
    return os.path.join(data_dir(), ".env")


def _init_paths() -> None:
    global HERE, PID_FILE, DAEMON_LOG, BURN_STATE_FILE, ENV_FILE
    global DAEMON_LOCK_FILE, START_LOCK_FILE
    global BURN_PAUSED_FILE, BURN_STARTUP_SENT_FILE, BURN_STARTUP_SNAPSHOT_LOCK_FILE
    HERE = data_dir()
    PID_FILE = os.path.join(HERE, "bittensor_burn_message.pid")
    DAEMON_LOG = os.path.join(HERE, "bittensor_burn_message.daemon.log")
    BURN_STATE_FILE = os.path.join(HERE, ".subnet_burn_state.json")
    BURN_STARTUP_SENT_FILE = os.path.join(HERE, ".burn_startup_snapshot_sent")
    BURN_STARTUP_SNAPSHOT_LOCK_FILE = os.path.join(HERE, ".burn_startup_snapshot.lock")
    DAEMON_LOCK_FILE = os.path.join(HERE, "bittensor_burn_message.daemon.lock")
    START_LOCK_FILE = os.path.join(HERE, ".start.lock")
    BURN_PAUSED_FILE = os.path.join(HERE, ".burn_monitoring_paused")
    ENV_FILE = env_file_path()


_init_paths()


def _subprocess_no_window_kwargs() -> dict:
    if sys.platform == "win32":
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}


def ensure_env_file() -> None:
    if os.path.exists(ENV_FILE):
        return
    if os.environ.get("BITTENSOR_BURN_MESSAGE_ENV_FILE"):
        return
    try:
        text = resources.files("bittensor_burn_message").joinpath("env.example").read_text(
            encoding="utf-8"
        )
    except Exception:
        text = (
            "BURN_TELEGRAM_BOT_TOKEN=\n"
            "BURN_TELEGRAM_CHAT_ID=\n"
            "TAOSTATS_API_KEY=\n"
            "TAOSTATS_API_BASE=https://api.taostats.io\n"
            "BURN_ALERT_THRESHOLD=0.1\n"
            "BURN_WATCH_INTERVAL_MINUTES=30\n"
        )
    with open(ENV_FILE, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"Created {ENV_FILE}")


def _parse_env_lines(text: str) -> None:
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ[key] = value


def load_env_file(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        _parse_env_lines(f.read())


def apply_config() -> None:
    global BURN_TELEGRAM_BOT_TOKEN, BURN_TELEGRAM_CHAT_ID
    global BURN_ALERT_THRESHOLD, BURN_WATCH_INTERVAL_MINUTES, TAOSTATS_API_KEY
    BURN_TELEGRAM_BOT_TOKEN = os.environ.get("BURN_TELEGRAM_BOT_TOKEN", "").strip()
    BURN_TELEGRAM_CHAT_ID = os.environ.get("BURN_TELEGRAM_CHAT_ID", "").strip()
    BURN_ALERT_THRESHOLD = float(os.environ.get("BURN_ALERT_THRESHOLD", "0.1"))
    BURN_WATCH_INTERVAL_MINUTES = float(
        os.environ.get("BURN_WATCH_INTERVAL_MINUTES", "30")
    )
    TAOSTATS_API_KEY = os.environ.get("TAOSTATS_API_KEY", "").strip()


def reload_config() -> None:
    """Reload user .env (daemon must call after config changes)."""
    load_env_file(ENV_FILE)
    apply_config()


ensure_env_file()
reload_config()


def package_cli() -> list[str]:
    """Argv prefix to invoke this package (installed entry point or python -m)."""
    cmd = shutil.which(CLI_NAME)
    if cmd:
        return [cmd]
    return [sys.executable, "-m", "bittensor_burn_message"]


def _windows_python_exe(*, windowless: bool = False) -> str:
    exe = sys.executable
    if windowless and exe.lower().endswith("python.exe"):
        pythonw = os.path.join(os.path.dirname(exe), "pythonw.exe")
        if os.path.isfile(pythonw):
            return pythonw
    return exe


def _quote_cmd_arg(arg: str) -> str:
    if not arg or any(c in arg for c in ' \t"'):
        return '"' + arg.replace('"', '\\"') + '"'
    return arg


def daemon_spawn_argv(subcommand: str = "_run") -> list[str]:
    """Argv for background daemon — bypass pip .exe on Windows (breaks DETACHED_PROCESS)."""
    if sys.platform == "win32":
        return [
            _windows_python_exe(windowless=True),
            "-m",
            "bittensor_burn_message",
            subcommand,
        ]
    if sys.platform == "darwin":
        return [
            os.path.realpath(sys.executable),
            "-m",
            "bittensor_burn_message",
            subcommand,
        ]
    # Linux: always python -m (pip user scripts live in ~/.local/bin, often missing from PATH/systemd).
    return [os.path.realpath(sys.executable), "-m", "bittensor_burn_message", subcommand]


def burn_monitoring_enabled() -> bool:
    return bool(
        BURN_TELEGRAM_BOT_TOKEN
        and BURN_TELEGRAM_CHAT_ID
        and TAOSTATS_API_KEY
    )


def burn_monitoring_paused() -> bool:
    return os.path.isfile(BURN_PAUSED_FILE)


def set_burn_monitoring_paused(paused: bool) -> None:
    if paused:
        with open(BURN_PAUSED_FILE, "w", encoding="utf-8") as f:
            f.write("1\n")
    elif os.path.isfile(BURN_PAUSED_FILE):
        os.remove(BURN_PAUSED_FILE)


def autostart_is_configured() -> bool:
    if sys.platform == "win32":
        proc = subprocess.run(
            ["schtasks", "/Query", "/TN", WINDOWS_TASK_NAME],
            capture_output=True,
            text=True,
            **_subprocess_no_window_kwargs(),
        )
        return proc.returncode == 0
    if sys.platform == "darwin":
        return os.path.exists(macos_launch_agent_path())
    return _linux_systemd_unit_valid(systemd_unit_path())


def _write_text_file_atomic(path: str, content: str) -> None:
    """Write atomically so systemd never sees a truncated unit during reload."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.",
        suffix=".tmp",
        dir=directory,
        text=True,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def _linux_systemd_unit_valid(path: str) -> bool:
    if not os.path.isfile(path):
        return False
    try:
        if os.path.getsize(path) < 32:
            return False
        with open(path, encoding="utf-8") as f:
            body = f.read(4096)
    except OSError:
        return False
    return (
        ("[Service]" in body and "ExecStart=" in body)
        or ("[Timer]" in body and ("OnBootSec=" in body or "OnUnitActiveSec=" in body))
    )


def _linux_systemd_unit_state(path: str) -> str:
    """Return enabled, broken, or missing for status/install messaging."""
    if not os.path.isfile(path):
        return "missing"
    if not _linux_systemd_unit_valid(path):
        return "broken"
    proc = subprocess.run(
        ["systemctl", "--user", "is-enabled", SYSTEMD_SERVICE_NAME],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        out = (proc.stdout or proc.stderr or "").strip().lower()
        if "masked" in out or "invalid" in out:
            return "broken"
    return "enabled"


def _linux_systemd_prepare_unit(unit_name: str) -> None:
    subprocess.run(
        ["systemctl", "--user", "unmask", unit_name],
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ["systemctl", "--user", "reset-failed", unit_name],
        capture_output=True,
        text=True,
    )


def ensure_daemon_running(*, quiet: bool = True, force: bool = False) -> bool:
    """Start daemon if not running. Returns True if daemon is up."""
    if daemon_pid() is not None:
        return True
    cmd_start(quiet=quiet, force=force)
    return daemon_pid() is not None


def _read_env_file_keys(path: str) -> dict[str, str]:
    if not os.path.exists(path):
        return {}
    out: dict[str, str] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            out[key.strip()] = val.strip().strip('"').strip("'")
    return out


def _write_env_file_keys(path: str, updates: dict[str, str]) -> None:
    existing_lines: list[str] = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            existing_lines = f.read().splitlines()
    keys_written: set[str] = set()
    new_lines: list[str] = []
    for line in existing_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            new_lines.append(line)
            continue
        key, _, _ = stripped.partition("=")
        key = key.strip()
        if key in updates:
            new_lines.append(f"{key}={updates[key]}")
            keys_written.add(key)
        else:
            new_lines.append(line)
    for key, val in updates.items():
        if key not in keys_written:
            new_lines.append(f"{key}={val}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines).rstrip() + "\n")


def parse_install_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog=f"{CLI_NAME} install",
        description="Install autostart and configure subnet burn rate Telegram alerts.",
    )
    p.add_argument(
        "--telegram_token",
        metavar="TOKEN",
        help="Your Telegram bot token for subnet burn rate alerts",
    )
    p.add_argument(
        "--telegram_chat_id",
        metavar="CHAT_ID",
        help="Your Telegram chat id for subnet burn rate alerts",
    )
    p.add_argument(
        "--interval",
        type=float,
        metavar="MINUTES",
        help="How often to poll burn rates (default: 30)",
    )
    p.add_argument(
        "--threshold",
        type=float,
        metavar="DELTA",
        help="Alert when owner burn changes by more than this (default: 0.1)",
    )
    p.add_argument(
        "--taostats_api_key",
        metavar="KEY",
        help="Your Taostats API key (https://taostats.io)",
    )
    return p.parse_args(argv)


def save_burn_config_from_install_args(args: argparse.Namespace) -> None:
    """Persist per-user burn monitor settings from install flags."""
    token = (args.telegram_token or "").strip()
    chat_id = (args.telegram_chat_id or "").strip()
    taostats_key = (args.taostats_api_key or "").strip()
    has_burn_args = bool(
        token
        or chat_id
        or taostats_key
        or args.interval is not None
        or args.threshold is not None
    )
    if not has_burn_args:
        return
    if not token or not chat_id:
        print(
            "Burn monitoring requires both --telegram_token and --telegram_chat_id.",
            file=sys.stderr,
        )
        sys.exit(1)
    if not taostats_key:
        print(
            "Burn monitoring requires --taostats_api_key "
            "(get a key at https://taostats.io).",
            file=sys.stderr,
        )
        sys.exit(1)
    updates: dict[str, str] = {
        "BURN_TELEGRAM_BOT_TOKEN": token,
        "BURN_TELEGRAM_CHAT_ID": chat_id,
        "TAOSTATS_API_KEY": taostats_key,
    }
    if args.threshold is not None:
        updates["BURN_ALERT_THRESHOLD"] = str(args.threshold)
    if args.interval is not None:
        updates["BURN_WATCH_INTERVAL_MINUTES"] = str(args.interval)
    _write_env_file_keys(ENV_FILE, updates)
    _clear_burn_startup_snapshot_sent()
    reload_config()
    interval = BURN_WATCH_INTERVAL_MINUTES
    print(
        f"Burn monitoring configured "
        f"(threshold {BURN_ALERT_THRESHOLD}, every {interval:g} min)."
    )


@contextlib.contextmanager
def _exclusive_file_lock(lock_path: str):
    fd: int | None = None
    for _ in range(200):
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            time.sleep(0.025)
    try:
        yield fd is not None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(lock_path)
        except OSError:
            pass


@contextlib.contextmanager
def _start_lock():
    with _exclusive_file_lock(START_LOCK_FILE) as acquired:
        yield acquired


def _daemon_lock_holder_pid() -> int | None:
    try:
        with open(DAEMON_LOCK_FILE, encoding="utf-8") as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError, OSError):
        return None


def _process_cmdline(pid: int) -> str:
    if sys.platform == "win32":
        try:
            proc = subprocess.run(
                [
                    "wmic",
                    "process",
                    "where",
                    f"ProcessId={int(pid)}",
                    "get",
                    "CommandLine",
                    "/format:list",
                ],
                capture_output=True,
                text=True,
                timeout=5,
                **_subprocess_no_window_kwargs(),
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return ""
        for line in (proc.stdout or "").splitlines():
            if line.startswith("CommandLine="):
                return line.partition("=")[2].strip()
        return ""
    if sys.platform == "darwin":
        try:
            proc = subprocess.run(
                ["ps", "-p", str(int(pid)), "-o", "args="],
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return ""
        return (proc.stdout or "").strip()
    try:
        with open(f"/proc/{int(pid)}/cmdline", "rb") as f:
            cmd = f.read().replace(b"\x00", b" ").decode("utf-8", errors="replace").strip()
    except OSError:
        cmd = ""
    if cmd:
        return cmd
    try:
        proc = subprocess.run(
            ["ps", "-p", str(int(pid)), "-o", "args="],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""
    return (proc.stdout or "").strip()


def _daemon_cmdline_matches(cmd: str) -> bool:
    lowered = cmd.lower()
    if not lowered:
        return False
    markers = (
        "bittensor_burn_message",
        "bittensor-burn-message",
    )
    if not any(marker in lowered for marker in markers):
        return False
    return "_run" in lowered or " -m " in lowered


def _is_our_daemon_pid(pid: int | None) -> bool:
    if pid is None or not is_running(pid):
        return False
    holder = _daemon_lock_holder_pid()
    if holder == pid and os.path.exists(DAEMON_LOCK_FILE):
        return True
    return _daemon_cmdline_matches(_process_cmdline(pid))


def _live_daemon_lock_holder() -> int | None:
    holder = _daemon_lock_holder_pid()
    if holder is not None and is_running(holder):
        return holder
    return None


def _cleanup_stale_daemon_files() -> None:
    if os.path.exists(PID_FILE):
        try:
            os.remove(PID_FILE)
        except OSError:
            pass
    try:
        os.unlink(DAEMON_LOCK_FILE)
    except OSError:
        pass


def acquire_daemon_lock() -> int | None:
    """Exclusive lock so only one _run daemon is active."""
    try:
        fd = os.open(DAEMON_LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        if _live_daemon_lock_holder() is not None:
            return None
        try:
            os.unlink(DAEMON_LOCK_FILE)
        except OSError:
            return None
        return acquire_daemon_lock()
    os.write(fd, str(os.getpid()).encode())
    return fd


def release_daemon_lock(fd: int | None) -> None:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        os.unlink(DAEMON_LOCK_FILE)
    except OSError:
        pass


def _network_is_reachable(timeout: float = 3.0) -> bool:
    import socket

    for host, port in (("1.1.1.1", 443), ("8.8.8.8", 53)):
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except OSError:
            continue
    return False


def _wait_for_network_ready(
    *,
    max_wait_seconds: float = AUTOSTART_NETWORK_WAIT_MAX_SECONDS,
    poll_seconds: float = AUTOSTART_NETWORK_POLL_SECONDS,
    log=None,
) -> bool:
    """Return True once outbound connectivity works, False after timeout."""
    deadline = time.time() + max_wait_seconds
    while time.time() < deadline:
        if _network_is_reachable():
            return True
        if log is not None:
            remaining = max(0.0, deadline - time.time())
            log(f"network not ready, retrying ({remaining:.0f}s left)")
        time.sleep(poll_seconds)
    return False


def _autostart_log(message: str) -> None:
    line = f"[autostart] {message}\n"
    sys.stderr.write(line)
    sys.stderr.flush()


def _apply_taostats_env() -> None:
    if TAOSTATS_API_KEY:
        os.environ["TAOSTATS_API_KEY"] = TAOSTATS_API_KEY
    base = os.environ.get("TAOSTATS_API_BASE", "https://api.taostats.io").strip()
    os.environ["TAOSTATS_API_BASE"] = base or "https://api.taostats.io"


def burn_startup_snapshot_sent() -> bool:
    return os.path.isfile(BURN_STARTUP_SENT_FILE)


def _mark_burn_startup_snapshot_sent() -> None:
    with open(BURN_STARTUP_SENT_FILE, "w", encoding="utf-8") as f:
        f.write(datetime.now(timezone.utc).isoformat() + "\n")


def _clear_burn_startup_snapshot_sent() -> None:
    if os.path.isfile(BURN_STARTUP_SENT_FILE):
        os.remove(BURN_STARTUP_SENT_FILE)


def send_install_burn_snapshot(*, quiet: bool = False) -> bool:
    """Full subnet burn snapshot — once after install (not on every reboot)."""
    reload_config()
    if not burn_monitoring_enabled() or burn_monitoring_paused():
        return False
    if burn_startup_snapshot_sent():
        if not quiet:
            print("Burn startup snapshot already sent (skipping).")
        return True
    with _exclusive_file_lock(BURN_STARTUP_SNAPSHOT_LOCK_FILE) as locked:
        if not locked:
            return False
        if burn_startup_snapshot_sent():
            return True
        if not _network_is_reachable():
            _wait_for_network_ready(max_wait_seconds=AUTOSTART_BURN_NETWORK_WAIT_MAX_SECONDS)
        _apply_taostats_env()
        if not quiet:
            print("Sending burn startup snapshot to Telegram...")
        try:
            code = run_burn_startup_snapshot(
                state_path=BURN_STATE_FILE,
                burn_token=BURN_TELEGRAM_BOT_TOKEN,
                burn_chat_id=BURN_TELEGRAM_CHAT_ID,
                http_timeout=BURN_STARTUP_HTTP_TIMEOUT_SECONDS,
                max_retries=BURN_STARTUP_HTTP_MAX_RETRIES,
            )
        except Exception as exc:
            sys.stderr.write(f"[burn] startup snapshot error: {exc}\n")
            sys.stderr.flush()
            if not quiet:
                print(
                    "Burn startup snapshot failed (network/API timeout). "
                    "Daemon is still running — retry with: bittensor-burn-message burn-snapshot"
                )
            return False
        if code == 0:
            _mark_burn_startup_snapshot_sent()
            if not quiet:
                print("Burn startup snapshot sent.")
            return True
        if not quiet:
            print(
                "Burn startup snapshot failed — check daemon log or run: "
                "bittensor-burn-message burn-snapshot"
            )
        return False


_burn_thread: threading.Thread | None = None


def _burn_thread_alive() -> bool:
    return _burn_thread is not None and _burn_thread.is_alive()


def _sync_burn_thread() -> None:
    """Start burn poll thread when enabled and not paused."""
    global _burn_thread
    if burn_monitoring_paused() or not burn_monitoring_enabled():
        return
    if _burn_thread_alive():
        return
    _burn_thread = None
    _apply_taostats_env()
    _burn_thread = threading.Thread(
        target=run_burn_poll_loop,
        kwargs={
            "state_path": BURN_STATE_FILE,
            "threshold": BURN_ALERT_THRESHOLD,
            "interval_minutes": BURN_WATCH_INTERVAL_MINUTES,
            "burn_token": BURN_TELEGRAM_BOT_TOKEN,
            "burn_chat_id": BURN_TELEGRAM_CHAT_ID,
            "pause_path": BURN_PAUSED_FILE,
        },
        daemon=True,
        name="burn-watch",
    )
    _burn_thread.start()
    sys.stderr.write(
        f"[burn] polling every {BURN_WATCH_INTERVAL_MINUTES:g} min "
        f"(threshold {BURN_ALERT_THRESHOLD})\n"
    )
    sys.stderr.flush()


def _detach_from_terminal() -> None:
    if sys.platform == "win32":
        return
    try:
        fd = os.open(os.devnull, os.O_RDWR)
    except OSError:
        return
    try:
        os.dup2(fd, 0)
        os.setsid()
    except OSError:
        pass
    finally:
        if fd > 2:
            os.close(fd)


def _daemon_try_startup_burn_snapshot() -> None:
    if not burn_monitoring_enabled() or burn_monitoring_paused():
        return
    if burn_startup_snapshot_sent():
        return

    def _worker() -> None:
        try:
            send_install_burn_snapshot(quiet=True)
        except Exception as exc:
            sys.stderr.write(f"[burn] daemon startup snapshot error: {exc}\n")
            sys.stderr.flush()

    threading.Thread(
        target=_worker,
        name="burn-startup-snapshot",
        daemon=True,
    ).start()


def _daemon_polling_loop() -> None:
    """Keep burn monitoring running and reload config periodically."""
    while True:
        reload_config()
        _sync_burn_thread()
        time.sleep(DAEMON_POLL_SECONDS)


def run_loop() -> None:
    lock_fd = acquire_daemon_lock()
    if lock_fd is None:
        sys.stderr.write(f"{CLI_NAME}: another daemon is already running\n")
        sys.stderr.flush()
        sys.exit(0)

    def _shutdown(*_args: object) -> None:
        release_daemon_lock(lock_fd)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    _detach_from_terminal()
    write_pid(os.getpid())
    try:
        reload_config()
        sys.stderr.write(
            f"[daemon] started pid={os.getpid()} data_dir={HERE}\n"
        )
        sys.stderr.flush()
        if os.environ.get("BITTENSOR_BURN_MESSAGE_AUTOSTART") == "1":
            sys.stderr.write(
                f"[autostart] settle delay "
                f"{AUTOSTART_INITIAL_DELAY_SECONDS:.0f}s\n"
            )
            sys.stderr.flush()
            time.sleep(AUTOSTART_INITIAL_DELAY_SECONDS)
        _sync_burn_thread()
        _daemon_try_startup_burn_snapshot()
        _daemon_polling_loop()
    finally:
        release_daemon_lock(lock_fd)


def write_pid(pid: int) -> None:
    with open(PID_FILE, "w", encoding="utf-8") as f:
        f.write(str(pid))


def read_pid() -> int | None:
    try:
        with open(PID_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return None


def is_running(pid: int | None) -> bool:
    if pid is None:
        return False
    if sys.platform == "win32":
        import ctypes

        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))
        if handle:
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def daemon_pid() -> int | None:
    """Best-effort live daemon pid (lock file is authoritative when holder is alive)."""
    holder = _live_daemon_lock_holder()
    if holder is not None:
        write_pid(holder)
        return holder
    if os.path.exists(DAEMON_LOCK_FILE):
        _cleanup_stale_daemon_files()
    pid = read_pid()
    if pid is not None:
        if _is_our_daemon_pid(pid):
            return pid
        if is_running(pid):
            return None
        try:
            os.remove(PID_FILE)
        except OSError:
            pass
    return None


def _daemon_log_burn_lines(max_lines: int = 8) -> list[str]:
    try:
        with open(DAEMON_LOG, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []
    hits = [
        line.rstrip()
        for line in lines
        if line.startswith("[burn]")
        or line.startswith("[autostart]")
    ]
    return hits[-max_lines:]


def _daemon_log_tail(max_lines: int = 40) -> str:
    try:
        with open(DAEMON_LOG, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        return "".join(lines[-max_lines:]).strip()
    except OSError:
        return ""


def _redirect_daemon_logs() -> None:
    path = (
        os.environ.get("BITTENSOR_BURN_MESSAGE_DAEMON_LOG", "").strip()
        or DAEMON_LOG
    )
    try:
        logf = open(path, "a", encoding="utf-8", buffering=1)
        sys.stdout = logf
        sys.stderr = logf
    except OSError:
        pass


def _wait_for_daemon(timeout: float = 15.0) -> int | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = daemon_pid()
        if pid is not None:
            write_pid(pid)
            return pid
        time.sleep(0.2)
    return None


def _popen_daemon() -> subprocess.Popen:
    env = os.environ.copy()
    env["BITTENSOR_BURN_MESSAGE_DAEMON_LOG"] = DAEMON_LOG
    kwargs: dict = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "cwd": HERE,
        "env": env,
    }
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(daemon_spawn_argv("_run"), **kwargs)


def cmd_start(*, quiet: bool = False, force: bool = False) -> None:
    if not quiet and not force and autostart_is_configured():
        print("Auto-start is installed. Daemon starts on login — manual start is disabled.")
        print("Use: bittensor-burn-message status")
        return
    with _start_lock() as locked:
        if not locked:
            print("Another start is in progress.")
            return
        pid = daemon_pid()
        if pid is not None:
            if not quiet:
                print(f"Already running (pid {pid}).")
            return
        _popen_daemon()
    pid = _wait_for_daemon()
    if pid is None:
        print(f"Daemon failed to start. Check log: {DAEMON_LOG}")
        tail = _daemon_log_tail()
        if tail:
            print("--- log tail ---")
            print(tail)
        return
    if quiet:
        print("Started.")
    else:
        print(f"Started (pid {pid}).")
        print("Use 'bittensor-burn-message status' for config paths.")


def cmd_autostart() -> None:
    """Used by Task Scheduler / systemd on login (not for manual use)."""
    holder = _live_daemon_lock_holder()
    if holder is not None:
        _autostart_log(f"daemon already running (pid {holder})")
        return

    _autostart_log(
        f"waiting {AUTOSTART_INITIAL_DELAY_SECONDS:.0f}s for login services to settle"
    )
    time.sleep(AUTOSTART_INITIAL_DELAY_SECONDS)

    if _wait_for_network_ready(log=_autostart_log):
        _autostart_log("network ready")
    else:
        _autostart_log(
            "network not confirmed — starting daemon anyway"
        )

    for attempt in range(1, AUTOSTART_MAX_ATTEMPTS + 1):
        if daemon_pid() is not None:
            _autostart_log(f"daemon running after attempt {attempt}")
            return
        _autostart_log(f"start attempt {attempt}/{AUTOSTART_MAX_ATTEMPTS}")
        cmd_start(quiet=True, force=True)
        if daemon_pid() is not None:
            _autostart_log(f"daemon running after attempt {attempt}")
            return
        if attempt >= AUTOSTART_MAX_ATTEMPTS:
            break
        delay = min(
            AUTOSTART_RETRY_BASE_SECONDS * (2 ** (attempt - 1)),
            AUTOSTART_RETRY_MAX_SECONDS,
        )
        _autostart_log(f"daemon not up, retrying in {delay:.0f}s")
        time.sleep(delay)

    _autostart_log("gave up — run: bittensor-burn-message wake")
    sys.exit(1)


def cmd_wake() -> None:
    """Start daemon when auto-start is installed but process is not running."""
    cmd_start(force=True)


def cmd_stop() -> None:
    """Pause burn monitoring."""
    if not burn_monitoring_enabled():
        print("Burn monitoring is not configured.")
        return
    set_burn_monitoring_paused(True)
    if not ensure_daemon_running(quiet=True, force=True):
        print("Could not start daemon.")
        return
    print("Burn monitoring stopped.")


def cmd_resume() -> None:
    """Resume burn monitoring Telegram alerts."""
    if not burn_monitoring_enabled():
        print("Burn monitoring is not configured.")
        print(
            "Run: bittensor-burn-message install --telegram_token ... "
            "--telegram_chat_id ... --taostats_api_key ..."
        )
        return
    set_burn_monitoring_paused(False)
    if not ensure_daemon_running(quiet=True, force=True):
        print("Could not start daemon.")
        return
    _apply_taostats_env()
    code = run_burn_startup_snapshot(
        state_path=BURN_STATE_FILE,
        burn_token=BURN_TELEGRAM_BOT_TOKEN,
        burn_chat_id=BURN_TELEGRAM_CHAT_ID,
    )
    if code == 0:
        _mark_burn_startup_snapshot_sent()
        print("Burn monitoring resumed (startup snapshot sent).")
    else:
        print("Burn monitoring resumed (startup snapshot failed — check daemon log).")


def cmd_shutdown() -> None:
    """Stop the background daemon (burn)."""
    pid = daemon_pid()
    if pid is None:
        print("Not running.")
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
        release_daemon_lock(None)
        return
    os.kill(pid, signal.SIGTERM)
    print(f"Daemon stopped (pid {pid}).")
    if os.path.exists(PID_FILE):
        os.remove(PID_FILE)
    release_daemon_lock(None)


def cmd_status() -> None:
    pid = daemon_pid()
    if pid is not None:
        print(f"Running (pid {pid}).")
    else:
        stale_pid = read_pid()
        if stale_pid is not None and is_running(stale_pid):
            print(
                f"Not running (stale pid {stale_pid} — another process reused that pid)."
            )
            print("  Run: bittensor-burn-message wake")
        else:
            print("Not running.")
            unit_state = (
                _linux_systemd_unit_state(systemd_unit_path())
                if sys.platform == "linux"
                else "enabled"
            )
            if unit_state == "broken":
                print("  Auto-start unit is broken — run: bittensor-burn-message install")
            elif autostart_is_configured():
                print("  Start now: bittensor-burn-message wake")
    if sys.platform == "win32":
        if _windows_task_exists(WINDOWS_TASK_NAME):
            print(f'Auto-start: enabled (Task Scheduler "{WINDOWS_TASK_NAME}").')
        else:
            print("Auto-start: not installed.")
        if _windows_task_exists(WINDOWS_WATCHDOG_TASK_NAME):
            print(
                f'Watchdog: enabled (Task Scheduler "{WINDOWS_WATCHDOG_TASK_NAME}", '
                f"every {WINDOWS_WATCHDOG_INTERVAL_MINUTES} min)."
            )
        elif _windows_task_exists(WINDOWS_TASK_NAME):
            print(
                f'Watchdog: not installed — run: bittensor-burn-message install '
                f'(adds "{WINDOWS_WATCHDOG_TASK_NAME}").'
            )
    elif sys.platform == "darwin":
        path = macos_launch_agent_path()
        if os.path.exists(path):
            print(f"Auto-start: enabled (LaunchAgent {path}).")
        else:
            print("Auto-start: not installed.")
        watchdog_path = macos_watchdog_launch_agent_path()
        if os.path.exists(watchdog_path):
            print(
                f"Watchdog: enabled (LaunchAgent {watchdog_path}, "
                f"every {MACOS_WATCHDOG_INTERVAL_SECONDS // 60} min)."
            )
        elif os.path.exists(path):
            print(
                "Watchdog: not installed — run: bittensor-burn-message install "
                f"(adds {MACOS_WATCHDOG_LAUNCH_AGENT_PLIST})."
            )
    elif _linux_systemd_unit_state(systemd_unit_path()) == "broken":
        print(
            f"Auto-start: broken ({systemd_unit_path()} is empty or invalid)."
        )
        print("  Repair: bittensor-burn-message install")
    elif os.path.exists(systemd_unit_path()):
        print(f"Auto-start: enabled ({systemd_unit_path()}).")
    else:
        print("Auto-start: not installed.")
    print(f"Config file: {ENV_FILE}")
    print(f"Data directory: {HERE}")
    if burn_monitoring_enabled():
        if burn_monitoring_paused():
            print(
                f"Burn monitoring: paused (threshold {BURN_ALERT_THRESHOLD}, "
                f"every {BURN_WATCH_INTERVAL_MINUTES:g} min)"
            )
            print("  Run: bittensor-burn-message resume")
        else:
            print(
                f"Burn monitoring: on (threshold {BURN_ALERT_THRESHOLD}, "
                f"every {BURN_WATCH_INTERVAL_MINUTES:g} min)"
            )
            print(
                "  Burn alerts go to YOUR bot/chat. "
                "Run: bittensor-burn-message stop to pause burn."
            )
    elif BURN_TELEGRAM_BOT_TOKEN or BURN_TELEGRAM_CHAT_ID:
        if not TAOSTATS_API_KEY:
            print(
                "Burn monitoring: incomplete (set TAOSTATS_API_KEY in config or "
                "use install --taostats_api_key ...)"
            )
        else:
            print(
                "Burn monitoring: incomplete "
                "(need --telegram_token and --telegram_chat_id on install)"
            )
    else:
        print(
            "Burn monitoring: off "
            "(bittensor-burn-message install --telegram_token ... "
            "--telegram_chat_id ... --taostats_api_key ...)"
        )
    print(f"Daemon log: {DAEMON_LOG}")
    burn_log = _daemon_log_burn_lines()
    if burn_log:
        print("Recent burn/autostart log:")
        for line in burn_log:
            print(f"  {line}")
    elif pid is not None and burn_monitoring_enabled() and not burn_monitoring_paused():
        print("  No burn log lines yet — check daemon log if Telegram is silent.")


def systemd_unit_path() -> str:
    return os.path.join(
        os.path.expanduser("~/.config/systemd/user"), SYSTEMD_SERVICE_NAME
    )


def macos_launch_agent_path() -> str:
    return os.path.join(
        os.path.expanduser("~/Library/LaunchAgents"), MACOS_LAUNCH_AGENT_PLIST
    )


def macos_watchdog_launch_agent_path() -> str:
    return os.path.join(
        os.path.expanduser("~/Library/LaunchAgents"), MACOS_WATCHDOG_LAUNCH_AGENT_PLIST
    )


def _macos_launch_agent_path_for_plist(plist_name: str) -> str:
    return os.path.join(os.path.expanduser("~/Library/LaunchAgents"), plist_name)


def _macos_remove_launch_agent_plist(plist_name: str) -> bool:
    path = _macos_launch_agent_path_for_plist(plist_name)
    if not os.path.exists(path):
        return False
    _launchctl_bootout_plist(path)
    os.remove(path)
    return True


def _macos_launch_agent_env() -> dict[str, str]:
    return {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.path.expanduser("~"),
    }


def _macos_bootstrap_launch_agent(path: str, label: str) -> None:
    proc = subprocess.run(
        ["launchctl", "bootstrap", _macos_gui_domain(), path],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        if "already bootstrapped" not in err.lower():
            print(err or "launchctl bootstrap failed")
            sys.exit(1)
        subprocess.run(
            [
                "launchctl", "kickstart", "-k",
                f"{_macos_gui_domain()}/{label}",
            ],
            capture_output=True,
            text=True,
        )


def _macos_gui_domain() -> str:
    return f"gui/{os.getuid()}"


def _launchctl_bootout_plist(plist_path: str) -> None:
    subprocess.run(
        ["launchctl", "bootout", _macos_gui_domain(), plist_path],
        capture_output=True,
        text=True,
    )


def cmd_install_macos() -> None:
    agent_dir = os.path.dirname(macos_launch_agent_path())
    os.makedirs(agent_dir, exist_ok=True)
    path = macos_launch_agent_path()
    watchdog_path = macos_watchdog_launch_agent_path()
    log_path = os.path.abspath(DAEMON_LOG)
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    env = _macos_launch_agent_env()
    env["BITTENSOR_BURN_MESSAGE_AUTOSTART"] = "1"
    plist = {
        "Label": MACOS_LAUNCH_AGENT_LABEL,
        "ProgramArguments": daemon_spawn_argv("_run"),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "WorkingDirectory": HERE,
        "StandardOutPath": log_path,
        "StandardErrorPath": log_path,
        "EnvironmentVariables": env,
    }
    watchdog_plist = {
        "Label": MACOS_WATCHDOG_LAUNCH_AGENT_LABEL,
        "ProgramArguments": daemon_spawn_argv("wake"),
        "RunAtLoad": True,
        "StartInterval": MACOS_WATCHDOG_INTERVAL_SECONDS,
        "WorkingDirectory": HERE,
        "StandardOutPath": log_path,
        "StandardErrorPath": log_path,
        "EnvironmentVariables": _macos_launch_agent_env(),
    }
    if os.path.exists(path):
        _launchctl_bootout_plist(path)
    if os.path.exists(watchdog_path):
        _launchctl_bootout_plist(watchdog_path)
    with open(path, "wb") as f:
        plistlib.dump(plist, f)
    with open(watchdog_path, "wb") as f:
        plistlib.dump(watchdog_plist, f)
    _macos_bootstrap_launch_agent(path, MACOS_LAUNCH_AGENT_LABEL)
    _macos_bootstrap_launch_agent(watchdog_path, MACOS_WATCHDOG_LAUNCH_AGENT_LABEL)
    print(f"Installed LaunchAgent {path}")
    print(
        f"Installed watchdog LaunchAgent {watchdog_path} "
        f"(every {MACOS_WATCHDOG_INTERVAL_SECONDS // 60} min)."
    )
    print("Will start automatically when you sign in to macOS.")
    if daemon_pid() is None:
        _wait_for_daemon()


def cmd_uninstall_macos() -> None:
    _clear_burn_startup_snapshot_sent()
    removed = False
    for plist_name in (
        MACOS_WATCHDOG_LAUNCH_AGENT_PLIST,
        MACOS_LAUNCH_AGENT_PLIST,
    ):
        if _macos_remove_launch_agent_plist(plist_name):
            print(f"Removed LaunchAgent {plist_name}")
            removed = True
    if not removed:
        print("No LaunchAgent installed.")
        return
    cmd_shutdown()


def autostart_command_line() -> str:
    return " ".join(_quote_cmd_arg(part) for part in daemon_spawn_argv("_autostart"))


def linux_daemon_command_line() -> str:
    """systemd ExecStart — run _run directly (oneshot _autostart kills the child cgroup)."""
    return " ".join(_quote_cmd_arg(part) for part in daemon_spawn_argv("_run"))


def autostart_stop_command_line() -> str:
    cmd = shutil.which(CLI_NAME)
    if cmd:
        return f"{_quote_cmd_arg(cmd)} shutdown"
    return f"{_quote_cmd_arg(sys.executable)} -m bittensor_burn_message shutdown"


def _run_powershell(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
        **_subprocess_no_window_kwargs(),
    )


def _windows_task_exists(task_name: str) -> bool:
    proc = subprocess.run(
        ["schtasks", "/Query", "/TN", task_name],
        capture_output=True,
        text=True,
        **_subprocess_no_window_kwargs(),
    )
    return proc.returncode == 0


def _windows_persistent_task_settings_ps() -> str:
    """Task Scheduler settings that never stop the job for battery/time limits."""
    return """
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew
"""


def _windows_register_task(
    task_name: str,
    subcommand: str,
    *,
    at_logon: bool = False,
    every_minutes: int | None = None,
) -> subprocess.CompletedProcess[str]:
    argv = daemon_spawn_argv(subcommand)
    exe = argv[0]
    argument = subprocess.list2cmdline(argv[1:])
    cwd = HERE
    user = os.environ.get("USERNAME", "")
    settings_ps = _windows_persistent_task_settings_ps()
    if at_logon:
        trigger_ps = "$trigger = New-ScheduledTaskTrigger -AtLogOn"
    elif every_minutes is not None:
        trigger_ps = (
            "$start = Get-Date\n"
            f"$trigger = New-ScheduledTaskTrigger -Once -At $start "
            f"-RepetitionInterval (New-TimeSpan -Minutes {every_minutes}) "
            "-RepetitionDuration (New-TimeSpan -Days 9999)"
        )
    else:
        raise ValueError("at_logon or every_minutes required")
    script = f"""
$ErrorActionPreference = 'Stop'
{settings_ps}
$action = New-ScheduledTaskAction `
    -Execute {json.dumps(exe)} `
    -Argument {json.dumps(argument)} `
    -WorkingDirectory {json.dumps(cwd)}
{trigger_ps}
$principal = New-ScheduledTaskPrincipal `
    -UserId {json.dumps(user)} `
    -LogonType Interactive `
    -RunLevel Limited
Register-ScheduledTask `
    -TaskName {json.dumps(task_name)} `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null
"""
    return _run_powershell(script)


def _windows_delete_task(task_name: str) -> bool:
    if not _windows_task_exists(task_name):
        return False
    subprocess.run(
        ["schtasks", "/Delete", "/TN", task_name, "/F"],
        capture_output=True,
        text=True,
        **_subprocess_no_window_kwargs(),
    )
    return True


def cmd_install_windows() -> None:
    proc = _windows_register_task(WINDOWS_TASK_NAME, "_autostart", at_logon=True)
    if proc.returncode != 0:
        print(proc.stderr or proc.stdout or "Task Scheduler install failed")
        sys.exit(1)
    proc = _windows_register_task(
        WINDOWS_WATCHDOG_TASK_NAME,
        "wake",
        every_minutes=WINDOWS_WATCHDOG_INTERVAL_MINUTES,
    )
    if proc.returncode != 0:
        print(proc.stderr or proc.stdout or "watchdog Task Scheduler install failed")
        sys.exit(1)
    print(f'Installed Task Scheduler job "{WINDOWS_TASK_NAME}" (at logon).')
    print(
        f'Installed watchdog "{WINDOWS_WATCHDOG_TASK_NAME}" '
        f'(every {WINDOWS_WATCHDOG_INTERVAL_MINUTES} min, no stop-on-battery/time limit).'
    )
    print("Will start automatically when you sign in to Windows.")
    cmd_start(quiet=True, force=True)


def cmd_uninstall_windows() -> None:
    _clear_burn_startup_snapshot_sent()
    removed_login = _windows_delete_task(WINDOWS_TASK_NAME)
    removed_watchdog = _windows_delete_task(WINDOWS_WATCHDOG_TASK_NAME)
    if not removed_login and not removed_watchdog:
        print("No Task Scheduler job installed.")
        return
    if removed_login:
        print(f'Removed Task Scheduler job "{WINDOWS_TASK_NAME}".')
    if removed_watchdog:
        print(f'Removed Task Scheduler job "{WINDOWS_WATCHDOG_TASK_NAME}".')
    cmd_shutdown()


def cmd_install_linux() -> None:
    unit_dir = os.path.dirname(systemd_unit_path())
    os.makedirs(unit_dir, exist_ok=True)
    start_cmd = linux_daemon_command_line().strip('"')
    stop_cmd = autostart_stop_command_line()
    wake_cmd = " ".join(_quote_cmd_arg(part) for part in daemon_spawn_argv("wake"))
    unit = f"""[Unit]
Description=bittensor-burn-message daemon
After=network-online.target
Wants=network-online.target
StartLimitBurst=12
StartLimitIntervalSec=600

[Service]
Type=simple
Restart=on-failure
RestartSec=15
WorkingDirectory={HERE}
Environment=BITTENSOR_BURN_MESSAGE_AUTOSTART=1
StandardInput=null
StandardOutput=journal
StandardError=journal
ExecStart={start_cmd}
ExecStop={stop_cmd}

[Install]
WantedBy=default.target
"""
    watchdog_service = f"""[Unit]
Description=bittensor-burn-message watchdog

[Service]
Type=oneshot
WorkingDirectory={HERE}
ExecStart={wake_cmd}
"""
    watchdog_timer = f"""[Unit]
Description=bittensor-burn-message watchdog timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
"""
    path = systemd_unit_path()
    watchdog_service_path = os.path.join(
        os.path.dirname(path), LINUX_WATCHDOG_SERVICE_NAME
    )
    watchdog_timer_path = os.path.join(
        os.path.dirname(path), LINUX_WATCHDOG_TIMER_NAME
    )
    for file_path, body in (
        (path, unit),
        (watchdog_service_path, watchdog_service),
        (watchdog_timer_path, watchdog_timer),
    ):
        _write_text_file_atomic(file_path, body)
        if not _linux_systemd_unit_valid(file_path):
            print(f"Failed to write systemd unit: {file_path}", file=sys.stderr)
            sys.exit(1)
    _linux_systemd_prepare_unit(SYSTEMD_SERVICE_NAME)
    _linux_systemd_prepare_unit(LINUX_WATCHDOG_TIMER_NAME)
    _linux_systemd_prepare_unit(LINUX_WATCHDOG_SERVICE_NAME)
    for args in (
        ["systemctl", "--user", "daemon-reload"],
        ["systemctl", "--user", "enable", "--now", SYSTEMD_SERVICE_NAME],
        ["systemctl", "--user", "enable", "--now", LINUX_WATCHDOG_TIMER_NAME],
    ):
        proc = subprocess.run(args, capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout or f"failed: {' '.join(args)}")
            sys.exit(1)
    print(f"Installed {path}")
    print(f"Installed watchdog timer {watchdog_timer_path} (every 15 min).")
    print(f"{CLI_NAME} will start automatically on login.")
    pid = _wait_for_daemon(timeout=30.0)
    if pid is not None:
        print(f"Started (pid {pid}).")
    else:
        print(f"Service enabled but daemon not up yet. Check log: {DAEMON_LOG}")


def cmd_uninstall_linux() -> None:
    _clear_burn_startup_snapshot_sent()
    path = systemd_unit_path()
    unit_dir = os.path.dirname(path)
    watchdog_service_path = os.path.join(unit_dir, LINUX_WATCHDOG_SERVICE_NAME)
    watchdog_timer_path = os.path.join(unit_dir, LINUX_WATCHDOG_TIMER_NAME)
    if not os.path.exists(path):
        print("No systemd service installed.")
        return
    for unit in (
        LINUX_WATCHDOG_TIMER_NAME,
        LINUX_WATCHDOG_SERVICE_NAME,
        SYSTEMD_SERVICE_NAME,
    ):
        subprocess.run(
            ["systemctl", "--user", "disable", "--now", unit],
            capture_output=True,
            text=True,
        )
    subprocess.run(
        ["systemctl", "--user", "daemon-reload"],
        capture_output=True,
        text=True,
    )
    for file_path in (
        path,
        watchdog_service_path,
        watchdog_timer_path,
    ):
        if os.path.exists(file_path):
            os.remove(file_path)
            print(f"Removed {file_path}")


def cmd_burn_snapshot() -> None:
    reload_config()
    if not BURN_TELEGRAM_BOT_TOKEN or not BURN_TELEGRAM_CHAT_ID:
        print("Burn Telegram not configured.", file=sys.stderr)
        sys.exit(1)
    if not TAOSTATS_API_KEY:
        print("Taostats API not configured.", file=sys.stderr)
        print(
            "  Set TAOSTATS_API_KEY in your config or run install with --taostats_api_key.",
            file=sys.stderr,
        )
        sys.exit(1)
    _apply_taostats_env()
    code = run_burn_startup_snapshot(
        state_path=BURN_STATE_FILE,
        burn_token=BURN_TELEGRAM_BOT_TOKEN,
        burn_chat_id=BURN_TELEGRAM_CHAT_ID,
    )
    if code == 0:
        _mark_burn_startup_snapshot_sent()
    sys.exit(code)


def cmd_burn_watch_once() -> None:
    reload_config()
    if not burn_monitoring_enabled():
        print("Burn monitoring not fully configured.", file=sys.stderr)
        print(f"  Config file: {ENV_FILE}", file=sys.stderr)
        if not TAOSTATS_API_KEY:
            print(
                "  Taostats API: set TAOSTATS_API_KEY in config or "
                "install --taostats_api_key ...",
                file=sys.stderr,
            )
        if not BURN_TELEGRAM_BOT_TOKEN or not BURN_TELEGRAM_CHAT_ID:
            print(
                "  Burn Telegram: bittensor-burn-message install --telegram_token ... "
                "--telegram_chat_id ... --taostats_api_key ...",
                file=sys.stderr,
            )
        sys.exit(1)
    _apply_taostats_env()
    code = run_burn_watch_once(
        state_path=BURN_STATE_FILE,
        threshold=BURN_ALERT_THRESHOLD,
        burn_token=BURN_TELEGRAM_BOT_TOKEN,
        burn_chat_id=BURN_TELEGRAM_CHAT_ID,
    )
    sys.exit(code)


def cmd_install(argv: list[str] | None = None) -> None:
    ensure_env_file()
    args = parse_install_args(argv if argv is not None else sys.argv[2:])
    save_burn_config_from_install_args(args)
    if sys.platform == "win32":
        cmd_install_windows()
    elif sys.platform == "darwin":
        cmd_install_macos()
    else:
        cmd_install_linux()

    if burn_monitoring_enabled():
        if not send_install_burn_snapshot(quiet=False):
            print(
                "Burn startup snapshot did not complete — the daemon will retry "
                "automatically (check: bittensor-burn-message burn-snapshot)."
            )


def cmd_uninstall() -> None:
    if sys.platform == "win32":
        cmd_uninstall_windows()
    elif sys.platform == "darwin":
        cmd_uninstall_macos()
    else:
        cmd_uninstall_linux()


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "_run":
        _redirect_daemon_logs()
        try:
            run_loop()
        except Exception:
            import traceback

            traceback.print_exc()
            sys.exit(1)
    elif cmd == "_autostart":
        cmd_autostart()
    elif cmd == "start":
        cmd_start()
    elif cmd == "wake":
        cmd_wake()
    elif cmd == "stop":
        cmd_stop()
    elif cmd == "resume":
        cmd_resume()
    elif cmd == "shutdown":
        cmd_shutdown()
    elif cmd == "status":
        cmd_status()
    elif cmd == "install":
        cmd_install(sys.argv[2:])
    elif cmd == "uninstall":
        cmd_uninstall()
    elif cmd == "burn-watch-once":
        cmd_burn_watch_once()
    elif cmd == "burn-snapshot":
        cmd_burn_snapshot()
    else:
        print(
            "Usage: bittensor-burn-message "
            "{start|wake|stop|resume|shutdown|status|install|uninstall|"
            "burn-snapshot|burn-watch-once}\n"
            "  bittensor-burn-message install --telegram_token TOKEN "
            "--telegram_chat_id CHAT_ID --taostats_api_key KEY "
            "[--interval MINUTES] [--threshold DELTA]"
        )
        sys.exit(1)


__all__ = ["main"]
