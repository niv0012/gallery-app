"""Storage backend for Gallery media (photos/videos + thumbnails).

Supports two backends, switched by settings.STORAGE_BACKEND:

  "local" - writes to settings.MEDIA_STORAGE_DIR on this machine's disk
            (original behavior; main.py serves it via StaticFiles).
  "r2"    - writes to a Cloudflare R2 bucket (S3-compatible) and serves
            files from settings.R2_PUBLIC_URL directly, bypassing this
            API process entirely for downloads.

Every function here still works with storage-relative *keys* (e.g.
"<owner_id>/<media_id>/original.jpg") — routes and schemas only ever
call save_upload, build_media_url, delete_stored_file, make_thumbnail,
make_video_thumbnail, duplicate_media_files, delete_media_folder. Which
backend is active is decided once, in this file, based on
settings.STORAGE_BACKEND — nothing outside this file needs to know or
change.
"""

import logging
import shutil
import subprocess
import tempfile
import uuid
from functools import lru_cache
from pathlib import Path

from fastapi import UploadFile

from app.core.config import settings
from app.models.gallery import MediaType

logger = logging.getLogger("app.storage")

# Extensions/content-types accepted from the upload form. Kept narrow on
# purpose — this is what actually gets written to storage and served back.
_PHOTO_CONTENT_TYPES = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/x-adobe-dng",
    "image/x-nikon-nef",
    "image/x-canon-cr2",
    "image/x-canon-cr3",
    "image/x-olympus-orf",
    "image/x-sony-arw",
    "image/raw",
}
_VIDEO_CONTENT_TYPES = {
    "video/mp4",
    "video/quicktime",
    "video/x-matroska",
    "video/webm",
    "video/x-msvideo",
    "video/avi",
    "video/x-m4v",
    "video/3gpp",
    "video/3gpp2",
    "video/x-ms-wmv",
    "video/mp2t",
}

THUMBNAIL_MAX_DIMENSION = 1080
# Grab the poster frame this far into the clip (skips a possible black
# first frame). Falls back to frame 0 if the video is shorter than this.
VIDEO_THUMBNAIL_TIMESTAMP_SECONDS = 1.0


def media_type_for_content_type(content_type: str) -> MediaType:
    if content_type in _VIDEO_CONTENT_TYPES:
        return MediaType.video
    if content_type in _PHOTO_CONTENT_TYPES:
        return MediaType.photo
    raise ValueError(f"Unsupported content type: {content_type}")


def _use_r2() -> bool:
    return settings.STORAGE_BACKEND == "r2"


# --------------------------------------------------------------------------
# Local-disk backend internals
# --------------------------------------------------------------------------

def _storage_root() -> Path:
    root = Path(settings.MEDIA_STORAGE_DIR)
    root.mkdir(parents=True, exist_ok=True)
    return root


def _media_dir(owner_id: uuid.UUID, media_id: uuid.UUID) -> Path:
    d = _storage_root() / str(owner_id) / str(media_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


# --------------------------------------------------------------------------
# R2 backend internals
# --------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _r2_client():
    import boto3

    return boto3.client(
        "s3",
        endpoint_url=settings.R2_ENDPOINT_URL,
        aws_access_key_id=settings.R2_ACCESS_KEY_ID,
        aws_secret_access_key=settings.R2_SECRET_ACCESS_KEY,
        region_name="auto",
    )


def _r2_key(owner_id: uuid.UUID, media_id: uuid.UUID, filename: str) -> str:
    return f"{owner_id}/{media_id}/{filename}"


# --------------------------------------------------------------------------
# Backend-agnostic helpers: move bytes between "wherever storage lives"
# and a local temp file, so thumbnail/dimension code (which needs a real
# local path to hand to Pillow/ffmpeg) works the same on either backend.
# --------------------------------------------------------------------------

def _fetch_to_temp(relative_path: str) -> Path:
    """Returns a local filesystem path containing this stored file's
    bytes. On "local" this is the real path (no copy). On "r2" this
    downloads to a temp file — caller should not assume it lives
    permanently and should not delete it if backend is "local".
    """
    if not _use_r2():
        return _storage_root() / relative_path

    suffix = Path(relative_path).suffix
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    tmp.close()
    _r2_client().download_file(settings.R2_BUCKET_NAME, relative_path, tmp.name)
    return Path(tmp.name)


def _store_local_file(*, local_path: Path, relative_path: str) -> None:
    """Puts a local file's bytes at `relative_path` in whichever backend
    is active. On "local", moves it into the storage root. On "r2",
    uploads it then removes the local temp copy.
    """
    if _use_r2():
        _r2_client().upload_file(str(local_path), settings.R2_BUCKET_NAME, relative_path)
        local_path.unlink(missing_ok=True)
    else:
        dest = _storage_root() / relative_path
        dest.parent.mkdir(parents=True, exist_ok=True)
        if local_path != dest:
            shutil.move(str(local_path), str(dest))


# --------------------------------------------------------------------------
# Public API — unchanged signatures, used by routes/media.py etc.
# --------------------------------------------------------------------------

def save_upload(*, owner_id: uuid.UUID, media_id: uuid.UUID, upload: UploadFile) -> tuple[str, int]:
    """Streams `upload` into storage under this media's folder/key.
    Returns (relative_path, size_bytes). Raises ValueError if the file
    exceeds settings.MAX_UPLOAD_SIZE_BYTES (partial file is cleaned up).
    """
    original_name = upload.filename or "upload.bin"
    suffix = Path(original_name).suffix
    relative_path = f"{owner_id}/{media_id}/original{suffix}"

    # Always buffer through a local temp file first: it's what lets us
    # enforce the size cap mid-stream and gives make_thumbnail/
    # make_video_thumbnail a real path to open, on either backend.
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    size = 0
    try:
        with tmp:
            while chunk := upload.file.read(1024 * 1024):
                size += len(chunk)
                if settings.MAX_UPLOAD_SIZE_BYTES is not None and size > settings.MAX_UPLOAD_SIZE_BYTES:
                    raise ValueError(
                        f"File exceeds max upload size of {settings.MAX_UPLOAD_SIZE_BYTES} bytes"
                    )
                tmp.write(chunk)
    except ValueError:
        Path(tmp.name).unlink(missing_ok=True)
        raise

    _store_local_file(local_path=Path(tmp.name), relative_path=relative_path)
    return relative_path, size


def make_thumbnail(*, owner_id: uuid.UUID, media_id: uuid.UUID, original_relative_path: str) -> str | None:
    """Generates a JPEG thumbnail for a photo using Pillow. Returns the
    relative path, or None if generation wasn't possible (Pillow/the
    file itself can't be read) — callers should treat a None thumbnail
    as "fall back to a placeholder in the UI", not an error.
    """
    try:
        from PIL import Image
    except ImportError:
        logger.warning("Pillow not installed — skipping thumbnail generation. `pip install Pillow`.")
        return None

    fetched = _fetch_to_temp(original_relative_path)
    thumb_relative = f"{owner_id}/{media_id}/thumbnail.jpg"
    thumb_tmp = Path(tempfile.mktemp(suffix=".jpg"))

    try:
        with Image.open(fetched) as img:
            img = img.convert("RGB")
            img.thumbnail((THUMBNAIL_MAX_DIMENSION, THUMBNAIL_MAX_DIMENSION))
            img.save(thumb_tmp, "JPEG", quality=85)
    except Exception:
        logger.exception("Thumbnail generation failed for %s", original_relative_path)
        return None
    finally:
        if _use_r2():
            fetched.unlink(missing_ok=True)

    _store_local_file(local_path=thumb_tmp, relative_path=thumb_relative)
    return thumb_relative


def make_video_thumbnail(*, owner_id: uuid.UUID, media_id: uuid.UUID, original_relative_path: str) -> str | None:
    """Generates a JPEG poster-frame thumbnail for a video using ffmpeg
    (must be installed on the server / in the deploy image — not a pip
    package). Returns the relative path, or None if ffmpeg isn't
    available or the frame extraction failed — callers should treat a
    None thumbnail as "fall back to a placeholder in the UI", not an
    error, same as make_thumbnail.
    """
    fetched = _fetch_to_temp(original_relative_path)
    thumb_relative = f"{owner_id}/{media_id}/thumbnail.jpg"
    thumb_tmp = Path(tempfile.mktemp(suffix=".jpg"))

    try:
        result = subprocess.run(
            [
                settings.FFMPEG_BINARY,
                "-y",
                "-ss", str(VIDEO_THUMBNAIL_TIMESTAMP_SECONDS),
                "-i", str(fetched),
                "-frames:v", "1",
                "-vf", f"scale='min({THUMBNAIL_MAX_DIMENSION},iw)':-2",
                str(thumb_tmp),
            ],
            capture_output=True,
            timeout=30,
        )
        if result.returncode != 0 or not thumb_tmp.exists():
            # Short clip (< 1s)? retry grabbing the very first frame.
            result = subprocess.run(
                [
                    settings.FFMPEG_BINARY, "-y",
                    "-i", str(fetched),
                    "-frames:v", "1",
                    "-vf", f"scale='min({THUMBNAIL_MAX_DIMENSION},iw)':-2",
                    str(thumb_tmp),
                ],
                capture_output=True,
                timeout=30,
            )
        if result.returncode != 0 or not thumb_tmp.exists():
            logger.warning("ffmpeg thumbnail failed for %s: %s", original_relative_path, result.stderr.decode(errors="ignore"))
            return None
    except FileNotFoundError:
        logger.warning("ffmpeg binary not found (settings.FFMPEG_BINARY=%r) — skipping video thumbnail.", settings.FFMPEG_BINARY)
        return None
    except Exception:
        logger.exception("Video thumbnail generation failed for %s", original_relative_path)
        return None
    finally:
        if _use_r2():
            fetched.unlink(missing_ok=True)

    _store_local_file(local_path=thumb_tmp, relative_path=thumb_relative)
    return thumb_relative


def get_video_duration_ms(original_relative_path: str) -> int | None:
    """Reads a video's duration via ffprobe. Returns None if ffprobe
    isn't available or the file can't be probed — callers should treat
    a None duration as "unknown" (the UI already falls back to
    displaying "--:--"), not an error, same as the thumbnail helpers
    above.
    """
    fetched = _fetch_to_temp(original_relative_path)
    try:
        result = subprocess.run(
            [
                settings.FFPROBE_BINARY,
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(fetched),
            ],
            capture_output=True,
            timeout=30,
        )
        if result.returncode != 0:
            logger.warning(
                "ffprobe duration read failed for %s: %s",
                original_relative_path,
                result.stderr.decode(errors="ignore"),
            )
            return None

        raw = result.stdout.decode(errors="ignore").strip()
        try:
            seconds = float(raw)
        except ValueError:
            logger.warning("ffprobe returned non-numeric duration %r for %s", raw, original_relative_path)
            return None

        return round(seconds * 1000)
    except FileNotFoundError:
        logger.warning("ffprobe binary not found (settings.FFPROBE_BINARY=%r) — skipping video duration.", settings.FFPROBE_BINARY)
        return None
    except Exception:
        logger.exception("Video duration read failed for %s", original_relative_path)
        return None
    finally:
        if _use_r2():
            fetched.unlink(missing_ok=True)


def get_image_dimensions(relative_path: str) -> tuple[int | None, int | None]:
    try:
        from PIL import Image
    except ImportError:
        return None, None

    fetched = _fetch_to_temp(relative_path)
    try:
        with Image.open(fetched) as img:
            return img.width, img.height
    except Exception:
        return None, None
    finally:
        if _use_r2():
            fetched.unlink(missing_ok=True)


def build_media_url(relative_path: str | None) -> str | None:
    if not relative_path:
        return None
    if _use_r2():
        return f"{settings.R2_PUBLIC_URL}/{relative_path}"
    return f"{settings.app_public_url}{settings.MEDIA_URL_PREFIX}/{relative_path}"


def get_signed_original_url(relative_path: str | None, expires_in_seconds: int = 3600) -> str | None:
    """Returns a time-limited presigned URL for downloading the original file directly
    from R2. If using local storage, returns the normal media URL (as it is already
    served publicly via StaticFiles).
    """
    if not relative_path:
        return None
    if _use_r2():
        client = _r2_client()
        return client.generate_presigned_url(
            "get_object",
            Params={"Bucket": settings.R2_BUCKET_NAME, "Key": relative_path},
            ExpiresIn=expires_in_seconds,
        )
    # Local fallback
    base_url = build_media_url(relative_path)
    if not base_url:
        return None
        
    import time
    import hmac
    import hashlib
    expires = int(time.time()) + expires_in_seconds
    message = f"{relative_path}:{expires}".encode()
    sig = hmac.new(settings.SECRET_KEY.encode(), message, hashlib.sha256).hexdigest()
    return f"{base_url}?expires={expires}&sig={sig}"


def build_share_url(token: str) -> str:
    """Builds the full shareable URL for a Share Link token — see
    SHARE_LINK_BASE_URL/SHARE_LINK_PATH_PREFIX in core/config.py.
    """
    return f"{settings.share_link_base_url}{settings.SHARE_LINK_PATH_PREFIX}/{token}"


def duplicate_media_files(
    *, owner_id: uuid.UUID, new_media_id: uuid.UUID, original_relative_path: str, thumbnail_relative_path: str | None
) -> tuple[str, str | None]:
    """Copies an existing media's original (and thumbnail, if any) into a
    brand-new media folder/key for `new_media_id`. Used by POST
    /media/{id}/copy to give the duplicate its own bytes rather than
    pointing two rows at the same file — so favoriting, trashing, or
    permanently deleting one copy never touches the other.

    Raises FileNotFoundError if the source original is missing.
    """
    new_suffix = Path(original_relative_path).suffix
    new_original_relative = f"{owner_id}/{new_media_id}/original{new_suffix}"
    new_thumb_relative = None

    if _use_r2():
        client = _r2_client()
        bucket = settings.R2_BUCKET_NAME
        try:
            client.head_object(Bucket=bucket, Key=original_relative_path)
        except Exception:
            raise FileNotFoundError(original_relative_path)
        client.copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": original_relative_path},
            Key=new_original_relative,
        )
        if thumbnail_relative_path:
            try:
                client.head_object(Bucket=bucket, Key=thumbnail_relative_path)
                new_thumb_relative = f"{owner_id}/{new_media_id}/thumbnail.jpg"
                client.copy_object(
                    Bucket=bucket,
                    CopySource={"Bucket": bucket, "Key": thumbnail_relative_path},
                    Key=new_thumb_relative,
                )
            except Exception:
                pass
        return new_original_relative, new_thumb_relative

    src_original = _storage_root() / original_relative_path
    if not src_original.exists():
        raise FileNotFoundError(original_relative_path)

    dest_dir = _media_dir(owner_id, new_media_id)
    dest_original = dest_dir / f"original{src_original.suffix}"
    shutil.copyfile(src_original, dest_original)

    if thumbnail_relative_path:
        src_thumb = _storage_root() / thumbnail_relative_path
        if src_thumb.exists():
            dest_thumb = dest_dir / "thumbnail.jpg"
            shutil.copyfile(src_thumb, dest_thumb)
            new_thumb_relative = str(dest_thumb.relative_to(_storage_root()))

    return str(dest_original.relative_to(_storage_root())), new_thumb_relative


def _copy_stored_object(src_relative: str, dest_relative: str) -> None:
    """Copies one stored object to another key/path on whichever backend
    is active, leaving the source untouched. Backend-agnostic building
    block for the pre-edit backup/restore pair below — same "copy,
    don't move" reasoning as duplicate_media_files, just within one
    media item's own folder instead of into a brand-new one.

    Raises FileNotFoundError if the source doesn't exist.
    """
    if _use_r2():
        client = _r2_client()
        bucket = settings.R2_BUCKET_NAME
        try:
            client.head_object(Bucket=bucket, Key=src_relative)
        except Exception:
            raise FileNotFoundError(src_relative)
        client.copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": src_relative},
            Key=dest_relative,
        )
        return

    src = _storage_root() / src_relative
    if not src.exists():
        raise FileNotFoundError(src_relative)
    dest = _storage_root() / dest_relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)


def get_stored_file_size(relative_path: str | None) -> int:
    """Returns the current size in bytes of a stored object, or 0 if it's
    missing/unreadable. Used after replace/revert operations to keep
    Media.size_bytes accurate without threading a size value through
    every call site.
    """
    if not relative_path:
        return 0
    if _use_r2():
        try:
            resp = _r2_client().head_object(Bucket=settings.R2_BUCKET_NAME, Key=relative_path)
            return resp.get("ContentLength", 0)
        except Exception:
            return 0
    path = _storage_root() / relative_path
    try:
        return path.stat().st_size
    except Exception:
        return 0


def backup_media_original(
    *, owner_id: uuid.UUID, media_id: uuid.UUID, original_relative_path: str, thumbnail_relative_path: str | None
) -> tuple[str, str | None]:
    """Copies the current original (+ thumbnail, if any) into "pre_edit_*"
    keys alongside it, so a later destructive overwrite can be undone
    via restore_media_original. Callers (see PUT /media/{id}/file)
    should only invoke this the *first* time a media item is
    overwritten — doing it again would clobber a true original with an
    already-edited version.

    Raises FileNotFoundError if the current original is missing.
    """
    suffix = Path(original_relative_path).suffix
    backup_original = f"{owner_id}/{media_id}/pre_edit_original{suffix}"
    _copy_stored_object(original_relative_path, backup_original)

    backup_thumb = None
    if thumbnail_relative_path:
        try:
            candidate = f"{owner_id}/{media_id}/pre_edit_thumbnail.jpg"
            _copy_stored_object(thumbnail_relative_path, candidate)
            backup_thumb = candidate
        except FileNotFoundError:
            # Thumbnail missing shouldn't block backing up the original.
            backup_thumb = None

    return backup_original, backup_thumb


def restore_media_original(
    *,
    owner_id: uuid.UUID,
    media_id: uuid.UUID,
    pre_edit_file_path: str,
    pre_edit_thumbnail_path: str | None,
    current_file_path: str,
    current_thumbnail_path: str | None,
) -> tuple[str, str | None]:
    """Moves the pre-edit backup back into the main original/thumbnail
    keys (Revert to Original), removing whatever edited version and
    backup copy are left over afterwards. Returns (restored_file_path,
    restored_thumbnail_path) for the caller to write onto the Media row.

    Raises FileNotFoundError if the backup original is missing.
    """
    suffix = Path(pre_edit_file_path).suffix
    restored_original = f"{owner_id}/{media_id}/original{suffix}"
    _copy_stored_object(pre_edit_file_path, restored_original)
    if restored_original != current_file_path:
        delete_stored_file(current_file_path)
    delete_stored_file(pre_edit_file_path)

    restored_thumb = None
    if pre_edit_thumbnail_path:
        try:
            candidate = f"{owner_id}/{media_id}/thumbnail.jpg"
            _copy_stored_object(pre_edit_thumbnail_path, candidate)
            restored_thumb = candidate
            if restored_thumb != current_thumbnail_path:
                delete_stored_file(current_thumbnail_path)
        except FileNotFoundError:
            restored_thumb = None
        delete_stored_file(pre_edit_thumbnail_path)

    return restored_original, restored_thumb


def replace_media_original(
    *, owner_id: uuid.UUID, media_id: uuid.UUID, upload: UploadFile, old_original_relative_path: str
) -> tuple[str, int]:
    """Overwrites this media's original file with newly-uploaded bytes
    (Overwrite Original). Reuses save_upload's streaming/size-cap logic
    since the destination key format is identical; if the new file's
    extension differs from the old one (e.g. exported to a different
    format), the stale old-extension file is removed afterward so
    nothing orphaned is left on disk/in the bucket.
    """
    new_relative_path, size = save_upload(owner_id=owner_id, media_id=media_id, upload=upload)
    if new_relative_path != old_original_relative_path:
        delete_stored_file(old_original_relative_path)
    return new_relative_path, size


def delete_stored_file(relative_path: str | None) -> None:
    if not relative_path:
        return
    if _use_r2():
        try:
            _r2_client().delete_object(Bucket=settings.R2_BUCKET_NAME, Key=relative_path)
        except Exception:
            logger.exception("Failed to delete R2 object %s", relative_path)
        return

    path = _storage_root() / relative_path
    try:
        path.unlink(missing_ok=True)
    except Exception:
        logger.exception("Failed to delete stored file %s", relative_path)


def delete_media_folder(owner_id: uuid.UUID, media_id: uuid.UUID) -> None:
    """Removes every object under <owner_id>/<media_id>/ (original +
    thumbnail together) — used on permanent delete.
    """
    prefix = f"{owner_id}/{media_id}/"
    if _use_r2():
        client = _r2_client()
        bucket = settings.R2_BUCKET_NAME
        try:
            resp = client.list_objects_v2(Bucket=bucket, Prefix=prefix)
            keys = [{"Key": obj["Key"]} for obj in resp.get("Contents", [])]
            if keys:
                client.delete_objects(Bucket=bucket, Delete={"Objects": keys})
        except Exception:
            logger.exception("Failed to delete R2 folder %s", prefix)
        return

    d = _storage_root() / str(owner_id) / str(media_id)
    shutil.rmtree(d, ignore_errors=True)