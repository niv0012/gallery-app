"""One-off backfill: make every already-uploaded video play on iOS + Android.

New uploads are handled automatically by app.core.transcode_worker. This
script applies the same conversion (MP4 / H.264 / AAC) to videos uploaded
BEFORE that fix, e.g. .mkv/.webm/.avi/.3gp, HEVC-in-mp4 (`hev1`), 10-bit
H.264, and so on. Files that already play everywhere are left untouched.

Usage (from D:\\picgallery\\backend, venv active):
    python -m app.scripts.fix_ios_videos --dry-run
    python -m app.scripts.fix_ios_videos
    python -m app.scripts.fix_ios_videos --limit 20

Safe to re-run: compatible files are skipped, and each video is committed
individually so one failure never blocks the rest.
"""
import argparse
import logging

from sqlalchemy import select

from app.core.config import settings
from app.core.storage import _fetch_to_temp, _use_r2
from app.core.transcode import is_universally_playable, probe_video
from app.core.transcode_worker import normalize_stored_video
from app.db.session import SessionLocal
from app.models.gallery import Media, MediaType

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("fix_ios_videos")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="only report what would change")
    parser.add_argument("--limit", type=int, default=0, help="stop after converting N videos")
    args = parser.parse_args()

    with SessionLocal() as db:
        rows = db.execute(
            select(Media.id, Media.file_path).where(Media.media_type == MediaType.video)
        ).all()

    logger.info("Checking %d videos", len(rows))
    converted = skipped = failed = 0

    for media_id, file_path in rows:
        if args.limit and converted >= args.limit:
            break
        try:
            local = _fetch_to_temp(file_path)
            try:
                info = probe_video(local, settings.FFPROBE_BINARY)
                playable = is_universally_playable(local, info)
            finally:
                if _use_r2():
                    local.unlink(missing_ok=True)

            if playable:
                skipped += 1
                continue

            if args.dry_run:
                logger.info("WOULD CONVERT %s (%s)", file_path,
                            f"{info.video_codec}/{info.pix_fmt}/{info.audio_codec}" if info else "unprobeable")
                converted += 1
                continue

            new_path = normalize_stored_video(media_id, file_path)
            logger.info("processed %s -> %s", file_path, new_path)
            converted += 1
        except Exception:
            failed += 1
            logger.exception("failed %s", file_path)

    logger.info("Done: %d %s, %d already fine, %d failed",
                converted, "to convert" if args.dry_run else "converted", skipped, failed)


if __name__ == "__main__":
    main()
