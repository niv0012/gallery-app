import logging
import uuid
from typing import Any
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy import select
import sqlalchemy as sa
from sqlalchemy.orm import Session

from app.api.deps import get_current_studio_user, get_current_user, require_active_plan
from app.core.activity_log import log_activity
from app.core.face_index import index_media_background
from app.core.storage import (
    backup_media_original,
    delete_media_folder,
    duplicate_media_files,
    get_image_dimensions,
    get_stored_file_size,
    get_video_duration_ms,
    make_thumbnail,
    make_video_thumbnail,
    media_type_for_content_type,
    replace_media_original,
    restore_media_original,
    save_upload,
    get_signed_original_url,
)
from app.core.rules import get_effective_rules
from app.core.transcode_worker import process_video_upload_background
from app.core.visibility import is_visible_to_client
from app.db.session import get_db
from app.models.activity_log import ActivityType
from app.models.album_share import AlbumClientShare
from app.models.connection import ConnectionStatus, StudioClientConnection
from app.models.gallery import Album, Folder, Media, MediaComment, MediaLike, MediaType
from app.models.notification import Notification, NotificationType
from app.models.user import User, UserRole
from app.schemas.gallery import (
    MediaCommentCreate,
    MediaCommentRead,
    MediaCommentUpdate,
    MediaLikeRead,
    MediaLikeToggleResponse,
    MediaRead,
    MediaUpdate,
    MediaPageRead,
    MediaCountsRead,
)
from app.schemas.user import MessageResponse

router = APIRouter(prefix="/media", tags=["gallery-media"])
logger = logging.getLogger(__name__)


def _get_owned_media(db: Session, media_id: uuid.UUID, owner_id: uuid.UUID) -> Media:
    media = db.get(Media, media_id)
    if media is None or media.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media not found")
    return media


def _get_accessible_media(db: Session, media_id: uuid.UUID, current_user: User) -> Media:
    """Access check for Likes/Comments (Task 23) — the only two media
    actions a client should be able to take on a studio's gallery, since
    liking/commenting doesn't touch the studio's own working library the
    way upload/edit/trash do (those stay behind `get_current_studio_user`
    above, unchanged).

    A studio must own the media outright, same as `_get_owned_media`. A
    client is let in if either relationship `albums.py`'s
    `/shared-with-me` and `client_gallery.py` already gate on is active
    for this specific album: an accepted `StudioClientConnection` with
    the media's owning studio, or a non-revoked `AlbumClientShare` for
    that exact album. Trashed media is never reachable this way.
    """
    media = db.get(Media, media_id)
    if media is None or media.is_deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media not found")

    if current_user.role == UserRole.photographer:
        if media.owner_id != current_user.id:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media not found")
        return media

    # Client: needs an album to check access against — media sitting
    # loose in a studio's unfiled library was never shared with anyone.
    if media.album_id is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media not found")

    has_connection = db.execute(
        select(StudioClientConnection.id).where(
            StudioClientConnection.studio_id == media.owner_id,
            StudioClientConnection.client_id == current_user.id,
            StudioClientConnection.status == ConnectionStatus.accepted,
        )
    ).scalars().first() is not None

    has_share = db.execute(
        select(AlbumClientShare.id).where(
            AlbumClientShare.album_id == media.album_id,
            AlbumClientShare.client_id == current_user.id,
            AlbumClientShare.revoked_at.is_(None),
        )
    ).scalars().first() is not None

    if not (has_connection or has_share):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media not found")

    if not is_visible_to_client(db, album_id=media.album_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media not found")

    return media


def _like_info_for(
    db: Session, media_ids: list[uuid.UUID], user_id: uuid.UUID
) -> tuple[dict[uuid.UUID, int], set[uuid.UUID]]:
    """Batch-fetches like counts and this user's liked-state for a set of
    media items in two queries total (not one per item), so list/detail
    responses can seed `like_count`/`is_liked_by_me` without an N+1.
    """
    if not media_ids:
        return {}, set()

    counts_rows = db.execute(
        select(MediaLike.media_id, sa.func.count())
        .where(MediaLike.media_id.in_(media_ids))
        .group_by(MediaLike.media_id)
    ).all()
    counts = {media_id: count for media_id, count in counts_rows}

    liked_rows = db.execute(
        select(MediaLike.media_id).where(
            MediaLike.media_id.in_(media_ids),
            MediaLike.user_id == user_id,
        )
    ).scalars().all()
    liked = set(liked_rows)

    return counts, liked


def _comment_count_for(db: Session, media_ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    """Batch-fetches comment counts (top-level + replies, nothing is
    soft-deleted on `MediaComment`) for a set of media items in one
    query — same shape/purpose as `_like_info_for` above, kept separate
    since callers that only need likes (e.g. the like-toggle response)
    shouldn't pay for a comment-count query they don't use.
    """
    if not media_ids:
        return {}

    rows = db.execute(
        select(MediaComment.media_id, sa.func.count())
        .where(MediaComment.media_id.in_(media_ids))
        .group_by(MediaComment.media_id)
    ).all()
    return {media_id: count for media_id, count in rows}


@router.post("/upload", response_model=MediaRead, status_code=status.HTTP_201_CREATED)
def upload_media(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
) -> MediaRead:
    """Uploads one photo/video. Multipart form: `file` is required;
    `album_id`/`folder_id` are optional query params — omit both to
    upload as "unfiled" media, same as an album/folder with no link.

    The file is written to disk and a Media row is committed only if
    both succeed; if the row insert fails after the file was saved, the
    orphaned file is cleaned up rather than left dangling.
    """
    if album_id is not None:
        album = db.get(Album, album_id)
        if album is None or album.owner_id != current_user.id or getattr(album, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Album not found")
    if folder_id is not None:
        folder = db.get(Folder, folder_id)
        if folder is None or folder.owner_id != current_user.id or getattr(folder, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Folder not found")

    content_type = file.content_type or ""
    try:
        media_type = media_type_for_content_type(content_type, filename=file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    media_id = uuid.uuid4()
    try:
        relative_path, size = save_upload(owner_id=current_user.id, media_id=media_id, upload=file)
    except ValueError as e:
        raise HTTPException(status_code=413, detail=str(e))
    except Exception:
        # Disk-full, permission error, storage backend unreachable, etc.
        # Previously unhandled here -> bare "Internal Server Error" with
        # no clue which stage failed. Log the real traceback and give the
        # client an actual message instead of a black box.
        logger.exception("save_upload failed for %s (owner=%s)", file.filename, current_user.id)
        raise HTTPException(status_code=500, detail="Failed to store the uploaded file. Check server logs / disk space.")

    try:
        thumbnail_path = None
        width = height = None
        duration_ms = None
        if media_type == MediaType.photo:
            thumbnail_path = make_thumbnail(
                owner_id=current_user.id, media_id=media_id, original_relative_path=relative_path
            )
            width, height = get_image_dimensions(relative_path)
        elif media_type == MediaType.video:
            # Enqueue the background transcode + thumbnail task for videos.
            # We defer thumbnail creation and duration probing to the worker.
            background_tasks.add_task(
                process_video_upload_background,
                media_id=media_id,
                owner_id=current_user.id,
                relative_path=relative_path,
                media_type=media_type,
            )

        db_file_path = relative_path
        db_file_name = file.filename or "upload"
        db_content_type = content_type

        from app.core.transcode import CONVERTIBLE_EXTENSIONS
        suffix = Path(db_file_name).suffix
        if media_type == MediaType.video and suffix.lower() in CONVERTIBLE_EXTENSIONS:
            db_file_path = f"{current_user.id}/{media_id}/original.mp4"
            db_file_name = str(Path(db_file_name).with_suffix(".mp4"))
            db_content_type = "video/mp4"

        media = Media(
            id=media_id,
            owner_id=current_user.id,
            album_id=album_id,
            folder_id=folder_id,
            media_type=media_type,
            file_name=db_file_name,
            file_path=db_file_path,
            thumbnail_path=thumbnail_path,
            content_type=db_content_type,
            size_bytes=size,
            width=width,
            height=height,
            duration_ms=duration_ms,
        )
        db.add(media)
        log_activity(
            db,
            studio_id=current_user.id,
            type=ActivityType.upload,
            title="New media uploaded",
            subtitle=media.file_name,
        )
        db.commit()
        db.refresh(media)
    except HTTPException:
        raise
    except Exception:
        # Catches thumbnail/dimension bugs, DB commit failures (bad
        # migration state, constraint violation, connection drop) — any
        # of it, not just the commit step. Every branch here now cleans
        # up the orphaned file AND logs the real traceback so the next
        # failure is diagnosable from the server console instead of
        # showing up client-side as a bare "Internal Server Error".
        db.rollback()
        delete_media_folder(current_user.id, media_id)
        logger.exception("upload_media failed after file save for %s (owner=%s)", file.filename, current_user.id)
        raise HTTPException(status_code=500, detail="Failed to save media record. Check server logs for details.")

    if media_type == MediaType.photo:
        # Runs after the response is sent (see core/face_index.py —
        # it opens its own DB session rather than reusing this one).
        background_tasks.add_task(index_media_background, media.id)

    return MediaRead.from_model(media)


def _find_existing_at_destination(
    db: Session,
    *,
    owner_id: uuid.UUID,
    album_id: uuid.UUID | None,
    folder_id: uuid.UUID | None,
    file_name: str,
) -> Media | None:
    query = select(Media).where(
        Media.owner_id == owner_id,
        Media.is_deleted.is_(False),
        Media.file_name == file_name,
        Media.album_id == album_id if album_id is not None else Media.album_id.is_(None),
        Media.folder_id == folder_id if folder_id is not None else Media.folder_id.is_(None),
    )
    return db.execute(query).scalars().first()


@router.post("/{media_id}/copy", response_model=MediaRead, status_code=status.HTTP_201_CREATED)
def copy_media(
    media_id: uuid.UUID,
    background_tasks: BackgroundTasks,
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    duplicate_resolution: str = "auto_rename",
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaRead:
    """Duplicates one media item into a brand-new row with its own copy
    of the original file (and thumbnail, if any) on disk — optionally
    filed into a different album/folder than the source. Omit both
    `album_id`/`folder_id` to duplicate in place (same album/folder as
    the source, or unfiled if the source is unfiled).

    `duplicate_resolution` controls what happens if the destination
    already has an item with the same file name:
    - "auto_rename" (default): append " (1)", " (2)", etc. to the copy's
      name until it's unique at the destination.
    - "skip": don't create anything — return the item already there.
    """
    if duplicate_resolution not in ("auto_rename", "skip"):
        raise HTTPException(
            status_code=400,
            detail='duplicate_resolution must be "auto_rename" or "skip"',
        )

    source = _get_owned_media(db, media_id, current_user.id)

    if album_id is not None:
        album = db.get(Album, album_id)
        if album is None or album.owner_id != current_user.id or getattr(album, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Album not found")
    if folder_id is not None:
        folder = db.get(Folder, folder_id)
        if folder is None or folder.owner_id != current_user.id or getattr(folder, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Folder not found")

    dest_album_id = album_id if album_id is not None else source.album_id
    dest_folder_id = folder_id if folder_id is not None else source.folder_id

    existing = _find_existing_at_destination(
        db,
        owner_id=current_user.id,
        album_id=dest_album_id,
        folder_id=dest_folder_id,
        file_name=source.file_name,
    )

    final_file_name = source.file_name
    if existing is not None:
        if duplicate_resolution == "skip":
            counts, liked = _like_info_for(db, [existing.id], current_user.id)
            return MediaRead.from_model(
                existing, like_count=counts.get(existing.id, 0), is_liked_by_me=existing.id in liked
            )

        stem = Path(source.file_name).stem
        ext = Path(source.file_name).suffix
        n = 1
        while (
            _find_existing_at_destination(
                db,
                owner_id=current_user.id,
                album_id=dest_album_id,
                folder_id=dest_folder_id,
                file_name=f"{stem} ({n}){ext}",
            )
            is not None
        ):
            n += 1
        final_file_name = f"{stem} ({n}){ext}"

    new_id = uuid.uuid4()
    try:
        new_original_path, new_thumb_path = duplicate_media_files(
            owner_id=current_user.id,
            new_media_id=new_id,
            original_relative_path=source.file_path,
            thumbnail_relative_path=source.thumbnail_path,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Original file is missing on disk")

    copy = Media(
        id=new_id,
        owner_id=current_user.id,
        album_id=dest_album_id,
        folder_id=dest_folder_id,
        media_type=source.media_type,
        file_name=final_file_name,
        file_path=new_original_path,
        thumbnail_path=new_thumb_path,
        content_type=source.content_type,
        size_bytes=source.size_bytes,
        width=source.width,
        height=source.height,
        duration_ms=source.duration_ms,
        edit_recipe=source.edit_recipe,
    )
    try:
        db.add(copy)
        db.commit()
        db.refresh(copy)
    except Exception:
        db.rollback()
        delete_media_folder(current_user.id, new_id)
        raise HTTPException(status_code=500, detail="Failed to save duplicated media record")

    if copy.media_type == MediaType.photo:
        background_tasks.add_task(index_media_background, copy.id)

    return MediaRead.from_model(copy)


@router.get("/counts", response_model=MediaCountsRead)
def count_media(
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    unfiled_only: bool = False,
    trashed: bool = False,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaCountsRead:
    query = select(
        sa.func.sum(sa.case((Media.media_type == MediaType.photo, 1), else_=0)),
        sa.func.sum(sa.case((Media.media_type == MediaType.video, 1), else_=0)),
    ).where(Media.owner_id == current_user.id, Media.is_deleted.is_(trashed))
    
    if unfiled_only:
        query = query.where(Media.album_id.is_(None), Media.folder_id.is_(None))
    else:
        if album_id is not None:
            query = query.where(Media.album_id == album_id)
        if folder_id is not None:
            query = query.where(Media.folder_id == folder_id)

    row = db.execute(query).first()
    return MediaCountsRead(
        total_photos=int(row[0] or 0) if row else 0,
        total_videos=int(row[1] or 0) if row else 0,
    )


@router.get("", response_model=list[MediaRead])
def list_media(
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    unfiled_only: bool = False,
    media_type: MediaType | None = None,
    favorites_only: bool = False,
    liked_by_client_id: uuid.UUID | None = None,
    trashed: bool = False,
    cursor: str | None = Query(default=None),
    page_size: int | None = Query(default=None),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[MediaRead]:
    """Returns a flat list of MediaRead items. The `cursor` and `page_size`
    params still work for pagination — pass the returned next offset as
    `cursor` on the next call — but the response shape is always a plain
    JSON array so Flutter callers can cast it directly as List<dynamic>.
    Use GET /media/page for the full paginated envelope {items, total_count,
    next_cursor} if you need it.
    """
    actual_offset = int(cursor) if cursor is not None and cursor.isdigit() else 0
    
    query = select(Media).where(Media.owner_id == current_user.id, Media.is_deleted.is_(trashed))
    
    if unfiled_only:
        query = query.where(Media.album_id.is_(None), Media.folder_id.is_(None))
    else:
        if album_id is not None:
            query = query.where(Media.album_id == album_id)
        if folder_id is not None:
            query = query.where(Media.folder_id == folder_id)
            
    if media_type is not None:
        query = query.where(Media.media_type == media_type)
    if favorites_only:
        query = query.where(Media.is_favorite.is_(True))
    if liked_by_client_id is not None:
        query = query.join(MediaLike, MediaLike.media_id == Media.id).where(MediaLike.user_id == liked_by_client_id)

    query = query.order_by(Media.created_at.desc())
    if page_size is not None:
        query = query.limit(page_size)
    if actual_offset > 0:
        query = query.offset(actual_offset)
    
    items = db.execute(query).scalars().all()

    counts, liked = _like_info_for(db, [m.id for m in items], current_user.id)
    comment_counts = _comment_count_for(db, [m.id for m in items])
    return [
        MediaRead.from_model(
            m,
            like_count=counts.get(m.id, 0),
            is_liked_by_me=m.id in liked,
            comment_count=comment_counts.get(m.id, 0),
        )
        for m in items
    ]


@router.get("/page", response_model=MediaPageRead)
def list_media_page(
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    unfiled_only: bool = False,
    media_type: MediaType | None = None,
    favorites_only: bool = False,
    liked_by_client_id: uuid.UUID | None = None,
    trashed: bool = False,
    cursor: str | None = Query(default=None),
    page_size: int | None = Query(default=None),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaPageRead:
    """Paginated envelope variant of GET /media. Returns
    {items, total_count, next_cursor} for callers that need the full
    pagination metadata.
    """
    actual_offset = int(cursor) if cursor is not None and cursor.isdigit() else 0
    
    query = select(Media).where(Media.owner_id == current_user.id, Media.is_deleted.is_(trashed))
    count_query = select(sa.func.count()).where(Media.owner_id == current_user.id, Media.is_deleted.is_(trashed))
    
    if unfiled_only:
        query = query.where(Media.album_id.is_(None), Media.folder_id.is_(None))
        count_query = count_query.where(Media.album_id.is_(None), Media.folder_id.is_(None))
    else:
        if album_id is not None:
            query = query.where(Media.album_id == album_id)
            count_query = count_query.where(Media.album_id == album_id)
        if folder_id is not None:
            query = query.where(Media.folder_id == folder_id)
            count_query = count_query.where(Media.folder_id == folder_id)
            
    if media_type is not None:
        query = query.where(Media.media_type == media_type)
        count_query = count_query.where(Media.media_type == media_type)
    if favorites_only:
        query = query.where(Media.is_favorite.is_(True))
        count_query = count_query.where(Media.is_favorite.is_(True))
    if liked_by_client_id is not None:
        query = query.join(MediaLike, MediaLike.media_id == Media.id).where(MediaLike.user_id == liked_by_client_id)
        count_query = count_query.join(MediaLike, MediaLike.media_id == Media.id).where(MediaLike.user_id == liked_by_client_id)

    query = query.order_by(Media.created_at.desc())
    if page_size is not None:
        query = query.limit(page_size)
    if actual_offset > 0:
        query = query.offset(actual_offset)
    
    items = db.execute(query).scalars().all()

    counts, liked = _like_info_for(db, [m.id for m in items], current_user.id)
    comment_counts = _comment_count_for(db, [m.id for m in items])
    media_reads = [
        MediaRead.from_model(
            m,
            like_count=counts.get(m.id, 0),
            is_liked_by_me=m.id in liked,
            comment_count=comment_counts.get(m.id, 0),
        )
        for m in items
    ]
    
    total_count = db.execute(count_query).scalar() or 0
    next_cursor = None
    if page_size is not None and actual_offset + page_size < total_count:
        next_cursor = str(actual_offset + page_size)
    
    return MediaPageRead(items=media_reads, total_count=total_count, next_cursor=next_cursor)


@router.get("/liked-by-me", response_model=list[MediaRead])
def list_liked_media(
    limit: int = Query(default=50000),
    offset: int = 0,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[MediaRead]:
    """Every media item the current user has liked, most-recently-liked
    first — the actual client-safe "Favorites" data source.

    A studio's own `is_favorite` flag (used by `GET /media?favorites_only`)
    is a curation tool on their *own* working library and stays
    studio-only; a client has no such flag to read. Liking (Task 23) is
    the one favorite-like signal a client can both set and see, so this
    endpoint is what `ClientSavedGalleriesScreen` should call instead of
    the old broken `GET /media?favorites_only` (owner-only, 403s for a
    client — see that screen's docstring).

    Re-checks access per row rather than trusting the historical like:
    a studio always sees only its own media (same as everywhere else in
    this file); a client only sees media whose album still has an
    active connection or share — a like made before a connection was
    later revoked shouldn't keep surfacing that studio's photo here.
    """
    liked_media_ids = list(
        db.execute(
            select(MediaLike.media_id)
            .where(MediaLike.user_id == current_user.id)
            .order_by(MediaLike.created_at.desc())
        ).scalars().all()
    )
    if not liked_media_ids:
        return []

    media_by_id = {
        m.id: m
        for m in db.execute(
            select(Media).where(Media.id.in_(liked_media_ids), Media.is_deleted.is_(False))
        ).scalars().all()
    }

    if current_user.role == UserRole.photographer:
        accessible_ids = [
            mid for mid in liked_media_ids
            if mid in media_by_id and media_by_id[mid].owner_id == current_user.id
        ]
    else:
        connected_studio_ids = set(
            db.execute(
                select(StudioClientConnection.studio_id).where(
                    StudioClientConnection.client_id == current_user.id,
                    StudioClientConnection.status == ConnectionStatus.accepted,
                )
            ).scalars().all()
        )
        shared_album_ids = set(
            db.execute(
                select(AlbumClientShare.album_id).where(
                    AlbumClientShare.client_id == current_user.id,
                    AlbumClientShare.revoked_at.is_(None),
                )
            ).scalars().all()
        )
        accessible_ids = [
            mid for mid in liked_media_ids
            if mid in media_by_id
            and media_by_id[mid].album_id is not None
            and (
                media_by_id[mid].owner_id in connected_studio_ids
                or media_by_id[mid].album_id in shared_album_ids
            )
            and is_visible_to_client(db, album_id=media_by_id[mid].album_id)
        ]

    # Keep this endpoint's own most-recently-liked ordering rather than
    # `_media_counts`-style re-sorting — `liked_media_ids` is already in
    # that order from the query above.
    accessible_ids = accessible_ids[offset : offset + limit]

    counts, liked = _like_info_for(db, accessible_ids, current_user.id)
    comment_counts = _comment_count_for(db, accessible_ids)
    return [
        MediaRead.from_model(
            media_by_id[mid],
            like_count=counts.get(mid, 0),
            is_liked_by_me=mid in liked,
            comment_count=comment_counts.get(mid, 0),
        )
        for mid in accessible_ids
    ]


@router.get("/{media_id}", response_model=MediaRead)
def get_media(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaRead:
    media = _get_owned_media(db, media_id, current_user.id)
    counts, liked = _like_info_for(db, [media.id], current_user.id)
    comment_counts = _comment_count_for(db, [media.id])
    return MediaRead.from_model(
        media,
        like_count=counts.get(media.id, 0),
        is_liked_by_me=media.id in liked,
        comment_count=comment_counts.get(media.id, 0),
    )


@router.patch("/{media_id}", response_model=MediaRead)
def update_media(
    media_id: uuid.UUID,
    payload: MediaUpdate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaRead:
    """Moves media between albums/folders, toggles favorite, and/or
    saves a non-destructive edit recipe. Trashed media can still be
    updated (e.g. un-favorited) — use POST /media/{id}/restore to bring
    it out of Trash.
    """
    media = _get_owned_media(db, media_id, current_user.id)
    updates = payload.model_dump(
        exclude_unset=True, exclude={"clear_album", "clear_folder", "clear_edit_recipe"}
    )

    if payload.clear_album:
        media.album_id = None
    elif "album_id" in updates and updates["album_id"] is not None:
        album = db.get(Album, updates["album_id"])
        if album is None or album.owner_id != current_user.id or getattr(album, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Album not found")
        media.album_id = updates["album_id"]

    if payload.clear_folder:
        media.folder_id = None
    elif "folder_id" in updates and updates["folder_id"] is not None:
        folder = db.get(Folder, updates["folder_id"])
        if folder is None or folder.owner_id != current_user.id or getattr(folder, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Folder not found")
        media.folder_id = updates["folder_id"]

    if "is_favorite" in updates and updates["is_favorite"] is not None:
        media.is_favorite = updates["is_favorite"]

    if "file_name" in updates and updates["file_name"] is not None:
        new_name = updates["file_name"].strip()
        if not new_name:
            raise HTTPException(status_code=400, detail="File name cannot be empty")
        if new_name != media.file_name:
            # Effective destination is whatever album/folder the media
            # will end up in after the moves above are applied.
            conflict = _find_existing_at_destination(
                db,
                owner_id=current_user.id,
                album_id=media.album_id,
                folder_id=media.folder_id,
                file_name=new_name,
            )
            if conflict is not None and conflict.id != media.id:
                raise HTTPException(status_code=409, detail="An item with that name already exists here")
            media.file_name = new_name

    if payload.clear_edit_recipe:
        media.edit_recipe = None
    elif "edit_recipe" in updates and updates["edit_recipe"] is not None:
        media.edit_recipe = updates["edit_recipe"]

    db.commit()
    db.refresh(media)
    counts, liked = _like_info_for(db, [media.id], current_user.id)
    comment_counts = _comment_count_for(db, [media.id])
    return MediaRead.from_model(
        media,
        like_count=counts.get(media.id, 0),
        is_liked_by_me=media.id in liked,
        comment_count=comment_counts.get(media.id, 0),
    )


@router.put("/{media_id}/file", response_model=MediaRead)
def replace_media_file(
    media_id: uuid.UUID,
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaRead:
    """Destructively overwrites a photo's original file in place — the
    photo editor's "Overwrite Original" / "Save as Copy over original"
    actions, as opposed to PATCH's non-destructive `edit_recipe`.

    The very first time this is called for a given media item, its
    current file (+ thumbnail, if any) are backed up into
    `pre_edit_file_path`/`pre_edit_thumbnail_path` first, so
    POST /media/{id}/revert can undo it later. Later calls leave that
    backup alone on purpose — it should always point at the *true*
    original, never at some already-edited intermediate version.
    """
    media = _get_owned_media(db, media_id, current_user.id)
    if media.media_type != MediaType.photo:
        raise HTTPException(status_code=400, detail="Only photos can be overwritten via this endpoint")

    content_type = file.content_type or media.content_type
    try:
        media_type_for_content_type(content_type, filename=file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if media.pre_edit_file_path is None:
        try:
            backup_path, backup_thumb = backup_media_original(
                owner_id=current_user.id,
                media_id=media.id,
                original_relative_path=media.file_path,
                thumbnail_relative_path=media.thumbnail_path,
            )
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail="Original file is missing on disk")
        media.pre_edit_file_path = backup_path
        media.pre_edit_thumbnail_path = backup_thumb

    try:
        new_path, size = replace_media_original(
            owner_id=current_user.id,
            media_id=media.id,
            upload=file,
            old_original_relative_path=media.file_path,
        )
    except ValueError as e:
        db.rollback()
        raise HTTPException(status_code=413, detail=str(e))
    except Exception:
        db.rollback()
        logger.exception("replace_media_file failed to store new bytes for %s", media.id)
        raise HTTPException(status_code=500, detail="Failed to store the replacement file. Check server logs.")

    media.file_path = new_path
    media.size_bytes = size
    media.content_type = content_type
    media.thumbnail_path = make_thumbnail(
        owner_id=current_user.id, media_id=media.id, original_relative_path=new_path
    )
    media.width, media.height = get_image_dimensions(new_path)
    # The uploaded bytes already have the current edit recipe baked in,
    # so carrying the old recipe forward would double-apply it the next
    # time this media is rendered/edited. Same reasoning as revert_media
    # clearing it.
    media.edit_recipe = None

    try:
        db.commit()
        db.refresh(media)
    except Exception:
        db.rollback()
        logger.exception("replace_media_file failed to save media record for %s", media.id)
        raise HTTPException(status_code=500, detail="Failed to save media record. Check server logs.")

    # Re-index the new pixels for face search, same as a fresh upload.
    background_tasks.add_task(index_media_background, media.id)

    counts, liked = _like_info_for(db, [media.id], current_user.id)
    comment_counts = _comment_count_for(db, [media.id])
    return MediaRead.from_model(
        media,
        like_count=counts.get(media.id, 0),
        is_liked_by_me=media.id in liked,
        comment_count=comment_counts.get(media.id, 0),
    )


@router.post("/{media_id}/revert", response_model=MediaRead)
def revert_media(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaRead:
    """Undoes a destructive overwrite by restoring the pre-edit backup
    captured the first time this media was overwritten (see PUT
    /media/{id}/file), and clears the non-destructive edit recipe too —
    after this call the media is back to exactly how it looked before
    any editing.
    """
    media = _get_owned_media(db, media_id, current_user.id)
    if media.pre_edit_file_path is None:
        raise HTTPException(status_code=400, detail="Nothing to revert — this media was never overwritten")

    try:
        restored_path, restored_thumb = restore_media_original(
            owner_id=current_user.id,
            media_id=media.id,
            pre_edit_file_path=media.pre_edit_file_path,
            pre_edit_thumbnail_path=media.pre_edit_thumbnail_path,
            current_file_path=media.file_path,
            current_thumbnail_path=media.thumbnail_path,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Backup file is missing on disk")

    media.file_path = restored_path
    media.thumbnail_path = restored_thumb
    media.size_bytes = get_stored_file_size(restored_path)
    media.width, media.height = get_image_dimensions(restored_path)
    media.pre_edit_file_path = None
    media.pre_edit_thumbnail_path = None
    media.edit_recipe = None

    try:
        db.commit()
        db.refresh(media)
    except Exception:
        db.rollback()
        logger.exception("revert_media failed to save media record for %s", media.id)
        raise HTTPException(status_code=500, detail="Failed to save media record. Check server logs.")

    counts, liked = _like_info_for(db, [media.id], current_user.id)
    comment_counts = _comment_count_for(db, [media.id])
    return MediaRead.from_model(
        media,
        like_count=counts.get(media.id, 0),
        is_liked_by_me=media.id in liked,
        comment_count=comment_counts.get(media.id, 0),
    )


@router.delete("/{media_id}", response_model=MessageResponse)
def trash_media(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Soft-deletes (moves to Trash). Files on disk are untouched until
    a permanent delete via POST /media/{id}/permanent-delete or
    DELETE /media/trash/empty.
    """
    media = _get_owned_media(db, media_id, current_user.id)
    media.is_deleted = True
    media.deleted_at = datetime.now(timezone.utc)
    db.commit()
    return MessageResponse(message="Moved to Trash.")


@router.post("/{media_id}/restore", response_model=MediaRead)
def restore_media(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MediaRead:
    media = _get_owned_media(db, media_id, current_user.id)
    if not media.is_deleted:
        raise HTTPException(status_code=400, detail="Media is not in Trash")
    media.is_deleted = False
    media.deleted_at = None
    db.commit()
    db.refresh(media)
    counts, liked = _like_info_for(db, [media.id], current_user.id)
    comment_counts = _comment_count_for(db, [media.id])
    return MediaRead.from_model(
        media,
        like_count=counts.get(media.id, 0),
        is_liked_by_me=media.id in liked,
        comment_count=comment_counts.get(media.id, 0),
    )


@router.delete("/{media_id}/permanent", response_model=MessageResponse)
def permanent_delete_media(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Irreversibly deletes the DB row AND the original/thumbnail files
    on disk. Only allowed while the item is already in Trash, as a
    speed bump against deleting something by accident.
    """
    media = _get_owned_media(db, media_id, current_user.id)
    if not media.is_deleted:
        raise HTTPException(status_code=400, detail="Move to Trash first before permanently deleting")

    delete_media_folder(current_user.id, media.id)
    db.delete(media)
    db.commit()
    return MessageResponse(message="Permanently deleted.")


@router.delete("/trash/empty", response_model=MessageResponse)
def empty_trash(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Permanently deletes every item currently in this studio's Trash —
    both the DB rows and the files on disk.
    """
    trashed = db.execute(
        select(Media).where(Media.owner_id == current_user.id, Media.is_deleted.is_(True))
    ).scalars().all()

    for media in trashed:
        delete_media_folder(current_user.id, media.id)
        db.delete(media)
    db.commit()

    return MessageResponse(message=f"Permanently deleted {len(trashed)} item(s) from Trash.")


# ---------------------------------------------------------------------------
# Media Likes (Task 23)
# ---------------------------------------------------------------------------


@router.post("/{media_id}/like", response_model=MediaLikeToggleResponse)
def toggle_like(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MediaLikeToggleResponse:
    """Toggles a like on a media item. If the current user already liked
    this media, the like is removed; otherwise it's added. Returns the
    resulting `liked` state and the new `like_count` so the client can
    update its UI atomically without a separate fetch.

    Open to both studios (their own media) and clients (media in an
    album shared with them) — see `_get_accessible_media`.
    """
    media = _get_accessible_media(db, media_id, current_user)

    existing = db.execute(
        select(MediaLike).where(
            MediaLike.media_id == media_id,
            MediaLike.user_id == current_user.id,
        )
    ).scalars().first()

    if existing is not None:
        db.delete(existing)
        liked = False
    else:
        like = MediaLike(media_id=media_id, user_id=current_user.id)
        db.add(like)
        liked = True
        
        if current_user.id != media.owner_id:
            notification = Notification(
                user_id=media.owner_id,
                type=NotificationType.gallery,
                title="New Like",
                subtitle=f"{current_user.full_name} liked a photo.",
                data={"media_id": str(media_id), "album_id": str(media.album_id)}
            )
            db.add(notification)

    db.commit()

    like_count = db.execute(
        select(sa.func.count()).select_from(MediaLike).where(MediaLike.media_id == media_id)
    ).scalar() or 0

    return MediaLikeToggleResponse(liked=liked, like_count=like_count)


@router.get("/{media_id}/likes", response_model=list[MediaLikeRead])
def list_likes(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[MediaLikeRead]:
    """Returns the list of user ids who liked this media item. Primarily
    used for analytics; the UI itself only needs the count (from the
    like-toggle response) and the `liked_by_me` boolean (checked locally
    against the current user's id).
    """
    _get_accessible_media(db, media_id, current_user)

    rows = db.execute(
        select(MediaLike, User)
        .join(User, MediaLike.user_id == User.id)
        .where(MediaLike.media_id == media_id)
        .order_by(MediaLike.created_at.desc())
    ).all()

    return [MediaLikeRead.from_model(l, user_full_name=u.full_name) for l, u in rows]


# ---------------------------------------------------------------------------
# Media Comments (Task 23)
# ---------------------------------------------------------------------------


@router.post("/{media_id}/comments", response_model=MediaCommentRead, status_code=status.HTTP_201_CREATED)
def create_comment(
    media_id: uuid.UUID,
    payload: MediaCommentCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MediaCommentRead:
    """Adds a comment (or reply) to a media item. Open to both studios
    and clients viewing a shared album — see `_get_accessible_media`.
    """
    media = _get_accessible_media(db, media_id, current_user)

    if payload.parent_id is not None:
        parent = db.get(MediaComment, payload.parent_id)
        if parent is None or parent.media_id != media_id:
            raise HTTPException(status_code=404, detail="Parent comment not found")

    comment = MediaComment(
        media_id=media_id,
        user_id=current_user.id,
        parent_id=payload.parent_id,
        text=payload.text,
    )
    db.add(comment)
    
    if current_user.id != media.owner_id:
        notification = Notification(
            user_id=media.owner_id,
            type=NotificationType.gallery,
            title="New Comment",
            subtitle=f"{current_user.full_name} commented on a photo.",
            data={"media_id": str(media_id), "album_id": str(media.album_id), "comment_id": str(comment.id)}
        )
        db.add(notification)
    db.commit()
    db.refresh(comment)

    return MediaCommentRead.from_model(comment, user_full_name=current_user.full_name)


@router.get("/{media_id}/original-url")
def get_media_original_url(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Returns a short-lived presigned URL (or static local URL) for downloading
    the uncompressed original file. Clients check folder rules; studios bypass them.
    """
    media = _get_accessible_media(db, media_id, current_user)
    
    if current_user.role == UserRole.client and current_user.id != media.owner_id:
        album = db.get(Album, media.album_id) if media.album_id else None
        folder_id = album.folder_id if album else None
        effective_rules = get_effective_rules(db, folder_id, None)
        if not effective_rules["allow_download"] or effective_rules["show_watermark"]:
            raise HTTPException(
                status_code=403, 
                detail="Original downloads are disabled or watermark is enabled for this photo."
            )

    url = get_signed_original_url(media.file_path)
    if not url:
        raise HTTPException(status_code=404, detail="Original file not found")
    return {"url": url}



@router.get("/{media_id}/comments", response_model=list[MediaCommentRead])
def list_comments(
    media_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[MediaCommentRead]:
    """Lists all comments for a media item — both top-level and replies —
    ordered by creation time (oldest first) so the client can thread them
    by `parent_id`.
    """
    _get_accessible_media(db, media_id, current_user)

    comments = db.execute(
        select(MediaComment)
        .where(MediaComment.media_id == media_id)
        .order_by(MediaComment.created_at.asc())
    ).scalars().all()

    # Resolve user full names. N+1 is fine here since a single media
    # item rarely has hundreds of comments; if that changes, switch to
    # a join.
    return [
        MediaCommentRead.from_model(
            c,
            user_full_name=(
                db.get(User, c.user_id).full_name if db.get(User, c.user_id) else ""
            ),
        )
        for c in comments
    ]


@router.patch("/{media_id}/comments/{comment_id}", response_model=MediaCommentRead)
def update_comment(
    media_id: uuid.UUID,
    comment_id: uuid.UUID,
    payload: MediaCommentUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MediaCommentRead:
    """Edits a comment's text. Only the comment author can edit their
    own comment.
    """
    _get_accessible_media(db, media_id, current_user)
    comment = db.get(MediaComment, comment_id)
    if comment is None or comment.media_id != media_id:
        raise HTTPException(status_code=404, detail="Comment not found")
    if comment.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="You can only edit your own comments")

    comment.text = payload.text
    db.commit()
    db.refresh(comment)

    return MediaCommentRead.from_model(comment, user_full_name=current_user.full_name)


@router.delete("/{media_id}/comments/{comment_id}", response_model=MessageResponse)
def delete_comment(
    media_id: uuid.UUID,
    comment_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Deletes a comment. If it's a top-level comment, all nested replies
    are also removed. Only the comment author can delete their own comment.
    """
    _get_accessible_media(db, media_id, current_user)
    comment = db.get(MediaComment, comment_id)
    if comment is None or comment.media_id != media_id:
        raise HTTPException(status_code=404, detail="Comment not found")
    if comment.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="You can only delete your own comments")

    # Recursively collect all descendant comment ids to delete
    ids_to_delete = {comment_id}
    changed = True
    while changed:
        changed = False
        rows = db.execute(
            select(MediaComment.id).where(
                MediaComment.media_id == media_id,
                MediaComment.parent_id.in_(list(ids_to_delete)),
                ~MediaComment.id.in_(list(ids_to_delete)),
            )
        ).scalars().all()
        for row_id in rows:
            if row_id not in ids_to_delete:
                ids_to_delete.add(row_id)
                changed = True

    db.execute(
        sa.delete(MediaComment).where(MediaComment.id.in_(list(ids_to_delete)))
    )
    db.commit()

    return MessageResponse(message="Comment deleted.")