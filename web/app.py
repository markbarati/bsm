from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import pathlib
import secrets
import sqlite3
import time
from contextlib import contextmanager
from typing import Any, AsyncIterator

import httpx
from fastapi import Depends, FastAPI, File, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

APP_VERSION = "0.2.0"
DATA = pathlib.Path(os.getenv("BSM_DATA", "/data"))
DB = DATA / "bsm.db"
UPLOADS = DATA / "uploads"
STATIC = pathlib.Path(__file__).parent / "static"
AGENT_SOCKET = os.getenv("BSM_AGENT_SOCKET", "/run/bsm/agent.sock")
AGENT_TOKEN_FILE = pathlib.Path(os.getenv("BSM_AGENT_TOKEN_FILE", "/run/secrets/agent_token"))
BOOTSTRAP_FILE = pathlib.Path(os.getenv("BSM_BOOTSTRAP_FILE", "/run/secrets/bootstrap_admin"))
SESSION_COOKIE = "bsm_session"
SESSION_TTL = 7 * 24 * 3600
LOGIN_ATTEMPTS: dict[str, list[float]] = {}

app = FastAPI(title="BSM Community", version=APP_VERSION, docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=STATIC), name="static")


def now_ts() -> int:
    return int(time.time())


def scrypt_hash(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return "scrypt$" + base64.urlsafe_b64encode(salt).decode() + "$" + base64.urlsafe_b64encode(digest).decode()


def verify_password(password: str, encoded: str) -> bool:
    try:
        kind, salt64, digest64 = encoded.split("$", 2)
        if kind != "scrypt":
            return False
        salt = base64.urlsafe_b64decode(salt64)
        expected = base64.urlsafe_b64decode(digest64)
        actual = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=len(expected))
        return hmac.compare_digest(expected, actual)
    except Exception:
        return False


@contextmanager
def db() -> Any:
    DATA.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    try:
        yield con
        con.commit()
    finally:
        con.close()


def init_db() -> None:
    UPLOADS.mkdir(parents=True, exist_ok=True)
    with db() as con:
        con.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS users (
              id INTEGER PRIMARY KEY,
              username TEXT UNIQUE NOT NULL,
              password_hash TEXT NOT NULL,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
              token_hash TEXT PRIMARY KEY,
              user_id INTEGER NOT NULL,
              csrf TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              expires_at INTEGER NOT NULL,
              ip TEXT,
              FOREIGN KEY(user_id) REFERENCES users(id)
            );
            """
        )
        count = con.execute("SELECT count(*) AS n FROM users").fetchone()["n"]
        if count == 0:
            if not BOOTSTRAP_FILE.exists():
                raise RuntimeError("Missing bootstrap admin secret")
            info = json.loads(BOOTSTRAP_FILE.read_text())
            con.execute(
                "INSERT INTO users(username,password_hash,created_at) VALUES(?,?,?)",
                (info["username"], info["password_hash"], now_ts()),
            )


@app.on_event("startup")
def startup() -> None:
    init_db()


def agent_token() -> str:
    return AGENT_TOKEN_FILE.read_text().strip()


def agent_client() -> httpx.AsyncClient:
    transport = httpx.AsyncHTTPTransport(uds=AGENT_SOCKET)
    return httpx.AsyncClient(
        transport=transport,
        base_url="http://bsm-agent",
        headers={"X-BSM-Agent-Token": agent_token()},
        timeout=120.0,
    )


def client_ip(request: Request) -> str:
    return request.headers.get("cf-connecting-ip") or request.client.host if request.client else "unknown"


def create_session(user_id: int, request: Request) -> tuple[str, str]:
    token = secrets.token_urlsafe(32)
    csrf = secrets.token_urlsafe(24)
    digest = hashlib.sha256(token.encode()).hexdigest()
    with db() as con:
        con.execute("DELETE FROM sessions WHERE expires_at < ?", (now_ts(),))
        con.execute(
            "INSERT INTO sessions(token_hash,user_id,csrf,created_at,expires_at,ip) VALUES(?,?,?,?,?,?)",
            (digest, user_id, csrf, now_ts(), now_ts() + SESSION_TTL, client_ip(request)),
        )
    return token, csrf


def get_session(request: Request) -> sqlite3.Row:
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        raise HTTPException(401, "Authentication required")
    digest = hashlib.sha256(token.encode()).hexdigest()
    with db() as con:
        row = con.execute(
            "SELECT s.*,u.username FROM sessions s JOIN users u ON u.id=s.user_id WHERE token_hash=? AND expires_at>?",
            (digest, now_ts()),
        ).fetchone()
    if not row:
        raise HTTPException(401, "Session expired")
    return row


def auth(request: Request) -> sqlite3.Row:
    return get_session(request)


def mutate_auth(request: Request, x_csrf_token: str = Header(default="")) -> sqlite3.Row:
    row = get_session(request)
    if not x_csrf_token or not hmac.compare_digest(x_csrf_token, row["csrf"]):
        raise HTTPException(403, "Invalid CSRF token")
    return row


def actor_headers(user: sqlite3.Row) -> dict[str, str]:
    return {"X-BSM-Actor": str(user["username"])}


@app.get("/", response_class=HTMLResponse)
def index() -> FileResponse:
    return FileResponse(STATIC / "index.html")


@app.post("/api/auth/login")
async def login(request: Request) -> JSONResponse:
    body = await request.json()
    username = str(body.get("username", ""))[:128]
    password = str(body.get("password", ""))
    ip = client_ip(request)
    recent = [t for t in LOGIN_ATTEMPTS.get(ip, []) if time.time() - t < 300]
    LOGIN_ATTEMPTS[ip] = recent
    if len(recent) >= 10:
        raise HTTPException(429, "Too many login attempts")
    with db() as con:
        user = con.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if not user or not verify_password(password, user["password_hash"]):
        LOGIN_ATTEMPTS[ip].append(time.time())
        await asyncio.sleep(0.6)
        raise HTTPException(401, "Invalid username or password")
    token, csrf = create_session(user["id"], request)
    resp = JSONResponse({"ok": True, "username": username, "csrf": csrf})
    secure = request.headers.get("x-forwarded-proto") == "https"
    resp.set_cookie(SESSION_COOKIE, token, httponly=True, samesite="strict", secure=secure, max_age=SESSION_TTL, path="/")
    return resp


@app.post("/api/auth/logout")
def logout(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> JSONResponse:
    token = request.cookies.get(SESSION_COOKIE, "")
    digest = hashlib.sha256(token.encode()).hexdigest()
    with db() as con:
        con.execute("DELETE FROM sessions WHERE token_hash=?", (digest,))
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(SESSION_COOKIE, path="/")
    return resp


@app.get("/api/me")
def me(user: sqlite3.Row = Depends(auth)) -> dict[str, Any]:
    return {"username": user["username"], "csrf": user["csrf"], "version": APP_VERSION}


async def agent_json(method: str, path: str, user: sqlite3.Row, **kwargs: Any) -> Any:
    async with agent_client() as client:
        headers = kwargs.pop("headers", {})
        headers.update(actor_headers(user))
        r = await client.request(method, path, headers=headers, **kwargs)
        if r.status_code >= 400:
            try:
                detail = r.json().get("error")
            except Exception:
                detail = r.text
            raise HTTPException(r.status_code, detail or "Agent request failed")
        return r.json()


@app.get("/api/dashboard")
async def dashboard(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/system", user)


@app.get("/api/containers")
async def containers(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/containers", user)


@app.get("/api/containers/{name}/logs")
async def container_logs(name: str, tail: int = 300, user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", f"/containers/{name}/logs?tail={min(tail, 2000)}", user)


@app.post("/api/containers/{name}/{action}")
async def container_action(name: str, action: str, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("POST", f"/containers/{name}/{action}", user, json={})


@app.get("/api/config")
async def config_get(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/config", user)


@app.put("/api/config")
async def config_put(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("PUT", "/config", user, json=await request.json())


@app.get("/api/jobs")
async def jobs(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/jobs", user)


@app.post("/api/jobs")
async def jobs_create(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("POST", "/jobs", user, json=await request.json())


@app.get("/api/jobs/{job_id}")
async def job(job_id: str, user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", f"/jobs/{job_id}", user)


@app.get("/api/jobs/{job_id}/log")
async def job_log(job_id: str, offset: int = 0, user: sqlite3.Row = Depends(auth)) -> Any:
    offset = max(0, min(offset, 2_000_000_000))
    return await agent_json("GET", f"/jobs/{job_id}/log?offset={offset}", user)


@app.get("/api/jobs/{job_id}/stream")
async def job_stream(job_id: str, user: sqlite3.Row = Depends(auth)) -> StreamingResponse:
    async def events() -> AsyncIterator[bytes]:
        offset = 0
        while True:
            try:
                async with agent_client() as client:
                    r = await client.get(f"/jobs/{job_id}/log?offset={offset}", headers=actor_headers(user))
                    payload = r.json()
                offset = payload.get("next_offset", offset)
                yield ("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode()
                status = (payload.get("job") or {}).get("status")
                if status in {"success", "failed"} and not payload.get("chunk"):
                    break
            except Exception as exc:
                yield ("event: error\ndata: " + json.dumps({"error": str(exc)}) + "\n\n").encode()
                break
            await asyncio.sleep(1)
    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


@app.get("/api/ledger")
async def ledger(limit: int = 300, user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", f"/ledger?limit={min(limit, 2000)}", user)


@app.get("/api/ledger/export/{kind}")
async def ledger_export(kind: str, user: sqlite3.Row = Depends(auth)) -> StreamingResponse:
    target = "/ledger/export.jsonl" if kind == "jsonl" else "/ledger/export.sh"
    async with agent_client() as client:
        r = await client.get(target, headers=actor_headers(user))
        if r.status_code >= 400:
            raise HTTPException(r.status_code, r.text)
        media = r.headers.get("content-type", "application/octet-stream")
        disposition = r.headers.get("content-disposition")
        headers = {"Content-Disposition": disposition} if disposition else {}
        return StreamingResponse(iter([r.content]), media_type=media, headers=headers)




@app.get("/api/ai/config")
async def ai_config_get(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/ai/config", user)


@app.put("/api/ai/config")
async def ai_config_put(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("PUT", "/ai/config", user, json=await request.json())


@app.post("/api/ai/context")
async def ai_context(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("POST", "/ai/context", user, json=await request.json())


@app.post("/api/ai/ask")
async def ai_ask(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("POST", "/ai/ask", user, json=await request.json())

@app.post("/api/diagnostics")
async def diagnostics(user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("POST", "/diagnostics", user, json={})


@app.get("/api/diagnostics/{diag_id}")
async def diagnostics_download(diag_id: str, user: sqlite3.Row = Depends(auth)) -> StreamingResponse:
    async with agent_client() as client:
        r = await client.get(f"/diagnostics/{diag_id}", headers=actor_headers(user))
        if r.status_code >= 400:
            raise HTTPException(r.status_code, r.text)
        return StreamingResponse(iter([r.content]), media_type="application/gzip", headers={"Content-Disposition": r.headers.get("content-disposition", "attachment")})


@app.get("/api/updates")
async def updates(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/updates", user)


@app.get("/api/releases")
async def releases(user: sqlite3.Row = Depends(auth)) -> Any:
    return await agent_json("GET", "/releases", user)


@app.post("/api/releases/{version}/activate")
async def release_activate(version: str, request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    return await agent_json("POST", f"/releases/{version}/activate", user, json=await request.json())


@app.post("/api/updates/upload")
async def updates_upload(file: UploadFile = File(...), user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    if not file.filename or not file.filename.endswith(".bsmupdate"):
        raise HTTPException(400, "Expected a .bsmupdate file")
    safe = pathlib.Path(file.filename).name
    path = UPLOADS / f"{int(time.time())}-{secrets.token_hex(4)}-{safe}"
    size = 0
    with path.open("wb") as f:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > 100 * 1024 * 1024:
                path.unlink(missing_ok=True)
                raise HTTPException(413, "Update file is too large")
            f.write(chunk)
    return await agent_json("POST", "/updates/stage", user, json={"path": str(path)})


@app.post("/api/updates/{update_id}/apply")
async def updates_apply(update_id: str, request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    body = await request.json()
    return await agent_json("POST", f"/updates/{update_id}/apply", user, json=body)


@app.post("/api/change-password")
async def change_password(request: Request, user: sqlite3.Row = Depends(mutate_auth)) -> Any:
    body = await request.json()
    current = str(body.get("current", ""))
    new = str(body.get("new", ""))
    if len(new) < 12:
        raise HTTPException(400, "New password must be at least 12 characters")
    with db() as con:
        row = con.execute("SELECT * FROM users WHERE id=?", (user["user_id"],)).fetchone()
        if not row or not verify_password(current, row["password_hash"]):
            raise HTTPException(403, "Current password is incorrect")
        con.execute("UPDATE users SET password_hash=? WHERE id=?", (scrypt_hash(new), user["user_id"]))
        con.execute("DELETE FROM sessions WHERE user_id=?", (user["user_id"],))
    return {"ok": True, "message": "Password changed. Sign in again."}
