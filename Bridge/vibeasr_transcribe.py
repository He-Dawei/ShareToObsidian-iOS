from __future__ import annotations

import argparse
import subprocess
import wave
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asr-exe", required=True)
    parser.add_argument("--vae-model", required=True)
    parser.add_argument("--lm-model", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--threads", default="4")
    parser.add_argument("--max-tokens", default="256")
    parser.add_argument("--chunk-seconds", type=float, default=10.0)
    parser.add_argument("--greedy", action="store_true")
    args = parser.parse_args()

    output = Path(args.output).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    chunks = split_wav(
        Path(args.audio).expanduser(),
        output.parent / "chunks",
        args.chunk_seconds,
    )
    transcripts: list[str] = []

    for index, chunk in enumerate(chunks):
        result = run_asr(args, chunk)
        if result.returncode != 0:
            raise RuntimeError(
                f"VibeASR.cpp failed for chunk {index + 1}/{len(chunks)}: "
                f"{result.stderr.strip()[-500:]}"
            )
        text = result.stdout.strip()
        if text:
            timestamp = format_timestamp(index * args.chunk_seconds)
            transcripts.append(f"[{timestamp}] {text}")

    transcript = "\n".join(transcripts).strip()
    if not transcript:
        transcript = "[VibeASR.cpp completed but found no clear speech.]"
    output.write_text(transcript + "\n", encoding="utf-8")
    return 0


def run_asr(
    args: argparse.Namespace,
    audio: Path,
) -> subprocess.CompletedProcess[str]:
    command = [
        str(Path(args.asr_exe).expanduser()),
        "--vae-model",
        str(Path(args.vae_model).expanduser()),
        "--lm-model",
        str(Path(args.lm_model).expanduser()),
        "--audio",
        str(audio),
        "-t",
        str(args.threads),
        "--max-tokens",
        str(args.max_tokens),
    ]
    if args.greedy:
        command.append("--greedy")
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def split_wav(audio: Path, chunk_dir: Path, chunk_seconds: float) -> list[Path]:
    if chunk_seconds <= 0:
        return [audio]

    chunk_dir.mkdir(parents=True, exist_ok=True)
    with wave.open(str(audio), "rb") as source:
        params = source.getparams()
        frames_per_chunk = max(1, int(params.framerate * chunk_seconds))
        chunks: list[Path] = []
        index = 1
        while True:
            frames = source.readframes(frames_per_chunk)
            if not frames:
                break
            chunk_path = chunk_dir / f"{audio.stem}-{index:03d}.wav"
            with wave.open(str(chunk_path), "wb") as target:
                target.setparams(params)
                target.writeframes(frames)
            chunks.append(chunk_path)
            index += 1
    return chunks or [audio]


def format_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


if __name__ == "__main__":
    raise SystemExit(main())
