import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import case, func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_client_user, get_current_studio_user, require_active_plan
from app.core.album_sharing import active_shares_for_client
from app.core.storage import build_media_url
from app.db.session import get_db
from app.models.connection import ConnectionStatus, StudioClientConnection
from app.models.gallery import Album, Folder, Media, MediaLike, MediaType, ShareLink
from app.models.user import User
from app.schemas.gallery import (
    AlbumCreate,
    AlbumRead,
    AlbumReorderRequest,
    AlbumStatsRead,
    AlbumUpdate,
    ConnectedAlbumRead,
)
from app.schemas.user import MessageResponse

router = APIRouter(prefix="/albums", tags=["gallery-albums"])


def _get_owned_album(db: Session, album_id: uuid.UUID, owner_id: uuid.UUID) -> Album:
    album = db.get(Album, album_id)
    if album is None or album.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")
    return album


def _media_counts(db: Session, owner_id: uuid.UUID) -> dict[uuid.UUID, tuple[int, int]]:
    """One query for (photo_count, video_count) of every album owned by
    this studio, excluding trashed media — avoids N+1 queries.
    """
    rows = db.execute(
        select(
            Media.album_id,
            func.sum(case((Media.media_type == MediaType.photo, 1), else_=0)),
            func.sum(case((Media.media_type == MediaType.video, 1), else_=0)),
        )
        .where(Media.owner_id == owner_id, Media.album_id.isnot(None), Media.is_deleted.is_(False))
        .group_by(Media.album_id)
    ).all()
    return {album_id: (int(photos or 0), int(videos or 0)) for album_id, photos, videos in rows}


def _cover_thumbnails(db: Session, owner_id: uuid.UUID) -> dict[uuid.UUID, str]:
    """The most-recently-added active media item's servable URL per
    album (thumbnail if one was generated, else the original file) —
    used as the real photo shown on each album card instead of the
    gradient-only placeholder. One query for every album owned by this
    studio, ordered so the first row seen per album is the newest.
    """
    rows = db.execute(
        select(Media.album_id, Media.thumbnail_path, Media.file_path)
        .where(Media.owner_id == owner_id, Media.album_id.isnot(None), Media.is_deleted.is_(False))
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


def _media_counts_multi(db: Session, owner_ids: list[uuid.UUID]) -> dict[uuid.UUID, tuple[int, int]]:
    """Same as `_media_counts` above but scoped to several studios' albums
    at once (one query total) — used by `shared-with-me`, where a
    client's albums can belong to any number of connected studios.
    """
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
    """Same as `_cover_thumbnails` above but scoped to several studios'
    albums at once (one query total) — used by `shared-with-me`.
    """
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


def _protected_share_link_album_ids_multi(db: Session, owner_ids: list[uuid.UUID]) -> set[uuid.UUID]:
    """Album ids (within `owner_ids`) that have at least one active,
    password-protected public `ShareLink` — active meaning not revoked
    and not expired. One query for every connected studio's albums at
    once, same batching reasoning as `_media_counts_multi` above.

    Deliberately independent of `AlbumClientShare`/`is_shared_with` —
    a `ShareLink` is a separate, unauthenticated distribution channel
    a studio may or may not have also created for the same album, and
    its password never gates *this* client's own (already-authenticated)
    access. See Task 21.23/21.24.
    """
    if not owner_ids:
        return set()
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc)
    rows = db.execute(
        select(ShareLink.album_id).where(
            ShareLink.owner_id.in_(owner_ids),
            ShareLink.password_hash.isnot(None),
            ShareLink.is_revoked.is_(False),
            (ShareLink.expires_at.is_(None)) | (ShareLink.expires_at > now),
        )
    ).scalars().all()
    return set(rows)


def _watermark_album_ids_multi(db: Session, owner_ids: list[uuid.UUID]) -> set[uuid.UUID]:
    """Album ids (within `owner_ids`) where the studio enabled
    `show_watermark=True` on at least one active public `ShareLink`.
    Used by `GET /albums/shared-with-me` to tell the client whether
    to overlay the studio logo on photos in that album.
    """
    if not owner_ids:
        return set()
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc)
    rows = db.execute(
        select(ShareLink.album_id).where(
            ShareLink.owner_id.in_(owner_ids),
            ShareLink.show_watermark.is_(True),
            ShareLink.is_revoked.is_(False),
            (ShareLink.expires_at.is_(None)) | (ShareLink.expires_at > now),
        )
    ).scalars().all()
    return {r for r in rows if r is not None}


@router.post("", response_model=AlbumRead, status_code=status.HTTP_201_CREATED)
def create_album(
    payload: AlbumCreate,
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
) -> AlbumRead:
    if payload.folder_id is not None:
        folder = db.get(Folder, payload.folder_id)
        if folder is None or folder.owner_id != current_user.id:
            raise HTTPException(status_code=404, detail="Folder not found")

    max_order = db.execute(
        select(func.max(Album.display_order)).where(Album.owner_id == current_user.id)
    ).scalar()

    album = Album(
        owner_id=current_user.id,
        name=payload.name,
        description=payload.description,
        folder_id=payload.folder_id,
        display_order=(max_order or 0) + 1,
        gradient_argb=",".join(str(v) for v in payload.gradient_argb) if payload.gradient_argb else None,
    )
    db.add(album)
    db.commit()
    db.refresh(album)
    return AlbumRead.from_model(album)


@router.get("", response_model=list[AlbumRead])
def list_albums(
    folder_id: uuid.UUID | None = None,
    unfiled_only: bool = False,
    favorites_only: bool = False,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[AlbumRead]:
    query = select(Album).where(Album.owner_id == current_user.id)
    if unfiled_only:
        query = query.where(Album.folder_id.is_(None))
    elif folder_id is not None:
        query = query.where(Album.folder_id == folder_id)
    if favorites_only:
        query = query.where(Album.is_favorite.is_(True))
    query = query.order_by(Album.display_order.asc(), Album.created_at.desc())

    albums = db.execute(query).scalars().all()
    counts = _media_counts(db, current_user.id)
    covers = _cover_thumbnails(db, current_user.id)
    return [
        AlbumRead.from_model(a, *counts.get(a.id, (0, 0)), cover_thumbnail_url=covers.get(a.id))
        for a in albums
    ]


@router.get("/stats", response_model=AlbumStatsRead)
def get_album_stats(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AlbumStatsRead:
    albums = db.execute(
        select(Album).where(Album.owner_id == current_user.id)
    ).scalars().all()
    if not albums:
        return AlbumStatsRead(
            total_albums=0,
            total_photos=0,
            total_favorites=0,
            average_photos_per_album=0,
            most_recent_album_id=None,
            largest_album_id=None,
            unfiled_album_count=0,
        )

    counts = _media_counts(db, current_user.id)
    total_photos = sum(counts.get(a.id, (0, 0))[0] for a in albums)
    most_recent = max(albums, key=lambda a: a.updated_at)
    largest = max(albums, key=lambda a: counts.get(a.id, (0, 0))[0])

    return AlbumStatsRead(
        total_albums=len(albums),
        total_photos=total_photos,
        total_favorites=sum(1 for a in albums if a.is_favorite),
        average_photos_per_album=total_photos / len(albums),
        most_recent_album_id=most_recent.id,
        largest_album_id=largest.id,
        unfiled_album_count=sum(1 for a in albums if a.folder_id is None),
    )


@router.get("/shared-with-me", response_model=list[ConnectedAlbumRead])
def list_shared_albums(
    studio_id: uuid.UUID | None = Query(
        default=None,
        description="Restrict to a single connected studio. Omit to see albums from every studio you're connected to.",
    ),
    media_type: MediaType | None = Query(
        default=None,
        description="Only albums containing at least one 'photo' or 'video'. Omit for no restriction.",
    ),
    liked_only: bool = Query(
        default=False,
        description="Only albums containing at least one media item this client has liked (Task 23).",
    ),
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[ConnectedAlbumRead]:
    """Client-only: albums belonging to studios this client has an
    *accepted* connection with. This is what the client-facing Gallery
    tab should call instead of `GET /albums` above (which is
    studio-only and 403s for a client — that's the bug this endpoint
    fixes). A pending or declined connection grants no visibility into
    that studio's gallery; only `accepted` counts.

    Unlike `list_shared_album_media`, this lists *albums*, so
    `media_type`/`liked_only` (Task 21.9) filter to albums containing at
    least one matching media item, rather than filtering individual
    media rows — same semantics as the client's "Liked" filter chip,
    generalized to also cover media type.
    """
    connected_studio_ids = list(
        db.execute(
            select(StudioClientConnection.studio_id).where(
                StudioClientConnection.client_id == current_user.id,
                StudioClientConnection.status == ConnectionStatus.accepted,
            )
        ).scalars().all()
    )

    if studio_id is not None:
        if studio_id not in connected_studio_ids:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You're not connected to this studio.",
            )
        owner_ids = [studio_id]
    else:
        owner_ids = connected_studio_ids

    if not owner_ids:
        return []

    shared_album_ids = active_shares_for_client(db, client_id=current_user.id)
    if not shared_album_ids:
        return []

    query = select(Album).where(
        Album.owner_id.in_(owner_ids),
        Album.id.in_(shared_album_ids),
    )

    if media_type is not None:
        query = query.where(
            Album.id.in_(
                select(Media.album_id).where(
                    Media.owner_id.in_(owner_ids),
                    Media.media_type == media_type,
                    Media.is_deleted.is_(False),
                    Media.album_id.isnot(None),
                )
            )
        )
    if liked_only:
        query = query.where(
            Album.id.in_(
                select(Media.album_id)
                .join(MediaLike, MediaLike.media_id == Media.id)
                .where(
                    Media.owner_id.in_(owner_ids),
                    Media.is_deleted.is_(False),
                    Media.album_id.isnot(None),
                    MediaLike.user_id == current_user.id,
                )
            )
        )

    albums = db.execute(
        query.order_by(Album.display_order.asc(), Album.created_at.desc())
    ).scalars().all()
    if not albums:
        return []

    studios = {
        s.id: s for s in db.execute(select(User).where(User.id.in_(owner_ids))).scalars().all()
    }
    counts = _media_counts_multi(db, owner_ids)
    covers = _cover_thumbnails_multi(db, owner_ids)
    protected_link_album_ids = _protected_share_link_album_ids_multi(db, owner_ids)
    watermark_album_ids = _watermark_album_ids_multi(db, owner_ids)

    return [
        ConnectedAlbumRead.from_model(
            a,
            studios[a.owner_id],
            *counts.get(a.id, (0, 0)),
            cover_thumbnail_url=covers.get(a.id),
            has_protected_share_link=a.id in protected_link_album_ids,
            show_watermark=a.id in watermark_album_ids,
        )
        for a in albums
        if a.owner_id in studios
    ]


@router.get("/{album_id}", response_model=AlbumRead)
def get_album(
    album_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AlbumRead:
    album = _get_owned_album(db, album_id, current_user.id)
    counts = _media_counts(db, current_user.id)
    covers = _cover_thumbnails(db, current_user.id)
    return AlbumRead.from_model(album, *counts.get(album.id, (0, 0)), cover_thumbnail_url=covers.get(album.id))


@router.patch("/{album_id}", response_model=AlbumRead)
def update_album(
    album_id: uuid.UUID,
    payload: AlbumUpdate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AlbumRead:
    album = _get_owned_album(db, album_id, current_user.id)
    updates = payload.model_dump(exclude_unset=True, exclude={"clear_description", "clear_folder"})

    if "name" in updates and updates["name"] is not None:
        album.name = updates["name"]

    if payload.clear_description:
        album.description = None
    elif "description" in updates and updates["description"] is not None:
        album.description = updates["description"]

    if payload.clear_folder:
        album.folder_id = None
    elif "folder_id" in updates and updates["folder_id"] is not None:
        folder = db.get(Folder, updates["folder_id"])
        if folder is None or folder.owner_id != current_user.id:
            raise HTTPException(status_code=404, detail="Folder not found")
        album.folder_id = updates["folder_id"]

    if "is_favorite" in updates and updates["is_favorite"] is not None:
        album.is_favorite = updates["is_favorite"]
    if "display_order" in updates and updates["display_order"] is not None:
        album.display_order = updates["display_order"]
    if "gradient_argb" in updates and updates["gradient_argb"] is not None:
        album.gradient_argb = ",".join(str(v) for v in updates["gradient_argb"])

    db.commit()
    db.refresh(album)
    counts = _media_counts(db, current_user.id)
    covers = _cover_thumbnails(db, current_user.id)
    return AlbumRead.from_model(album, *counts.get(album.id, (0, 0)), cover_thumbnail_url=covers.get(album.id))


@router.post("/reorder", response_model=list[AlbumRead])
def reorder_albums(
    payload: AlbumReorderRequest,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[AlbumRead]:
    """Bulk-updates `display_order` for the given albums in one request
    (drag-to-reorder on the Albums List screen). Any album id not owned
    by this studio is ignored rather than rejecting the whole batch.
    """
    for item in payload.items:
        album = db.get(Album, item.id)
        if album is not None and album.owner_id == current_user.id:
            album.display_order = item.display_order
    db.commit()

    albums = db.execute(
        select(Album)
        .where(Album.owner_id == current_user.id)
        .order_by(Album.display_order.asc())
    ).scalars().all()
    counts = _media_counts(db, current_user.id)
    covers = _cover_thumbnails(db, current_user.id)
    return [
        AlbumRead.from_model(a, *counts.get(a.id, (0, 0)), cover_thumbnail_url=covers.get(a.id))
        for a in albums
    ]


@router.delete("/{album_id}", response_model=MessageResponse)
def delete_album(
    album_id: uuid.UUID,
    force: bool = Query(
        default=False,
        description="If true, any active media in this album is moved to Trash first. "
        "If false and the album still has active media, the request is rejected with 409.",
    ),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    from datetime import datetime, timezone

    album = _get_owned_album(db, album_id, current_user.id)

    active_media = db.execute(
        select(Media).where(Media.album_id == album.id, Media.is_deleted.is_(False))
    ).scalars().all()

    if active_media and not force:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Album still has {len(active_media)} item(s). Pass force=true to move them to Trash.",
        )

    for media in active_media:
        media.is_deleted = True
        media.deleted_at = datetime.now(timezone.utc)

    db.delete(album)
    db.commit()
    return MessageResponse(message="Album deleted.")