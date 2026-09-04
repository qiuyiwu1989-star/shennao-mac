"""深脑上传客户端：走现成的录音链路，不需要给深脑加任何接口。

认证用「原生端 Bearer」通道（lib/recording/route-context.ts 明确支持）：
    Authorization: Bearer <supabase access token>
    x-deepbrain-org-id: <org uuid>

上传五步（对应深脑 apps/web/src/app/api/recordings/*）：
    1. POST /api/recordings                              建会话
    2. POST /api/recordings/{id}/chunks/ticket           要一个分片上传地址
    3. PUT  <uploadUrl>                                  直传腾讯云 COS，不过深脑服务器
    4. POST /api/recordings/{id}/chunks/{seq}/complete   服务端校验分片
    5. POST /api/recordings/{id}/stop                    冻结分片总数与时长（不做会 409）
    6. POST /api/recordings/{id}/finalize                收尾，之后自动进说话人分离与分析

密码只在系统对话框里输入，直接换成 token，本工具不落盘、不打印密码。
refresh token 存 macOS 钥匙串（服务名 deepbrain-importer）。
"""
from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path

CONFIG = json.loads((Path(__file__).resolve().parent / "deepbrain.json").read_text())
API = CONFIG["apiBase"].rstrip("/")
SB = CONFIG["supabaseUrl"].rstrip("/")
ANON = CONFIG["supabaseAnonKey"]

# 凭证改存文件，不再用钥匙串。
# 原因：钥匙串授权绑代码签名身份，而 ad-hoc 签名每次重新部署身份都变，
# macOS 每次都当陌生程序弹框问登录密码，点「始终允许」也没用。
# 代价：文件 0600，只有本用户可读，比钥匙串弱；存的是 refresh token 不是密码，
# 泄露可在深脑吊销。Swift 版读的是同一个文件，两边不会各存一份。
CRED_FILE = Path.home() / "Library/Application Support/深脑/credentials.json"
_KEY_MAP = {"refresh_token": "refreshToken", "email": "email", "org_id": "orgId"}
MAX_CHUNK_BYTES = 8 * 1024 * 1024      # 与深脑 service.ts 的 MAX_CHUNK_BYTES 对齐


class DeepBrainError(RuntimeError):
    pass


# --- HTTP ---
def _request(method: str, url: str, *, headers: dict | None = None,
             json_body: dict | None = None, data: bytes | None = None,
             timeout: float = 120) -> tuple[int, bytes]:
    body = data
    hdr = dict(headers or {})
    if json_body is not None:
        body = json.dumps(json_body).encode()
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def _json_or_raise(status: int, raw: bytes, what: str) -> dict:
    if status >= 400:
        detail = raw.decode("utf-8", "replace")[:300]
        raise DeepBrainError(f"{what} 失败 HTTP {status}：{detail}")
    return json.loads(raw or b"{}")


# --- 钥匙串 ---
def _cred_read() -> dict:
    try:
        return json.loads(CRED_FILE.read_text())
    except Exception:
        return {}


def _keychain_get(account: str = "refresh_token") -> str | None:
    return _cred_read().get(_KEY_MAP.get(account, account)) or None


def _keychain_set(value: str, account: str = "refresh_token") -> None:
    blob = _cred_read()
    blob[_KEY_MAP.get(account, account)] = value
    CRED_FILE.parent.mkdir(parents=True, exist_ok=True)
    CRED_FILE.write_text(json.dumps(blob, ensure_ascii=False))
    CRED_FILE.chmod(0o600)


def _prompt(label: str, hidden: bool = False) -> str:
    """弹到最前面，否则对话框会藏在别的窗口后面，看起来像卡住了。"""
    hidden_clause = " with hidden answer" if hidden else ""
    script = (
        'tell application "System Events"\n'
        '  activate\n'
        f'  set r to display dialog "{label}" default answer "" '
        f'with title "深脑登录" with icon note{hidden_clause}\n'
        '  return text returned of r\n'
        'end tell'
    )
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise DeepBrainError("已取消登录" if "-128" in r.stderr else f"弹窗失败：{r.stderr.strip()[:120]}")
    return r.stdout.strip()


# --- 认证 ---
def login() -> str:
    """弹系统对话框让用户自己输入。密码只用于换 token，不落盘。"""
    email = _prompt("深脑账号（邮箱）")
    password = _prompt("深脑密码", hidden=True)
    status, raw = _request("POST", f"{SB}/auth/v1/token?grant_type=password",
                           headers={"apikey": ANON},
                           json_body={"email": email, "password": password})
    data = _json_or_raise(status, raw, "登录")
    if not data.get("refresh_token"):
        raise DeepBrainError("登录应答里没有 refresh_token")
    _keychain_set(data["refresh_token"])
    _keychain_set(email, "email")
    return data["access_token"]


def access_token() -> str:
    """用钥匙串里的 refresh token 换 access token，并轮换保存。"""
    refresh = _keychain_get()
    if not refresh:
        raise DeepBrainError("尚未登录。先运行：python deepbrain.py login")
    status, raw = _request("POST", f"{SB}/auth/v1/token?grant_type=refresh_token",
                           headers={"apikey": ANON}, json_body={"refresh_token": refresh})
    if status >= 400:
        raise DeepBrainError("登录已失效，请重新运行：python deepbrain.py login")
    data = json.loads(raw)
    if data.get("refresh_token"):
        _keychain_set(data["refresh_token"])
    return data["access_token"]


def org_id(token: str) -> str:
    """从 memberships 表取所属组织（深脑原生端要求显式指定 org）。"""
    cached = _keychain_get("org_id")
    if cached:
        return cached
    status, raw = _request("GET", f"{SB}/rest/v1/memberships?select=org_id&limit=1",
                           headers={"apikey": ANON, "Authorization": f"Bearer {token}"})
    rows = _json_or_raise(status, raw, "查询组织")
    if not rows:
        raise DeepBrainError("这个账号没有任何组织，先在深脑网页里初始化")
    oid = rows[0]["org_id"]
    _keychain_set(oid, "org_id")
    return oid


@dataclass
class Session:
    token: str
    org: str

    @property
    def headers(self) -> dict:
        return {"Authorization": f"Bearer {self.token}", "x-deepbrain-org-id": self.org}


def connect() -> Session:
    token = access_token()
    return Session(token=token, org=org_id(token))


# --- 上传 ---
def upload_recording(sess: Session, path: Path, title: str, duration_sec: float,
                     mime: str = "audio/ogg", on_step=None) -> dict:
    """把一个已录好的音频文件当作一次录音会话推给深脑。

    1 小时 opus 约 7.2MB，在单片 8MB 上限内，通常只需要一个分片。
    """
    audio = path.read_bytes()
    if not audio:
        raise DeepBrainError(f"{path.name} 是空文件")
    step = on_step or (lambda _m: None)

    step("建会话")
    status, raw = _request("POST", f"{API}/api/recordings", headers=sess.headers, json_body={
        "clientRequestId": f"mac-ble-{path.stem}",   # 幂等键：同一文件重传不会建两个会话
        "title": title,
        "captureClient": "macos",
        "capabilities": ["mic"],
    })
    session = _json_or_raise(status, raw, "建会话")["session"]
    session_id = session["id"]

    # clientRequestId 是幂等键：同一文件重推会拿回同一个会话。
    # 若它早已 stop/finalize，就不能再塞分片（服务端 409 INVALID_STATE）——
    # 这不是错误，是「已经做完了」。直接返回，别把重试变成失败。
    if session.get("status") not in ("recording", "uploading"):
        step(f"会话已是 {session.get('status')}，无需重传")
        return {"sessionId": session_id, "chunks": session.get("expected_chunk_count") or 0,
                "bytes": len(audio), "alreadyDone": True,
                "url": f"{API}/recordings/{session_id}"}

    total_ms = max(1, int(duration_sec * 1000))
    parts = [audio[i:i + MAX_CHUNK_BYTES] for i in range(0, len(audio), MAX_CHUNK_BYTES)]
    for seq, part in enumerate(parts):
        step(f"分片 {seq + 1}/{len(parts)}")
        started = total_ms * seq // len(parts)
        ended = total_ms * (seq + 1) // len(parts)
        status, raw = _request("POST", f"{API}/api/recordings/{session_id}/chunks/ticket",
                               headers=sess.headers, json_body={
                                   "sequence": seq,
                                   "idempotencyKey": f"{path.stem}-{seq}-{uuid.uuid5(uuid.NAMESPACE_URL, path.name).hex[:8]}",
                                   "mimeType": mime,
                                   "byteLength": len(part),
                                   "startedAtMs": started,
                                   "endedAtMs": max(ended, started + 1),
                                   "uploadMode": "background",
                               })
        if status == 409 and b"CHUNK_ALREADY_VERIFIED" in raw:
            step(f"分片 {seq + 1} 已在服务端，跳过")   # 重试时的正常情况，不是错误
            continue
        ticket = _json_or_raise(status, raw, "申请上传地址")

        up_status, up_raw = _request("PUT", ticket["uploadUrl"], data=part,
                                     headers={"Content-Type": mime}, timeout=600)
        if up_status >= 400:
            raise DeepBrainError(f"直传 COS 失败 HTTP {up_status}："
                                 f"{up_raw.decode('utf-8','replace')[:200]}")

        status, raw = _request("POST",
                               f"{API}/api/recordings/{session_id}/chunks/{seq}/complete",
                               headers=sess.headers, json_body={})
        _json_or_raise(status, raw, f"确认分片 {seq}")

    # 必须先 stop 冻结「分片总数 + 时长」，否则 finalize 会 409「录音尚未冻结分片数量」。
    # 这是深脑录音链路的核心不变量：清单一旦冻结，后到的分片就再也进不来。
    step("冻结清单")
    status, raw = _request("POST", f"{API}/api/recordings/{session_id}/stop",
                           headers=sess.headers, json_body={
                               "durationMs": total_ms,
                               "expectedChunkCount": len(parts),
                           })
    _json_or_raise(status, raw, "冻结清单")

    step("收尾")
    status, raw = _request("POST", f"{API}/api/recordings/{session_id}/finalize",
                           headers=sess.headers, json_body={})
    _json_or_raise(status, raw, "收尾")
    return {"sessionId": session_id, "chunks": len(parts), "bytes": len(audio),
            "alreadyDone": False, "url": f"{API}/recordings/{session_id}"}


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "whoami"
    if cmd == "login":
        login()
        print("登录成功，凭证已存入 macOS 钥匙串")
    elif cmd == "whoami":
        s = connect()
        print(f"账号 {_keychain_get('email')}\n组织 {s.org}\n深脑 {API}")
    else:
        print(__doc__)
