"""TrustUI's local CLI bridge. Python 3.11+, standard library only."""
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import tempfile
import time
import tomllib


class UserError(ValueError):
    def __init__(self, key, *values):
        self.key = key
        self.values = [str(value) for value in values]
        super().__init__(key.replace("%@", "%s") % tuple(self.values))


def read_config(path):
    raw = path.read_bytes()
    return tomllib.loads(raw.decode()), hashlib.sha256(raw).hexdigest()


def validate(config):
    endpoint = config.get("endpoint", {})
    if not endpoint.get("hostname") or not endpoint.get("addresses"):
        raise ValueError("Укажите имя сервера и хотя бы один адрес.")
    for owner, key in [(endpoint, "addresses"), (config, "dns_upstreams"), (config, "exclusions")]:
        value = owner.get(key, [])
        if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
            raise UserError("%@: нужны непустые строки.", key)
    if config.get("vpn_mode") not in ("general", "selective"):
        raise ValueError("Неизвестный режим маршрутизации.")
    if endpoint.get("upstream_protocol") not in ("http2", "http3"):
        raise ValueError("Выберите HTTP/2 или HTTP/3.")
    if not config.get("listener"):
        raise ValueError("В конфигурации отсутствует listener.")


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(x) for x in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{toml_value(k)} = {toml_value(v)}" for k, v in value.items()) + " }"
    raise UserError("Неподдерживаемый тип TOML: %@", type(value).__name__)


def encode_config(config):
    lines = []

    def table(values, path):
        if path:
            lines.extend(["", "[" + ".".join(toml_value(k) for k in path) + "]"])
        for key, value in values.items():
            if not isinstance(value, dict):
                lines.append(f"{toml_value(key)} = {toml_value(value)}")
        for key, value in values.items():
            if isinstance(value, dict):
                table(value, path + [key])

    table(config, [])
    result = "\n".join(lines) + "\n"
    tomllib.loads(result)
    return result.encode()


def atomic_write(path, content):
    fd, name = tempfile.mkstemp(prefix=".trustui-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def load(directory):
    config, revision = read_config(directory / "trusttunnel_client.toml")
    profiles, warnings, invalid_profiles = [], [], []
    for path in sorted(directory.glob("*.toml")):
        if path.name == "trusttunnel_client.toml":
            continue
        try:
            data, _ = read_config(path)
            endpoint = data.get("endpoint", data)
            if endpoint.get("hostname") and endpoint.get("addresses"):
                profiles.append({"name": path.stem, "endpoint": endpoint})
        except (ValueError, OSError):
            warnings.append(f"Не удалось прочитать {path.name}")
            invalid_profiles.append(path.name)
    return {"config": config, "revision": revision, "profiles": profiles,
            "warnings": warnings, "invalidProfiles": invalid_profiles}


def save(directory, request):
    path = directory / "trusttunnel_client.toml"
    with (directory / ".trustui.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current, revision = read_config(path)
        if revision != request["revision"]:
            raise ValueError("Файл изменён другим приложением. Перечитайте настройки перед сохранением.")
        edits = request["edits"]
        for key in ("vpn_mode", "killswitch_enabled", "dns_upstreams", "exclusions", "loglevel"):
            if key in edits:
                current[key] = edits[key]
        if "endpoint" in edits:
            current["endpoint"] = edits["endpoint"]
        validate(current)
        encoded = encode_config(current)
        # Keep the original text, including comments, in a private backup.
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup = path.with_name(f"{path.name}.{stamp}.bak")
        atomic_write(backup, path.read_bytes())
        atomic_write(path, encoded)
    return {"revision": hashlib.sha256(encoded).hexdigest(), "backup": str(backup)}


def identity(pid):
    result = subprocess.run(
        ["/bin/ps", "-ww", "-p", str(int(pid)), "-o", "lstart=", "-o", "command="],
        capture_output=True, text=True, check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def running(state):
    return bool(state.get("identity")) and identity(state["pid"]) == state["identity"]


def external_pids():
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,comm="], capture_output=True, text=True, check=True)
    return [int(parts[0]) for line in result.stdout.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2
            and Path(parts[1]).name == "trusttunnel_client"]


def read_state(support):
    try:
        return json.loads((support / "run.json").read_text())
    except FileNotFoundError:
        return {}


def log_tail(support):
    path = support / "client.log"
    try:
        with path.open("rb") as file:
            file.seek(0, 2)
            file.seek(max(0, file.tell() - 48000))
            text = file.read().decode(errors="replace")
    except FileNotFoundError:
        return ""
    try:
        endpoint = read_config(support / "session.toml")[0].get("endpoint", {})
        for key in ("password", "username"):
            secret = endpoint.get(key)
            if secret:
                text = text.replace(secret, "••••")
    except (OSError, ValueError):
        # Never show potentially unredacted logs when the session config is unavailable.
        return "Журнал скрыт: не удалось прочитать конфигурацию сеанса."
    return text


def status(support):
    state = read_state(support)
    active = running(state)
    external = [pid for pid in external_pids() if not active or pid != state["pid"]]
    return {"running": active, "external": external, "pid": state.get("pid", 0) if active else 0,
            "started": state.get("started", 0), "hostname": state.get("hostname", ""),
            "hadSession": bool(state), "log": log_tail(support)}


@contextlib.contextmanager
def as_user(uid):
    old_uid, old_gid = os.geteuid(), os.getegid()
    if old_uid == 0:
        os.setegid(pwd.getpwuid(uid).pw_gid)
        os.seteuid(uid)
    try:
        yield
    finally:
        if old_uid == 0:
            os.seteuid(old_uid)
            os.setegid(old_gid)


def start(directory, support, uid):
    with as_user(uid):
        support.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = (support / "session.lock").open("a")
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with as_user(uid):
            if running(read_state(support)) or external_pids():
                raise ValueError("Клиент уже запущен. Сначала остановите текущий сеанс.")
            binary = directory / "trusttunnel_client"
            if not os.access(binary, os.X_OK):
                raise ValueError("Не найден исполняемый файл trusttunnel_client.")
            path = directory / "trusttunnel_client.toml"
            raw = path.read_bytes()
            config = tomllib.loads(raw.decode())
            validate(config)
            snapshot = support / "session.toml"
            atomic_write(snapshot, raw)
            log_path = support / "client.log"
            if log_path.exists():
                os.replace(log_path, support / "client.previous.log")
            fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as log:
            child = subprocess.Popen([str(binary), "-c", str(snapshot)], cwd=directory,
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     start_new_session=True)
        try:
            time.sleep(0.4)
            if child.poll() is not None:
                raise ValueError("Клиент завершился при запуске. Причина — в журнале.")
            state = {"pid": child.pid, "identity": identity(child.pid),
                     "started": time.time(), "hostname": config["endpoint"]["hostname"]}
            if not state["identity"]:
                raise ValueError("Не удалось определить запущенный процесс.")
            with as_user(uid):
                atomic_write(support / "run.json", json.dumps(state).encode())
            return state
        except BaseException:
            if child.poll() is None:
                child.send_signal(signal.SIGINT)
            raise


def stop(support, uid):
    with as_user(uid):
        state = read_state(support)
    if not running(state):
        return {"stopped": True}
    if int(state["pid"]) <= 1 or not state["identity"].endswith(
            f"/trusttunnel_client -c {support / 'session.toml'}"):
        raise ValueError("Этот процесс не принадлежит сеансу TrustUI.")
    # PID + launch time + full command protect against a reused PID.
    os.kill(state["pid"], signal.SIGINT)
    for _ in range(50):
        if not running(state):
            return {"stopped": True}
        time.sleep(0.1)
    raise ValueError("Клиент ещё завершает работу. Проверьте журнал и повторите остановку.")


def main():
    action = sys.argv[1]
    request = json.loads(sys.argv[2]) if len(sys.argv) > 2 else json.load(sys.stdin)
    uid = int(request.get("uid", os.getuid()))
    support = Path(pwd.getpwuid(uid).pw_dir) / "Library/Application Support/TrustUI"
    directory = Path(request.get("directory", str(Path.home() / "trusttunnel"))).expanduser().resolve()
    if action == "load":
        return load(directory)
    if action == "save":
        return save(directory, request)
    if action == "status":
        return status(support)
    if action in ("start", "stop"):
        if os.geteuid() != 0:
            raise ValueError("Для управления туннелем нужны права администратора.")
        return start(directory, support, uid) if action == "start" else stop(support, uid)
    raise ValueError("Неизвестная команда.")


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=False, default=str))
    except Exception as error:
        if isinstance(error, FileNotFoundError):
            error = UserError("Файл не найден: %@. Откройте инструкцию для настройки CLI.", error.filename or "")
        elif isinstance(error, PermissionError):
            error = UserError("Нет доступа к файлу: %@. Проверьте права доступа к папке CLI.", error.filename or "")
        result = {"error": str(error)}
        if isinstance(error, UserError):
            result.update(errorKey=error.key, errorArguments=error.values)
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(1)
