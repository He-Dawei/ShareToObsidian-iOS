from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
from html import escape as html_escape, unescape as html_unescape
from ipaddress import ip_address
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="bridge.config.json")
    args = parser.parse_args()

    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    ensure_vault_layout(config)
    write_lock = threading.Lock()
    start_cloud_relay_worker(config, write_lock)

    server = ThreadingHTTPServer(
        (config.get("host", "0.0.0.0"), int(config.get("port", 8765))),
        handler_factory(config, write_lock),
    )
    print(f"Obsidian bridge listening on http://{config.get('host', '0.0.0.0')}:{config.get('port', 8765)}")
    server.serve_forever()
    return 0


def handler_factory(config: dict, write_lock: threading.Lock | None = None):
    write_lock = write_lock or threading.Lock()
    enrichment_executor = ThreadPoolExecutor(
        max_workers=max(1, int(config.get("background_enrichment_workers", 1))),
        thread_name_prefix="capture-enrichment",
    )

    class ObsidianBridgeHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path == "/health":
                root = notes_root(config)
                ai = config.get("ai") or {}
                self.write_json(
                    {
                        "ok": True,
                        "queueWritable": root.exists() and root.is_dir(),
                        "notesRoot": str(root),
                        "aiEnabled": bool(ai.get("enabled", False)),
                        "aiConfigured": ai_is_configured(config),
                        "aiProvider": str(ai.get("provider", "openai")).lower(),
                    }
                )
                return
            if path == "/pairing":
                if not is_local_client(self.client_address[0]):
                    self.write_error_json(403, "PAIRING_FORBIDDEN", "Pairing is only available from the local computer.")
                    return
                self.write_json(pairing_payload(config))
                return
            if path in {"/pair", "/pairing.html"}:
                if not is_lan_client(self.client_address[0]):
                    self.write_error_json(403, "PAIRING_FORBIDDEN", "Pairing is only available from the local network.")
                    return
                self.write_html(pairing_html(config))
                return
            self.write_error_json(404, "NOT_FOUND", f"Unknown endpoint: {path}")

        def do_POST(self) -> None:
            parsed_path = urlparse(self.path)
            path = parsed_path.path
            query = parse_qs(parsed_path.query)
            fast = query.get("fast", ["0"])[0] == "1"
            if path not in {"/captures", "/drafts", "/metadata", "/captures/delete", "/captures/read"}:
                self.write_error_json(404, "NOT_FOUND", f"Unknown endpoint: {path}")
                return
            if not authorized(self.headers.get("Authorization"), config.get("token", "")):
                self.write_error_json(401, "UNAUTHORIZED", "Missing or invalid Bridge token.")
                return

            length = int(self.headers.get("Content-Length", "0"))
            payload = self.rfile.read(length)
            try:
                item = json.loads(payload.decode("utf-8"))
                if path == "/captures/delete":
                    with write_lock:
                        result = delete_capture_note(config, item)
                    self.write_json(result)
                    return
                if path == "/captures/read":
                    self.write_json({"ok": True, "item": read_capture_item(config, item)})
                    return
                item = enrich_capture(config, item, fetch_remote_metadata=not fast)
                if path == "/metadata":
                    self.write_json(item)
                    return
                if path == "/drafts":
                    self.write_json(generate_markdown_draft(config, item))
                    return
                synced_at = dt.datetime.now(dt.timezone.utc).isoformat()
                item["status"] = "synced"
                item["syncError"] = None
                item["lastSyncedAt"] = synced_at
                item["updatedAt"] = synced_at
                with write_lock:
                    note_path = write_capture_note(config, item)
                    rebuild_knowledge_synthesis(config)
                relative_path = note_path.relative_to(notes_root(config)).as_posix()
                self.write_json(
                    {
                        "ok": True,
                        "path": str(note_path),
                        "relativePath": relative_path,
                        "item": item,
                    }
                )
                if config.get("background_enrichment_enabled", True):
                    pending_item = dict(item)
                    pending_item["remoteNotePath"] = relative_path
                    enrichment_executor.submit(
                        enrich_capture_in_background,
                        config,
                        pending_item,
                        write_lock,
                    )
            except Exception as exc:
                self.write_error_json(500, "BRIDGE_ERROR", str(exc))

        def log_message(self, format: str, *args) -> None:
            print(f"{self.address_string()} - {format % args}")

        def write_json(self, value: dict) -> None:
            data = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def write_html(self, value: str) -> None:
            data = value.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def write_error_json(self, status: int, code: str, message: str) -> None:
            data = json.dumps(
                {
                    "ok": False,
                    "error": {
                        "code": code,
                        "message": message,
                    },
                },
                ensure_ascii=False,
            ).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return ObsidianBridgeHandler


def authorized(header: str | None, token: str) -> bool:
    if not token:
        return True
    return header == f"Bearer {token}"


def is_local_client(address: str) -> bool:
    return address in {"127.0.0.1", "::1", "localhost"}


def is_lan_client(address: str) -> bool:
    try:
        parsed = ip_address(address)
    except ValueError:
        return False
    return parsed.is_loopback or parsed.is_private or parsed.is_link_local


def pairing_payload(config: dict) -> dict:
    host = str(config.get("public_host") or local_ipv4() or "127.0.0.1")
    port = int(config.get("port", 8765))
    return {
        "bridgeURL": f"http://{host}:{port}",
        "token": config.get("token", ""),
        "notesRoot": str(notes_root(config)),
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
    }


def pairing_url(config: dict) -> str:
    payload = pairing_payload(config)
    return (
        "sharetoobsidian://pair"
        f"?bridgeURL={quote(str(payload['bridgeURL']), safe='')}"
        f"&token={quote(str(payload.get('token', '')), safe='')}"
    )


def pairing_html(config: dict) -> str:
    payload = pairing_payload(config)
    bridge_url = html_escape(str(payload["bridgeURL"]))
    deep_link = html_escape(pairing_url(config))
    fallback_json = html_escape(json.dumps(payload, ensure_ascii=False, indent=2))
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ShareToObsidian 配对</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; line-height: 1.45; }}
    a.button {{ display: inline-block; padding: 12px 16px; background: #0a7cff; color: white; border-radius: 8px; text-decoration: none; font-weight: 600; }}
    code, pre {{ background: #f3f4f6; border-radius: 6px; }}
    pre {{ padding: 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }}
    .warning {{ color: #9a3412; font-weight: 600; }}
  </style>
</head>
<body>
  <h1>ShareToObsidian 配对</h1>
  <p>Bridge URL: <code>{bridge_url}</code></p>
  <p><a class="button" href="{deep_link}">打开 App 并导入配对</a></p>
  <p class="warning">此页面包含 Bridge Token。只在你自己的局域网和 iPhone 上打开。</p>
  <h2>备用 JSON</h2>
  <p>如果按钮无法打开 App，把下面 JSON 复制到 App 的“同步设置 -> 快速配对”。</p>
  <pre>{fallback_json}</pre>
</body>
</html>
"""


def local_ipv4() -> str:
    import socket

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return ""
    finally:
        sock.close()


def ensure_vault_layout(config: dict) -> None:
    root = notes_root(config)
    (root / config.get("inbox_subdir", "00_Inbox")).mkdir(parents=True, exist_ok=True)
    (root / "10_Notes").mkdir(parents=True, exist_ok=True)
    (root / "90_Knowledge").mkdir(parents=True, exist_ok=True)

    ensure_agents_rules(root)
    ensure_claude_rules(root)


def ensure_agents_rules(root: Path) -> None:
    agents = root / "AGENTS.md"
    default_text = (
        "# 移动收藏学习规则\n\n"
        "- 优先读取 `90_Knowledge/AI学习上下文.md`，它是 Codex/Claude 的入口摘要。\n"
        "- 再读取 `10_Notes/` 的结构化笔记。\n"
        "- `00_Inbox/` 是未进一步整理的原始入库内容。\n"
        "- `90_Knowledge/收藏知识框架.md` 是长期知识框架索引。\n"
        "- Codex/Claude 后续分析时应基于这些文件提炼主题、行动项和复习问题。\n"
    )
    if not agents.exists():
        agents.write_text(default_text, encoding="utf-8")
        return

    text = agents.read_text(encoding="utf-8", errors="replace")
    ai_context_line = "- 优先读取 `90_Knowledge/AI学习上下文.md`，它是 Codex/Claude 的入口摘要。"
    if ai_context_line not in text:
        agents.write_text(text.rstrip() + "\n" + ai_context_line + "\n", encoding="utf-8")


def ensure_claude_rules(root: Path) -> None:
    claude = root / "CLAUDE.md"
    default_text = (
        "# 移动收藏学习入口\n\n"
        "在此目录工作时，按以下顺序读取和整理：\n\n"
        "1. `90_Knowledge/AI学习上下文.md`：最近收藏、主题信号和学习入口。\n"
        "2. `90_Knowledge/收藏知识框架.md`：长期知识框架。\n"
        "3. `10_Notes/`：结构化收藏正文。\n"
        "4. `00_Inbox/`：仅在需要核对原始字段时读取。\n\n"
        "基于收藏继续提炼核心观点、可验证事实、个人判断、行动项和复习问题。"
        "不要编造原视频内容；信息不足时标记待验证。\n"
    )
    if not claude.exists():
        claude.write_text(default_text, encoding="utf-8")
        return

    text = claude.read_text(encoding="utf-8", errors="replace")
    ai_context_line = "1. `90_Knowledge/AI学习上下文.md`：最近收藏、主题信号和学习入口。"
    if ai_context_line not in text:
        claude.write_text(text.rstrip() + "\n\n" + ai_context_line + "\n", encoding="utf-8")


def write_capture_note(config: dict, item: dict) -> Path:
    root = notes_root(config) / "10_Notes"
    root.mkdir(parents=True, exist_ok=True)

    title = str(item.get("title") or "移动收藏")
    markdown = str(item.get("draftMarkdown") or fallback_markdown(item))
    if should_replace_draft(markdown, item):
        markdown = fallback_markdown(item)
    created = parse_date(item.get("createdAt")) or dt.datetime.now()
    remote_note_path = str(item.get("remoteNotePath") or "")
    if not remote_note_path:
        existing_note_path = find_note_path_by_capture_id(config, str(item.get("id") or ""))
        if existing_note_path is not None:
            remote_note_path = existing_note_path.relative_to(notes_root(config)).as_posix()
    if remote_note_path:
        root_for_indexes = notes_root(config).resolve()
        note_path = resolve_note_path(root_for_indexes, remote_note_path)
        remove_note_from_indexes(root_for_indexes, note_path)
        note_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        filename = f"{created:%Y-%m-%d}-{slugify(title)}.md"
        note_path = unique_path(root / filename)
    item["remoteNotePath"] = note_path.relative_to(notes_root(config)).as_posix()
    note_path.write_text(markdown.strip() + "\n", encoding="utf-8")

    raw_path = notes_root(config) / config.get("inbox_subdir", "00_Inbox") / f"{note_path.stem}.json"
    raw_path.write_text(json.dumps(item, ensure_ascii=False, indent=2), encoding="utf-8")
    return note_path


def find_note_path_by_capture_id(config: dict, capture_id: str) -> Path | None:
    capture_id = capture_id.strip()
    if not capture_id:
        return None
    root = notes_root(config).resolve()
    inbox = root / config.get("inbox_subdir", "00_Inbox")
    if not inbox.exists():
        return None
    for raw_path in inbox.glob("*.json"):
        try:
            stored = json.loads(raw_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if str(stored.get("id") or "") != capture_id:
            continue
        requested = str(stored.get("remoteNotePath") or "")
        if requested:
            candidate = resolve_note_path(root, requested)
        else:
            candidate = root / "10_Notes" / f"{raw_path.stem}.md"
        if candidate.exists():
            return candidate
    return None


def read_capture_item(config: dict, payload: dict) -> dict:
    root = notes_root(config).resolve()
    requested = str(payload.get("path") or payload.get("remoteNotePath") or "")
    if not requested:
        raise ValueError("Missing note path")

    note_path = resolve_note_path(root, requested)
    raw_path = root / config.get("inbox_subdir", "00_Inbox") / f"{note_path.stem}.json"
    if not note_path.exists() or not raw_path.exists():
        raise FileNotFoundError(f"Capture not found: {requested}")
    item = json.loads(raw_path.read_text(encoding="utf-8"))
    item["remoteNotePath"] = note_path.relative_to(root).as_posix()
    return item


def enrich_capture_in_background(config: dict, item: dict, write_lock: threading.Lock) -> None:
    try:
        metadata = item.get("metadata")
        if not isinstance(metadata, dict) or not metadata:
            metadata = fetch_metadata(config, str(item.get("url") or ""))
        candidate = enrich_capture(
            config,
            item,
            fetch_remote_metadata=False,
            metadata_override=metadata,
        )
        generated = draft_for_automatic_processing(config, candidate)
        persisted = persist_background_enrichment(
            config,
            item,
            metadata,
            generated,
            write_lock,
        )
        if persisted is None or metadata.get("transcript") or metadata.get("content_text"):
            return

        transcript, transcription_error = transcribe_capture_audio(
            config,
            str(item.get("url") or ""),
            str(item.get("platform") or detect_platform(str(item.get("url") or ""))),
        )
        if not transcript:
            if transcription_error:
                print(f"Background transcription failed for {item.get('url')}: {transcription_error}")
            return

        transcript_metadata = dict(metadata)
        transcript_metadata["transcript"] = transcript
        transcript_metadata["transcription_engine"] = "VibeASR.cpp"
        transcript_candidate = enrich_capture(
            config,
            persisted,
            fetch_remote_metadata=False,
            metadata_override=transcript_metadata,
        )
        transcript_draft = draft_for_automatic_processing(config, transcript_candidate)
        persist_background_enrichment(
            config,
            persisted,
            transcript_metadata,
            transcript_draft,
            write_lock,
            completion_field="backgroundTranscribedAt",
        )
    except Exception as exc:
        print(f"Background enrichment failed for {item.get('url')}: {exc}")


def persist_background_enrichment(
    config: dict,
    item: dict,
    metadata: dict,
    generated: dict,
    write_lock: threading.Lock,
    completion_field: str = "backgroundEnrichedAt",
) -> dict | None:
    with write_lock:
        try:
            latest = read_capture_item(config, item)
        except FileNotFoundError:
            return None

        merged = enrich_capture(
            config,
            latest,
            fetch_remote_metadata=False,
            metadata_override=metadata,
        )
        generated_tags = [str(tag) for tag in generated.get("tags") or [] if str(tag).strip()]
        merged["tags"] = list(dict.fromkeys([*(merged.get("tags") or []), *generated_tags]))
        merged["alternativeDrafts"] = generated.get("alternatives") or merged.get("alternativeDrafts") or []
        if merged.get("isUserEdited") is not True:
            merged["summary"] = generated.get("summary") or merged.get("summary")
            merged["draftMarkdown"] = generated.get("markdown") or merged.get("draftMarkdown")
        completed_at = dt.datetime.now(dt.timezone.utc).isoformat()
        merged["status"] = "synced"
        merged["syncError"] = None
        merged["lastSyncedAt"] = merged.get("lastSyncedAt") or completed_at
        merged["updatedAt"] = completed_at
        merged["backgroundEnrichedAt"] = completed_at
        merged[completion_field] = completed_at
        write_capture_note(config, merged)
        rebuild_knowledge_synthesis(config)
        return merged


def start_cloud_relay_worker(config: dict, write_lock: threading.Lock) -> threading.Thread | None:
    root = cloud_relay_root(config)
    if root is None:
        return None
    for subdir in ("Queue", "Processed", "Failed"):
        (root / subdir).mkdir(parents=True, exist_ok=True)
    worker = threading.Thread(
        target=cloud_relay_loop,
        args=(config, write_lock),
        name="icloud-relay",
        daemon=True,
    )
    worker.start()
    print(f"iCloud relay watching: {root / 'Queue'}")
    return worker


def cloud_relay_loop(config: dict, write_lock: threading.Lock) -> None:
    poll_seconds = max(2, int(config.get("cloud_relay_poll_seconds", 5)))
    retry_after: dict[Path, float] = {}
    while True:
        root = cloud_relay_root(config)
        if root is not None:
            queue_dir = root / "Queue"
            queue_dir.mkdir(parents=True, exist_ok=True)
            for path in sorted(queue_dir.glob("*.json")):
                if retry_after.get(path, 0) > time.monotonic():
                    continue
                try:
                    process_cloud_relay_file(config, path, write_lock)
                    retry_after.pop(path, None)
                except Exception as exc:
                    retry_after[path] = time.monotonic() + max(15, poll_seconds * 3)
                    print(f"iCloud relay retry pending for {path.name}: {exc}")
        time.sleep(poll_seconds)


def process_cloud_relay_file(config: dict, queue_path: Path, write_lock: threading.Lock) -> dict:
    root = cloud_relay_root(config)
    if root is None:
        raise ValueError("cloud_relay_dir is not configured")
    queue_root = (root / "Queue").resolve()
    resolved_queue_path = queue_path.resolve()
    if queue_root not in resolved_queue_path.parents:
        raise ValueError("Refusing to process a relay file outside Queue")

    before = queue_path.stat()
    item = json.loads(queue_path.read_text(encoding="utf-8"))
    item_id = str(item.get("id") or "").strip()
    if not item_id:
        raise ValueError(f"Relay item has no id: {queue_path.name}")
    now = dt.datetime.now(dt.timezone.utc).isoformat()

    if str(item.get("status") or "") == "deleted":
        with write_lock:
            remote_path = str(item.get("remoteNotePath") or "")
            if remote_path:
                delete_capture_note(config, {"path": remote_path})
        item["status"] = "deleted"
        item["updatedAt"] = now
        item["lastSyncedAt"] = now
    else:
        enriched = enrich_capture(config, item, fetch_remote_metadata=True)
        generated = draft_for_automatic_processing(config, enriched)
        generated_tags = [str(tag) for tag in generated.get("tags") or [] if str(tag).strip()]
        enriched["tags"] = list(dict.fromkeys([*(enriched.get("tags") or []), *generated_tags]))
        enriched["alternativeDrafts"] = generated.get("alternatives") or enriched.get("alternativeDrafts") or []
        if enriched.get("isUserEdited") is not True:
            enriched["summary"] = generated.get("summary") or enriched.get("summary")
            enriched["draftMarkdown"] = generated.get("markdown") or enriched.get("draftMarkdown")
        enriched["status"] = "synced"
        enriched["syncError"] = None
        enriched["lastSyncedAt"] = now
        enriched["updatedAt"] = now
        enriched["cloudRelayedAt"] = now
        with write_lock:
            write_capture_note(config, enriched)
            rebuild_knowledge_synthesis(config)
        item = enriched

    processed_dir = root / "Processed"
    processed_dir.mkdir(parents=True, exist_ok=True)
    processed_path = processed_dir / f"{item_id}.json"
    temporary_path = processed_path.with_suffix(".json.tmp")
    temporary_path.write_text(json.dumps(item, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary_path.replace(processed_path)

    try:
        after = queue_path.stat()
        if after.st_mtime_ns == before.st_mtime_ns and after.st_size == before.st_size:
            queue_path.unlink()
    except FileNotFoundError:
        pass
    return item


def cloud_relay_root(config: dict) -> Path | None:
    value = str(config.get("cloud_relay_dir") or "").strip()
    return Path(value).expanduser() if value else None


def delete_capture_note(config: dict, payload: dict) -> dict:
    root = notes_root(config).resolve()
    requested = str(payload.get("path") or payload.get("remoteNotePath") or "")
    if not requested:
        raise ValueError("Missing note path")

    note_path = resolve_note_path(root, requested)
    trash = root / "80_Trash"
    trash.mkdir(parents=True, exist_ok=True)

    moved: list[str] = []
    if note_path.exists():
        trashed_note = unique_path(trash / note_path.name)
        note_path.replace(trashed_note)
        moved.append(str(trashed_note))

    raw_path = root / "00_Inbox" / f"{note_path.stem}.json"
    if raw_path.exists():
        trashed_raw = unique_path(trash / raw_path.name)
        raw_path.replace(trashed_raw)
        moved.append(str(trashed_raw))

    remove_note_from_indexes(root, note_path)
    rebuild_knowledge_synthesis(config)
    return {"ok": True, "deleted": bool(moved), "moved": moved}


def resolve_note_path(root: Path, requested: str) -> Path:
    candidate = Path(requested)
    if not candidate.is_absolute():
        candidate = root / requested
    candidate = candidate.resolve()
    if candidate != root and root not in candidate.parents:
        raise ValueError("Refusing to delete outside notes root")
    return candidate


def remove_note_from_indexes(root: Path, note_path: Path) -> None:
    rel = note_path.relative_to(root).as_posix()
    wiki = rel[:-3] if rel.endswith(".md") else rel
    index_files = [
        root / "90_Knowledge" / "收藏知识框架.md",
        root / "90_Knowledge" / "平台索引.md",
        root / "90_Knowledge" / "标签索引.md",
    ]
    for path in index_files:
        if not path.exists():
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        kept = [line for line in lines if wiki not in line and rel not in line]
        path.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")


def enrich_capture(
    config: dict,
    item: dict,
    fetch_remote_metadata: bool = True,
    metadata_override: dict | None = None,
) -> dict:
    item = dict(item)
    if metadata_override is not None:
        metadata = metadata_override
    else:
        metadata = fetch_metadata(config, str(item.get("url") or "")) if fetch_remote_metadata else {}
    if metadata:
        item["metadata"] = metadata
        if not item.get("title") or str(item.get("title", "")).endswith("收藏内容"):
            item["title"] = metadata.get("title") or item.get("title")
        if metadata.get("description") and should_replace_summary(str(item.get("summary") or "")):
            item["summary"] = first_sentence(metadata["description"])
        if should_replace_draft(str(item.get("draftMarkdown") or ""), item):
            item["draftMarkdown"] = fallback_markdown(item)

    tags = list(dict.fromkeys(str(tag) for tag in item.get("tags") or [] if str(tag).strip()))
    platform = str(item.get("platform") or detect_platform(str(item.get("url") or "")))
    for tag in ["移动收藏", platform]:
        if tag and tag != "unknown" and tag not in tags:
            tags.append(tag)
    if platform in {"douyin", "bilibili", "xiaohongshu"} and "视频" not in tags:
        tags.append("视频")
    item["platform"] = platform
    item["tags"] = tags
    return item


def fetch_metadata(config: dict, url: str) -> dict:
    if not url:
        return {}
    platform = detect_platform(url)
    if platform in {"web", "wechat"}:
        web_metadata, web_error = fetch_web_content(config, url)
        if web_metadata:
            return web_metadata
    else:
        web_error = ""

    video_metadata, video_error = fetch_ytdlp_metadata(config, url)
    if video_metadata:
        return video_metadata

    if platform not in {"web", "wechat"}:
        web_metadata, web_error = fetch_web_content(config, url)
        if web_metadata:
            return web_metadata

    error = (web_error or video_error) if platform in {"web", "wechat"} else (video_error or web_error)
    return {"metadata_error": error} if error else {}


def fetch_ytdlp_metadata(config: dict, url: str) -> tuple[dict, str]:
    ytdlp = find_ytdlp(config)
    if not ytdlp:
        return {}, "yt-dlp 未安装或路径无效"
    cmd = [
        ytdlp,
        "--dump-single-json",
        "--no-playlist",
        "--skip-download",
        "--no-warnings",
        "--socket-timeout",
        str(config.get("metadata_socket_timeout", 12)),
    ]
    cookies_file = find_cookies_file(config)
    if cookies_file:
        cmd.extend(["--cookies", cookies_file])
    cmd.append(url)
    try:
        result = subprocess.run(
            cmd,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=int(config.get("metadata_timeout_seconds", 25)),
            env=network_environment(config, url),
        )
    except Exception as exc:
        return {}, str(exc)
    if result.returncode != 0:
        return {}, result.stderr.strip()[-500:]
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return {}, str(exc)
    return compact_metadata(raw, config), ""


def transcribe_capture_audio(config: dict, url: str, platform: str) -> tuple[str, str]:
    transcription = config.get("transcription") or {}
    if not transcription.get("enabled", False):
        return "", ""
    enabled_platforms = {
        str(value).lower()
        for value in transcription.get("platforms") or ["douyin", "bilibili", "xiaohongshu"]
    }
    if platform.lower() not in enabled_platforms:
        return "", ""

    ytdlp = find_ytdlp(config)
    command_template = transcription.get("command") or []
    if not ytdlp:
        return "", "yt-dlp 未安装或路径无效"
    if not command_template:
        return "", "transcription.command 未配置"

    with tempfile.TemporaryDirectory(prefix="sharetoobsidian-asr-") as tmp:
        work_dir = Path(tmp)
        audio_template = work_dir / "audio.%(ext)s"
        download_command = [
            ytdlp,
            "--no-playlist",
            "--no-warnings",
            "--socket-timeout",
            str(config.get("metadata_socket_timeout", 12)),
        ]
        cookies_file = find_cookies_file(config)
        if cookies_file:
            download_command.extend(["--cookies", cookies_file])
        ffmpeg_path = str(transcription.get("ffmpeg_path") or "").strip()
        if ffmpeg_path:
            download_command.extend(["--ffmpeg-location", ffmpeg_path])
        download_command.extend(
            [
                "-x",
                "--audio-format",
                "wav",
                "-o",
                str(audio_template),
                "--",
                url,
            ]
        )
        try:
            downloaded = subprocess.run(
                download_command,
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=int(transcription.get("download_timeout_seconds", 180)),
                env=network_environment(config, url),
            )
        except Exception as exc:
            return "", str(exc)
        if downloaded.returncode != 0:
            return "", downloaded.stderr.strip()[-500:]

        audio_files = sorted(work_dir.glob("audio*.wav"))
        if not audio_files:
            return "", "yt-dlp 未生成 WAV 音频"
        output_path = work_dir / "transcript.txt"
        values = {
            "audio": str(audio_files[0]),
            "output": str(output_path),
        }
        command = [
            str(part).replace("{audio}", values["audio"]).replace("{output}", values["output"])
            for part in command_template
        ]
        try:
            transcribed = subprocess.run(
                command,
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=int(transcription.get("timeout_seconds", 1800)),
            )
        except Exception as exc:
            return "", str(exc)
        if transcribed.returncode != 0:
            return "", transcribed.stderr.strip()[-500:]
        if not output_path.exists():
            return "", "转写命令未生成输出文件"

        transcript = output_path.read_text(encoding="utf-8", errors="replace").strip()
        max_chars = int(transcription.get("max_chars", config.get("content_max_chars", 12000)))
        return transcript[:max_chars], ""


def fetch_web_content(config: dict, url: str) -> tuple[dict, str]:
    defuddle = find_defuddle(config)
    if not defuddle:
        return {}, "Defuddle 未安装或路径无效"
    cmd = [
        defuddle,
        "parse",
        url,
        "--markdown",
        "--json",
        "--user-agent",
        str(
            config.get(
                "web_user_agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
            )
        ),
    ]
    try:
        result = subprocess.run(
            cmd,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=int(config.get("content_timeout_seconds", 30)),
            env=network_environment(config, url),
        )
    except Exception as exc:
        return {}, str(exc)
    if result.returncode != 0:
        return {}, result.stderr.strip()[-500:]
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return {}, str(exc)

    content = str(raw.get("content") or "").strip()
    max_chars = int(config.get("content_max_chars", 12000))
    metadata = {
        "title": raw.get("title"),
        "description": raw.get("description"),
        "uploader": raw.get("author"),
        "thumbnail": raw.get("image"),
        "webpage_url": url,
        "extractor": "Defuddle",
        "content_text": content[:max_chars],
    }
    compact = {key: value for key, value in metadata.items() if value not in (None, "")}
    return compact, ""


def find_ytdlp(config: dict) -> str:
    configured = config.get("ytdlp_path")
    candidates = [
        configured,
        shutil.which("yt-dlp"),
        Path.home() / "tools" / "yt-dlp" / "yt-dlp.exe",
        r"C:\Users\44527\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\Scripts\yt-dlp.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return ""


def find_defuddle(config: dict) -> str:
    configured = config.get("defuddle_path")
    candidates = [
        configured,
        shutil.which("defuddle"),
        Path.home() / "AppData" / "Roaming" / "npm" / "defuddle.cmd",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return ""


def find_cookies_file(config: dict) -> str:
    configured = config.get("cookies_file")
    if configured and Path(configured).exists():
        return str(Path(configured))
    return ""


def network_environment(config: dict, url: str) -> dict[str, str]:
    environment = os.environ.copy()
    direct_platforms = {
        str(value).lower()
        for value in config.get("direct_network_platforms") or ["bilibili"]
    }
    if detect_platform(url) not in direct_platforms:
        return environment
    for name in (
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    ):
        environment.pop(name, None)
    return environment


def compact_metadata(raw: dict, config: dict | None = None) -> dict:
    keys = [
        "title",
        "description",
        "uploader",
        "channel",
        "duration",
        "view_count",
        "like_count",
        "thumbnail",
        "webpage_url",
        "extractor",
        "transcript",
        "content_text",
    ]
    metadata = {key: raw.get(key) for key in keys if raw.get(key) not in (None, "")}
    transcript = extract_subtitle_text(
        raw,
        timeout=int((config or {}).get("subtitle_timeout_seconds", 15)),
        max_chars=int((config or {}).get("content_max_chars", 12000)),
    )
    if transcript:
        metadata["transcript"] = transcript
    return metadata


def extract_subtitle_text(raw: dict, timeout: int = 15, max_chars: int = 12000) -> str:
    subtitle_groups = [
        raw.get("subtitles") or {},
        raw.get("automatic_captions") or {},
    ]
    for group in subtitle_groups:
        languages = sorted(group.keys(), key=subtitle_language_priority)
        for language in languages:
            entries = sorted(
                group.get(language) or [],
                key=lambda entry: subtitle_format_priority(str(entry.get("ext") or "")),
            )
            for entry in entries:
                text = subtitle_entry_text(entry, raw, timeout)
                if text:
                    return text[:max_chars]
    return ""


def subtitle_language_priority(language: str) -> tuple[int, str]:
    value = language.lower()
    if value in {"zh-cn", "zh-hans"}:
        return 0, value
    if value == "zh":
        return 1, value
    if "zh" in value:
        return 2, value
    if value in {"en", "en-us", "en-gb"}:
        return 10, value
    if "en" in value:
        return 11, value
    return 50, value


def subtitle_format_priority(extension: str) -> int:
    order = {"json": 0, "json3": 1, "srv3": 2, "vtt": 3, "srt": 4}
    return order.get(extension.lower(), 20)


def subtitle_entry_text(entry: dict, raw: dict, timeout: int) -> str:
    data = entry.get("data")
    if isinstance(data, str) and data.strip():
        return parse_subtitle_payload(data)

    url = str(entry.get("url") or "").strip()
    if not url:
        return ""
    if url.startswith("//"):
        url = "https:" + url
    headers = {}
    for key, value in (raw.get("http_headers") or {}).items():
        if key.lower() in {"user-agent", "referer", "accept-language"}:
            headers[str(key)] = str(value)
    try:
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read().decode("utf-8", errors="replace")
    except (OSError, urllib.error.URLError):
        return ""
    return parse_subtitle_payload(payload)


def parse_subtitle_payload(payload: str) -> str:
    value = payload.strip().lstrip("\ufeff")
    if not value:
        return ""
    if value.startswith("{"):
        try:
            data = json.loads(value)
        except json.JSONDecodeError:
            data = {}
        body = data.get("body") or []
        if isinstance(body, list) and body:
            lines = [
                timed_subtitle_line(item.get("from"), item.get("content"))
                for item in body
                if isinstance(item, dict)
            ]
            return join_subtitle_lines(lines)
        events = data.get("events") or []
        if isinstance(events, list):
            lines = []
            for event in events:
                if not isinstance(event, dict):
                    continue
                text = "".join(
                    str(segment.get("utf8") or "")
                    for segment in event.get("segs") or []
                    if isinstance(segment, dict)
                )
                lines.append(timed_subtitle_line(float(event.get("tStartMs") or 0) / 1000, text))
            return join_subtitle_lines(lines)
    return parse_text_subtitles(value)


def parse_text_subtitles(payload: str) -> str:
    lines = []
    timestamp = ""
    for raw_line in payload.splitlines():
        line = raw_line.strip()
        if not line or line == "WEBVTT" or line.isdigit():
            continue
        if "-->" in line:
            timestamp = normalize_subtitle_timestamp(line.split("-->", 1)[0].strip())
            continue
        if line.startswith(("NOTE", "STYLE", "REGION", "Kind:", "Language:")):
            continue
        text = html_unescape(re.sub(r"<[^>]+>", "", line)).strip()
        if text:
            lines.append(f"[{timestamp}] {text}" if timestamp else text)
    return join_subtitle_lines(lines)


def normalize_subtitle_timestamp(value: str) -> str:
    parts = value.replace(",", ".").split(":")
    try:
        seconds = float(parts[-1])
        if len(parts) >= 2:
            seconds += int(parts[-2]) * 60
        if len(parts) >= 3:
            seconds += int(parts[-3]) * 3600
    except (ValueError, IndexError):
        return value
    return format_subtitle_timestamp(seconds)


def timed_subtitle_line(seconds: object, content: object) -> str:
    text = str(content or "").strip()
    if not text:
        return ""
    try:
        timestamp = format_subtitle_timestamp(float(seconds or 0))
    except (TypeError, ValueError):
        timestamp = ""
    return f"[{timestamp}] {text}" if timestamp else text


def format_subtitle_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def join_subtitle_lines(lines: list[str]) -> str:
    result = []
    previous_text = ""
    for line in lines:
        value = str(line or "").strip()
        if not value:
            continue
        plain_text = re.sub(r"^\[[^\]]+\]\s*", "", value)
        if plain_text == previous_text:
            continue
        result.append(value)
        previous_text = plain_text
    return "\n".join(result)


def should_replace_draft(markdown: str, item: dict) -> bool:
    if item.get("isUserEdited") is True:
        return False
    if not markdown.strip():
        return True
    generated_markers = ["待提炼", "这条内容解决了什么问题", "可以马上行动的一步"]
    return any(marker in markdown for marker in generated_markers)


def should_replace_summary(summary: str) -> bool:
    summary = summary.strip()
    if not summary:
        return True
    placeholder_markers = ["待提炼", "等待补充", "先保留原始链接", "暂无自动简介"]
    return any(marker in summary for marker in placeholder_markers)


def generate_markdown_draft(config: dict, item: dict) -> dict:
    ai_draft = generate_ai_markdown_draft(config, item)
    if ai_draft:
        return ai_draft
    return {
        "summary": make_summary(item),
        "markdown": fallback_markdown(item),
        "alternatives": [
            markdown_variant(item, "行动清单"),
            markdown_variant(item, "知识卡片"),
            markdown_variant(item, "问题驱动"),
        ],
        "tags": item.get("tags") or [],
    }


def draft_for_automatic_processing(config: dict, item: dict) -> dict:
    if item.get("isUserEdited") is True:
        return {
            "summary": item.get("summary") or make_summary(item),
            "markdown": item.get("draftMarkdown") or fallback_markdown(item),
            "alternatives": item.get("alternativeDrafts") or [],
            "tags": item.get("tags") or [],
        }
    return generate_markdown_draft(config, item)


def generate_ai_markdown_draft(config: dict, item: dict) -> dict | None:
    ai = config.get("ai") or {}
    if not ai.get("enabled", False):
        return None

    provider = str(ai.get("provider", "openai")).lower()
    default_key_env = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
    api_key = os.environ.get(str(ai.get("api_key_env", default_key_env)))
    if not api_key:
        return None

    default_base_url = "https://api.anthropic.com" if provider == "anthropic" else "https://api.openai.com/v1"
    default_model = "claude-3-5-haiku-latest" if provider == "anthropic" else "gpt-4.1-mini"
    base_url = ai_value(ai, "base_url", default_base_url).rstrip("/")
    model = ai_value(ai, "model", default_model)
    timeout = int(ai.get("timeout_seconds", 45))
    prompt = ai_prompt(config, item)
    system_prompt = "你是帮助用户整理 Obsidian 收藏笔记的中文知识管理助手。只输出严格 JSON。"

    if provider == "anthropic":
        endpoint = f"{base_url}/v1/messages"
        headers = {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json; charset=utf-8",
        }
        body = {
            "model": model,
            "max_tokens": 5000,
            "system": system_prompt,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.4,
        }
    elif provider == "openai":
        endpoint = f"{base_url}/chat/completions"
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json; charset=utf-8",
        }
        body = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.4,
        }
    else:
        return None

    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return None

    if provider == "anthropic":
        content = "".join(
            str(block.get("text", ""))
            for block in payload.get("content", [])
            if isinstance(block, dict) and block.get("type") == "text"
        ).strip()
    else:
        content = (
            payload.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "")
            .strip()
        )

    return parse_ai_draft(content, item)


def ai_value(ai: dict, key: str, default: str) -> str:
    env_name = str(ai.get(f"{key}_env") or "").strip()
    if env_name:
        env_value = os.environ.get(env_name)
        if env_value:
            return env_value.strip()
    return str(ai.get(key, default)).strip()


def ai_is_configured(config: dict) -> bool:
    ai = config.get("ai") or {}
    if not ai.get("enabled", False):
        return False
    provider = str(ai.get("provider", "openai")).lower()
    default_key_env = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
    api_key = os.environ.get(str(ai.get("api_key_env", default_key_env)))
    return bool(api_key and ai_value(ai, "base_url", "") and ai_value(ai, "model", ""))


def parse_ai_draft(content: str, item: dict) -> dict | None:
    try:
        draft = json.loads(extract_json_object(content))
    except json.JSONDecodeError:
        return None

    if not isinstance(draft, dict):
        return None
    required = {"summary", "markdown", "alternatives", "tags"}
    if not required.issubset(draft.keys()):
        return None
    if not isinstance(draft.get("summary"), str) or not isinstance(draft.get("markdown"), str):
        return None
    if not isinstance(draft.get("alternatives"), list) or len(draft["alternatives"]) < 3:
        return None
    required_sections = ["## 核心内容", "## 视频介绍", "## 后续行动"]
    if any(section not in draft["markdown"] for section in required_sections):
        return None
    draft["alternatives"] = [str(value) for value in draft["alternatives"][:3]]
    draft["tags"] = [str(value) for value in draft.get("tags") or item.get("tags") or []]
    return draft


def ai_prompt(config: dict, item: dict) -> str:
    metadata = item.get("metadata") or {}
    tags = ", ".join(str(tag) for tag in item.get("tags") or [])
    existing_tags = ", ".join(existing_vault_tags(config))
    return (
        "请根据下面的分享内容，生成 Obsidian Markdown 草稿。\n"
        "要求：中文、结构化、适合后续 Codex/Claude 继续学习；不要编造具体视频事实；没有信息就写待补充。\n"
        "输出严格 JSON，字段为 summary, markdown, alternatives, tags。\n"
        "markdown 主稿必须包含“## 核心内容”“## 视频介绍”“## 后续行动”三个二级标题。\n"
        "alternatives 必须正好 3 个 Markdown 字符串，分别偏行动清单、知识卡片、问题驱动。\n\n"
        f"知识库已有标签（优先复用，确有必要才新增）：{existing_tags or '暂无'}\n"
        f"标题：{item.get('title') or ''}\n"
        f"平台：{item.get('platform') or ''}\n"
        f"链接：{item.get('url') or ''}\n"
        f"已有摘要：{item.get('summary') or ''}\n"
        f"标签：{tags}\n"
        f"作者/频道：{metadata.get('uploader') or metadata.get('channel') or ''}\n"
        f"简介：{metadata.get('description') or ''}\n"
        f"口播/转写：{metadata.get('transcript') or metadata.get('content_text') or ''}\n"
    )


def existing_vault_tags(config: dict, limit: int = 40) -> list[str]:
    if not config.get("obsidian_vault"):
        return []
    inbox = notes_root(config) / config.get("inbox_subdir", "00_Inbox")
    counts: Counter[str] = Counter()
    if not inbox.exists():
        return []
    for path in inbox.glob("*.json"):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for tag in item.get("tags") or []:
            value = str(tag).strip()
            if value:
                counts[value] += 1
    return [tag for tag, _ in counts.most_common(limit)]


def extract_json_object(value: str) -> str:
    value = value.strip()
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value)
        value = re.sub(r"\s*```$", "", value)
    start = value.find("{")
    end = value.rfind("}")
    if start == -1 or end == -1 or end < start:
        return value
    return value[start : end + 1]


def make_summary(item: dict) -> str:
    summary = str(item.get("summary") or "").strip()
    if summary:
        return summary
    metadata = item.get("metadata") or {}
    description = str(metadata.get("description") or "").strip()
    if description:
        return first_sentence(description)
    platform = str(item.get("platform") or "unknown")
    return f"待提炼：已捕获来自 {platform} 的分享链接，等待补充视频内容、口播转写和个人判断。"


def markdown_variant(item: dict, style: str) -> str:
    title = str(item.get("title") or "移动收藏")
    url = str(item.get("url") or "")
    platform = str(item.get("platform") or "unknown")
    tags = item.get("tags") or []
    tag_text = " ".join(f"#{tag}" for tag in tags)
    yaml_tags = ", ".join(f'"{tag}"' for tag in tags)
    summary = make_summary(item)
    if style == "行动清单":
        body = (
            "## 为什么收藏\n\n"
            f"{summary}\n\n"
            "## 可以执行的动作\n\n"
            "- [ ] 立刻能做的一步：\n"
            "- [ ] 需要查证的信息：\n"
            "- [ ] 可以复用到学习/求职/项目的做法：\n\n"
            "## 放弃条件\n\n"
            "- 如果后续验证价值不高，删除或归档。\n"
        )
    elif style == "知识卡片":
        body = (
            "## 一句话\n\n"
            f"{summary}\n\n"
            "## 概念\n\n"
            "- 核心概念：\n"
            "- 适用场景：\n"
            "- 反例/边界：\n\n"
            "## 关联\n\n"
            "- 和已有知识的连接：\n"
        )
    else:
        body = (
            "## 问题\n\n"
            "- 这条内容试图回答什么问题：\n"
            "- 我还不确定什么：\n"
            "- 下一次让 Codex/Claude 追问什么：\n\n"
            "## 初步答案\n\n"
            f"{summary}\n"
        )
    return (
        "---\n"
        f'title: "{title}"\n'
        f"source: {platform}\n"
        f'url: "{url}"\n'
        "status: draft\n"
        f'note_style: "{style}"\n'
        f"tags: [{yaml_tags}]\n"
        "---\n\n"
        f"# {title}\n\n"
        f"{body}\n"
        "## 自动标签\n\n"
        f"{tag_text}\n\n"
        "## 原始链接\n\n"
        f"{url}\n"
    )


def fallback_markdown(item: dict) -> str:
    title = str(item.get("title") or "移动收藏")
    url = str(item.get("url") or "")
    platform = str(item.get("platform") or "unknown")
    summary = str(item.get("summary") or "")
    tags = item.get("tags") or []
    metadata = item.get("metadata") or {}
    description = str(metadata.get("description") or "")
    transcript = str(metadata.get("transcript") or metadata.get("content_text") or "")
    uploader = str(metadata.get("uploader") or metadata.get("channel") or "")
    duration = metadata.get("duration")
    metadata_error = str(metadata.get("metadata_error") or "")
    tag_text = " ".join(f"#{tag}" for tag in tags)
    yaml_tags = ", ".join(f'"{tag}"' for tag in tags)
    meta_lines = []
    if uploader:
        meta_lines.append(f"- 作者/频道：{uploader}")
    if duration:
        meta_lines.append(f"- 时长：{duration} 秒")
    if metadata.get("view_count"):
        meta_lines.append(f"- 播放/阅读：{metadata['view_count']}")
    if metadata.get("like_count"):
        meta_lines.append(f"- 点赞：{metadata['like_count']}")
    if metadata.get("thumbnail"):
        meta_lines.append(f"- 封面：{metadata['thumbnail']}")
    if metadata.get("extractor"):
        meta_lines.append(f"- 提取器：{metadata['extractor']}")
    if metadata_error:
        meta_lines.append(f"- 元数据提取失败：{metadata_error}")
    metadata_text = "\n".join(meta_lines) if meta_lines else "- 暂无自动元数据"
    description_text = description.strip()[:1200] if description else "暂无自动简介，后续可补入口播转写或人工摘要。"
    transcript_text = transcript.strip()[:2500] if transcript else "暂无口播转写。后续可接入字幕/语音转写后自动补全。"
    summary_text = summary.strip()
    if should_replace_summary(summary_text) and description:
        summary_text = first_sentence(description)
    if not summary_text:
        summary_text = "待提炼：先保留原始链接和元数据，后续补充核心观点。"
    return (
        "---\n"
        f'title: "{title}"\n'
        f"source: {platform}\n"
        f'url: "{url}"\n'
        "status: draft\n"
        f"tags: [{yaml_tags}]\n"
        "---\n\n"
        f"# {title}\n\n"
        "## 核心内容\n\n"
        f"{summary_text}\n\n"
        "## 视频介绍\n\n"
        f"{description_text}\n\n"
        "## 视频内容/口播转写\n\n"
        f"{transcript_text}\n\n"
        "## 关键观点\n\n"
        "- 这条内容解决了什么问题：\n"
        "- 值得长期保存的观点：\n"
        "- 可迁移到学习/求职/项目的一点：\n\n"
        "## 我的判断\n\n"
        "- 是否值得长期保存：\n"
        "- 和我当前目标的关系：\n"
        "- 需要二次验证的信息：\n\n"
        "## 后续行动\n\n"
        "- [ ] 补充 3 句摘要\n"
        "- [ ] 标出可执行动作\n"
        "- [ ] 判断是否加入长期知识框架\n\n"
        "## 自动标签\n\n"
        f"{tag_text}\n\n"
        "## 原始链接\n\n"
        f"{url}\n\n"
        f"平台：{platform}\n\n"
        "## 元数据\n\n"
        f"{metadata_text}\n"
    )


def rebuild_knowledge_synthesis(config: dict) -> None:
    root = notes_root(config)
    notes = sorted((root / "10_Notes").glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    limit = int(config.get("knowledge_recent_limit", 80))
    notes = notes[:limit]
    records = [note_record(root, path) for path in notes]
    write_framework_index(config, root, records)
    write_platform_index(root, records)
    write_tag_index(root, records)
    write_ai_learning_context(root, records)
    write_topic_map(root, records)
    write_review_questions(root, records)
    write_action_pool(root, records)


def note_record(root: Path, note_path: Path) -> dict:
    text = note_path.read_text(encoding="utf-8", errors="replace")
    sidecar = load_capture_sidecar(root, note_path)
    title = note_path.stem
    heading = re.search(r"^#\s+(.+)$", text, re.MULTILINE)
    if heading:
        title = heading.group(1).strip()

    tags = set(str(tag).strip() for tag in sidecar.get("tags") or [] if str(tag).strip())
    tags.update(re.findall(r"#([\w\-\u4e00-\u9fff]+)", text))
    yaml_tags = re.search(r"^tags:\s*\[([^\]]*)\]\s*$", text, re.MULTILINE)
    if yaml_tags:
        tags.update(
            value.strip().strip("\"'")
            for value in yaml_tags.group(1).split(",")
            if value.strip().strip("\"'")
        )

    platform = str(sidecar.get("platform") or "").strip()
    platform_match = re.search(r"^source:\s*\"?([^\"\n]+)\"?$", text, re.MULTILINE)
    if not platform and platform_match:
        platform = platform_match.group(1).strip()
    if not platform:
        body_platform = re.search(r"^平台[:：]\s*([^\s]+)\s*$", text, re.MULTILINE)
        platform = body_platform.group(1).strip() if body_platform else ""
    if not platform:
        url = str(sidecar.get("url") or "")
        if not url:
            url_match = re.search(r"https?://[^\s\])>\"']+", text)
            url = url_match.group(0) if url_match else ""
        platform = detect_platform(url)

    rel = note_path.relative_to(root).as_posix()
    summary = extract_section(text, "核心内容") or extract_section(text, "一句话") or extract_section(text, "为什么收藏")
    created = parse_date(sidecar.get("createdAt"))
    date_text = (created or dt.datetime.fromtimestamp(note_path.stat().st_mtime)).date().isoformat()
    return {
        "title": title,
        "tags": sorted(tags),
        "platform": platform or "unknown",
        "rel": rel,
        "summary": first_sentence(summary or str(sidecar.get("summary") or "")),
        "date": date_text,
    }


def load_capture_sidecar(root: Path, note_path: Path) -> dict:
    sidecar_path = root / "00_Inbox" / f"{note_path.stem}.json"
    if not sidecar_path.exists():
        return {}
    try:
        value = json.loads(sidecar_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def extract_section(text: str, heading: str) -> str:
    pattern = rf"^##\s+{re.escape(heading)}\s*$([\s\S]*?)(?=^##\s+|\Z)"
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1).strip() if match else ""


def write_framework_index(config: dict, root: Path, records: list[dict]) -> None:
    relative_path = config.get("framework_file", "90_Knowledge/收藏知识框架.md")
    path = root / relative_path
    lines = [
        "# 收藏知识框架",
        "",
        f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}",
        "",
        "## 最近入库",
        "",
    ]
    for record in records:
        tags = " ".join(f"#{tag}" for tag in record["tags"])
        lines.append(
            f"- {record['date']} [[{record['rel'][:-3]}]] "
            f"`{record['platform']}` {tags} - {record['title']}"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def write_platform_index(root: Path, records: list[dict]) -> None:
    grouped: dict[str, list[dict]] = {}
    for record in records:
        grouped.setdefault(record["platform"], []).append(record)
    lines = ["# 平台索引", "", f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}", ""]
    for platform, items in sorted(grouped.items(), key=lambda pair: (-len(pair[1]), pair[0])):
        lines.extend([f"## {platform}", ""])
        lines.extend(f"- [[{item['rel'][:-3]}]] - {item['title']}" for item in items)
        lines.append("")
    write_knowledge_file(root, "平台索引.md", lines)


def write_tag_index(root: Path, records: list[dict]) -> None:
    grouped: dict[str, list[dict]] = {}
    for record in records:
        for tag in record["tags"] or ["未分类"]:
            grouped.setdefault(tag, []).append(record)
    lines = ["# 标签索引", "", f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}", ""]
    for tag, items in sorted(grouped.items(), key=lambda pair: (-len(pair[1]), pair[0])):
        lines.extend([f"## {tag}", ""])
        lines.extend(f"- [[{item['rel'][:-3]}]] - {item['title']}" for item in items)
        lines.append("")
    write_knowledge_file(root, "标签索引.md", lines)


def write_ai_learning_context(root: Path, records: list[dict]) -> None:
    platform_counts = Counter(record["platform"] for record in records)
    tag_counts = Counter(tag for record in records for tag in (record["tags"] or ["未分类"]))

    lines = [
        "# AI学习上下文",
        "",
        "用途：Codex/Claude 开始分析移动收藏时先读本文件，再按链接打开原始笔记。",
        f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}",
        f"最近样本数：{len(records)}",
        "",
        "## 推荐读取顺序",
        "",
        "1. `90_Knowledge/AI学习上下文.md`：先看最近收藏和主题信号。",
        "2. `90_Knowledge/收藏主题地图.md`：判断长期主题分布。",
        "3. `90_Knowledge/收藏行动池.md`：找需要继续整理的内容。",
        "4. `10_Notes/`：需要证据时打开原始结构化笔记。",
        "",
        "## 最近收藏入口",
        "",
    ]
    for record in records[:20]:
        tags = " ".join(f"#{tag}" for tag in record["tags"][:6])
        summary = record["summary"] or "待补充摘要"
        lines.append(f"- [[{record['rel'][:-3]}]] `{record['platform']}` {tags} - {summary}")

    lines.extend(["", "## 当前主题信号", ""])
    if platform_counts:
        platform_text = "；".join(f"`{platform}` {count}" for platform, count in platform_counts.most_common())
        lines.append(f"- 平台分布：{platform_text}")
    if tag_counts:
        tag_text = "；".join(f"#{tag} {count}" for tag, count in tag_counts.most_common(20))
        lines.append(f"- 高频标签：{tag_text}")

    lines.extend(
        [
            "",
            "## 给 Codex/Claude 的处理规则",
            "",
            "- 不要编造视频事实；没有转写或元数据时标记为待验证。",
            "- 优先把收藏转成：核心观点、可验证事实、个人判断、行动项、复习问题。",
            "- 发现高频主题时，更新知识框架，而不是只堆链接。",
            "- 对求职、韩语学习、项目实践相关内容优先提炼可执行下一步。",
        ]
    )
    write_knowledge_file(root, "AI学习上下文.md", lines)


def write_topic_map(root: Path, records: list[dict]) -> None:
    by_platform: dict[str, list[dict]] = {}
    by_tag: dict[str, list[dict]] = {}
    for record in records:
        by_platform.setdefault(record["platform"], []).append(record)
        for tag in record["tags"] or ["未分类"]:
            by_tag.setdefault(tag, []).append(record)

    lines = [
        "# 收藏主题地图",
        "",
        f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}",
        "",
        "## 平台分布",
        "",
    ]
    for platform, items in sorted(by_platform.items(), key=lambda pair: (-len(pair[1]), pair[0])):
        lines.append(f"- `{platform}`：{len(items)} 条")
    lines.extend(["", "## 高频主题", ""])
    for tag, items in sorted(by_tag.items(), key=lambda pair: (-len(pair[1]), pair[0]))[:30]:
        links = "、".join(f"[[{item['rel'][:-3]}]]" for item in items[:5])
        lines.append(f"- #{tag}：{len(items)} 条；代表内容：{links}")
    write_knowledge_file(root, "收藏主题地图.md", lines)


def write_review_questions(root: Path, records: list[dict]) -> None:
    lines = [
        "# 收藏复习问题",
        "",
        f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}",
        "",
    ]
    for record in records[:40]:
        lines.extend(
            [
                f"## [[{record['rel'][:-3]}]]",
                "",
                f"- 这条内容的核心观点是什么？",
                f"- 它和我当前学习/求职/项目目标有什么关系？",
                f"- 哪个事实需要二次验证？",
                "",
            ]
        )
    write_knowledge_file(root, "收藏复习问题.md", lines)


def write_action_pool(root: Path, records: list[dict]) -> None:
    lines = [
        "# 收藏行动池",
        "",
        f"更新时间：{dt.datetime.now():%Y-%m-%d %H:%M}",
        "",
        "## 待处理",
        "",
    ]
    for record in records[:50]:
        lines.append(f"- [ ] 整理 [[{record['rel'][:-3]}]]：补 3 句摘要，判断是否进入长期知识框架。")
    write_knowledge_file(root, "收藏行动池.md", lines)


def write_knowledge_file(root: Path, filename: str, lines: list[str]) -> None:
    path = root / "90_Knowledge" / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def notes_root(config: dict) -> Path:
    return Path(config["obsidian_vault"]) / config.get("notes_subdir", "移动收藏")


def detect_platform(url: str) -> str:
    host = urlparse(url).netloc.lower()
    if matches_domain(host, {"douyin.com", "iesdouyin.com", "amemv.com"}):
        return "douyin"
    if matches_domain(host, {"bilibili.com", "b23.tv", "bili2233.cn"}):
        return "bilibili"
    if matches_domain(host, {"xiaohongshu.com", "xhslink.com"}):
        return "xiaohongshu"
    if matches_domain(host, {"weixin.qq.com", "mp.weixin.qq.com"}):
        return "wechat"
    return "web" if host else "unknown"


def matches_domain(host: str, domains: set[str]) -> bool:
    return any(host == domain or host.endswith(f".{domain}") for domain in domains)


def first_sentence(value: str) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    if len(value) <= 180:
        return value
    return value[:180].rstrip() + "..."


def parse_date(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def slugify(value: str) -> str:
    value = re.sub(r"[\\/:*?\"<>|#\[\]]+", "-", value)
    value = re.sub(r"\s+", "-", value).strip(" .-")
    return value[:80] or "移动收藏"


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(2, 1000):
        candidate = path.with_name(f"{path.stem}-{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Unable to create unique path for {path}")


if __name__ == "__main__":
    raise SystemExit(main())
