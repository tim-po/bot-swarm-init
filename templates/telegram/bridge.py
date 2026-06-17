#!/usr/bin/env python3
"""
Telegram <-> swarm mail bus bridge for PlanLink.

Long-polls Telegram getUpdates; forwards every incoming text message to the
coordinator pane via the worker's peer_send action. Persists the update
offset and a chat_id -> username map in state.json so we can send replies
back without re-asking who someone is.

No third-party deps. stdlib only.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENV_FILE = HERE / ".env"
STATE_FILE = HERE / "state.json"
LOG_FILE = HERE / "bridge.log"


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    if not ENV_FILE.exists():
        sys.exit(f"missing {ENV_FILE}")
    for raw in ENV_FILE.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    for k in ("TELEGRAM_BOT_TOKEN", "COORDINATOR_SID", "SWARM_SLUG", "WORKER_SOCK"):
        if k not in env:
            sys.exit(f"missing {k} in {ENV_FILE}")
    return env


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"offset": 0, "chats": {}}


def save_state(state: dict) -> None:
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    tmp.replace(STATE_FILE)


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    with LOG_FILE.open("a") as fh:
        fh.write(line)


def tg_call(token: str, method: str, params: dict, timeout: int = 60) -> dict:
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def worker_call(sock_path: str, route: str, payload: dict) -> dict:
    body = json.dumps(payload).encode()
    request = (
        f"POST {route} HTTP/1.1\r\n"
        "Host: w\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode() + body

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(sock_path)
    sock.sendall(request)
    chunks: list[bytes] = []
    while True:
        data = sock.recv(8192)
        if not data:
            break
        chunks.append(data)
    sock.close()
    raw = b"".join(chunks)
    _, _, body_bytes = raw.partition(b"\r\n\r\n")
    try:
        return json.loads(body_bytes)
    except json.JSONDecodeError:
        return {"raw": body_bytes.decode("utf-8", errors="replace")}


def forward_to_coordinator(env: dict, message: dict) -> None:
    chat = message.get("chat", {})
    sender = message.get("from", {})
    text = message.get("text") or message.get("caption") or "(non-text message)"
    sender_handle = (
        f"@{sender.get('username')}"
        if sender.get("username")
        else sender.get("first_name") or "unknown"
    )
    chat_id = chat.get("id")

    forwarded = (
        f"[telegram <- {sender_handle} (chat_id={chat_id})]\n{text}\n\n"
        f"Reply with: bash data/planlink/telegram/send.sh {chat_id} \"your text\""
    )

    result = worker_call(
        env["WORKER_SOCK"],
        "/actions/peer_send",
        {
            "slug": env["SWARM_SLUG"],
            "from_sid": "telegram-bridge",
            "to": env["COORDINATOR_SID"],
            "text": forwarded,
        },
    )
    log(f"forwarded msg from {sender_handle} chat_id={chat_id}; worker said: {result}")


def main() -> None:
    env = load_env()
    state = load_state()
    token = env["TELEGRAM_BOT_TOKEN"]
    log(f"bridge starting; offset={state['offset']}; known chats={len(state['chats'])}")

    while True:
        try:
            params = {"timeout": 50, "offset": state["offset"]}
            resp = tg_call(token, "getUpdates", params, timeout=60)
        except Exception as exc:
            log(f"getUpdates error: {exc!r}; sleeping 5s")
            time.sleep(5)
            continue

        if not resp.get("ok"):
            log(f"getUpdates not ok: {resp}; sleeping 5s")
            time.sleep(5)
            continue

        for update in resp.get("result", []):
            update_id = update["update_id"]
            state["offset"] = update_id + 1

            msg = update.get("message") or update.get("edited_message")
            if not msg:
                continue
            chat = msg.get("chat", {})
            sender = msg.get("from", {})
            chat_id = str(chat.get("id"))
            state["chats"][chat_id] = {
                "username": sender.get("username"),
                "first_name": sender.get("first_name"),
                "last_name": sender.get("last_name"),
                "type": chat.get("type"),
                "last_seen": int(time.time()),
            }

            text = msg.get("text", "")
            if text.strip() == "/start":
                try:
                    tg_call(
                        token,
                        "sendMessage",
                        {
                            "chat_id": chat_id,
                            "text": (
                                "Привет. Это ПЛАН+ swarm. Я передаю сообщения "
                                "координатору проекта — пишите как обычный чат, "
                                "он ответит здесь же."
                            ),
                        },
                    )
                except Exception as exc:
                    log(f"sendMessage on /start failed: {exc!r}")

            try:
                forward_to_coordinator(env, msg)
            except Exception as exc:
                log(f"forward error: {exc!r}")

            save_state(state)

        # offset moved even on empty result via the loop above; save anyway
        save_state(state)


if __name__ == "__main__":
    main()
