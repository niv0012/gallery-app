import uuid
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import and_, case, func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_client_user
from app.api.routes.download_history import _resolve_downloaded_by
from app.api.routes.media import _comment_count_for, _like_info_for
from app.core.album_sharing import active_shares_for_client, is_shared_with
from app.core.download_log import record_download_event
from app.core.storage import build_media_url
from app.core.visibility import is_visible_to_client
from app.db.session import get_db
from app.models.album_share import AlbumClientShare
from app.models.connection import ConnectionStatus, StudioClientConnection
from app.models.gallery import Album, DownloadEvent, DownloadSource, Folder, Media, MediaLike, MediaType, ShareLink, GalleryViewEvent
from app.models.user import User, UserRole
from app.schemas.gallery import AlbumRead, DownloadEventCreate, DownloadEventRead, MediaRead
from app.schemas.gallery_share import SharedFolderRead, SharedStudioRead

router = APIRouter(prefix="/client", tags=["client-gallery"])


def _require_shared_studio(db: Session, studio_id: uuid.UUID, client_id: uuid.UUID) -> User:
    """404s unless this studio currently has at least one active explicit share
    with the current client (either AlbumClientShare or direct ShareLink).
    """
    has_explicit = db.execute(
        select(AlbumClientShare.id).where(
            AlbumClientShare.studio_id == studio_id,
            AlbumClientShare.client_id == client_id,
            AlbumClientShare.revoked_at.is_(None),
        )
    ).first()

    if has_explicit is None:
        now = datetime.now(timezone.utc)
        has_direct_link = db.execute(
            select(ShareLink.id).where(
                ShareLink.owner_id == studio_id,
                ShareLink.client_id == client_id,
                ShareLink.is_revoked.is_(False),
                and_(
                    ShareLink.expires_at.is_(None)
                    | (ShareLink.expires_at > now)  # type: ignore[operator]
                ),
            )
        ).first()
        if has_direct_link is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Studio not found")

    studio = db.get(User, studio_id)
    if studio is None or studio.role != UserRole.photographer or studio.is_deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Studio not found")
    return studio


def _media_counts_multi(db: Session, owner_ids: list[uuid.UUID]) -> dict[uuid.UUID, tuple[int, int]]:
    if not owner_ids:
        return {}
    rows = db.execute(
        select(
            Media.album_id,
            func.sum(case((Media.media_type == MediaType.photo, 1), else_=0)),
            func.sum(case((Media.media_type == MediaType.video, 1), else_=0)),
        )
        .where(Media.owner_id.in_(owner_ids), Media.album_id.isnot(None), Media.is_deleted.is_(False))
        .group_by(Media.album_id)
    ).all()
    return {album_id: (int(photos or 0), int(videos or 0)) for album_id, photos, videos in rows}


def _cover_thumbnails_multi(db: Session, owner_ids: list[uuid.UUID]) -> dict[uuid.UUID, str]:
    if not owner_ids:
        return {}
    rows = db.execute(
        select(Media.album_id, Media.thumbnail_path, Media.file_path)
        .where(Media.owner_id.in_(owner_ids), Media.album_id.isnot(None), Media.is_deleted.is_(False))
        .order_by(Media.album_id, Media.created_at.desc())
    ).all()
    covers: dict[uuid.UUID, str] = {}
    for album_id, thumbnail_path, file_path in rows:
        if album_id in covers:
            continue
        url = build_media_url(thumbnail_path or file_path)
        if url:
            covers[album_id] = url
    return covers


@router.get("/studios", response_model=list[SharedStudioRead])
def list_shared_studios(
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[SharedStudioRead]:
    """Backs `SharedStudiosScreen` (Task 13) — every studio that currently
    has at least one active share with this client, most recently shared
    first.

    Includes explicit `AlbumClientShare` rows and direct `ShareLink` rows 
    assigned to this client.
    """
    # ── Path 1: explicit per-album shares ──────────────────────────────
    explicit_album_rows = db.execute(
        select(
            AlbumClientShare.studio_id,
            AlbumClientShare.album_id,
            AlbumClientShare.shared_at,
        )
        .where(
            AlbumClientShare.client_id == current_user.id,
            AlbumClientShare.revoked_at.is_(None),
        )
    ).all()

    studio_albums: dict[uuid.UUID, set[uuid.UUID]] = {}
    studio_latest: dict[uuid.UUID, object] = {}

    for sid, aid, lat in explicit_album_rows:
        if sid not in studio_albums:
            studio_albums[sid] = set()
        studio_albums[sid].add(aid)
        
        current_lat = studio_latest.get(sid)
        if lat is not None and (current_lat is None or lat > current_lat):
            studio_latest[sid] = lat

    # ── Path 2: direct share links assigned to this client ───────────────
    now = datetime.now(timezone.utc)

    direct_link_rows = db.execute(
        select(
            ShareLink.owner_id,
            ShareLink.album_id,
            ShareLink.created_at,
        )
        .where(
            ShareLink.client_id == current_user.id,
            ShareLink.is_revoked.is_(False),
            and_(
                ShareLink.expires_at.is_(None)
                | (ShareLink.expires_at > now)  # type: ignore[operator]
            ),
        )
    ).all()
    
    for sid, aid, lat in direct_link_rows:
        if sid not in studio_albums:
            studio_albums[sid] = set()
        studio_albums[sid].add(aid)

        current_lat = studio_latest.get(sid)
        if lat is not None and (current_lat is None or lat > current_lat):
            studio_latest[sid] = lat

    all_studio_ids = set(studio_albums.keys())
    if not all_studio_ids:
        return []

    studios = {
        s.id: s
        for s in db.execute(select(User).where(User.id.in_(list(all_studio_ids)))).scalars().all()
    }

    # Build result sorted by most-recently-shared descending.
    combined: list[tuple[uuid.UUID, int, object]] = []
    for sid in all_studio_ids:
        combined.append((sid, len(studio_albums[sid]), studio_latest.get(sid)))

    combined.sort(key=lambda x: x[2] or datetime.min.replace(tzinfo=timezone.utc), reverse=True)

    result: list[SharedStudioRead] = []
    for studio_id, shared_count, _ in combined:
        studio = studios.get(studio_id)
        if studio is None or studio.is_deleted:
            continue
        result.append(
            SharedStudioRead(
                id=studio.id,
                name=studio.studio_name or studio.full_name,
                logo_url=studio.avatar_url,
                shared_count=shared_count,
            )
        )
    return result


@router.get("/studios/{studio_id}/folders", response_model=list[SharedFolderRead])
def list_shared_folders(
    studio_id: uuid.UUID,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[SharedFolderRead]:
    """Backs `StudioSharedFoldersScreen` (Task 14) — this studio's
    folder tree, pruned to only folders that contain a shared album,
    either directly or through a sub-folder. Ancestor folders of a
    shared sub-folder are included too (with `shared_album_count=0` if
    they hold no directly-shared albums themselves) purely so the tree
    stays connected to its root — the client should be able to
    navigate down to a shared folder, not see it float with no path to
    it.
    """
    _require_shared_studio(db, studio_id, current_user.id)

    shared_album_ids = set(active_shares_for_client(db, client_id=current_user.id))
    if not shared_album_ids:
        return []

    shared_albums = db.execute(
        select(Album.id, Album.folder_id).where(
            Album.owner_id == studio_id, Album.id.in_(shared_album_ids)
        )
    ).all()
    if not shared_albums:
        return []

    direct_shared_count: dict[uuid.UUID, int] = {}
    leaf_folder_ids: set[uuid.UUID] = set()
    for _, folder_id in shared_albums:
        if folder_id is None:
            continue
        leaf_folder_ids.add(folder_id)
        direct_shared_count[folder_id] = direct_shared_count.get(folder_id, 0) + 1

    if not leaf_folder_ids:
        return []

    all_folders = {
        f.id: f
        for f in db.execute(select(Folder).where(Folder.deleted_at.is_(None), Folder.owner_id == studio_id)).scalars().all()
    }

    # Walk each leaf folder up to the root, collecting every ancestor so
    # the pruned tree stays connected.
    
    def _is_folder_tree_visible(f_id: uuid.UUID) -> bool:
        curr = f_id
        seen = set()
        while curr is not None:
            if curr in seen:
                break
            seen.add(curr)
            f = all_folders.get(curr)
            if f is None or getattr(f, "is_hidden", False):
                return False
            curr = f.parent_id
        return True

    included_ids: set[uuid.UUID] = set()
    for folder_id in leaf_folder_ids:
        if not _is_folder_tree_visible(folder_id):
            continue
            
        current_id: uuid.UUID | None = folder_id
        while current_id is not None and current_id not in included_ids:
            included_ids.add(current_id)
            folder = all_folders.get(current_id)
            current_id = folder.parent_id if folder else None

    return [
        SharedFolderRead(
            id=folder.id,
            name=folder.name,
            parent_id=folder.parent_id,
            gradient_argb=[int(v) for v in folder.gradient_argb.split(",") if v]
            if folder.gradient_argb
            else [],
            shared_album_count=direct_shared_count.get(folder.id, 0),
        )
        for fid in included_ids
        if (folder := all_folders.get(fid)) is not None
    ]


@router.get("/studios/{studio_id}/albums", response_model=list[AlbumRead])
def list_shared_albums_for_studio(
    studio_id: uuid.UUID,
    folder_id: uuid.UUID | None = Query(
        default=None, description="Omit for albums shared at the studio root (no folder)."
    ),
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[AlbumRead]:
    """Backs the album grid (Task 15) once a client has drilled into a
    studio/folder from the shared-gallery flow. Reuses `AlbumRead` (with
    `cover_thumbnail_url`) exactly as the studio-only `GET /albums`
    endpoint does, so the existing cover-photo and video-thumbnail
    fixes keep working unchanged — the only difference here is the
    filter: albums must both live in `folder_id` *and* have an active
    share with this client.
    """
    _require_shared_studio(db, studio_id, current_user.id)

    shared_album_ids = set(active_shares_for_client(db, client_id=current_user.id))
    if not shared_album_ids:
        return []

    albums = db.execute(
        select(Album)
        .where(
            Album.owner_id == studio_id,
            Album.folder_id == folder_id,
            Album.id.in_(shared_album_ids),
        )
        .order_by(Album.display_order.asc(), Album.created_at.desc())
    ).scalars().all()
    
    # Filter out albums inside hidden folders
    albums = [a for a in albums if is_visible_to_client(db, album_id=a.id)]
    
    if not albums:
        return []

    counts = _media_counts_multi(db, [studio_id])
    covers = _cover_thumbnails_multi(db, [studio_id])

    return [
        AlbumRead.from_model(
            a, *counts.get(a.id, (0, 0)), cover_thumbnail_url=covers.get(a.id)
        )
        for a in albums
    ]


@router.get("/studios/{studio_id}/albums/{album_id}/media", response_model=list[MediaRead])
def list_shared_album_media(
    studio_id: uuid.UUID,
    album_id: uuid.UUID,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
    skip: int = Query(default=0, ge=0),
    limit: int = Query(default=50000, ge=1),
    media_type: MediaType | None = Query(
        default=None, description="Restrict to 'photo' or 'video'. Omit for both."
    ),
    liked_only: bool = Query(
        default=False, description="Only media this client has liked (Task 23)."
    ),
    sort: Literal["recent", "oldest"] = Query(
        default="recent", description="'recent' = newest created_at first (default), 'oldest' = reverse."
    ),
) -> list[MediaRead]:
    """Full photo-by-photo media listing for a single shared album.

    Gated by two checks:
    1. The studio must have at least one active share with this client
       (via ``_require_shared_studio`` — returns 404 if not).
    2. This specific album must be actively shared with this client
       (via ``is_shared_with`` — returns 404 if the album exists but
       isn't shared, or was revoked).

    Returns paginated ``MediaRead`` list, ordered by ``sort`` (default
    ``"recent"`` — ``created_at`` desc, same default order the studio
    owner sees in ``GET /media``; ``"oldest"`` reverses it). Supports
    ``skip``/``limit`` for pagination, plus ``media_type``/``liked_only``
    filters (Task 21.7) — both applied in SQL, before ``skip``/``limit``,
    so pagination stays correct against the filtered set rather than the
    full album.
    """
    _require_shared_studio(db, studio_id, current_user.id)

    # Extra guard: confirm this specific album is shared with this client.
    if not is_shared_with(db, album_id=album_id, client_id=current_user.id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")

    # Confirm the album actually belongs to this studio (prevents IDOR).
    album = db.get(Album, album_id)
    if album is None or album.owner_id != studio_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")
        
    if not is_visible_to_client(db, album_id=album_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")

    query = select(Media).where(
        Media.album_id == album_id,
        Media.owner_id == studio_id,
        Media.is_deleted.is_(False),
    )
    if media_type is not None:
        query = query.where(Media.media_type == media_type)
    if liked_only:
        query = query.where(
            Media.id.in_(
                select(MediaLike.media_id).where(MediaLike.user_id == current_user.id)
            )
        )

    order_by = Media.created_at.asc() if sort == "oldest" else Media.created_at.desc()
    media_items = (
        db.execute(query.order_by(order_by).offset(skip).limit(limit))
        .scalars()
        .all()
    )

    if skip == 0:
        db.add(GalleryViewEvent(
            owner_id=studio_id,
            album_id=album_id,
            viewer_id=current_user.id
        ))
        db.commit()


    counts, liked = _like_info_for(db, [m.id for m in media_items], current_user.id)
    comment_counts = _comment_count_for(db, [m.id for m in media_items])
    return [
        MediaRead.from_model(
            m,
            like_count=counts.get(m.id, 0),
            is_liked_by_me=m.id in liked,
            comment_count=comment_counts.get(m.id, 0),
        )
        for m in media_items
    ]


@router.post("/download-history", response_model=DownloadEventRead, status_code=status.HTTP_201_CREATED)
def log_client_download(
    payload: DownloadEventCreate,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> DownloadEventRead:
    """Client-side counterpart to the studio-only `POST /download-history`
    — lets a client log their own in-app download of a photo/video from
    a studio's shared gallery. Previously missing entirely: the app was
    calling the studio-only route for client downloads too, which 403'd
    and left the event silently unrecorded.

    Gated the same way client reads already are: the media's album must
    currently be actively shared with this client (`is_shared_with`),
    never just "does this media_id exist" — a client can't manufacture
    history for media they were never shown.
    """
    media = db.get(Media, payload.media_id)
    if (
        media is None
        or media.album_id is None
        or not is_shared_with(db, album_id=media.album_id, client_id=current_user.id)
    ):
        raise HTTPException(status_code=404, detail="Media not found")
        
    if not is_visible_to_client(db, album_id=media.album_id):
        raise HTTPException(status_code=404, detail="Media not found")

    event = record_download_event(
        db,
        media=media,
        source=DownloadSource.app,
        downloaded_by_user_id=current_user.id,
    )
    db.commit()
    db.refresh(event)
    return DownloadEventRead.from_model(
        event,
        _resolve_downloaded_by(event, current_user.full_name),
        thumbnail_url=build_media_url(media.thumbnail_path) or build_media_url(media.file_path),
        file_url=build_media_url(media.file_path),
    )


@router.get("/download-history", response_model=list[DownloadEventRead])
def list_my_download_history(
    media_id: uuid.UUID | None = None,
    limit: int = Query(default=50000),
    offset: int = 0,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[DownloadEventRead]:
    """The client's own personal Download History — every download
    *this client* has personally made in-app, across every studio,
    most recent first. Distinct from
    `GET /client/studios/{studio_id}/download-history` below (which
    shows all activity on one studio's shared albums, from any viewer);
    this is scoped to `downloaded_by_user_id == current_user.id` and
    needs no `studio_id` since its entry points (client Profile, Home)
    are account-level, not studio-scoped.
    """
    query = (
        select(DownloadEvent, User.full_name, Media)
        .outerjoin(User, User.id == DownloadEvent.downloaded_by_user_id)
        .outerjoin(Media, Media.id == DownloadEvent.media_id)
        .where(DownloadEvent.downloaded_by_user_id == current_user.id)
    )
    if media_id is not None:
        query = query.where(DownloadEvent.media_id == media_id)

    query = query.order_by(DownloadEvent.downloaded_at.desc()).limit(limit).offset(offset)
    rows = db.execute(query).all()

    return [
        DownloadEventRead.from_model(
            event,
            _resolve_downloaded_by(event, full_name),
            thumbnail_url=(build_media_url(media.thumbnail_path) or build_media_url(media.file_path))
            if media is not None
            else None,
            file_url=build_media_url(media.file_path) if media is not None else None,
        )
        for event, full_name, media in rows
    ]


@router.get("/studios/{studio_id}/download-history", response_model=list[DownloadEventRead])
def list_shared_download_history(
    studio_id: uuid.UUID,
    album_id: uuid.UUID | None = Query(
        default=None,
        description="Restrict to a single shared album. Omit to see every album this studio has shared with you.",
    ),
    skip: int = Query(default=0, ge=0),
    limit: int = Query(default=50000, ge=1),
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[DownloadEventRead]:
    """Task 21.22's drafted design, now implemented: lets a client see
    download activity for galleries actually shared with them — never
    the studio's full Download History (`GET /download-history`, which
    stays studio-only), and never another client's activity.

    Gated the same two ways as `list_shared_album_media`:
    1. The studio must have at least one active share with this client
       (`_require_shared_studio` — 404s otherwise).
    2. Every row returned is filtered to `album_id`s currently in this
       client's own active-share set (`active_shares_for_client`), so a
       revoked share's download history disappears the same instant the
       album itself would stop showing up elsewhere.

    If `album_id` is given, it's additionally checked against
    `is_shared_with` (same 404-if-not-actively-shared behavior
    `list_shared_album_media` uses) rather than silently returning an
    empty list for an album this client was never allowed to see.

    Reuses `download_history.py`'s `_resolve_downloaded_by` so the
    "who downloaded this" label collapses to the same three fallbacks
    (full name / free-text label / "Shared link viewer" / "Unknown")
    the studio-side history already uses, rather than re-deriving it.
    """
    _require_shared_studio(db, studio_id, current_user.id)

    shared_album_ids = set(active_shares_for_client(db, client_id=current_user.id))
    if not shared_album_ids:
        return []

    if album_id is not None:
        if not is_shared_with(db, album_id=album_id, client_id=current_user.id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")
        if not is_visible_to_client(db, album_id=album_id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")
        scoped_album_ids: set[uuid.UUID] = {album_id}
    else:
        # Filter out hidden albums
        scoped_album_ids = {a_id for a_id in shared_album_ids if is_visible_to_client(db, album_id=a_id)}

    if not scoped_album_ids:
        return []

    rows = db.execute(
        select(DownloadEvent, User.full_name)
        .outerjoin(User, User.id == DownloadEvent.downloaded_by_user_id)
        .where(
            DownloadEvent.owner_id == studio_id,
            DownloadEvent.album_id.in_(scoped_album_ids),
        )
        .order_by(DownloadEvent.downloaded_at.desc())
        .offset(skip)
        .limit(limit)
    ).all()

    return [
        DownloadEventRead.from_model(event, _resolve_downloaded_by(event, full_name))
        for event, full_name in rows
    ]