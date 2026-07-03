#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import io
import ipaddress
import json
import os
import pathlib
import re
import shlex
import shutil
import socketserver
import stat
import subprocess
import tarfile
import tempfile
import threading
import time
import traceback
import urllib.parse
import urllib.request
import urllib.error
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler
from typing import Any, Iterable

VERSION = "0.2.0"
ETC = pathlib.Path("/etc/bsm")
STATE = pathlib.Path("/var/lib/bsm")
LOGS = pathlib.Path("/var/log/bsm")
RUN = pathlib.Path("/run/bsm")
SOCKET = RUN / "agent.sock"
TOKEN_FILE = ETC / "agent.token"
CONFIG_FILE = ETC / "server.json"
SECRETS_FILE = ETC / "secrets.json"
JOBS_DIR = STATE / "jobs"
DIAG_DIR = STATE / "diagnostics"
UPDATE_DIR = STATE / "updates"
LEDGER_JSONL = LOGS / "command-ledger.jsonl"
LEDGER_SH = LOGS / "command-ledger.sh"
CURRENT = pathlib.Path("/opt/bsm-community/current")
ENGINE = CURRENT / "engine/bsm-server-engine"
UPLOAD_ROOT = pathlib.Path("/var/lib/bsm/web/uploads")

SENSITIVE_KEY = re.compile(r"(?i)(password|passwd|token|secret|api[_-]?key|private[_-]?key|credential)")
SENSITIVE_ARG = re.compile(r"(?i)(--?(?:password|passwd|token|secret|api[_-]?key)(?:=|\s+))([^\s]+)")
SENSITIVE_ASSIGNMENT = re.compile(
    r"(?i)(\b(?:password|passwd|token|secret|api[_-]?key|client[_-]?secret|authorization)\b\s*[:=]\s*)"
    r"(?:['\"][^'\"]*['\"]|[^\s,;}]+)"
)
AUTH_HEADER = re.compile(r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[^\s]+")
PEM_BLOCK = re.compile(r"-----BEGIN [^-]+-----.*?-----END [^-]+-----", re.DOTALL)
KNOWN_TOKEN = re.compile(
    r"(?i)\b(?:sk-[A-Za-z0-9_-]{16,}|github_pat_[A-Za-z0-9_]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{16,})\b"
)
JWT_TOKEN = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")
EMAIL_ADDRESS = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b")
IPV4_ADDRESS = re.compile(r"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")

DEFAULT_CONFIG: dict[str, Any] = {
    "domain": "example.com",
    "public_ip": "",
    "timezone": "UTC",
    "app_owner": "ubuntu",
    "apps": {
        "portainer": True,
        "homepage": True,
        "filebrowser": True,
        "uptime-kuma": True,
        "dozzle": True,
        "beszel": True,
        "gitea": True,
        "vaultwarden": True,
        "it-tools": True,
        "stirling-pdf": True,
        "webtop": True,
        "rdesktop": True,
    },
    "ports": {
        "portainer": 9443,
        "homepage": 3000,
        "uptime": 3001,
        "gitea": 3002,
        "filebrowser": 18081,
        "dozzle": 8082,
        "beszel": 8090,
        "vaultwarden": 18084,
        "ittools": 8085,
        "stirling": 8086,
        "webtop": 13003,
        "rdp_local": 18888,
        "rdp_public": 8888,
    },
    "cloudflare": {
        "install": True,
        "access_email": "",
        "manager_hostname": "manager.example.com",
    },
    "rdp": {
        "mode": "cloudflare",
        "allowed_cidr": "",
        "install_chromium": True,
    },
    "registration": {
        "gitea": True,
        "vaultwarden": True,
    },
    "backup": {
        "enabled": False,
        "rclone_remote": "remote",
        "remote_path": "backups/server/full",
        "hour": "04:15",
        "retention_days": 14,
    },
    "advanced": {
        "allow_unsigned_taskpacks": False,
        "trace_shell": False,
    },
    "ai": {
        "provider": "openai",
        "model": "",
        "base_url": "",
        "timeout_seconds": 90,
        "max_context_chars": 120000,
    },
}

SECRET_DEFAULTS = {
    "cloudflare_tunnel_token": "",
    "cloudflare_api_token": "",
    "webtop_user": "admin",
    "webtop_password": "",
    "rdp_password": "",
    "ai_api_key": "",
}


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic_json(path: pathlib.Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_json(path: pathlib.Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return json.loads(json.dumps(default))


def deep_merge(base: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    out = json.loads(json.dumps(base))
    for k, v in incoming.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def ensure_layout() -> None:
    for p in (ETC, STATE, LOGS, RUN, JOBS_DIR, DIAG_DIR, UPDATE_DIR, UPLOAD_ROOT):
        p.mkdir(parents=True, exist_ok=True)
    os.chmod(ETC, 0o700)
    os.chmod(LOGS, 0o700)
    if not CONFIG_FILE.exists():
        atomic_json(CONFIG_FILE, DEFAULT_CONFIG)
    if not SECRETS_FILE.exists():
        s = dict(SECRET_DEFAULTS)
        s["webtop_password"] = os.urandom(16).hex()
        s["rdp_password"] = os.urandom(16).hex()
        atomic_json(SECRETS_FILE, s)
    LEDGER_JSONL.touch(exist_ok=True)
    LEDGER_SH.touch(exist_ok=True)
    os.chmod(LEDGER_JSONL, 0o600)
    os.chmod(LEDGER_SH, 0o600)


def secret_values() -> list[str]:
    data = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    return [str(v) for v in data.values() if isinstance(v, str) and len(v) >= 6]


def redact_text(text: str) -> str:
    text = PEM_BLOCK.sub("[REDACTED PRIVATE KEY]", text)
    text = AUTH_HEADER.sub(lambda m: m.group(1) + "[REDACTED]", text)
    text = SENSITIVE_ARG.sub(lambda m: m.group(1) + "[REDACTED]", text)
    text = SENSITIVE_ASSIGNMENT.sub(lambda m: m.group(1) + "[REDACTED]", text)
    text = KNOWN_TOKEN.sub("[REDACTED TOKEN]", text)
    text = JWT_TOKEN.sub("[REDACTED JWT]", text)
    for value in secret_values():
        text = text.replace(value, "[REDACTED]")
    return text


def anonymize_text(text: str) -> str:
    """Remove user-identifying network details while preserving private/loopback topology."""
    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    domain = str(cfg.get("domain", "")).strip()
    public_ip = str(cfg.get("public_ip", "")).strip()
    if domain and domain != "example.com":
        text = re.sub(re.escape(domain), "[DOMAIN]", text, flags=re.IGNORECASE)
    if public_ip:
        text = text.replace(public_ip, "[PUBLIC_IP]")
    text = EMAIL_ADDRESS.sub("[EMAIL]", text)

    def mask_ip(match: re.Match[str]) -> str:
        raw = match.group(0)
        try:
            ip = ipaddress.ip_address(raw)
        except ValueError:
            return raw
        return "[PUBLIC_IP]" if ip.is_global else raw

    return IPV4_ADDRESS.sub(mask_ip, text)


def redact_obj(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: ("[SET]" if SENSITIVE_KEY.search(k) and v else "" if SENSITIVE_KEY.search(k) else redact_obj(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_obj(v) for v in obj]
    if isinstance(obj, str):
        return redact_text(obj)
    return obj


def append_ledger(entry: dict[str, Any]) -> None:
    entry = redact_obj(entry)
    with LEDGER_JSONL.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    argv = entry.get("argv") or []
    command = " ".join(shlex.quote(str(x)) for x in argv) if isinstance(argv, list) else str(argv)
    with LEDGER_SH.open("a", encoding="utf-8") as f:
        f.write(f"\n# {entry.get('timestamp')} actor={entry.get('actor')} job={entry.get('job_id','-')} cwd={entry.get('cwd','-')}\n")
        if command:
            f.write(redact_text(command) + "\n")
        f.write(f"# exit={entry.get('exit_code')} duration_ms={entry.get('duration_ms')}\n")


def run_command(
    argv: list[str],
    *,
    actor: str = "system",
    job_id: str = "",
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    log_path: pathlib.Path | None = None,
) -> subprocess.CompletedProcess[str]:
    start = time.monotonic()
    command_text = " ".join(shlex.quote(x) for x in argv)
    if log_path:
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"\n$ {redact_text(command_text)}\n")
    proc = subprocess.Popen(
        argv,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        errors="replace",
    )
    lines: list[str] = []
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            lines.append(line)
            if len(lines) > 2000:
                lines = lines[-2000:]
            if log_path:
                with log_path.open("a", encoding="utf-8") as log:
                    log.write(redact_text(line))
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        lines.append("\n[BSM] Command timed out.\n")
    output = "".join(lines)
    duration_ms = int((time.monotonic() - start) * 1000)
    append_ledger({
        "timestamp": now(),
        "actor": actor,
        "source": "agent",
        "job_id": job_id,
        "argv": argv,
        "cwd": cwd or os.getcwd(),
        "exit_code": proc.returncode,
        "duration_ms": duration_ms,
        "output_tail": output[-12000:],
    })
    return subprocess.CompletedProcess(argv, proc.returncode, output, "")


def file_sha256(path: pathlib.Path) -> str | None:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def record_file_change(path: pathlib.Path, before: str | None, actor: str, job_id: str = "") -> None:
    after = file_sha256(path)
    append_ledger({
        "timestamp": now(),
        "actor": actor,
        "source": "file-change",
        "job_id": job_id,
        "argv": ["WRITE_FILE", str(path)],
        "cwd": str(path.parent),
        "exit_code": 0,
        "duration_ms": 0,
        "before_sha256": before,
        "after_sha256": after,
    })


def read_mem() -> tuple[int, int]:
    vals: dict[str, int] = {}
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            key, value = line.split(":", 1)
            vals[key] = int(value.strip().split()[0]) * 1024
    return vals.get("MemTotal", 0), vals.get("MemAvailable", 0)


def service_state(name: str) -> str:
    p = subprocess.run(["systemctl", "is-active", name], text=True, capture_output=True)
    return p.stdout.strip() or "unknown"


def docker_stats() -> dict[str, dict[str, str]]:
    try:
        p = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{json .}}"],
            text=True, capture_output=True, timeout=25,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}
    stats: dict[str, dict[str, str]] = {}
    if p.returncode != 0:
        return stats
    for line in p.stdout.splitlines():
        try:
            row = json.loads(line)
            name = row.get("Name") or row.get("Container")
            if name:
                stats[name] = {
                    "cpu": row.get("CPUPerc", "—"),
                    "memory": row.get("MemUsage", "—"),
                    "memory_percent": row.get("MemPerc", "—"),
                    "network": row.get("NetIO", "—"),
                    "block": row.get("BlockIO", "—"),
                    "pids": row.get("PIDs", "—"),
                }
        except json.JSONDecodeError:
            continue
    return stats


def docker_containers() -> list[dict[str, Any]]:
    fmt = "{{json .}}"
    try:
        p = subprocess.run(["docker", "ps", "-a", "--format", fmt], text=True, capture_output=True)
    except FileNotFoundError:
        return []
    if p.returncode != 0:
        return []
    stats = docker_stats()
    out = []
    for line in p.stdout.splitlines():
        try:
            row = json.loads(line)
            name = row.get("Names")
            item = {
                "id": row.get("ID"),
                "name": name,
                "image": row.get("Image"),
                "state": row.get("State"),
                "status": row.get("Status"),
                "ports": row.get("Ports"),
                "created": row.get("RunningFor"),
            }
            item.update(stats.get(name, {}))
            out.append(item)
        except json.JSONDecodeError:
            continue
    return out


def system_snapshot() -> dict[str, Any]:
    total, available = read_mem()
    disk = shutil.disk_usage("/")
    load = os.getloadavg()
    containers = docker_containers()
    return {
        "timestamp": now(),
        "hostname": os.uname().nodename,
        "kernel": os.uname().release,
        "architecture": os.uname().machine,
        "cpu_count": os.cpu_count(),
        "load": load,
        "memory": {"total": total, "available": available, "used": max(total - available, 0)},
        "disk": {"total": disk.total, "free": disk.free, "used": disk.used},
        "services": {
            "docker": service_state("docker"),
            "hestia": service_state("hestia"),
            "nginx": service_state("nginx"),
            "mariadb": service_state("mariadb"),
            "cloudflared": service_state("cloudflared"),
            "bsm-agent": service_state("bsm-agent"),
        },
        "containers": {
            "total": len(containers),
            "running": sum(1 for c in containers if c.get("state") == "running"),
            "unhealthy": sum(1 for c in containers if "unhealthy" in (c.get("status") or "").lower()),
        },
    }


def validate_config(raw: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    config = deep_merge(DEFAULT_CONFIG, raw)
    secrets = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    incoming_secrets = raw.get("secrets") or {}
    for k in SECRET_DEFAULTS:
        val = incoming_secrets.get(k)
        if isinstance(val, str) and val and val != "[SET]":
            secrets[k] = val
    config.pop("secrets", None)

    domain = str(config.get("domain", "")).strip().lower()
    if not re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,63}", domain):
        raise ValueError("Invalid base domain")
    config["domain"] = domain
    if config["rdp"]["mode"] not in {"cloudflare", "public", "disabled"}:
        raise ValueError("Invalid RDP mode")
    if config["rdp"]["mode"] == "public" and not config["rdp"].get("allowed_cidr"):
        raise ValueError("Public RDP requires allowed_cidr")
    for key, value in config["ports"].items():
        value = int(value)
        if not 1 <= value <= 65535:
            raise ValueError(f"Invalid port: {key}")
        config["ports"][key] = value
    return config, secrets


def config_for_ui() -> dict[str, Any]:
    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    sec = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    cfg["secrets"] = {k: "[SET]" if v else "" for k, v in sec.items()}
    return cfg


def make_v2_env() -> pathlib.Path:
    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    sec = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    generated = STATE / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    path = generated / "bsm-engine.env"
    apps = " ".join(k for k, v in cfg["apps"].items() if v)
    ports = cfg["ports"]
    lines = {
        "DOMAIN": cfg["domain"],
        "PUBLIC_IP": cfg.get("public_ip", ""),
        "TIMEZONE": cfg["timezone"],
        "APP_OWNER": cfg["app_owner"],
        "INSTALL_HESTIA": "no",
        "HESTIA_HOSTNAME": f"cp.{cfg['domain']}",
        "APPS": apps,
        "PORT_PORTAINER": ports["portainer"],
        "PORT_HOMEPAGE": ports["homepage"],
        "PORT_UPTIME": ports["uptime"],
        "PORT_GITEA": ports["gitea"],
        "PORT_FILEBROWSER": ports["filebrowser"],
        "PORT_DOZZLE": ports["dozzle"],
        "PORT_BESZEL": ports["beszel"],
        "PORT_VAULTWARDEN": ports["vaultwarden"],
        "PORT_ITTOOLS": ports["ittools"],
        "PORT_STIRLING": ports["stirling"],
        "PORT_WEBTOP": ports["webtop"],
        "INSTALL_CLOUDFLARED": "yes" if cfg["cloudflare"]["install"] else "no",
        "CF_TUNNEL_TOKEN": sec.get("cloudflare_tunnel_token", ""),
        "CF_ACCESS_EMAIL": cfg["cloudflare"].get("access_email", ""),
        "RDP_EXPOSURE": cfg["rdp"]["mode"],
        "RDP_LOCAL_PORT": ports["rdp_local"],
        "RDP_PUBLIC_PORT": ports["rdp_public"],
        "RDP_ALLOWED_CIDR": cfg["rdp"].get("allowed_cidr", ""),
        "RDP_INSTALL_CHROMIUM": "yes" if cfg["rdp"].get("install_chromium") else "no",
        "WEBTOP_USER": sec.get("webtop_user", "admin"),
        "WEBTOP_PASSWORD": sec.get("webtop_password", ""),
        "RDP_PASSWORD": sec.get("rdp_password", ""),
        "VAULTWARDEN_SIGNUPS_ALLOWED": "true" if cfg["registration"]["vaultwarden"] else "false",
        "GITEA_REGISTRATION": "true" if cfg["registration"]["gitea"] else "false",
        "BACKUP_ENABLE": "yes" if cfg["backup"]["enabled"] else "no",
        "RCLONE_REMOTE": cfg["backup"]["rclone_remote"],
        "BACKUP_REMOTE_PATH": cfg["backup"]["remote_path"],
        "BACKUP_HOUR": cfg["backup"]["hour"],
        "BACKUP_RETENTION_DAYS": cfg["backup"]["retention_days"],
    }
    before = file_sha256(path)
    with path.open("w", encoding="utf-8") as f:
        f.write("# Generated by BSM Community. Trusted shell environment file.\n")
        for key, value in lines.items():
            f.write(f"{key}={shlex.quote(str(value))}\n")
    os.chmod(path, 0o600)
    record_file_change(path, before, "bsm-agent")
    return path



AI_SERVICE_ALLOWLIST = {"docker", "hestia", "nginx", "mariadb", "cloudflared", "bsm-agent"}


def _tail_text(path: pathlib.Path, max_lines: int, max_chars: int) -> str:
    if not path.exists():
        return ""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-max_lines:]
    return "\n".join(lines)[-max_chars:]


def _safe_container_name(name: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise ValueError("Invalid container name")
    return name


def build_ai_context(options: dict[str, Any]) -> dict[str, Any]:
    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    max_chars = max(5000, min(int(cfg.get("ai", {}).get("max_context_chars", 120000)), 250000))
    sections: list[tuple[str, str]] = []

    if options.get("system", True):
        sections.append(("System snapshot", json.dumps(system_snapshot(), ensure_ascii=False, indent=2)))
    if options.get("containers", True):
        sections.append(("Docker containers", json.dumps(docker_containers(), ensure_ascii=False, indent=2)))
    if options.get("config", True):
        sections.append(("Redacted configuration", json.dumps(redact_obj(config_for_ui()), ensure_ascii=False, indent=2)))
    if options.get("ledger", False):
        limit = max(1, min(int(options.get("ledger_lines", 120)), 500))
        sections.append(("Command ledger tail", _tail_text(LEDGER_JSONL, limit, 50000)))

    container_names = options.get("container_logs") or []
    if not isinstance(container_names, list):
        raise ValueError("container_logs must be a list")
    for name in container_names[:8]:
        name = _safe_container_name(str(name))
        p = subprocess.run(["docker", "logs", "--tail", "300", name], text=True, capture_output=True, timeout=30)
        sections.append((f"Container log: {name}", (p.stdout + p.stderr)[-40000:]))

    services = options.get("service_logs") or []
    if not isinstance(services, list):
        raise ValueError("service_logs must be a list")
    for service in services[:8]:
        service = str(service)
        if service not in AI_SERVICE_ALLOWLIST:
            raise ValueError(f"Service is not allowlisted: {service}")
        p = subprocess.run(["journalctl", "-u", service, "-n", "250", "--no-pager"], text=True, capture_output=True, timeout=30)
        sections.append((f"Systemd log: {service}", (p.stdout + p.stderr)[-40000:]))

    anonymize = bool(options.get("anonymize", True))
    parts: list[str] = []
    for title, body in sections:
        clean = redact_text(body or "(empty)")
        if anonymize:
            clean = anonymize_text(clean)
        parts.append(f"\n===== {title} =====\n{clean}")
    text = "".join(parts)
    truncated = len(text) > max_chars
    if truncated:
        text = text[:max_chars] + "\n\n[Context truncated by BSM]"
    return {
        "text": text,
        "characters": len(text),
        "truncated": truncated,
        "sections": [title for title, _ in sections],
        "anonymized": anonymize,
    }


def ai_config_for_ui() -> dict[str, Any]:
    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    sec = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    ai = dict(cfg.get("ai") or {})
    ai["api_key"] = "[SET]" if sec.get("ai_api_key") else ""
    return ai


def save_ai_config(raw: dict[str, Any], actor: str) -> dict[str, Any]:
    provider = str(raw.get("provider", "openai")).strip().lower()
    if provider not in {"openai", "anthropic", "gemini", "openai-compatible"}:
        raise ValueError("Unsupported AI provider")
    model = str(raw.get("model", "")).strip()
    if not model:
        raise ValueError("Model is required")
    base_url = str(raw.get("base_url", "")).strip()
    if provider == "openai-compatible" and not base_url.startswith(("https://", "http://")):
        raise ValueError("A valid base_url is required for an OpenAI-compatible provider")
    timeout_seconds = max(15, min(int(raw.get("timeout_seconds", 90)), 300))
    max_context_chars = max(5000, min(int(raw.get("max_context_chars", 120000)), 250000))

    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    cfg["ai"] = {
        "provider": provider,
        "model": model,
        "base_url": base_url,
        "timeout_seconds": timeout_seconds,
        "max_context_chars": max_context_chars,
    }
    sec = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    key = raw.get("api_key")
    if bool(raw.get("clear_api_key", False)):
        sec["ai_api_key"] = ""
    elif isinstance(key, str) and key and key != "[SET]":
        sec["ai_api_key"] = key.strip()
    before_cfg = file_sha256(CONFIG_FILE)
    before_sec = file_sha256(SECRETS_FILE)
    atomic_json(CONFIG_FILE, cfg)
    atomic_json(SECRETS_FILE, sec)
    record_file_change(CONFIG_FILE, before_cfg, actor)
    record_file_change(SECRETS_FILE, before_sec, actor)
    return ai_config_for_ui()


def _http_json(url: str, headers: dict[str, str], payload: dict[str, Any], timeout: int) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **headers}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read(4 * 1024 * 1024)
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read(65536).decode("utf-8", "replace")
        raise RuntimeError(f"AI provider returned HTTP {exc.code}: {redact_text(body)}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"AI provider connection failed: {exc.reason}") from exc


def _extract_openai_text(data: dict[str, Any]) -> str:
    if isinstance(data.get("output_text"), str):
        return data["output_text"]
    chunks: list[str] = []
    for item in data.get("output") or []:
        for content in item.get("content") or []:
            text = content.get("text")
            if isinstance(text, str):
                chunks.append(text)
    return "\n".join(chunks).strip()


def ask_ai(question: str, options: dict[str, Any], actor: str, context_snapshot: str = "") -> dict[str, Any]:
    question = question.strip()
    if not question or len(question) > 12000:
        raise ValueError("Question must contain 1 to 12000 characters")
    cfg = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, {}))
    sec = deep_merge(SECRET_DEFAULTS, load_json(SECRETS_FILE, {}))
    ai = cfg.get("ai") or {}
    provider = str(ai.get("provider", "openai"))
    model = str(ai.get("model", "")).strip()
    api_key = str(sec.get("ai_api_key", "")).strip()
    if not model or not api_key:
        raise ValueError("AI provider, model, and API key must be configured first")
    if context_snapshot:
        max_chars = max(5000, min(int(ai.get("max_context_chars", 120000)), 250000))
        prepared = redact_text(str(context_snapshot))
        anonymized = bool(options.get("anonymize", True))
        if anonymized:
            prepared = anonymize_text(prepared)
        truncated = len(prepared) > max_chars
        if truncated:
            prepared = prepared[:max_chars] + "\n\n[Context truncated by BSM]"
        context = {
            "text": prepared,
            "characters": len(prepared),
            "truncated": truncated,
            "sections": ["User-reviewed preview"],
            "anonymized": anonymized,
        }
    else:
        context = build_ai_context(options)
    timeout = int(ai.get("timeout_seconds", 90))
    system = (
        "You are a read-only Linux and Docker troubleshooting assistant. "
        "Analyze only the supplied sanitized context. Do not claim to have executed commands. "
        "Separate confirmed facts from hypotheses. Suggest the least destructive checks first. "
        "Never request secrets, private keys, passwords, or full unredacted configuration. "
        "When proposing commands, explain their effect and flag destructive commands clearly."
    )
    user_text = f"User question:\n{question}\n\nSanitized server context:\n{context['text']}"

    if provider == "openai":
        data = _http_json(
            "https://api.openai.com/v1/responses",
            {"Authorization": f"Bearer {api_key}"},
            {"model": model, "instructions": system, "input": user_text, "store": False},
            timeout,
        )
        answer = _extract_openai_text(data)
    elif provider == "anthropic":
        data = _http_json(
            "https://api.anthropic.com/v1/messages",
            {"x-api-key": api_key, "anthropic-version": "2023-06-01"},
            {"model": model, "max_tokens": 1800, "system": system, "messages": [{"role": "user", "content": user_text}]},
            timeout,
        )
        answer = "\n".join(x.get("text", "") for x in data.get("content") or [] if x.get("type") == "text").strip()
    elif provider == "gemini":
        model_path = urllib.parse.quote(model, safe="-_.")
        data = _http_json(
            f"https://generativelanguage.googleapis.com/v1beta/models/{model_path}:generateContent",
            {"x-goog-api-key": api_key},
            {"system_instruction": {"parts": [{"text": system}]}, "contents": [{"role": "user", "parts": [{"text": user_text}]}]},
            timeout,
        )
        answer = "\n".join(
            part.get("text", "")
            for candidate in data.get("candidates") or []
            for part in (candidate.get("content") or {}).get("parts") or []
        ).strip()
    else:
        base = str(ai.get("base_url", "")).rstrip("/")
        url = base if base.endswith("/chat/completions") else base + "/chat/completions"
        data = _http_json(
            url,
            {"Authorization": f"Bearer {api_key}"},
            {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user_text}]},
            timeout,
        )
        answer = str((((data.get("choices") or [{}])[0].get("message") or {}).get("content") or "")).strip()

    if not answer:
        raise RuntimeError("The AI provider returned no text")
    append_ledger({
        "timestamp": now(), "actor": actor, "source": "ai-advice", "job_id": "",
        "argv": ["AI_ASK", provider, model], "cwd": str(STATE), "exit_code": 0,
        "duration_ms": 0, "context_sections": context["sections"], "context_characters": context["characters"],
        "question_sha256": hashlib.sha256(question.encode()).hexdigest(),
    })
    return {
        "answer": answer,
        "provider": provider,
        "model": model,
        "context": {k: context[k] for k in ("characters", "truncated", "sections", "anonymized")},
    }

def job_paths(job_id: str) -> tuple[pathlib.Path, pathlib.Path]:
    return JOBS_DIR / f"{job_id}.json", JOBS_DIR / f"{job_id}.log"


def save_job(job: dict[str, Any]) -> None:
    meta, _ = job_paths(job["id"])
    atomic_json(meta, job)


def load_job(job_id: str) -> dict[str, Any] | None:
    meta, _ = job_paths(job_id)
    return load_json(meta, None)


def update_job(job_id: str, **changes: Any) -> dict[str, Any]:
    job = load_job(job_id) or {"id": job_id}
    job.update(changes)
    save_job(job)
    return job


def run_job(job_id: str, task: str, actor: str) -> None:
    meta, log_path = job_paths(job_id)
    update_job(job_id, status="running", started_at=now(), progress=3, message="Starting")
    try:
        if task == "reconcile":
            env_path = make_v2_env()
            cmd = [str(ENGINE / "install.sh"), "--config", str(env_path), "--non-interactive"]
        elif task == "verify":
            env_path = make_v2_env()
            cmd = [str(ENGINE / "scripts/verify.sh"), str(env_path)]
        elif task == "update-containers":
            cmd = [str(ENGINE / "scripts/update.sh")]
        elif task == "backup":
            cmd = [str(ENGINE / "scripts/backup.sh")]
        elif task == "restore-test":
            cmd = [str(ENGINE / "scripts/restore-test.sh")]
        elif task == "status":
            cmd = [str(ENGINE / "scripts/status.sh")]
        else:
            raise ValueError(f"Task not allowed: {task}")

        update_job(job_id, progress=10, message=f"Running {task}")
        result = run_command(cmd, actor=actor, job_id=job_id, cwd=str(ENGINE), log_path=log_path)
        if result.returncode != 0:
            raise RuntimeError(f"Task exited with code {result.returncode}")
        update_job(job_id, status="success", finished_at=now(), progress=100, message="Completed")
    except Exception as exc:
        with log_path.open("a", encoding="utf-8") as f:
            f.write("\n[BSM ERROR] " + redact_text(str(exc)) + "\n")
            f.write(redact_text(traceback.format_exc()) + "\n")
        update_job(job_id, status="failed", finished_at=now(), progress=100, message=redact_text(str(exc)))


def create_job(task: str, actor: str) -> dict[str, Any]:
    allowed = {"reconcile", "verify", "update-containers", "backup", "restore-test", "status"}
    if task not in allowed:
        raise ValueError("Task is not allowlisted")
    job_id = uuid.uuid4().hex[:16]
    job = {
        "id": job_id,
        "task": task,
        "actor": actor,
        "status": "queued",
        "progress": 0,
        "message": "Queued",
        "created_at": now(),
    }
    save_job(job)
    _, log = job_paths(job_id)
    log.touch()
    threading.Thread(target=run_job, args=(job_id, task, actor), daemon=True).start()
    return job


def list_jobs(limit: int = 50) -> list[dict[str, Any]]:
    jobs = []
    for p in sorted(JOBS_DIR.glob("*.json"), key=lambda x: x.stat().st_mtime, reverse=True)[:limit]:
        data = load_json(p, None)
        if data:
            jobs.append(data)
    return jobs


def safe_member(name: str) -> bool:
    p = pathlib.PurePosixPath(name)
    return not p.is_absolute() and ".." not in p.parts and not name.startswith("/")


def stage_update(upload_path: str, actor: str) -> dict[str, Any]:
    source = pathlib.Path(upload_path).resolve()
    root = UPLOAD_ROOT.resolve()
    if root not in source.parents or not source.is_file():
        raise ValueError("Update file is outside the upload directory")
    if source.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("Update package is too large")
    update_id = uuid.uuid4().hex[:12]
    dest = UPDATE_DIR / update_id
    dest.mkdir(parents=True)
    with zipfile.ZipFile(source) as z:
        names = z.namelist()
        if any(not safe_member(n) for n in names):
            raise ValueError("Unsafe path in update archive")
        if "manifest.json" not in names or "payload.tar.gz" not in names:
            raise ValueError("Update requires manifest.json and payload.tar.gz")
        manifest = json.loads(z.read("manifest.json"))
        payload = z.read("payload.tar.gz")
    expected = str(manifest.get("payload_sha256", ""))
    actual = hashlib.sha256(payload).hexdigest()
    if not hmac.compare_digest(expected, actual):
        raise ValueError("Payload checksum mismatch")
    if manifest.get("kind") not in {"panel", "taskpack"}:
        raise ValueError("Unsupported update kind")
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    (dest / "payload.tar.gz").write_bytes(payload)
    info = {
        "id": update_id,
        "status": "staged",
        "manifest": manifest,
        "sha256": actual,
        "staged_at": now(),
        "actor": actor,
    }
    atomic_json(dest / "state.json", info)
    append_ledger({
        "timestamp": now(), "actor": actor, "source": "update", "job_id": "",
        "argv": ["STAGE_UPDATE", str(source)], "cwd": str(dest), "exit_code": 0,
        "duration_ms": 0, "manifest": manifest, "payload_sha256": actual,
    })
    return info


def safe_extract_tar(path: pathlib.Path, target: pathlib.Path) -> None:
    with tarfile.open(path, "r:gz") as tf:
        members = tf.getmembers()
        for m in members:
            if not safe_member(m.name) or m.issym() or m.islnk():
                raise ValueError(f"Unsafe tar member: {m.name}")
        tf.extractall(target)


def apply_update(update_id: str, actor: str) -> dict[str, Any]:
    dest = UPDATE_DIR / update_id
    state = load_json(dest / "state.json", None)
    if not state or state.get("status") != "staged":
        raise ValueError("Update is not staged")
    manifest = state["manifest"]
    kind = manifest["kind"]
    version = str(manifest.get("version", "")).strip()
    if not re.fullmatch(r"[0-9A-Za-z._-]+", version):
        raise ValueError("Invalid update version")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="bsm-update-", dir=str(UPDATE_DIR)))
    try:
        safe_extract_tar(dest / "payload.tar.gz", tmp)
        roots = [p for p in tmp.iterdir() if p.is_dir()]
        src = roots[0] if len(roots) == 1 else tmp
        if kind == "panel":
            required = ["release.json", "docker-compose.yml", "agent/bsm_agent.py", "web/Dockerfile"]
            for rel in required:
                if not (src / rel).exists():
                    raise ValueError(f"Missing required release file: {rel}")
            release_dir = pathlib.Path("/opt/bsm-community/releases") / version
            if release_dir.exists():
                shutil.rmtree(release_dir)
            shutil.copytree(src, release_dir)
            ensure_release_env(release_dir)
            current = pathlib.Path("/opt/bsm-community/current")
            new_link = current.with_name("current.new")
            if new_link.exists() or new_link.is_symlink():
                new_link.unlink()
            new_link.symlink_to(release_dir)
            os.replace(new_link, current)
            state["status"] = "apply-scheduled"
            state["applied_at"] = now()
            atomic_json(dest / "state.json", state)
            append_ledger({
                "timestamp": now(), "actor": actor, "source": "update", "job_id": "",
                "argv": ["APPLY_PANEL_UPDATE", version], "cwd": str(release_dir),
                "exit_code": 0, "duration_ms": 0,
            })
            subprocess.Popen([
                "systemd-run", "--unit", f"bsm-update-{update_id}", "--on-active=2s",
                "/bin/bash", "-lc",
                "install -m 0644 /opt/bsm-community/current/agent/bsm-agent.service /etc/systemd/system/bsm-agent.service; "
                "systemctl daemon-reload; systemctl restart bsm-agent; "
                "docker compose --env-file /opt/bsm-community/current/.env -f /opt/bsm-community/current/docker-compose.yml up -d --build",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return state
        taskpack_name = str(manifest.get("name", "taskpack"))
        if not re.fullmatch(r"[A-Za-z0-9._-]+", taskpack_name):
            raise ValueError("Invalid taskpack name")
        target = pathlib.Path("/opt/bsm-community/taskpacks") / taskpack_name / version
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(src, target)
        state["status"] = "installed-disabled"
        state["applied_at"] = now()
        state["target"] = str(target)
        atomic_json(dest / "state.json", state)
        return state
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def list_updates() -> list[dict[str, Any]]:
    result = []
    for p in sorted(UPDATE_DIR.glob("*/state.json"), key=lambda x: x.stat().st_mtime, reverse=True):
        item = load_json(p, None)
        if item:
            result.append(item)
    return result


def list_releases() -> list[dict[str, Any]]:
    releases_dir = pathlib.Path("/opt/bsm-community/releases")
    current_path = pathlib.Path("/opt/bsm-community/current")
    try:
        active = str(current_path.resolve())
    except Exception:
        active = ""
    result = []
    if releases_dir.exists():
        for p in sorted(releases_dir.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
            if not p.is_dir():
                continue
            info = load_json(p / "release.json", {})
            result.append({
                "version": info.get("version", p.name),
                "path": str(p),
                "active": str(p.resolve()) == active,
                "modified_at": dt.datetime.fromtimestamp(p.stat().st_mtime, dt.timezone.utc).isoformat(),
            })
    return result


def ensure_release_env(release_dir: pathlib.Path) -> None:
    try:
        import grp
        gid = grp.getgrnam("bsm").gr_gid
    except Exception:
        gid = 0
    env_path = release_dir / ".env"
    env_path.write_text(f"BSM_GID={gid}\n", encoding="utf-8")
    os.chmod(env_path, 0o600)


def activate_release(version: str, actor: str) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9A-Za-z._-]+", version):
        raise ValueError("Invalid release version")
    target = pathlib.Path("/opt/bsm-community/releases") / version
    if not target.is_dir():
        raise ValueError("Release not found")
    required = ["release.json", "docker-compose.yml", "agent/bsm_agent.py", "web/Dockerfile"]
    for rel in required:
        if not (target / rel).exists():
            raise ValueError(f"Release is incomplete: {rel}")
    ensure_release_env(target)
    current = pathlib.Path("/opt/bsm-community/current")
    new_link = current.with_name("current.new")
    if new_link.exists() or new_link.is_symlink():
        new_link.unlink()
    new_link.symlink_to(target)
    os.replace(new_link, current)
    append_ledger({
        "timestamp": now(), "actor": actor, "source": "release", "job_id": "",
        "argv": ["ACTIVATE_RELEASE", version], "cwd": str(target),
        "exit_code": 0, "duration_ms": 0,
    })
    subprocess.Popen([
        "systemd-run", "--unit", f"bsm-rollback-{uuid.uuid4().hex[:8]}", "--on-active=2s",
        "/bin/bash", "-lc",
        "install -m 0644 /opt/bsm-community/current/agent/bsm-agent.service /etc/systemd/system/bsm-agent.service; "
        "systemctl daemon-reload; systemctl restart bsm-agent; "
        "docker compose --env-file /opt/bsm-community/current/.env -f /opt/bsm-community/current/docker-compose.yml up -d --build",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True, "version": version, "status": "scheduled"}


def create_diagnostics(actor: str) -> dict[str, Any]:
    diag_id = uuid.uuid4().hex[:12]
    work = pathlib.Path(tempfile.mkdtemp(prefix="bsm-diag-", dir=str(DIAG_DIR)))
    commands = {
        "os-release.txt": ["cat", "/etc/os-release"],
        "uname.txt": ["uname", "-a"],
        "disk.txt": ["df", "-hT"],
        "memory.txt": ["free", "-h"],
        "ports.txt": ["ss", "-lntp"],
        "docker-ps.txt": ["docker", "ps", "-a"],
        "docker-info.txt": ["docker", "info"],
        "hestia-services.txt": ["/usr/local/hestia/bin/v-list-sys-services"],
        "cloudflared.txt": ["systemctl", "status", "cloudflared", "--no-pager"],
        "bsm-agent.txt": ["systemctl", "status", "bsm-agent", "--no-pager"],
    }
    for filename, cmd in commands.items():
        try:
            p = run_command(cmd, actor=actor, job_id=f"diag-{diag_id}")
            (work / filename).write_text(redact_text(p.stdout), encoding="utf-8")
        except Exception as exc:
            (work / filename).write_text(redact_text(str(exc)), encoding="utf-8")
    (work / "config-redacted.json").write_text(json.dumps(redact_obj(config_for_ui()), indent=2), encoding="utf-8")
    if LEDGER_JSONL.exists():
        lines = LEDGER_JSONL.read_text(encoding="utf-8", errors="replace").splitlines()[-500:]
        (work / "ledger-tail.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    archive = DIAG_DIR / f"bsm-diagnostics-{diag_id}.tar.gz"
    with tarfile.open(archive, "w:gz") as tf:
        tf.add(work, arcname=f"bsm-diagnostics-{diag_id}")
    shutil.rmtree(work, ignore_errors=True)
    append_ledger({
        "timestamp": now(), "actor": actor, "source": "diagnostics", "job_id": "",
        "argv": ["CREATE_DIAGNOSTICS", str(archive)], "cwd": str(DIAG_DIR),
        "exit_code": 0, "duration_ms": 0,
    })
    return {"id": diag_id, "filename": archive.name, "size": archive.stat().st_size, "created_at": now()}


class UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    server_version = f"BSMAgent/{VERSION}"

    def log_message(self, fmt: str, *args: Any) -> None:
        with (LOGS / "agent-access.log").open("a", encoding="utf-8") as f:
            f.write(f"{now()} {self.client_address!r} {fmt % args}\n")

    def _auth(self) -> bool:
        expected = TOKEN_FILE.read_text(encoding="utf-8").strip()
        supplied = self.headers.get("X-BSM-Agent-Token", "")
        return bool(expected and hmac.compare_digest(expected, supplied))

    def _json(self, status: int, data: Any) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bytes(self, status: int, data: bytes, content_type: str, filename: str | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if filename:
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 2 * 1024 * 1024:
            raise ValueError("Request body too large")
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw or b"{}")

    def _route(self) -> tuple[str, dict[str, list[str]]]:
        parsed = urllib.parse.urlparse(self.path)
        return parsed.path, urllib.parse.parse_qs(parsed.query)

    def do_GET(self) -> None:  # noqa: N802
        if not self._auth():
            self._json(401, {"error": "unauthorized"})
            return
        path, query = self._route()
        try:
            if path == "/health":
                self._json(200, {"ok": True, "version": VERSION})
            elif path == "/system":
                self._json(200, system_snapshot())
            elif path == "/containers":
                self._json(200, docker_containers())
            elif path.startswith("/containers/") and path.endswith("/logs"):
                name = path.split("/")[2]
                tail = min(int(query.get("tail", ["200"])[0]), 2000)
                p = run_command(["docker", "logs", "--tail", str(tail), name], actor="web")
                self._json(200, {"name": name, "logs": p.stdout})
            elif path == "/config":
                self._json(200, config_for_ui())
            elif path == "/ai/config":
                self._json(200, ai_config_for_ui())
            elif path == "/jobs":
                self._json(200, list_jobs())
            elif path.startswith("/jobs/") and path.endswith("/log"):
                job_id = path.split("/")[2]
                offset = max(int(query.get("offset", ["0"])[0]), 0)
                _, log_path = job_paths(job_id)
                data = log_path.read_bytes() if log_path.exists() else b""
                chunk = data[offset: offset + 256 * 1024]
                job = load_job(job_id)
                self._json(200, {"offset": offset, "next_offset": offset + len(chunk), "chunk": chunk.decode("utf-8", "replace"), "job": job})
            elif path.startswith("/jobs/"):
                job = load_job(path.split("/")[2])
                self._json(200 if job else 404, job or {"error": "not found"})
            elif path == "/ledger":
                limit = min(int(query.get("limit", ["300"])[0]), 2000)
                lines = LEDGER_JSONL.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:]
                entries = []
                for line in reversed(lines):
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
                self._json(200, entries)
            elif path == "/ledger/export.jsonl":
                self._bytes(200, LEDGER_JSONL.read_bytes(), "application/x-ndjson", "bsm-command-ledger.jsonl")
            elif path == "/ledger/export.sh":
                self._bytes(200, LEDGER_SH.read_bytes(), "text/x-shellscript", "bsm-command-ledger.sh")
            elif path == "/updates":
                self._json(200, list_updates())
            elif path == "/releases":
                self._json(200, list_releases())
            elif path.startswith("/diagnostics/"):
                diag_id = path.split("/")[2]
                archive = DIAG_DIR / f"bsm-diagnostics-{diag_id}.tar.gz"
                if not archive.exists():
                    self._json(404, {"error": "not found"})
                else:
                    self._bytes(200, archive.read_bytes(), "application/gzip", archive.name)
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:
            self._json(500, {"error": redact_text(str(exc))})

    def do_PUT(self) -> None:  # noqa: N802
        if not self._auth():
            self._json(401, {"error": "unauthorized"})
            return
        path, _ = self._route()
        try:
            body = self._body()
            actor = self.headers.get("X-BSM-Actor", "web")
            if path == "/config":
                config, secrets = validate_config(body)
                before_cfg = file_sha256(CONFIG_FILE)
                before_sec = file_sha256(SECRETS_FILE)
                atomic_json(CONFIG_FILE, config)
                atomic_json(SECRETS_FILE, secrets)
                record_file_change(CONFIG_FILE, before_cfg, actor)
                record_file_change(SECRETS_FILE, before_sec, actor)
                self._json(200, config_for_ui())
            elif path == "/ai/config":
                self._json(200, save_ai_config(body, actor))
            else:
                self._json(404, {"error": "not found"})
        except ValueError as exc:
            self._json(400, {"error": str(exc)})
        except Exception as exc:
            self._json(500, {"error": redact_text(str(exc))})

    def do_POST(self) -> None:  # noqa: N802
        if not self._auth():
            self._json(401, {"error": "unauthorized"})
            return
        path, _ = self._route()
        actor = self.headers.get("X-BSM-Actor", "web")
        try:
            body = self._body()
            if path == "/jobs":
                self._json(202, create_job(str(body.get("task", "")), actor))
            elif path.startswith("/containers/"):
                parts = path.split("/")
                if len(parts) != 4 or parts[3] not in {"start", "stop", "restart"}:
                    raise ValueError("Invalid container action")
                name, action = parts[2], parts[3]
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
                    raise ValueError("Invalid container name")
                p = run_command(["docker", action, name], actor=actor)
                self._json(200 if p.returncode == 0 else 409, {"ok": p.returncode == 0, "output": p.stdout})
            elif path == "/ai/context":
                self._json(200, build_ai_context(body))
            elif path == "/ai/ask":
                self._json(200, ask_ai(
                    str(body.get("question", "")),
                    body.get("context") or {},
                    actor,
                    str(body.get("context_snapshot", "")),
                ))
            elif path == "/diagnostics":
                self._json(201, create_diagnostics(actor))
            elif path == "/updates/stage":
                self._json(201, stage_update(str(body.get("path", "")), actor))
            elif path.startswith("/updates/") and path.endswith("/apply"):
                update_id = path.split("/")[2]
                confirm = body.get("confirm")
                if confirm != "APPLY UPDATE":
                    raise ValueError("Confirmation phrase is required")
                self._json(202, apply_update(update_id, actor))
            elif path.startswith("/releases/") and path.endswith("/activate"):
                version = path.split("/")[2]
                if body.get("confirm") != "ROLLBACK":
                    raise ValueError("Rollback confirmation phrase is required")
                self._json(202, activate_release(version, actor))
            else:
                self._json(404, {"error": "not found"})
        except ValueError as exc:
            self._json(400, {"error": str(exc)})
        except Exception as exc:
            self._json(500, {"error": redact_text(str(exc))})


def main() -> None:
    ensure_layout()
    if not TOKEN_FILE.exists() or not TOKEN_FILE.read_text(encoding="utf-8").strip():
        raise SystemExit("Missing /etc/bsm/agent.token")
    if SOCKET.exists() or SOCKET.is_socket():
        SOCKET.unlink()
    server = UnixHTTPServer(str(SOCKET), Handler)
    os.chmod(SOCKET, 0o660)
    try:
        import grp
        gid = grp.getgrnam("bsm").gr_gid
        os.chown(SOCKET, 0, gid)
    except Exception:
        pass
    print(f"BSM agent {VERSION} listening on {SOCKET}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        if SOCKET.exists():
            SOCKET.unlink()


if __name__ == "__main__":
    main()
