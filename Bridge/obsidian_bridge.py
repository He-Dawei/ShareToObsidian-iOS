from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
from html import escape as html_escape
from ipaddress import ip_address
import json
import os
import re
import shutil
import subprocess
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

    server = ThreadingHTTPServer(
        (config.get("host", "0.0.0.0"), int(config.get("port", 8765))),
        handler_factory(config),
    )
    print(f"Obsidian bridge listening on http://{config.get('host', '0.0.0.0')}:{config.get('port', 8765)}")
    server.serve_forever()
    return 0


def handler_factory(config: dict):
    class ObsidianBridgeHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path == "/health":
                root = notes_root(config)
                self.write_json(
                    {
                        "ok": True,
                        "queueWritable": root.exists() and root.is_dir(),
                        "notesRoot": str(root),
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
            if path not in {"/captures", "/drafts", "/metadata", "/captures/delete"}:
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
                    result = delete_capture_note(config, item)
                    self.write_json(result)
                    return
                item = enrich_capture(config, item, fetch_remote_metadata=not fast)
                if path == "/metadata":
                    self.write_json(item)
                    return
                if path == "/drafts":
                    self.write_json(generate_markdown_draft(config, item))
                    return
                note_path = write_capture_note(config, item)
                rebuild_knowledge_synthesis(config)
                self.write_json(
                    {
                        "ok": True,
                        "path": str(note_path),
                        "relativePath": note_path.relative_to(notes_root(config)).as_posix(),
                        "item": item,
                    }
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


def write_capture_note(config: dict, item: dict) -> Path:
    root = notes_root(config) / "10_Notes"
    root.mkdir(parents=True, exist_ok=True)

    title = str(item.get("title") or "移动收藏")
    markdown = str(item.get("draftMarkdown") or fallback_markdown(item))
    if should_replace_draft(markdown, item):
        markdown = fallback_markdown(item)
    created = parse_date(item.get("createdAt")) or dt.datetime.now()
    remote_note_path = str(item.get("remoteNotePath") or "")
    if remote_note_path:
        root_for_indexes = notes_root(config).resolve()
        note_path = resolve_note_path(root_for_indexes, remote_note_path)
        remove_note_from_indexes(root_for_indexes, note_path)
        note_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        filename = f"{created:%Y-%m-%d}-{slugify(title)}.md"
        note_path = unique_path(root / filename)
    note_path.write_text(markdown.strip() + "\n", encoding="utf-8")

    raw_path = notes_root(config) / config.get("inbox_subdir", "00_Inbox") / f"{note_path.stem}.json"
    raw_path.write_text(json.dumps(item, ensure_ascii=False, indent=2), encoding="utf-8")
    return note_path


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


def enrich_capture(config: dict, item: dict, fetch_remote_metadata: bool = True) -> dict:
    item = dict(item)
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
    ytdlp = find_ytdlp(config)
    if not ytdlp:
        return {}
    cmd = [
        ytdlp,
        "--dump-single-json",
        "--no-playlist",
        "--skip-download",
        "--no-warnings",
        "--socket-timeout",
        str(config.get("metadata_socket_timeout", 12)),
        url,
    ]
    try:
        result = subprocess.run(
            cmd,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=int(config.get("metadata_timeout_seconds", 25)),
        )
    except Exception as exc:
        return {"metadata_error": str(exc)}
    if result.returncode != 0:
        return {"metadata_error": result.stderr.strip()[-500:]}
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return {"metadata_error": str(exc)}
    return compact_metadata(raw)


def find_ytdlp(config: dict) -> str:
    configured = config.get("ytdlp_path")
    candidates = [
        configured,
        shutil.which("yt-dlp"),
        r"C:\Users\44527\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\Scripts\yt-dlp.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return ""


def compact_metadata(raw: dict) -> dict:
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
    return {key: raw.get(key) for key in keys if raw.get(key) not in (None, "")}


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


def generate_ai_markdown_draft(config: dict, item: dict) -> dict | None:
    ai = config.get("ai") or {}
    if not ai.get("enabled", False):
        return None
    api_key = os.environ.get(str(ai.get("api_key_env", "OPENAI_API_KEY")))
    if not api_key:
        return None

    base_url = str(ai.get("base_url", "https://api.openai.com/v1")).rstrip("/")
    model = str(ai.get("model", "gpt-4.1-mini"))
    timeout = int(ai.get("timeout_seconds", 45))
    prompt = ai_prompt(item)
    body = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "你是帮助用户整理 Obsidian 收藏笔记的中文知识管理助手。只输出严格 JSON。",
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.4,
    }
    request = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json; charset=utf-8",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return None

    content = (
        payload.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
        .strip()
    )
    try:
        draft = json.loads(extract_json_object(content))
    except json.JSONDecodeError:
        return None

    if not isinstance(draft, dict):
        return None
    required = {"summary", "markdown", "alternatives", "tags"}
    if not required.issubset(draft.keys()):
        return None
    if not isinstance(draft.get("alternatives"), list) or len(draft["alternatives"]) < 3:
        return None
    draft["alternatives"] = [str(value) for value in draft["alternatives"][:3]]
    draft["tags"] = [str(value) for value in draft.get("tags") or item.get("tags") or []]
    return draft


def ai_prompt(item: dict) -> str:
    metadata = item.get("metadata") or {}
    tags = ", ".join(str(tag) for tag in item.get("tags") or [])
    return (
        "请根据下面的分享内容，生成 Obsidian Markdown 草稿。\n"
        "要求：中文、结构化、适合后续 Codex/Claude 继续学习；不要编造具体视频事实；没有信息就写待补充。\n"
        "输出严格 JSON，字段为 summary, markdown, alternatives, tags。\n"
        "alternatives 必须正好 3 个 Markdown 字符串，分别偏行动清单、知识卡片、问题驱动。\n\n"
        f"标题：{item.get('title') or ''}\n"
        f"平台：{item.get('platform') or ''}\n"
        f"链接：{item.get('url') or ''}\n"
        f"已有摘要：{item.get('summary') or ''}\n"
        f"标签：{tags}\n"
        f"作者/频道：{metadata.get('uploader') or metadata.get('channel') or ''}\n"
        f"简介：{metadata.get('description') or ''}\n"
        f"口播/转写：{metadata.get('transcript') or metadata.get('content_text') or ''}\n"
    )


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
