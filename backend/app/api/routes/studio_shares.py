import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_studio_user
from app.core.storage import build_media_url
from app.core.visibility import is_visible_to_client
from app.db.session import get_db
from app.models.album_share import AlbumClientShare
from app.models.connection import ConnectionStatus, StudioClientConnection
from app.models.gallery import Album, Folder, Media
from app.models.notification import Notification, NotificationType
from app.models.user import User
from app.core.firebase_service import send_push_notification
from app.schemas.gallery_share import (
    AlbumClientShareRead,
    AlbumShareCreate,
    BulkShareResult,
    FolderShareCreate,
)
from app.schemas.user import MessageResponse

router = APIRouter(prefix="/studio/shares", tags=["studio-shares"])


def _get_owned_album(db: Session, album_id: uuid.UUID, owner_id: uuid.UUID) -> Album:
    album = db.get(Album, album_id)
    if album is None or album.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")
    return album


def _get_owned_folder(db: Session, folder_id: uuid.UUID, owner_id: uuid.UUID) -> Folder:
    folder = db.get(Folder, folder_id)
    if folder is None or folder.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Folder not found")
    return folder


def _require_connected_client(db: Session, studio_id: uuid.UUID, client_id: uuid.UUID) -> User:
    """Raises 400 unless `client_id` has an *accepted*
    `StudioClientConnection` with this studio — sharing is only ever
    offered from the connected-clients picker (Task 17), so a studio
    trying to share with someone they aren't connected to is always a
    bug or a forged request, never a legitimate case to allow through.
    """
    connection = db.execute(
        select(StudioClientConnection).where(
            StudioClientConnection.studio_id == studio_id,
            StudioClientConnection.client_id == client_id,
        )
    ).scalar_one_or_none()
    if connection is None or connection.status != ConnectionStatus.accepted:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="This client isn't connected to your studio.",
        )
    client = db.get(User, client_id)
    if client is None or client.is_deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Client not found")
    return client


def _get_or_reactivate_share(
    db: Session, *, album_id: uuid.UUID, client_id: uuid.UUID, studio_id: uuid.UUID
) -> tuple[AlbumClientShare, bool]:
    """Finds an existing share row for this (album, client) pair and
    reactivates it if it was revoked; creates a new row if none exists
    at all. Returns `(share, created)` — `created` is False both when
    an active share already existed and when a revoked one was
    reactivated, since neither case is a fresh row from the caller's
    perspective (see `BulkShareResult`, which only wants to know what's
    newly *visible* to the client, not row-creation mechanics).
    """
    existing = db.execute(
        select(AlbumClientShare).where(
            AlbumClientShare.album_id == album_id,
            AlbumClientShare.client_id == client_id,
        )
    ).scalar_one_or_none()

    if existing is not None:
        if existing.revoked_at is not None:
            existing.revoked_at = None
            db.flush()
            return existing, True
        return existing, False

    share = AlbumClientShare(album_id=album_id, client_id=client_id, studio_id=studio_id)
    db.add(share)
    db.flush()
    return share, True


def _cover_thumbnail_for(db: Session, album_id: uuid.UUID) -> str | None:
    row = db.execute(
        select(Media.thumbnail_path, Media.file_path)
        .where(Media.album_id == album_id, Media.is_deleted.is_(False))
        .order_by(Media.created_at.desc())
        .limit(1)
    ).first()
    if row is None:
        return None
    thumbnail_path, file_path = row
    return build_media_url(thumbnail_path or file_path)


@router.post("", response_model=AlbumClientShareRead, status_code=status.HTTP_201_CREATED)
def share_album(
    payload: AlbumShareCreate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AlbumClientShareRead:
    """Shares one album with one connected client. Idempotent: sharing
    an already-shared album just returns the existing (active) share,
    same convention as `favorite_studio`.
    """
    album = _get_owned_album(db, payload.album_id, current_user.id)
    if not is_visible_to_client(db, album_id=album.id):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Cannot share a hidden album.")
    _require_connected_client(db, current_user.id, payload.client_id)

    share, created = _get_or_reactivate_share(
        db, album_id=album.id, client_id=payload.client_id, studio_id=current_user.id
    )
    
    if created:
        client = db.get(User, payload.client_id)
        if client:
            title = "New Album Shared"
            studio_name = current_user.studio_name or current_user.full_name
            body = f"{studio_name} shared the album '{album.name}' with you."
            db.add(Notification(
                user_id=client.id,
                type=NotificationType.gallery,
                title=title,
                subtitle=body,
                data={"album_id": str(album.id)}
            ))
            # Gated on the client's push_notifications_enabled toggle.
            if client.fcm_token and client.push_notifications_enabled:
                send_push_notification(
                    token=client.fcm_token,
                    title=title,
                    body=body,
                    data={"type": "gallery", "album_id": str(album.id)}
                )

    db.commit()
    db.refresh(share)

    return AlbumClientShareRead.from_model(
        share, album_name=album.name, album_cover_thumbnail_url=_cover_thumbnail_for(db, album.id)
    )


@router.post("/folder", response_model=BulkShareResult, status_code=status.HTTP_201_CREATED)
def share_folder(
    payload: FolderShareCreate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> BulkShareResult:
    """Shares every album currently in `folder_id` with one connected
    client in a single call — reuses the same idempotent
    find-or-reactivate logic as `share_album`, just looped over every
    album in the folder. Only shares the folder's direct albums, not
    albums in sub-folders — matches how `GET /folders/{id}/albums`
    scopes "albums in this folder" elsewhere in the app.
    """
    folder = _get_owned_folder(db, payload.folder_id, current_user.id)
    if not is_visible_to_client(db, folder_id=folder.id):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Cannot share a hidden folder.")
    _require_connected_client(db, current_user.id, payload.client_id)

    albums = db.execute(
        select(Album).where(Album.deleted_at.is_(None), Album.owner_id == current_user.id, Album.folder_id == folder.id)
    ).scalars().all()

    results: list[AlbumClientShareRead] = []
    created_count = 0
    already_shared_count = 0
    for album in albums:
        share, created = _get_or_reactivate_share(
            db, album_id=album.id, client_id=payload.client_id, studio_id=current_user.id
        )
        if created:
            created_count += 1
        else:
            already_shared_count += 1
        results.append(
            AlbumClientShareRead.from_model(
                share,
                album_name=album.name,
                album_cover_thumbnail_url=_cover_thumbnail_for(db, album.id),
            )
        )

    if created_count > 0:
        client = db.get(User, payload.client_id)
        if client:
            title = "New Folder Shared"
            studio_name = current_user.studio_name or current_user.full_name
            body = f"{studio_name} shared the folder '{folder.name}' with you."
            db.add(Notification(
                user_id=client.id,
                type=NotificationType.gallery,
                title=title,
                subtitle=body,
                data={"folder_id": str(folder.id)}
            ))
            # Gated on the client's push_notifications_enabled toggle.
            if client.fcm_token and client.push_notifications_enabled:
                send_push_notification(
                    token=client.fcm_token,
                    title=title,
                    body=body,
                    data={"type": "gallery", "folder_id": str(folder.id)}
                )

    db.commit()

    return BulkShareResult(
        shares=results, created_count=created_count, already_shared_count=already_shared_count
    )


@router.delete("/{share_id}", response_model=MessageResponse)
def revoke_share(
    share_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Soft-revokes a share (sets `revoked_at`) — never hard-deletes, so
    the row stays around as history (see `AlbumClientShare` docstring).
    A repeat revoke of an already-revoked share is a no-op, not an
    error.
    """
    share = db.get(AlbumClientShare, share_id)
    if share is None or share.studio_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Share not found")

    if share.revoked_at is None:
        share.revoked_at = datetime.now(timezone.utc)
        db.commit()

    return MessageResponse(message="Share revoked")


@router.get("", response_model=list[AlbumClientShareRead])
def list_shares_for_client(
    client_id: uuid.UUID = Query(..., description="List this studio's active shares with one client."),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[AlbumClientShareRead]:
    """The studio's own view of what's currently shared with a given
    client (Task 7) — backs a future "manage sharing" screen where a
    studio can see and toggle what one client can see. Active shares
    only (`revoked_at IS NULL`); revoked history isn't surfaced here.
    """
    rows = db.execute(
        select(AlbumClientShare, Album)
        .join(Album, Album.id == AlbumClientShare.album_id)
        .where(
            AlbumClientShare.studio_id == current_user.id,
            AlbumClientShare.client_id == client_id,
            AlbumClientShare.revoked_at.is_(None),
        )
        .order_by(AlbumClientShare.shared_at.desc())
    ).all()

    visible_rows = [(share, album) for share, album in rows if is_visible_to_client(db, album_id=album.id)]

    return [
        AlbumClientShareRead.from_model(
            share, album_name=album.name, album_cover_thumbnail_url=_cover_thumbnail_for(db, album.id)
        )
        for share, album in visible_rows
    ]