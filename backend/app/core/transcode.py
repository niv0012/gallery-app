"""Video normalisation so every uploaded video plays on BOTH iOS and Android.

Why this exists
---------------
iOS (AVPlayer) is much pickier than Android (ExoPlayer). It refuses with
"Cannot Open - This media format is not supported" for:

* containers it doesn't know: .mkv .webm .avi .wmv .3gp .ts/.mts/.m2ts ...
* codecs it doesn't know: VP8/VP9/AV1, MPEG-4 part 2, ...
* HEVC in an .mp4 tagged `hev1` (Android phones often write this; iOS needs `hvc1`)
* 10-bit / 4:2:2 / 4:4:4 H.264
* truncated files / files whose moov atom is missing (e.g. a half-written transcode)

Android, in turn, can't play HEVC .mov from iPhones on older devices.

The one format that is safe everywhere is: MP4 + H.264 (8-bit, yuv420p) + AAC.
`normalize_video()` converts anything else into exactly that, and leaves files
that already match untouched.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

# Containers we trust as-is *if* the streams inside are also compatible.
# (.mov is deliberately NOT here: it was always converted to .mp4 before,
# and keeping that keeps Android behaviour identical.)
_SAFE_EXTENSIONS = {".mp4", ".m4v"}

# Extensions that get converted and whose old URL should redirect to .mp4.
CONVERTIBLE_EXTENSIONS = (
    ".mov", ".hevc", ".mkv", ".webm", ".avi", ".wmv",
    ".3gp", ".3g2", ".ts", ".mts", ".m2ts", ".flv", ".mpg", ".mpeg",
)

_PROBE_TIMEOUT_S = 60
_TRANSCODE_TIMEOUT_S = 2 * 60 * 60


@dataclass(frozen=True)
class VideoInfo:
    format_name: str
    duration_s: float | None
    video_codec: str | None
    pix_fmt: str | None
    audio_codec: str | None


def probe_video(path: Path, ffprobe_binary: str) -> VideoInfo | None:
    """Returns stream info, or None if the file can't be read/probed."""
    cmd = [
        ffprobe_binary, "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", str(path),
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, timeout=_PROBE_TIMEOUT_S)
    except FileNotFoundError:
        logger.warning("ffprobe not found (%r); falling back to extension rules", ffprobe_binary)
        return None
    except subprocess.TimeoutExpired:
        logger.warning("ffprobe timed out for %s", path)
        return None
    if res.returncode != 0:
        logger.warning("ffprobe failed for %s: %s", path, res.stderr.decode(errors="ignore")[:500])
        return None
    try:
        data = json.loads(res.stdout.decode(errors="ignore") or "{}")
    except ValueError:
        return None

    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"
                  and not (s.get("disposition") or {}).get("attached_pic")), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    fmt = data.get("format") or {}
    try:
        duration = float(fmt.get("duration")) if fmt.get("duration") not in (None, "N/A") else None
    except (TypeError, ValueError):
        duration = None
    return VideoInfo(
        format_name=str(fmt.get("format_name") or ""),
        duration_s=duration,
        video_codec=(video or {}).get("codec_name"),
        pix_fmt=(video or {}).get("pix_fmt"),
        audio_codec=(audio or {}).get("codec_name"),
    )


def _video_is_copyable(info: VideoInfo | None) -> bool:
    """H.264, 8-bit 4:2:0 -> can be stream-copied (no quality loss, very fast)."""
    return bool(
        info
        and info.video_codec == "h264"
        and info.pix_fmt in ("yuv420p", "yuvj420p")
    )


def _audio_is_copyable(info: VideoInfo | None) -> bool:
    return bool(info and (info.audio_codec is None or info.audio_codec == "aac"))


def is_universally_playable(path: Path, info: VideoInfo | None) -> bool:
    """True when the file is already MP4 + H.264 8-bit + AAC (or silent)."""
    if path.suffix.lower() not in _SAFE_EXTENSIONS:
        return False
    if info is None:
        # Couldn't probe. A .mp4 we can't read is not something we can fix
        # by guessing; leave it alone rather than risk destroying it.
        return True
    if "mov" not in info.format_name:  # ffprobe reports mp4 as "mov,mp4,m4a,3gp,3g2,mj2"
        return False
    return _video_is_copyable(info) and _audio_is_copyable(info)


def _replace_with_retry(src: Path, dst: Path, attempts: int = 5) -> None:
    """os.replace that survives Windows briefly locking a file that is being streamed."""
    last: Exception | None = None
    for i in range(attempts):
        try:
            os.replace(src, dst)
            return
        except PermissionError as exc:  # Windows: file open by another process
            last = exc
            time.sleep(1 + i)
    assert last is not None
    raise last


def normalize_video(local_path: Path, ffmpeg_binary: str, ffprobe_binary: str) -> tuple[Path, bool]:
    """Make `local_path` playable on iOS + Android.

    Returns `(path, changed)`:
      * `(local_path, False)` if it was already fine (nothing was touched);
      * `(local_path, True)` if it was a .mp4 that has been replaced in place;
      * `(local_path.with_suffix('.mp4'), True)` if the source had another extension.

    The output is written to a temporary `.part` file and only moved into place
    once ffmpeg finished successfully, so a half-written file is never served
    (a truncated MP4 is itself a classic cause of the iOS "Cannot Open" error).
    Raises on failure; the caller keeps the original untouched in that case.
    """
    info = probe_video(local_path, ffprobe_binary)

    if is_universally_playable(local_path, info):
        return local_path, False

    if info is None and local_path.suffix.lower() not in CONVERTIBLE_EXTENSIONS:
        return local_path, False  # unknown thing we cannot probe: don't touch

    target = local_path.with_suffix(".mp4")
    part = target.with_name(f"{target.stem}.transcoding.part")

    copy_video = _video_is_copyable(info)
    copy_audio = _audio_is_copyable(info) and info is not None

    cmd = [ffmpeg_binary, "-y", "-v", "error", "-i", str(local_path),
           # exactly one video + (optional) one audio; drop iPhone data/timecode tracks
           "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-map_metadata", "0"]
    if copy_video:
        cmd += ["-c:v", "copy"]
    else:
        cmd += [
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-profile:v", "high",
            # libx264 + yuv420p need even dimensions
            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
        ]
    cmd += ["-c:a", "copy"] if copy_audio else ["-c:a", "aac", "-b:a", "160k"]
    cmd += ["-movflags", "+faststart", "-max_muxing_queue_size", "4096", "-f", "mp4", str(part)]

    logger.info("Normalising %s (video=%s audio=%s)", local_path.name,
                "copy" if copy_video else "h264", "copy" if copy_audio else "aac")
    try:
        res = subprocess.run(cmd, capture_output=True, timeout=_TRANSCODE_TIMEOUT_S)
        if res.returncode != 0 or not part.exists() or part.stat().st_size == 0:
            raise RuntimeError(res.stderr.decode(errors="ignore")[-1500:] or "ffmpeg produced no output")

        out_info = probe_video(part, ffprobe_binary)
        if info is not None and out_info is None:
            raise RuntimeError("transcoded file failed verification (unreadable)")
        if (info and out_info and info.duration_s and out_info.duration_s
                and out_info.duration_s < info.duration_s * 0.9):
            raise RuntimeError(
                f"transcoded file is truncated ({out_info.duration_s:.1f}s of {info.duration_s:.1f}s)"
            )
        _replace_with_retry(part, target)
        return target, True
    finally:
        part.unlink(missing_ok=True)
