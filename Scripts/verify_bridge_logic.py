from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = REPO_ROOT / "Bridge" / "obsidian_bridge.py"


def load_bridge_module():
    spec = importlib.util.spec_from_file_location("obsidian_bridge_verify", BRIDGE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load Bridge/obsidian_bridge.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    bridge = load_bridge_module()

    def fake_fetch_metadata(_config: dict, _url: str) -> dict:
        return {
            "title": "Metadata Title",
            "description": "Metadata description should replace placeholder summary.",
            "uploader": "Verifier",
            "extractor": "verifier",
            "transcript": "Transcript text should appear in generated markdown.",
        }

    bridge.fetch_metadata = fake_fetch_metadata
    item = {
        "url": "https://example.com/metadata-refresh",
        "platform": "web",
        "title": "网页收藏内容",
        "summary": "待提炼：已捕获来自网页的分享链接。",
        "draftMarkdown": "# 网页收藏内容\n\n## 核心内容\n\n待提炼：旧占位。\n",
        "tags": ["移动收藏"],
        "isUserEdited": False,
    }

    enriched = bridge.enrich_capture({}, item, fetch_remote_metadata=True)
    assert enriched["title"] == "Metadata Title"
    assert enriched["summary"] == "Metadata description should replace placeholder summary."
    assert "Metadata description should replace placeholder summary." in enriched["draftMarkdown"]
    assert "Transcript text should appear in generated markdown." in enriched["draftMarkdown"]
    assert "视频内容/口播转写" in enriched["draftMarkdown"]
    assert "Verifier" in enriched["draftMarkdown"]
    assert "待提炼：旧占位" not in enriched["draftMarkdown"]
    assert bridge.detect_platform("https://www.iesdouyin.com/share/video/1") == "douyin"
    assert bridge.detect_platform("https://v.douyin.com/abc") == "douyin"
    assert bridge.detect_platform("https://bili2233.cn/abc") == "bilibili"
    assert bridge.detect_platform("https://b23.tv/abc") == "bilibili"
    assert bridge.detect_platform("https://xhslink.com/a") == "xiaohongshu"
    assert bridge.detect_platform("https://mp.weixin.qq.com/s/a") == "wechat"

    with tempfile.TemporaryDirectory() as tmp:
        defuddle = Path(tmp) / "defuddle.cmd"
        defuddle.write_text("@echo off\n", encoding="utf-8")
        original_run = bridge.subprocess.run
        captured_command = []

        def fake_defuddle_run(command, **_kwargs):
            captured_command.extend(command)
            return SimpleNamespace(
                returncode=0,
                stdout=json.dumps(
                    {
                        "title": "Defuddle 标题",
                        "description": "网页摘要",
                        "author": "网页作者",
                        "image": "https://example.com/cover.jpg",
                        "content": "正文内容 " * 20,
                    },
                    ensure_ascii=False,
                ),
                stderr="",
            )

        try:
            bridge.subprocess.run = fake_defuddle_run
            web_metadata, web_error = bridge.fetch_web_content(
                {
                    "defuddle_path": str(defuddle),
                    "content_max_chars": 24,
                },
                "https://example.com/article",
            )
        finally:
            bridge.subprocess.run = original_run

        assert not web_error
        assert web_metadata["title"] == "Defuddle 标题"
        assert web_metadata["uploader"] == "网页作者"
        assert web_metadata["extractor"] == "Defuddle"
        assert len(web_metadata["content_text"]) == 24
        assert captured_command[:3] == [
            str(defuddle),
            "parse",
            "https://example.com/article",
        ]
        assert "--markdown" in captured_command
        assert "--json" in captured_command

    subtitle_metadata = bridge.compact_metadata(
        {
            "title": "字幕视频",
            "subtitles": {
                "en": [
                    {
                        "ext": "vtt",
                        "data": "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nEnglish subtitle",
                    }
                ],
                "zh-CN": [
                    {
                        "ext": "json",
                        "data": json.dumps(
                            {
                                "body": [
                                    {"from": 1.2, "to": 2.8, "content": "第一句字幕"},
                                    {"from": 65.0, "to": 67.0, "content": "第二句字幕"},
                                ]
                            },
                            ensure_ascii=False,
                        ),
                    }
                ],
            },
        },
        {"content_max_chars": 200},
    )
    assert "[00:01] 第一句字幕" in subtitle_metadata["transcript"]
    assert "[01:05] 第二句字幕" in subtitle_metadata["transcript"]
    assert "English subtitle" not in subtitle_metadata["transcript"]
    assert bridge.parse_subtitle_payload(
        "WEBVTT\n\n00:00:03.000 --> 00:00:05.000\n<b>VTT 字幕</b>"
    ) == "[00:03] VTT 字幕"

    ai_item = {
        "url": "https://example.com/ai-draft",
        "platform": "web",
        "title": "AI 草稿验证",
        "summary": "验证两种兼容协议。",
        "tags": ["移动收藏"],
    }
    ai_draft = {
        "summary": "AI 已生成摘要",
        "markdown": (
            "# AI 草稿\n\n"
            "## 核心内容\n\n这是模型生成的正文。\n\n"
            "## 视频介绍\n\n待补充。\n\n"
            "## 后续行动\n\n- [ ] 验证结果。"
        ),
        "alternatives": ["# 行动清单", "# 知识卡片", "# 问题驱动"],
        "tags": ["移动收藏", "AI"],
    }
    original_urlopen = bridge.urllib.request.urlopen
    old_ai_key = os.environ.get("VERIFY_AI_KEY")
    old_ai_base = os.environ.get("VERIFY_AI_BASE")
    old_ai_model = os.environ.get("VERIFY_AI_MODEL")
    requests = []

    class FakeResponse:
        def __init__(self, payload: dict):
            self.payload = payload

        def __enter__(self):
            return self

        def __exit__(self, _exc_type, _exc_value, _traceback):
            return False

        def read(self) -> bytes:
            return json.dumps(self.payload, ensure_ascii=False).encode("utf-8")

    def fake_urlopen(request, timeout: int):
        requests.append((request, timeout))
        if request.full_url.endswith("/v1/messages"):
            return FakeResponse(
                {
                    "content": [
                        {"type": "thinking", "thinking": "ignored"},
                        {"type": "text", "text": json.dumps(ai_draft, ensure_ascii=False)},
                    ]
                }
            )
        return FakeResponse(
            {
                "choices": [
                    {"message": {"content": json.dumps(ai_draft, ensure_ascii=False)}}
                ]
            }
        )

    try:
        os.environ["VERIFY_AI_KEY"] = "test-key"
        os.environ["VERIFY_AI_BASE"] = "https://api.example.test/anthropic"
        os.environ["VERIFY_AI_MODEL"] = "test-model"
        bridge.urllib.request.urlopen = fake_urlopen

        anthropic_config = {
            "ai": {
                "enabled": True,
                "provider": "anthropic",
                "base_url_env": "VERIFY_AI_BASE",
                "model_env": "VERIFY_AI_MODEL",
                "api_key_env": "VERIFY_AI_KEY",
                "timeout_seconds": 12,
            }
        }
        assert bridge.ai_is_configured(anthropic_config)
        assert bridge.generate_markdown_draft(anthropic_config, ai_item) == ai_draft
        anthropic_request, anthropic_timeout = requests[-1]
        anthropic_headers = {key.lower(): value for key, value in anthropic_request.header_items()}
        anthropic_body = json.loads(anthropic_request.data.decode("utf-8"))
        assert anthropic_request.full_url == "https://api.example.test/anthropic/v1/messages"
        assert anthropic_headers["x-api-key"] == "test-key"
        assert anthropic_headers["anthropic-version"] == "2023-06-01"
        assert anthropic_body["model"] == "test-model"
        assert anthropic_body["max_tokens"] == 5000
        assert anthropic_timeout == 12

        openai_config = {
            "ai": {
                "enabled": True,
                "provider": "openai",
                "base_url": "https://api.example.test/v1",
                "model": "test-openai-model",
                "api_key_env": "VERIFY_AI_KEY",
            }
        }
        assert bridge.generate_markdown_draft(openai_config, ai_item) == ai_draft
        openai_request, _ = requests[-1]
        openai_headers = {key.lower(): value for key, value in openai_request.header_items()}
        openai_body = json.loads(openai_request.data.decode("utf-8"))
        assert openai_request.full_url == "https://api.example.test/v1/chat/completions"
        assert openai_headers["authorization"] == "Bearer test-key"
        assert openai_body["model"] == "test-openai-model"
    finally:
        bridge.urllib.request.urlopen = original_urlopen
        for name, value in (
            ("VERIFY_AI_KEY", old_ai_key),
            ("VERIFY_AI_BASE", old_ai_base),
            ("VERIFY_AI_MODEL", old_ai_model),
        ):
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "移动收藏"
        notes = root / "10_Notes"
        inbox = root / "00_Inbox"
        notes.mkdir(parents=True)
        inbox.mkdir(parents=True)
        note = notes / "sample.md"
        note.write_text(
            "---\n"
            "source: douyin\n"
            "---\n\n"
            "# 示例收藏\n\n"
            "## 核心内容\n\n"
            "这是用于验证 AI 学习上下文的摘要。\n\n"
            "## 自动标签\n\n"
            "#移动收藏 #douyin #视频\n",
            encoding="utf-8",
        )
        (inbox / "sample.json").write_text(
            """
            {
              "url": "https://v.douyin.com/sample",
              "platform": "douyin",
              "title": "示例收藏",
              "summary": "这是用于验证 AI 学习上下文的摘要。",
              "tags": ["移动收藏", "douyin", "视频"],
              "createdAt": "2026-07-29T08:00:00Z"
            }
            """,
            encoding="utf-8",
        )
        bridge.ensure_vault_layout({"obsidian_vault": tmp, "notes_subdir": "移动收藏"})
        stale_framework = root / "90_Knowledge" / "收藏知识框架.md"
        stale_framework.write_text(
            "# 收藏知识框架\n\n## 最近入库\n\n- [[10_Notes/deleted-verifier]] - stale\n",
            encoding="utf-8",
        )
        bridge.rebuild_knowledge_synthesis({"obsidian_vault": tmp, "notes_subdir": "移动收藏"})
        ai_context = root / "90_Knowledge" / "AI学习上下文.md"
        assert ai_context.exists()
        ai_text = ai_context.read_text(encoding="utf-8")
        assert "Codex/Claude" in ai_text
        assert "[[10_Notes/sample]]" in ai_text
        assert "#douyin" in ai_text
        assert "`douyin` 1" in ai_text
        framework_text = stale_framework.read_text(encoding="utf-8")
        assert "deleted-verifier" not in framework_text
        assert framework_text.count("[[10_Notes/sample]]") == 1
        assert "2026-07-29" in framework_text
        platform_text = (root / "90_Knowledge" / "平台索引.md").read_text(encoding="utf-8")
        assert "## douyin" in platform_text
        assert "[[10_Notes/sample]]" in platform_text
        tag_text = (root / "90_Knowledge" / "标签索引.md").read_text(encoding="utf-8")
        assert "## 视频" in tag_text
        assert "[[10_Notes/sample]]" in tag_text
        agents_text = (root / "AGENTS.md").read_text(encoding="utf-8")
        assert "AI学习上下文.md" in agents_text
        config = {"obsidian_vault": tmp, "notes_subdir": "移动收藏"}
        assert bridge.existing_vault_tags(config)[:3] == ["移动收藏", "douyin", "视频"]
        prompt = bridge.ai_prompt(config, ai_item)
        assert "知识库已有标签" in prompt
        assert "douyin" in prompt
    print("bridge-enrich-placeholder-draft-ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
