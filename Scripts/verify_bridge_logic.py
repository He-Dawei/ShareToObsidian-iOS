from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


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
    print("bridge-enrich-placeholder-draft-ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
