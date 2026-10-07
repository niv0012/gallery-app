"""Auto-delete scheduler — permanently removes Media rows (and their
stored files) that are older than ``settings.MEDIA_RETENTION_HOURS``.

Designed to be called from a long-running asyncio background task
started in ``app/main.py``'s lifespan, **not** from a request handler.

The deletion path is identical to the manual ``POST /media/{id}/permanent``
endpoint so both code paths stay in sync:
  1. ``delete_media_folder(owner_id, media_id)`` -- wipes original +
     thumbnail from local disk *or* R2, whichever backend is active.
  2. ``db.delete(media)`` + ``db.commit()`` -- removes the DB row,
     which cascades to any child rows (likes, comments, face embeddings,
     download events) via the FK ``ondelete`` rules in the schema.

Both active media **and** already-trashed (``is_deleted=True``) media
older than the cutoff are deleted -- there is no reason to keep trashed
files around once the retention window closes.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.core.config import settings
from app.core.storage import delete_media_folder
from app.db.session import SessionLocal
from app.models.gallery import Media, Album, Folder
from app.api.routes.zip_jobs import run_zip_cleanup


logger = logging.getLogger(__name__)

# How long the scheduler sleeps between runs. One hour is a reasonable
# resolution -- the retention window is measured in hours, so this means
# a file will be deleted within at most one hour after its window closes.
_CHECK_INTERVAL_SECONDS = 3600  # 1 hour


def run_auto_delete() -> int:
    """Runs one sweep of the auto-delete job synchronously.

    Opens its own DB session (safe to call from a background thread or
    an asyncio task via ``asyncio.to_thread``), finds every Media row
    older than the retention cutoff, deletes its files, and removes the
    DB row.

    Returns the number of items permanently deleted this run.
    """
    if not settings.AUTO_DELETE_ENABLED:
        return 0

    # Use timezone-aware cutoff for comparison.
    cutoff = datetime.now(timezone.utc) - timedelta(hours=settings.MEDIA_RETENTION_HOURS)
    
    logger.info(
        "[AUTO_DELETE] Starting sweep. Retention: %d h -- deleting media created before %s",
        settings.MEDIA_RETENTION_HOURS,
        cutoff.isoformat(),
    )

    deleted_count = 0
    error_count = 0
    trash_deleted_count = 0

    db = SessionLocal()
    try:
        # Fetch all media (active and trashed) older than the cutoff.
        old_media = db.execute(
            select(Media).where(Media.created_at <= cutoff)
        ).scalars().all()


        logger.info("[AUTO_DELETE] Found %d item(s) past retention cutoff.", len(old_media))

        for media in old_media:
            try:
                # 1. Remove files from storage (local disk or R2).
                delete_media_folder(media.owner_id, media.id)
                # 2. Remove the DB row (cascades to likes/comments/embeddings).
                db.delete(media)
                deleted_count += 1
            except Exception:
                logger.exception(
                    "[AUTO_DELETE] Failed to delete media id=%s (owner=%s)",
                    media.id,
                    media.owner_id,
                )
                error_count += 1

        # Trash Purge: 30 days
        trash_cutoff = datetime.now(timezone.utc) - timedelta(days=30)
        
        old_trashed_media = db.execute(
            select(Media).where(Media.deleted_at <= trash_cutoff)
        ).scalars().all()
        for media in old_trashed_media:
            try:
                delete_media_folder(media.owner_id, media.id)
                db.delete(media)
                trash_deleted_count += 1
            except Exception:
                logger.exception("[AUTO_DELETE] Failed to purge trashed media id=%s", media.id)
                error_count += 1

        old_trashed_albums = db.execute(
            select(Album).where(Album.deleted_at <= trash_cutoff)
        ).scalars().all()
        for album in old_trashed_albums:
            db.delete(album)
            trash_deleted_count += 1

        old_trashed_folders = db.execute(
            select(Folder).where(Folder.deleted_at <= trash_cutoff)
        ).scalars().all()
        for folder in old_trashed_folders:
            db.delete(folder)
            trash_deleted_count += 1

        db.commit()
    except Exception:
        logger.exception("[AUTO_DELETE] Unhandled error during auto-delete sweep -- rolling back.")
        db.rollback()
    finally:
        db.close()

    logger.info(
        "[AUTO_DELETE] Sweep complete. Retention Deleted: %d, Trash Purged: %d, Errors: %d",
        deleted_count,
        trash_deleted_count,
        error_count,
    )
    
    try:
        zip_deleted = run_zip_cleanup()
        if zip_deleted > 0:
            logger.info("[AUTO_DELETE] Cleaned up %d expired/failed ZIP jobs.", zip_deleted)
    except Exception:
        logger.exception("[AUTO_DELETE] Error during ZIP cleanup.")

    return deleted_count + trash_deleted_count


async def auto_delete_loop() -> None:
    """Long-running asyncio coroutine -- runs ``run_auto_delete()`` once
    on startup, then sleeps for ``_CHECK_INTERVAL_SECONDS`` and repeats.

    Runs the synchronous DB/file work in a thread pool via
    ``asyncio.to_thread`` so it never blocks the event loop.

    Intended to be started as a background task from the FastAPI
    ``lifespan`` context manager and cancelled on shutdown.
    """
    logger.info(
        "[AUTO_DELETE] Scheduler started. Retention=%d h, interval=%d s, enabled=%s",
        settings.MEDIA_RETENTION_HOURS,
        _CHECK_INTERVAL_SECONDS,
        settings.AUTO_DELETE_ENABLED,
    )
    while True:
        try:
            await asyncio.to_thread(run_auto_delete)
        except asyncio.CancelledError:
            logger.info("[AUTO_DELETE] Scheduler cancelled -- shutting down.")
            raise
        except Exception:
            # Catch-all so a transient error (e.g. DB unreachable) does not
            # kill the scheduler permanently -- it will retry next interval.
            logger.exception("[AUTO_DELETE] Unexpected error in scheduler loop.")

        try:
            await asyncio.sleep(_CHECK_INTERVAL_SECONDS)
        except asyncio.CancelledError:
            logger.info("[AUTO_DELETE] Scheduler sleep interrupted -- shutting down.")
            raise
