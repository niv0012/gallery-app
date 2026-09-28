import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Body, Depends, File, HTTPException, UploadFile, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_client_user, get_current_studio_user

from app.core.storage import build_media_url, delete_stored_file, save_upload
from app.db.session import get_db
from app.models.connection import ConnectionInitiator, ConnectionStatus, StudioClientConnection
from app.models.favorite import StudioFavorite
from app.models.notification import Notification, NotificationType
from app.models.studio_backup import StudioBackup
from app.models.studio_portfolio import StudioPortfolioImage
from app.models.user import User, UserRole
from app.core.firebase_service import send_push_notification
from app.schemas.studio import (
    AvatarUploadResponse,
    FavoriteStudioRead,
    StudioBackupRead,
    StudioDirectoryItem,
    StudioPortfolioImageRead,
    StudioSummary,
)
from app.schemas.user import MessageResponse

router = APIRouter(prefix="/studios", tags=["studios"])

# Only images are accepted for avatar/cover/portfolio uploads — these are
# profile-decoration uploads, not Gallery media, so there's no video case
# to support here (unlike app/core/storage.py's media_type_for_content_type).
_ALLOWED_IMAGE_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"}


def _validate_image_upload(upload: UploadFile) -> None:
    if upload.content_type not in _ALLOWED_IMAGE_CONTENT_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Please upload a JPEG, PNG, WEBP, or HEIC image.",
        )


def _get_studio_or_404(db: Session, studio_id: uuid.UUID) -> User:
    studio = db.get(User, studio_id)
    if studio is None or studio.role != UserRole.photographer or studio.is_deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Studio not found")
    return studio


def _get_favorite(db: Session, client_id: uuid.UUID, studio_id: uuid.UUID) -> StudioFavorite | None:
    return db.execute(
        select(StudioFavorite).where(
            StudioFavorite.client_id == client_id, StudioFavorite.studio_id == studio_id
        )
    ).scalar_one_or_none()


def _get_connection_between(
    db: Session, studio_id: uuid.UUID, client_id: uuid.UUID
) -> StudioClientConnection | None:
    return db.execute(
        select(StudioClientConnection).where(
            StudioClientConnection.studio_id == studio_id,
            StudioClientConnection.client_id == client_id,
        )
    ).scalar_one_or_none()


def _gallery_urls_for(db: Session, studio_ids: list[uuid.UUID]) -> dict[uuid.UUID, list[str]]:
    """Batch-loads Showcase Portfolio thumbnail URLs for many studios in
    one query, keyed by studio (owner) id — used by every endpoint that
    returns a list of `StudioSummary`-based rows so we don't run N
    portfolio queries for N studios.
    """
    if not studio_ids:
        return {}

    rows = db.execute(
        select(StudioPortfolioImage)
        .where(StudioPortfolioImage.owner_id.in_(studio_ids))
        .order_by(StudioPortfolioImage.display_order, StudioPortfolioImage.created_at.desc())
    ).scalars().all()

    urls_by_owner: dict[uuid.UUID, list[str]] = {}
    for image in rows:
        urls_by_owner.setdefault(image.owner_id, []).append(build_media_url(image.relative_path))
    return urls_by_owner


def _studio_summary(studio: User, gallery_urls: list[str]) -> StudioSummary:
    """Builds a `StudioSummary` with `gallery_urls` attached.
    `cover_image_url` comes through automatically via `model_validate`
    since it's a plain column now (see Task 1) — only `gallery_urls`
    needs to be threaded in separately here.
    """
    return StudioSummary(**StudioSummary.model_validate(studio).model_dump(exclude={"gallery_urls"}), gallery_urls=gallery_urls)


@router.get("", response_model=list[StudioDirectoryItem])
def list_studios(
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[StudioDirectoryItem]:
    """Backs the Discover Studios screen. Every active photographer
    account, with `connection_status`/`is_favorite` computed relative
    to the requesting client. Search and category filtering stay
    client-side in Flutter (same as before), so this always returns
    the full directory rather than taking query params.
    """
    studios = db.execute(
        select(User).where(User.role == UserRole.photographer, User.is_deleted.is_(False))
    ).scalars().all()

    connections = db.execute(
        select(StudioClientConnection).where(StudioClientConnection.client_id == current_user.id)
    ).scalars().all()
    connection_by_studio = {c.studio_id: c for c in connections}

    favorites = db.execute(
        select(StudioFavorite.studio_id).where(StudioFavorite.client_id == current_user.id)
    ).scalars().all()
    favorited_ids = set(favorites)

    gallery_urls_by_studio = _gallery_urls_for(db, [s.id for s in studios])

    items: list[StudioDirectoryItem] = []
    for studio in studios:
        connection = connection_by_studio.get(studio.id)
        if connection is None or connection.status == ConnectionStatus.declined:
            connection_status = "notConnected"
        elif connection.status == ConnectionStatus.pending:
            connection_status = "pending"
        else:
            connection_status = "connected"

        summary = _studio_summary(studio, gallery_urls_by_studio.get(studio.id, []))
        items.append(
            StudioDirectoryItem(
                **summary.model_dump(),
                connection_status=connection_status,
                is_favorite=studio.id in favorited_ids,
            )
        )
    return items


@router.get("/favorites", response_model=list[FavoriteStudioRead])
def list_favorite_studios(
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> list[FavoriteStudioRead]:
    """Backs the Favorite Studios screen. Most-recently-favorited studio
    first.
    """
    rows = db.execute(
        select(StudioFavorite, User)
        .join(User, User.id == StudioFavorite.studio_id)
        .where(StudioFavorite.client_id == current_user.id)
        .order_by(StudioFavorite.created_at.desc())
    ).all()
    gallery_urls_by_studio = _gallery_urls_for(db, [studio.id for _, studio in rows])
    return [
        FavoriteStudioRead(
            studio=_studio_summary(studio, gallery_urls_by_studio.get(studio.id, [])),
            favorited_at=favorite.created_at,
        )
        for favorite, studio in rows
    ]


@router.post("/{studio_id}/favorite", response_model=FavoriteStudioRead, status_code=status.HTTP_201_CREATED)
def favorite_studio(
    studio_id: uuid.UUID,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> FavoriteStudioRead:
    """Idempotent: favoriting an already-favorited studio just returns
    the existing favorite rather than erroring, same as
    `add_albums_to_collection` skipping ids already in the collection.
    """
    studio = _get_studio_or_404(db, studio_id)

    favorite = _get_favorite(db, current_user.id, studio_id)
    if favorite is None:
        favorite = StudioFavorite(client_id=current_user.id, studio_id=studio_id)
        db.add(favorite)
        db.commit()
        db.refresh(favorite)

    gallery_urls = _gallery_urls_for(db, [studio_id]).get(studio_id, [])
    return FavoriteStudioRead(studio=_studio_summary(studio, gallery_urls), favorited_at=favorite.created_at)


@router.delete("/{studio_id}/favorite", response_model=MessageResponse)
def unfavorite_studio(
    studio_id: uuid.UUID,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    favorite = _get_favorite(db, current_user.id, studio_id)
    if favorite is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="This studio isn't in your favorites."
        )

    db.delete(favorite)
    db.commit()
    return MessageResponse(message="Removed from favorites.")


@router.post("/{studio_id}/connect", response_model=MessageResponse, status_code=status.HTTP_201_CREATED)
def request_connection(
    studio_id: uuid.UUID,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Client-initiated counterpart to `POST /connections/invite`
    (studio-initiated). Re-requesting after a decline resets the
    existing row back to `pending` rather than creating a duplicate —
    same convention `invite_client` uses.
    """
    studio = _get_studio_or_404(db, studio_id)

    connection = _get_connection_between(db, studio_id, current_user.id)
    if connection is not None:
        if connection.status == ConnectionStatus.accepted:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="You're already connected to this studio."
            )
        if connection.status == ConnectionStatus.pending:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="A request to this studio is already pending."
            )
        connection.status = ConnectionStatus.pending
        connection.initiated_by = ConnectionInitiator.client
        connection.requested_at = datetime.now(timezone.utc)
        connection.responded_at = None
    else:
        connection = StudioClientConnection(
            studio_id=studio_id,
            client_id=current_user.id,
            status=ConnectionStatus.pending,
            initiated_by=ConnectionInitiator.client,
        )
        db.add(connection)

    # Flush (not commit) so an auto-generated `connection.id` is available
    # to embed in the Notification's `data` payload below, while still
    # landing both rows in the same transaction/commit.
    db.flush()

    db.add(
        Notification(
            user_id=studio.id,
            type=NotificationType.connection,
            title="New connection request",
            subtitle=f"{current_user.full_name} wants to connect.",
            data={"connection_id": str(connection.id)},
        )
    )

    db.commit()

    # Push notification to studio's device — gated on the studio's
    # push_notifications_enabled toggle.
    if studio.fcm_token and studio.push_notifications_enabled:
        send_push_notification(
            token=studio.fcm_token,
            title="New Connection Request",
            body=f"{current_user.full_name} wants to connect with your studio.",
            data={"type": "connection", "connection_id": str(connection.id)},
        )

    return MessageResponse(message="Connection request sent.")


@router.delete("/{studio_id}/connect", response_model=MessageResponse)
def withdraw_connection_request(
    studio_id: uuid.UUID,
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Lets a client withdraw their own still-pending request. Can't be
    used to decline a studio's invite (use `POST
    /connections/{id}/decline` for that) — only pending requests the
    client themselves initiated.
    """
    connection = _get_connection_between(db, studio_id, current_user.id)
    if connection is None or connection.status != ConnectionStatus.pending:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No pending request to this studio.")
    if connection.initiated_by != ConnectionInitiator.client:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="This studio invited you — decline it from your Connections screen instead.",
        )

    db.delete(connection)
    db.commit()
    return MessageResponse(message="Request withdrawn.")


# --------------------------------------------------------------------------
# A studio managing its own profile — logo, cover photo, and Showcase
# Portfolio grid (Edit Studio Profile screen). Everything below is
# studio-only (`get_current_studio_user`), unlike the client-facing
# routes above.
# --------------------------------------------------------------------------

@router.post("/me/avatar", response_model=AvatarUploadResponse)
def upload_studio_avatar(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AvatarUploadResponse:
    """Uploads/replaces the studio's logo. Reuses the Gallery media
    storage helpers with a throwaway uuid4 standing in for `media_id`
    since there's no `Media` row here — just a single stored image
    keyed by owner id."""
    _validate_image_upload(file)

    old_relative_path = None
    # avatar_url only ever holds a full public URL; there's no relative
    # path stored anywhere to delete the old file from, so old logos are
    # simply left orphaned in storage (same tradeoff already accepted
    # for other "replace this URL field" flows in this app).

    relative_path, _size = save_upload(owner_id=current_user.id, media_id=uuid.uuid4(), upload=file)
    current_user.avatar_url = build_media_url(relative_path)
    db.commit()

    return AvatarUploadResponse(avatar_url=current_user.avatar_url)


@router.delete("/me/avatar", response_model=MessageResponse)
def delete_studio_avatar(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Removes the studio's logo, reverting them to the default camera icon."""
    if current_user.avatar_url:
        current_user.avatar_url = None
        db.commit()
    return MessageResponse(message="Studio logo removed.")

@router.post("/me/cover", response_model=AvatarUploadResponse)
def upload_studio_cover(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AvatarUploadResponse:
    """Uploads/replaces the studio's cover photo. Same pattern as
    upload_studio_avatar above."""
    _validate_image_upload(file)

    relative_path, _size = save_upload(owner_id=current_user.id, media_id=uuid.uuid4(), upload=file)
    current_user.cover_image_url = build_media_url(relative_path)
    db.commit()

    return AvatarUploadResponse(cover_image_url=current_user.cover_image_url)


@router.get("/me/portfolio", response_model=list[StudioPortfolioImageRead])
def list_my_portfolio(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[StudioPortfolioImageRead]:
    """Lists the current studio's Showcase Portfolio images, newest first."""
    images = db.execute(
        select(StudioPortfolioImage)
        .where(StudioPortfolioImage.owner_id == current_user.id)
        .order_by(StudioPortfolioImage.created_at.desc())
    ).scalars().all()
    return [
        StudioPortfolioImageRead(id=image.id, url=build_media_url(image.relative_path))
        for image in images
    ]


@router.post("/me/portfolio", response_model=StudioPortfolioImageRead, status_code=status.HTTP_201_CREATED)
def add_portfolio_image(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> StudioPortfolioImageRead:
    """Adds one image to the current studio's Showcase Portfolio grid."""
    _validate_image_upload(file)

    image_id = uuid.uuid4()
    relative_path, _size = save_upload(owner_id=current_user.id, media_id=image_id, upload=file)

    image = StudioPortfolioImage(id=image_id, owner_id=current_user.id, relative_path=relative_path)
    db.add(image)
    db.commit()
    db.refresh(image)

    return StudioPortfolioImageRead(id=image.id, url=build_media_url(image.relative_path))


@router.delete("/me/portfolio/{image_id}", response_model=MessageResponse)
def delete_portfolio_image(
    image_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Removes one image from the current studio's Showcase Portfolio grid."""
    image = db.execute(
        select(StudioPortfolioImage).where(
            StudioPortfolioImage.id == image_id, StudioPortfolioImage.owner_id == current_user.id
        )
    ).scalar_one_or_none()
    if image is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Portfolio image not found")

    delete_stored_file(image.relative_path)
    db.delete(image)
    db.commit()

    return MessageResponse(message="Portfolio image removed.")


# --------------------------------------------------------------------------
# Backup & Restore (Task 6). There's no settings table server-side today
# (settings live in the app's local Hive store — see
# `settings_local_store.dart`), so `POST /studios/me/backup` just stores
# whatever JSON blob the app sends as an opaque snapshot, and
# `GET /studios/me/backup` hands back the most recent one. Restore
# (Task 7) reads `payload` straight off the response.
# --------------------------------------------------------------------------

@router.post("/me/backup", response_model=StudioBackupRead, status_code=status.HTTP_201_CREATED)
def create_backup(
    payload: dict[str, Any] = Body(...),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> StudioBackupRead:
    """Saves a new settings-backup snapshot for the current studio.
    Each call adds a new row (see `StudioBackup` docstring) rather than
    overwriting a single record, so history stays available even though
    only the latest one is surfaced in the app today.
    """
    backup = StudioBackup(owner_id=current_user.id, payload=payload)
    db.add(backup)
    db.commit()
    db.refresh(backup)

    return StudioBackupRead.model_validate(backup)


@router.get("/me/backup", response_model=StudioBackupRead)
def get_latest_backup(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> StudioBackupRead:
    """Returns the current studio's most recent settings backup. Used
    both to show "Last backed up: ..." on the App Settings screen and,
    in Task 7, to restore from.
    """
    backup = db.execute(
        select(StudioBackup)
        .where(StudioBackup.owner_id == current_user.id)
        .order_by(StudioBackup.created_at.desc())
        .limit(1)
    ).scalar_one_or_none()

    if backup is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No backup found for this studio.")

    return StudioBackupRead.model_validate(backup)