import base64
import hashlib
import hmac
import ipaddress
import os
import secrets
import sqlite3
import subprocess
from pathlib import Path
from typing import Optional

import qrcode
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse, PlainTextResponse, StreamingResponse
from pydantic import BaseModel, Field

APP_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("X7_DB", "/var/lib/x7-panel/panel.db"))
ADMIN_USER = os.getenv("X7_ADMIN_USER", "")
PASSWORD_HASH = os.getenv("X7_ADMIN_PASSWORD_HASH", "")
IFACE = os.getenv("X7_INTERFACE", "x7wg0")
PORT = int(os.getenv("X7_WG_PORT", "51821"))
SERVER_ENDPOINT = os.getenv("X7_ENDPOINT", "")
DNS = os.getenv("X7_DNS", "1.1.1.1")
MODE = os.getenv("X7_MODE", "standalone")
CLIENT_ALLOWED_IPS = os.getenv("X7_CLIENT_ALLOWED_IPS", "0.0.0.0/0")
CONF = Path("/etc/wireguard") / f"{IFACE}.conf"

app = FastAPI(title="X7 Panel", version="0.5.0", docs_url=None, redoc_url=None)


def db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS peers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        public_key TEXT NOT NULL UNIQUE,
        address TEXT NOT NULL UNIQUE,
        private_key TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )""")
    conn.commit()
    return conn


def verify_password(password: str) -> bool:
    try:
        salt, expected = PASSWORD_HASH.split("$", 1)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 310000).hex()
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError):
        return False


def require_auth(authorization: Optional[str]):
    if not authorization or not authorization.startswith("Basic "):
        raise HTTPException(status_code=401, detail="ابتدا وارد پنل شوید")
    try:
        raw = base64.b64decode(authorization[6:], validate=True).decode("utf-8")
        username, password = raw.split(":", 1)
    except Exception:
        raise HTTPException(status_code=401, detail="نام کاربری یا رمز عبور نادرست است")
    if not ADMIN_USER or not hmac.compare_digest(username, ADMIN_USER) or not verify_password(password):
        raise HTTPException(status_code=401, detail="نام کاربری یا رمز عبور نادرست است")


def cmd(args, input_text=None, check=True):
    try:
        return subprocess.run(args, input=input_text, text=True, capture_output=True,
                              check=check, timeout=20)
    except FileNotFoundError:
        raise HTTPException(503, "ابزار WireGuard نصب نیست")
    except subprocess.TimeoutExpired:
        raise HTTPException(504, "فرمان سرور بیش از حد طول کشید")
    except subprocess.CalledProcessError as exc:
        raise HTTPException(503, (exc.stderr or "فرمان WireGuard ناموفق بود")[-500:])


def ensure_ready():
    if not CONF.exists():
        raise HTTPException(503, f"اینترفیس {IFACE} آماده نیست")


def persist_peers():
    if not CONF.exists():
        raise HTTPException(503, "WireGuard config file is missing")
    lines = CONF.read_text(encoding="utf-8").splitlines()
    base_lines = []
    for line in lines:
        if line.strip().lower() == "[peer]":
            break
        base_lines.append(line)
    conn = db()
    rows = conn.execute("SELECT public_key,address FROM peers ORDER BY id").fetchall()
    conn.close()
    chunks = ["\n".join(base_lines).rstrip(), ""]
    for row in rows:
        chunks.extend(["[Peer]", f"PublicKey = {row['public_key']}",
                       f"AllowedIPs = {row['address']}", ""])
    tmp = CONF.with_suffix(".conf.tmp")
    tmp.write_text("\n".join(chunks).rstrip() + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(CONF)


def server_public_key():
    ensure_ready()
    result = cmd(["wg", "show", IFACE, "public-key"], check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


class LoginInput(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class PeerCreate(BaseModel):
    name: str = Field(min_length=2, max_length=32, pattern=r"^[A-Za-z0-9_-]+$")
    address: Optional[str] = None


def allocate_peer_address(conn):
    raw = os.getenv("X7_SERVER_ADDRESS", "10.78.0.1/24")
    try:
        server_iface = ipaddress.ip_interface(raw)
        network = server_iface.network
    except ValueError:
        network = ipaddress.ip_network("10.78.0.0/24")
        server_iface = ipaddress.ip_interface("10.78.0.1/24")
    used = {str(server_iface.ip)}
    used.update(r[0].split("/")[0] for r in conn.execute("SELECT address FROM peers"))
    # Keep automatic allocation in the first 4096 host addresses.
    for candidate in network.hosts():
        if str(candidate) not in used:
            return ipaddress.ip_interface(f"{candidate}/32")
        if int(candidate) - int(network.network_address) > 4096:
            break
    raise HTTPException(409, "ظرفیت آدرس‌های این شبکه تمام شده است")


@app.get("/", response_class=HTMLResponse)
def index():
    return HTMLResponse((APP_DIR / "index.html").read_text(encoding="utf-8"))


@app.post("/api/login")
def login(data: LoginInput):
    if (not ADMIN_USER or not hmac.compare_digest(data.username, ADMIN_USER)
            or not verify_password(data.password)):
        raise HTTPException(status_code=401, detail="نام کاربری یا رمز عبور نادرست است")
    return {"ok": True}


@app.get("/api/status")
def status(authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    ensure_ready()
    show = cmd(["wg", "show", IFACE], check=False)
    return {"mode": MODE, "interface": IFACE, "listen_port": PORT,
            "active": show.returncode == 0, "public_key": server_public_key(),
            "endpoint_configured": bool(SERVER_ENDPOINT)}


@app.get("/api/peers")
def list_peers(authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    conn = db()
    rows = conn.execute("SELECT id,name,public_key,address,created_at FROM peers ORDER BY id DESC").fetchall()
    conn.close()
    runtime = {}
    result = cmd(["wg", "show", IFACE, "dump"], check=False)
    if result.returncode == 0:
        for line in result.stdout.splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 8:
                runtime[parts[0]] = {"endpoint": parts[2], "latest_handshake": parts[4],
                                     "rx": int(parts[5]), "tx": int(parts[6])}
    return [{"id": r["id"], "name": r["name"], "public_key": r["public_key"],
             "address": r["address"], "created_at": r["created_at"],
             "runtime": runtime.get(r["public_key"], {})} for r in rows]


def build_client_config(private_key: str, address: str):
    if not SERVER_ENDPOINT:
        raise HTTPException(409, "آدرس عمومی سرور تنظیم نشده است")
    return ("[Interface]\n" f"PrivateKey = {private_key}\n"
            f"Address = {address}/32\n" f"DNS = {DNS}\n\n"
            "[Peer]\n" f"PublicKey = {server_public_key()}\n"
            f"Endpoint = {SERVER_ENDPOINT}:{PORT}\n"
            f"AllowedIPs = {CLIENT_ALLOWED_IPS}\n" "PersistentKeepalive = 25\n")


@app.post("/api/peers")
def create_peer(peer: PeerCreate, authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    ensure_ready()
    if not SERVER_ENDPOINT:
        raise HTTPException(409, "آدرس عمومی سرور تنظیم نشده است")
    conn = db()
    try:
        if peer.address:
            iface = ipaddress.ip_interface(peer.address)
            if iface.version != 4 or iface.network.prefixlen != 32:
                raise ValueError()
        else:
            iface = allocate_peer_address(conn)
    except ValueError:
        conn.close()
        raise HTTPException(400, "آدرس باید IPv4 با پسوند /32 باشد")
    if conn.execute("SELECT 1 FROM peers WHERE name=? OR address=?",
                    (peer.name, str(iface))).fetchone():
        conn.close()
        raise HTTPException(409, "نام یا آدرس این کاربر تکراری است")
    private = cmd(["wg", "genkey"]).stdout.strip()
    public = cmd(["wg", "pubkey"], input_text=private).stdout.strip()
    added = False
    try:
        cmd(["wg", "set", IFACE, "peer", public, "allowed-ips", str(iface)])
        added = True
        cur = conn.execute("INSERT INTO peers(name,public_key,address,private_key) VALUES(?,?,?,?)",
                           (peer.name, public, str(iface), private))
        peer_id = cur.lastrowid
        conn.commit()
        persist_peers()
    except Exception:
        if added:
            cmd(["wg", "set", IFACE, "peer", public, "remove"], check=False)
        conn.rollback()
        conn.close()
        raise
    conn.close()
    return {"id": peer_id, "name": peer.name, "public_key": public,
            "client_config": build_client_config(private, str(iface.ip)),
            "message": "کلید خصوصی را محرمانه نگه دارید."}


@app.get("/api/peers/{peer_id}/config")
def get_peer_config(peer_id: int, authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    conn = db()
    row = conn.execute("SELECT name,address,private_key FROM peers WHERE id=?", (peer_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(404, "کاربر پیدا نشد")
    return PlainTextResponse(build_client_config(row["private_key"], row["address"].split("/")[0]),
                              headers={"Content-Disposition": f'attachment; filename="{row["name"]}.conf"'})


@app.get("/api/peers/{peer_id}/qr")
def peer_qr(peer_id: int, authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    conn = db()
    row = conn.execute("SELECT address,private_key FROM peers WHERE id=?", (peer_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(404, "کاربر پیدا نشد")
    img = qrcode.make(build_client_config(row["private_key"], row["address"].split("/")[0]))
    import io
    out = io.BytesIO()
    img.save(out, format="PNG")
    out.seek(0)
    return StreamingResponse(out, media_type="image/png")


@app.delete("/api/peers/{peer_id}")
def delete_peer(peer_id: int, authorization: Optional[str] = Header(default=None)):
    require_auth(authorization)
    conn = db()
    row = conn.execute("SELECT public_key FROM peers WHERE id=?", (peer_id,)).fetchone()
    if not row:
        conn.close()
        raise HTTPException(404, "کاربر پیدا نشد")
    cmd(["wg", "set", IFACE, "peer", row["public_key"], "remove"])
    conn.execute("DELETE FROM peers WHERE id=?", (peer_id,))
    conn.commit()
    conn.close()
    persist_peers()
    return {"deleted": peer_id}
