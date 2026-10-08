import logging
import uuid
from pathlib import Path

from app.core.config import settings
from app.core.storage import (
    _fetch_to_temp,
    _r2_client,
    _use_r2,
    delete_stored_file,
    get_video_duration_ms,
    make_video_thumbnail,
)
from app.core.transcode import CONVERTIBLE_EXTENSIONS, normalize_video
from app.db.session import SessionLocal
from app.models.gallery import Media, MediaType

logger = logging.getLogger(__name__)

# Originals with these extensions are kept after conversion (existing behaviour:
# the Flutter app caches the URL right after upload, and iOS can play .mov).
# Every other converted original is deleted once the .mp4 is verified, so any
# stale URL 404s and main.py's fallback middleware redirects it to the .mp4.
_KEEP_ORIGINAL_EXTENSIONS = {".mov", ".hevc"}


def normalize_stored_video(media_id: uuid.UUID, relative_path: str) -> str:
    """Makes the stored video iOS+Android playable (MP4/H.264/AAC).

    Returns the relative path of the playable file (unchanged if the file
    was already fine or conversion failed). Updates the Media row when the
    path changes. Never raises: on any failure the original stays in place.
    """
    use_r2 = _use_r2()
    rel = Path(relative_path)
    fetched = None
    result_path = None
    try:
        fetched = _fetch_to_temp(relative_path)
        result_path, changed = normalize_video(
            fetched, settings.FFMPEG_BINARY, settings.FFPROBE_BINARY
        )
        if not changed:
            return relative_path

        new_relative = rel.with_suffix(".mp4").as_posix()

        if use_r2:
            _r2_client().upload_file(
                str(result_path),
                settings.R2_BUCKET_NAME,
                new_relative,
                ExtraArgs={"ContentType": "video/mp4"},
            )

        with SessionLocal() as db:
            media = db.get(Media, media_id)
            if media:
                media.file_path = new_relative
                if media.file_name.lower().endswith(CONVERTIBLE_EXTENSIONS):
                    media.file_name = str(Path(media.file_name).with_suffix(".mp4"))
                media.content_type = "video/mp4"
                db.commit()

        if new_relative != relative_path and rel.suffix.lower() not in _KEEP_ORIGINAL_EXTENSIONS:
            delete_stored_file(relative_path)

        return new_relative
    except Exception:
        logger.exception("Video normalisation failed for %s; keeping original", relative_path)
        return relative_path
    finally:
        if use_r2:
            for p in (fetched, result_path):
                if p is not None:
                    Path(p).unlink(missing_ok=True)


def process_video_upload_background(
    media_id: uuid.UUID,
    owner_id: uuid.UUID,
    relative_path: str,
    media_type: MediaType,
):
    """Background worker: converts the uploaded video to an iOS+Android
    compatible MP4 (any container/codec, not just .mov), updates the
    database, then generates the thumbnail and duration."""
    new_relative_path = relative_path

    if media_type == MediaType.video:
        new_relative_path = normalize_stored_video(media_id, relative_path)

    thumbnail_path = None
    duration_ms = None

    if media_type == MediaType.video:
        thumbnail_path = make_video_thumbnail(
            owner_id=owner_id,
            media_id=media_id,
            original_relative_path=new_relative_path,
        )
        duration_ms = get_video_duration_ms(new_relative_path)

    with SessionLocal() as db:
        media = db.get(Media, media_id)
        if media:
            if thumbnail_path:
                media.thumbnail_path = thumbnail_path
            if duration_ms is not None:
                media.duration_ms = duration_ms
            db.commit()
