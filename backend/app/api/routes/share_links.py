import logging
import secrets
import uuid
import os
import tempfile
import zipfile
from datetime import datetime, timezone
from starlette.background import BackgroundTask
from fastapi.responses import FileResponse

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile, status, Request
from collections import defaultdict
import hashlib
from sqlalchemy import select, delete, text, func
from sqlalchemy.orm import Session

from pydantic import BaseModel, EmailStr

from app.api.deps import get_current_studio_user, get_optional_current_user, require_active_plan
from app.core.download_log import record_download_event
from app.core.storage import get_signed_original_url
from app.core.face_index import extract_query_faces, resolve_query_face, search_faces
from app.core.security import hash_password, verify_password
from app.core.visibility import is_visible_to_client
from app.core.rules import get_effective_rules
from app.db.session import get_db
from app.models.gallery import Album, DownloadSource, Media, ShareLink, GalleryViewEvent, Folder, ShareLinkAlbum, ShareLinkFolder, ShareLinkMedia, ShareLinkEvent, ShareLinkEventType, ShareLinkFavourite, FaceSearchAttempt, FaceSearchEmail
from app.models.notification import Notification, NotificationType
from app.core.notification_service import send_push_if_enabled
from app.models.user import User
from app.schemas.face import DetectedFaceRead, FaceBoxRead, FaceMatchRead, FaceSearchResponse
from app.schemas.gallery import (
    MediaRead,
    PublicAlbumSummary,
    PublicFolderSummary,
    CurrentFolderInfo,
    PublicShareLinkRead,
    PublicShareLinkUnlockRequest,
    ShareLinkCreate,
    ShareLinkRead,
    ShareLinkStatusRead,
    ShareLinkUpdate,
    PrivateLinkRequest,
    ShareLinkFavouriteRequest,
    ShareLinkAnalyticsRead,
    _split_csv,
)
from app.schemas.user import MessageResponse

# Studio-side management — same auth model as albums/folders/media.
router = APIRouter(prefix="/share-links", tags=["gallery-share-links"])

# Client-facing viewing — deliberately has no auth dependency anywhere
# in this router. Every route here identifies the link purely by its
# opaque `token`, never by the internal `id`/`owner_id`.
public_router = APIRouter(prefix="/public/share-links", tags=["public-share-links"])


TOKEN_BYTES = 8  # secrets.token_urlsafe(8) -> 11 url-safe chars


def _generate_unique_token(db: Session) -> str:
    for _ in range(5):
        candidate = secrets.token_urlsafe(TOKEN_BYTES)
        exists = db.execute(select(ShareLink.id).where(ShareLink.token == candidate)).scalar_one_or_none()
        if exists is None:
            return candidate
    # Astronomically unlikely, but never loop forever.
    raise HTTPException(status_code=500, detail="Could not generate a unique share link token")


def _get_owned_link(db: Session, link_id: uuid.UUID, owner_id: uuid.UUID) -> ShareLink:
    link = db.get(ShareLink, link_id)
    if link is None or link.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="ShareLink not found")
    return link


def _fetch_album_ids_for_links(db: Session, links: list[ShareLink]) -> dict[uuid.UUID, list[uuid.UUID]]:
    link_ids = [link.id for link in links if link.source_folder_id is not None]
    if not link_ids:
        return {}
    
    rows = db.execute(
        select(ShareLinkAlbum.share_link_id, ShareLinkAlbum.album_id)
        .where(ShareLinkAlbum.share_link_id.in_(link_ids))
        .order_by(ShareLinkAlbum.display_order)
    ).all()
    
    mapping = {}
    for link_id, album_id in rows:
        mapping.setdefault(link_id, []).append(album_id)
    return mapping


def _fetch_folder_ids_for_links(db: Session, links: list[ShareLink]) -> dict[uuid.UUID, list[uuid.UUID]]:
    """Return {link_id: [folder_id, ...]} for all folder-type links."""
    link_ids = [link.id for link in links if link.source_folder_id is not None]
    if not link_ids:
        return {}
    rows = db.execute(
        select(ShareLinkFolder.share_link_id, ShareLinkFolder.folder_id)
        .where(ShareLinkFolder.share_link_id.in_(link_ids))
    ).all()
    mapping: dict[uuid.UUID, list[uuid.UUID]] = {}
    for link_id, folder_id in rows:
        mapping.setdefault(link_id, []).append(folder_id)
    return mapping


def _get_subtree_folder_ids(db: Session, root_id: uuid.UUID) -> set[uuid.UUID]:
    """Return all folder IDs in the subtree rooted at root_id (inclusive),
    using a recursive CTE. O(subtree size), called once per request.
    """
    rows = db.execute(
        text("""
            WITH RECURSIVE folder_tree AS (
                SELECT id FROM folders WHERE id = :root_id AND deleted_at IS NULL
                UNION ALL
                SELECT f.id FROM folders f
                INNER JOIN folder_tree ft ON f.parent_id = ft.id
                WHERE f.deleted_at IS NULL
            )
            SELECT id FROM folder_tree
        """),
        {"root_id": root_id},
    ).scalars().all()
    return set(rows)


def _folder_in_scope(db: Session, link: ShareLink, folder_id: uuid.UUID) -> bool:
    """Check whether a folder is accessible via this share link.

    Rules:
      - include_all=True  →  folder must be in the link's source_folder_id subtree.
      - otherwise         →  folder_id equals source_folder_id (the root, for listing)
                             OR folder_id is in the subtree of any share_link_folders row.
    Always requires is_visible_to_client and not deleted.
    """
    if not is_visible_to_client(db, folder_id=folder_id):
        return False
    folder = db.get(Folder, folder_id)
    if folder is None or folder.deleted_at is not None:
        return False

    root_id = link.source_folder_id
    if root_id is None:
        return False

    if getattr(link, 'include_all', False):
        # Any folder in the subtree of the root
        subtree = _get_subtree_folder_ids(db, root_id)
        return folder_id in subtree

    # folder_id equals root (for listing purposes)
    if folder_id == root_id:
        return True

    # folder_id is in the subtree of any explicitly shared folder
    shared_folders = db.execute(
        select(ShareLinkFolder.folder_id)
        .where(ShareLinkFolder.share_link_id == link.id)
    ).scalars().all()

    for sf_id in shared_folders:
        subtree = _get_subtree_folder_ids(db, sf_id)
        if folder_id in subtree:
            return True

    return False


def _media_in_scope(db: Session, link: ShareLink, media: Media) -> bool:
    """Check whether a media item is accessible via this share link.

    A media item is in scope if:
      1. media.album_id is in share_link_albums, OR
         the album is inside a folder in scope (include_all or shared-folder subtree).
      2. media is loose (album_id IS None) and:
         (media.folder_id == source_folder_id and (include_all or include_folder_items)),
         OR media.folder_id is in the subtree of a share_link_folders folder.

    Always requires not is_deleted, and folder/album visible to client.
    """
    if media.is_deleted:
        return False

    root_id = link.source_folder_id

    # --- media in an album ---
    if media.album_id is not None:
        # Old-style single-album link
        if link.album_id is not None and media.album_id == link.album_id:
            if not is_visible_to_client(db, album_id=media.album_id):
                return False
            return True
        # Check share_link_albums table
        in_link = db.execute(
            select(ShareLinkAlbum.id)
            .where(
                ShareLinkAlbum.share_link_id == link.id,
                ShareLinkAlbum.album_id == media.album_id,
            )
        ).scalar_one_or_none()
        if in_link is not None:
            return is_visible_to_client(db, album_id=media.album_id)

        # For include_all or folder-subtree shares: album must be in scope
        if root_id is not None and (getattr(link, 'include_all', False) or _has_folder_rows(db, link)):
            album = db.get(Album, media.album_id)
            if album is None or album.deleted_at is not None:
                return False
            if not is_visible_to_client(db, album_id=album.id):
                return False
            if album.folder_id is None:
                return False
            return _folder_in_scope(db, link, album.folder_id)

        return False

    # --- loose media (album_id IS None) ---
    if media.folder_id is None:
        return False

    if root_id is None:
        return False

    if not is_visible_to_client(db, folder_id=media.folder_id):
        return False

    # Loose items directly in the root folder
    if media.folder_id == root_id:
        return getattr(link, 'include_all', False) or getattr(link, 'include_folder_items', False)

    # Loose items in a sub-folder that is in scope
    return _folder_in_scope(db, link, media.folder_id)


def _has_folder_rows(db: Session, link: ShareLink) -> bool:
    """True when the link has at least one share_link_folders row."""
    n = db.execute(
        select(func.count(ShareLinkFolder.id))
        .where(ShareLinkFolder.share_link_id == link.id)
    ).scalar() or 0
    return n > 0


def _is_expired(link: ShareLink) -> bool:
    if link.expires_at is None:
        return False
    now = datetime.now(timezone.utc) if link.expires_at.tzinfo else datetime.utcnow()
    return link.expires_at <= now


# ---------------------------------------------------------------------------
# Studio-side management (auth required)
# ---------------------------------------------------------------------------


@router.post("", response_model=ShareLinkRead, status_code=status.HTTP_201_CREATED)
def create_share_link(
    payload: ShareLinkCreate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> ShareLinkRead:
    if payload.album_id:
        album = db.get(Album, payload.album_id)
        if album is None or album.owner_id != current_user.id or getattr(album, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Album not found")
    elif payload.source_folder_id:
        folder = db.get(Folder, payload.source_folder_id)
        if folder is None or folder.owner_id != current_user.id or getattr(folder, "deleted_at", None) is not None:
            raise HTTPException(status_code=404, detail="Folder not found")

    link = ShareLink(
        owner_id=current_user.id,
        album_id=payload.album_id,
        source_folder_id=payload.source_folder_id,
        auto_include_new=payload.auto_include_new,
        include_all=payload.include_all,
        include_folder_items=payload.include_folder_items,
        token=_generate_unique_token(db),
        client_id=payload.client_id,
        password_hash=hash_password(payload.password) if payload.password else None,
        pin_hash=hash_password(payload.pin) if payload.pin else None,
        expires_at=payload.expires_at,
        allow_download=payload.allow_download,
        show_watermark=payload.show_watermark,
        kind=payload.kind,
    )
    db.add(link)
    db.flush()

    if payload.source_folder_id:
        subtree = _get_subtree_folder_ids(db, payload.source_folder_id)

        # Persist album_ids
        if payload.album_ids is not None:
            valid_albums = db.execute(
                select(Album.id).where(
                    Album.folder_id.in_(subtree),
                    Album.id.in_(payload.album_ids),
                    Album.deleted_at.is_(None),
                )
            ).scalars().all()
            valid_album_set = set(valid_albums)
            for idx, a_id in enumerate(payload.album_ids):
                if a_id not in valid_album_set:
                    raise HTTPException(status_code=422, detail=f"Album {a_id} does not belong to the selected folder")
                if not is_visible_to_client(db, album_id=a_id):
                    raise HTTPException(status_code=422, detail=f"Cannot share hidden album {a_id}")
                db.add(ShareLinkAlbum(share_link_id=link.id, album_id=a_id, display_order=idx))

        # Persist folder_ids
        if payload.folder_ids is not None:
            for f_id in payload.folder_ids:
                if f_id not in subtree:
                    raise HTTPException(status_code=422, detail=f"Folder {f_id} is not inside the root folder")
                if not is_visible_to_client(db, folder_id=f_id):
                    raise HTTPException(status_code=422, detail=f"Cannot share hidden folder {f_id}")
                db.add(ShareLinkFolder(share_link_id=link.id, folder_id=f_id))

    db.commit()
    db.refresh(link)

    album_ids_map = _fetch_album_ids_for_links(db, [link])
    folder_ids_map = _fetch_folder_ids_for_links(db, [link])
    return ShareLinkRead.from_model(
        link,
        album_ids=album_ids_map.get(link.id),
        folder_ids=folder_ids_map.get(link.id),
    )


@router.get("", response_model=list[ShareLinkRead])
def list_share_links(
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    active_only: bool = False,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[ShareLinkRead]:
    query = select(ShareLink).where(ShareLink.owner_id == current_user.id)
    if album_id is not None:
        query = query.where(ShareLink.album_id == album_id)
    if folder_id is not None:
        query = query.where(ShareLink.source_folder_id == folder_id)
    if active_only:
        query = query.where(ShareLink.is_revoked.is_(False))
    query = query.order_by(ShareLink.created_at.desc())

    links = db.execute(query).scalars().all()
    album_ids_map = _fetch_album_ids_for_links(db, links)
    folder_ids_map = _fetch_folder_ids_for_links(db, links)

    results = [
        ShareLinkRead.from_model(
            link,
            album_ids=album_ids_map.get(link.id),
            folder_ids=folder_ids_map.get(link.id),
        )
        for link in links
    ]
    return [r for r in results if not active_only or r.is_active]


@router.get("/{link_id}", response_model=ShareLinkRead)
def get_share_link(
    link_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> ShareLinkRead:
    link = _get_owned_link(db, link_id, current_user.id)
    album_ids_map = _fetch_album_ids_for_links(db, [link])
    folder_ids_map = _fetch_folder_ids_for_links(db, [link])
    return ShareLinkRead.from_model(
        link,
        album_ids=album_ids_map.get(link.id),
        folder_ids=folder_ids_map.get(link.id),
    )


@router.patch("/{link_id}", response_model=ShareLinkRead)
def update_share_link(
    link_id: uuid.UUID,
    payload: ShareLinkUpdate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> ShareLinkRead:
    link = _get_owned_link(db, link_id, current_user.id)
    updates = payload.model_dump(exclude_unset=True, exclude={"clear_password", "clear_expiry", "clear_client", "clear_pin"})

    if payload.clear_client:
        link.client_id = None
    elif "client_id" in updates and updates["client_id"] is not None:
        link.client_id = updates["client_id"]

    if payload.clear_password:
        link.password_hash = None
    elif "password" in updates and updates["password"] is not None:
        link.password_hash = hash_password(updates["password"])

    if payload.clear_pin:
        link.pin_hash = None
    elif "pin" in updates and updates["pin"] is not None:
        link.pin_hash = hash_password(updates["pin"])

    if payload.clear_expiry:
        link.expires_at = None
    elif "expires_at" in updates and updates["expires_at"] is not None:
        link.expires_at = updates["expires_at"]

    if "allow_download" in updates and updates["allow_download"] is not None:
        link.allow_download = updates["allow_download"]
    if "show_watermark" in updates and updates["show_watermark"] is not None:
        link.show_watermark = updates["show_watermark"]
    if "is_revoked" in updates and updates["is_revoked"] is not None:
        link.is_revoked = updates["is_revoked"]
    if "auto_include_new" in updates and updates["auto_include_new"] is not None:
        link.auto_include_new = updates["auto_include_new"]
    if "include_all" in updates and updates["include_all"] is not None:
        link.include_all = updates["include_all"]
    if "include_folder_items" in updates and updates["include_folder_items"] is not None:
        link.include_folder_items = updates["include_folder_items"]
    if "kind" in updates and updates["kind"] is not None:
        link.kind = updates["kind"]

    if link.source_folder_id and ("album_ids" in updates or "folder_ids" in updates):
        subtree = _get_subtree_folder_ids(db, link.source_folder_id)

        if "album_ids" in updates and updates["album_ids"] is not None:
            db.execute(delete(ShareLinkAlbum).where(ShareLinkAlbum.share_link_id == link.id))
            valid_albums = db.execute(
                select(Album.id).where(
                    Album.folder_id.in_(subtree),
                    Album.id.in_(updates["album_ids"]),
                    Album.deleted_at.is_(None),
                )
            ).scalars().all()
            valid_album_set = set(valid_albums)
            for idx, a_id in enumerate(updates["album_ids"]):
                if a_id not in valid_album_set:
                    raise HTTPException(status_code=422, detail=f"Album {a_id} does not belong to the selected folder")
                if not is_visible_to_client(db, album_id=a_id):
                    raise HTTPException(status_code=422, detail=f"Cannot share hidden album {a_id}")
                db.add(ShareLinkAlbum(share_link_id=link.id, album_id=a_id, display_order=idx))

        if "folder_ids" in updates and updates["folder_ids"] is not None:
            db.execute(delete(ShareLinkFolder).where(ShareLinkFolder.share_link_id == link.id))
            for f_id in updates["folder_ids"]:
                if f_id not in subtree:
                    raise HTTPException(status_code=422, detail=f"Folder {f_id} is not inside the root folder")
                if not is_visible_to_client(db, folder_id=f_id):
                    raise HTTPException(status_code=422, detail=f"Cannot share hidden folder {f_id}")
                db.add(ShareLinkFolder(share_link_id=link.id, folder_id=f_id))

    db.commit()
    db.refresh(link)
    album_ids_map = _fetch_album_ids_for_links(db, [link])
    folder_ids_map = _fetch_folder_ids_for_links(db, [link])
    return ShareLinkRead.from_model(
        link,
        album_ids=album_ids_map.get(link.id),
        folder_ids=folder_ids_map.get(link.id),
    )


@router.get("/{link_id}/analytics", response_model=ShareLinkAnalyticsRead)
def get_share_link_analytics(
    link_id: uuid.UUID,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_active_plan),
) -> ShareLinkAnalyticsRead:
    link = db.get(ShareLink, link_id)
    if link is None or link.owner_id != current_user.id or getattr(link, "deleted_at", None) is not None:
        raise HTTPException(status_code=404, detail="Share link not found")
        
    from sqlalchemy import func
    
    events = db.execute(select(ShareLinkEvent).where(ShareLinkEvent.share_link_id == link.id)).scalars().all()
    
    views_count = sum(1 for e in events if e.event_type == ShareLinkEventType.view)
    downloads_count = sum(1 for e in events if e.event_type == ShareLinkEventType.download)
    face_searches_count = sum(1 for e in events if e.event_type == ShareLinkEventType.face_search)
    emails_submitted = sum(1 for e in events if e.event_type == ShareLinkEventType.email_submit)
    favourites_count = sum(1 for e in events if e.event_type == ShareLinkEventType.favourite)
    
    favs = db.execute(
        select(ShareLinkFavourite.media_id, func.count(ShareLinkFavourite.id))
        .where(ShareLinkFavourite.share_link_id == link.id)
        .group_by(ShareLinkFavourite.media_id)
    ).all()
    
    favourites_breakdown = [{"media_id": str(m), "count": c} for m, c in favs]
    
    # Task 5.3: Fetch captured emails
    emails = db.execute(
        select(FaceSearchEmail.email)
        .where(FaceSearchEmail.share_link_id == link.id)
        .order_by(FaceSearchEmail.created_at.desc())
    ).scalars().all()
    
    return ShareLinkAnalyticsRead(
        views_count=views_count,
        downloads_count=downloads_count,
        face_searches_count=face_searches_count,
        emails_submitted=emails_submitted,
        favourites_count=favourites_count,
        favourites_breakdown=favourites_breakdown,
        emails_captured=list(emails),
    )


@router.delete("/{link_id}", response_model=MessageResponse)
def delete_share_link(
    link_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    link = _get_owned_link(db, link_id, current_user.id)
    db.delete(link)
    db.commit()
    return MessageResponse(message="Share link deleted.")


# ---------------------------------------------------------------------------
# Public viewing (optional auth) — used by the client-side "Shared Gallery" screen
# ---------------------------------------------------------------------------


logger = logging.getLogger(__name__)


def _get_link_by_token_or_404(db: Session, token: str) -> ShareLink:
    logger.info(f"[SHARE_LOOKUP_DEBUG] Share lookup request: shareId (token)='{token}'")
    link = db.execute(select(ShareLink).where(ShareLink.token == token)).scalar_one_or_none()
    if link is None:
        logger.warning(f"[SHARE_LOOKUP_DEBUG] Share record NOT found for token='{token}'")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "GALLERY_NOT_FOUND", "message": "This gallery is no longer available"},
        )
    logger.info(f"[SHARE_LOOKUP_DEBUG] Share record found: id='{link.id}', albumId='{link.album_id}', is_revoked={link.is_revoked}")
    return link


def _assert_link_reachable(link: ShareLink) -> None:
    if link.is_revoked:
        logger.warning(f"[SHARE_LOOKUP_DEBUG] Share link '{link.token}' has been revoked.")
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail={"code": "GALLERY_REVOKED", "message": "This gallery is no longer available"},
        )
    if _is_expired(link):
        logger.warning(f"[SHARE_LOOKUP_DEBUG] Share link '{link.token}' has expired.")
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail={"code": "GALLERY_EXPIRED", "message": "This gallery link has expired."},
        )


def _assert_client_authorized(link: ShareLink, user: User | None) -> None:
    if link.client_id is None:
        return
    if user is None or (user.id != link.client_id and user.id != link.owner_id):
        logger.warning(
            f"[SHARE_LOOKUP_DEBUG] Unauthorized client '{user.id if user else None}' attempted access to private share '{link.token}' (authorized client_id: '{link.client_id}', owner: '{link.owner_id}')"
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "UNAUTHORIZED_CLIENT", "message": "You are not authorized to access this private gallery."},
        )


def _get_share_target(db: Session, link: ShareLink) -> tuple[Album | None, Folder | None]:
    if link.album_id:
        logger.info(f"[SHARE_LOOKUP_DEBUG] Album lookup request for albumId='{link.album_id}' (from share token='{link.token}')")
        album = db.get(Album, link.album_id)
        if album is None:
            logger.error(f"[SHARE_LOOKUP_DEBUG] Linked albumId='{link.album_id}' NOT found in database for share token='{link.token}')")
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "GALLERY_NOT_FOUND", "message": "This shared gallery is no longer available."},
            )
        logger.info(f"[SHARE_LOOKUP_DEBUG] Album found: name='{album.name}', owner_id='{album.owner_id}')")
        if not is_visible_to_client(db, album_id=album.id):
            logger.error(f"[SHARE_LOOKUP_DEBUG] Linked albumId='{link.album_id}' is hidden for share token='{link.token}')")
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "GALLERY_NOT_FOUND", "message": "This shared gallery is no longer available."},
            )
        return album, None
    elif link.source_folder_id:
        logger.info(f"[SHARE_LOOKUP_DEBUG] Folder lookup request for sourceFolderId='{link.source_folder_id}' (from share token='{link.token}')")
        folder = db.get(Folder, link.source_folder_id)
        if folder is None or folder.deleted_at is not None:
            logger.error(f"[SHARE_LOOKUP_DEBUG] Linked sourceFolderId='{link.source_folder_id}' NOT found in database for share token='{link.token}')")
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "FOLDER_NOT_FOUND", "message": "This shared folder is no longer available."},
            )
        logger.info(f"[SHARE_LOOKUP_DEBUG] Folder found: name='{folder.name}', owner_id='{folder.owner_id}')")
        return None, folder
    
    raise HTTPException(status_code=500, detail="Invalid share link target")


def _assert_credentials_ok(db: Session, link: ShareLink, password: str | None, pin: str | None, request: Request | None) -> None:
    if link.password_hash:
        if not password:
            logger.warning(f"[SHARE_LOOKUP_DEBUG] Password required for share link '{link.token}'")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"code": "PASSWORD_REQUIRED", "message": "Password is required for this gallery."},
            )
        if not verify_password(password, link.password_hash):
            logger.warning(f"[SHARE_LOOKUP_DEBUG] Incorrect passcode attempt for share link '{link.token}'")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"code": "INVALID_PASSWORD", "message": "Incorrect password."},
            )

    if link.pin_hash:
        ip = request.client.host if request and request.client else "unknown"
        ip_hash = hashlib.sha256(ip.encode('utf-8')).hexdigest()
        now = datetime.now(timezone.utc)
        from datetime import timedelta
        lockout_time = now - timedelta(minutes=15)
        
        from app.models.gallery import ShareLinkPinAttempt
        
        recent_attempts = db.execute(
            select(func.count(ShareLinkPinAttempt.id)).where(
                ShareLinkPinAttempt.share_link_id == link.id,
                ShareLinkPinAttempt.ip_hash == ip_hash,
                ShareLinkPinAttempt.created_at >= lockout_time
            )
        ).scalar() or 0
        
        if recent_attempts >= 5:
            raise HTTPException(status_code=429, detail="Too many incorrect PIN attempts. Try again in 15 minutes.")

        if not pin:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"code": "PIN_REQUIRED", "message": "PIN is required for this gallery."},
            )
        
        if not verify_password(pin, link.pin_hash):
            db.add(ShareLinkPinAttempt(share_link_id=link.id, ip_hash=ip_hash))
            db.commit()
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"code": "INVALID_PIN", "message": "Incorrect PIN."},
            )


def _verify_link_access(db: Session, token: str, user: User | None = None, password: str | None = None, pin: str | None = None, check_password: bool = True, request: Request | None = None) -> ShareLink:
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_client_authorized(link, user)
    if check_password:
        _assert_credentials_ok(db, link, password, pin, request)
    return link


@public_router.get("/{token}/status", response_model=ShareLinkStatusRead)
def get_share_link_status(
    token: str,
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> ShareLinkStatusRead:
    """Lets the client render the passcode gate (or an expired/revoked/unauthorized
    message) without submitting a password and without counting a view.
    """
    logger.info(f"[SHARE_LOOKUP_DEBUG] Public status check for token='{token}'")
    link = _verify_link_access(db, token, user, check_password=False)
    _get_share_target(db, link)
    active = not link.is_revoked and not _is_expired(link)
    return ShareLinkStatusRead(
        requires_password=link.password_hash is not None, 
        requires_pin=link.pin_hash is not None,
        is_active=active, 
        client_id=link.client_id,
        kind=link.kind
    )


@public_router.get("/{token}", response_model=PublicShareLinkRead)
def view_shared_gallery(
    token: str,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    """Fetches the shared album + its media. Requires authorized client check
    and the correct `password` query param if the link is protected. Each
    successful call counts as one view for analytics.
    """
    logger.info(f"[SHARE_LOOKUP_DEBUG] Public view gallery request for token='{token}'")
    link = _verify_link_access(db, token, user, password, pin, True, request)
    album, folder = _get_share_target(db, link)

    link.views_count += 1
    link.last_viewed_at = datetime.now(timezone.utc)
    db.add(GalleryViewEvent(
        owner_id=link.owner_id,
        share_link_id=link.id,
        album_id=album.id if album else None,
        viewer_id=user.id if user else None
    ))
    db.add(ShareLinkEvent(
        share_link_id=link.id,
        event_type=ShareLinkEventType.view,
    ))
    db.commit()
    
    from app.schemas.gallery import PublicCollectionSummary

    if album:
        from app.models.gallery import ShareLinkKind, ShareLinkMedia
        if link.kind == ShareLinkKind.face_search:
            media = []
        elif link.kind == ShareLinkKind.selection:
            media = db.execute(
                select(Media)
                .join(ShareLinkMedia, ShareLinkMedia.media_id == Media.id)
                .where(ShareLinkMedia.share_link_id == link.id, Media.is_deleted.is_(False))
                .order_by(Media.created_at.desc())
            ).scalars().all()
        else:
            media = db.execute(
                select(Media)
                .where(Media.album_id == album.id, Media.is_deleted.is_(False))
                .order_by(Media.created_at.desc())
            ).scalars().all()
    
        logger.info(f"[SHARE_LOOKUP_DEBUG] Public view gallery success for token='{token}' -> albumId='{album.id}', media count={len(media)}")
    
        owner = db.get(User, link.owner_id)
        studio_logo_url = owner.avatar_url if owner else None

        return PublicShareLinkRead(
            token=link.token,
            album=PublicAlbumSummary(
                id=album.id,
                name=album.name,
                description=album.description,
                gradient_argb=_split_csv(album.gradient_argb),
            ),
            media=[MediaRead.from_model(m) for m in media],
            allow_download=link.allow_download,
            show_watermark=link.show_watermark,
            requires_password=link.password_hash is not None,
            requires_pin=link.pin_hash is not None,
            studio_logo_url=studio_logo_url,
            kind=link.kind,
        )
    elif folder:
        from app.models.gallery import ShareLinkKind
        owner = db.get(User, link.owner_id)
        studio_logo_url = owner.avatar_url if owner else None

        if link.kind == ShareLinkKind.face_search:
            # Face search: no listing, just return empty
            return PublicShareLinkRead(
                token=link.token,
                albums=[],
                folders=[],
                allow_download=link.allow_download,
                show_watermark=link.show_watermark,
                requires_password=link.password_hash is not None,
                requires_pin=link.pin_hash is not None,
                studio_logo_url=studio_logo_url,
                kind=link.kind,
            )

        include_all = getattr(link, 'include_all', False)

        # --- Determine in-scope sub-folders of the root ---
        if include_all:
            # All non-hidden, non-deleted direct children of root
            root_subfolder_rows = db.execute(
                select(Folder).where(
                    Folder.parent_id == folder.id,
                    Folder.deleted_at.is_(None),
                )
            ).scalars().all()
            in_scope_subfolders = [f for f in root_subfolder_rows if is_visible_to_client(db, folder_id=f.id)]
        else:
            # Only folders explicitly in share_link_folders that are direct children of root
            shared_folder_ids = db.execute(
                select(ShareLinkFolder.folder_id)
                .where(ShareLinkFolder.share_link_id == link.id)
            ).scalars().all()
            shared_folder_id_set = set(shared_folder_ids)
            root_subfolder_rows = db.execute(
                select(Folder).where(
                    Folder.parent_id == folder.id,
                    Folder.deleted_at.is_(None),
                    Folder.id.in_(shared_folder_id_set) if shared_folder_id_set else False,
                )
            ).scalars().all() if shared_folder_id_set else []
            in_scope_subfolders = [f for f in root_subfolder_rows if is_visible_to_client(db, folder_id=f.id)]

        # --- Count albums and items per sub-folder (no N+1: one query) ---
        if in_scope_subfolders:
            sf_ids = [f.id for f in in_scope_subfolders]
            album_counts_raw = db.execute(
                select(Album.folder_id, func.count(Album.id))
                .where(Album.folder_id.in_(sf_ids), Album.deleted_at.is_(None))
                .group_by(Album.folder_id)
            ).all()
            album_counts = {row[0]: row[1] for row in album_counts_raw}

            media_counts_raw = db.execute(
                select(Media.folder_id, func.count(Media.id))
                .where(
                    Media.folder_id.in_(sf_ids),
                    Media.album_id.is_(None),
                    Media.is_deleted.is_(False),
                )
                .group_by(Media.folder_id)
            ).all()
            media_counts = {row[0]: row[1] for row in media_counts_raw}
        else:
            album_counts = {}
            media_counts = {}

        folder_summaries = [
            PublicFolderSummary(
                id=f.id,
                name=f.name,
                gradient_argb=_split_csv(getattr(f, 'gradient_argb', None)),
                album_count=album_counts.get(f.id, 0),
                item_count=media_counts.get(f.id, 0),
            )
            for f in in_scope_subfolders
        ]

        # --- Albums directly in root ---
        if include_all:
            root_albums_rows = db.execute(
                select(Album).where(
                    Album.folder_id == folder.id,
                    Album.deleted_at.is_(None),
                )
            ).scalars().all()
            root_albums = [a for a in root_albums_rows if is_visible_to_client(db, album_id=a.id)]
        else:
            root_albums_rows = db.execute(
                select(Album)
                .join(ShareLinkAlbum, ShareLinkAlbum.album_id == Album.id)
                .where(
                    ShareLinkAlbum.share_link_id == link.id,
                    Album.folder_id == folder.id,
                    Album.deleted_at.is_(None),
                )
                .order_by(ShareLinkAlbum.display_order.asc())
            ).scalars().all()
            root_albums = [a for a in root_albums_rows if is_visible_to_client(db, album_id=a.id)]

        album_summaries = [
            PublicAlbumSummary(
                id=a.id,
                name=a.name,
                description=a.description,
                gradient_argb=_split_csv(a.gradient_argb),
            )
            for a in root_albums
        ]

        # --- Loose media directly in root ---
        include_folder_items = getattr(link, 'include_folder_items', False)
        if include_all or include_folder_items:
            loose_media = db.execute(
                select(Media).where(
                    Media.folder_id == folder.id,
                    Media.album_id.is_(None),
                    Media.is_deleted.is_(False),
                ).order_by(Media.created_at.desc())
            ).scalars().all()
        else:
            loose_media = []

        return PublicShareLinkRead(
            token=link.token,
            albums=album_summaries,
            folders=folder_summaries,
            media=[MediaRead.from_model(m) for m in loose_media],
            allow_download=link.allow_download,
            show_watermark=link.show_watermark,
            requires_password=link.password_hash is not None,
            requires_pin=link.pin_hash is not None,
            studio_logo_url=studio_logo_url,
            kind=link.kind,
        )


@public_router.get("/{token}/folders/{folder_id}", response_model=PublicShareLinkRead)
def view_shared_gallery_folder(
    token: str,
    folder_id: uuid.UUID,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    """Returns the contents of a sub-folder in a folder share link:
    its direct sub-folders, albums, and loose media (all subject to scope
    and visibility rules). 404 if folder_id is not in scope.
    """
    link = _verify_link_access(db, token, user, password, pin, True, request)

    if not _folder_in_scope(db, link, folder_id):
        raise HTTPException(status_code=404, detail="Folder not found in this share")

    current_folder_obj = db.get(Folder, folder_id)
    if current_folder_obj is None:
        raise HTTPException(status_code=404, detail="Folder not found")

    # Count view
    link.views_count += 1
    link.last_viewed_at = datetime.now(timezone.utc)
    db.add(ShareLinkEvent(share_link_id=link.id, event_type=ShareLinkEventType.view))
    db.commit()

    include_all = getattr(link, 'include_all', False)
    owner = db.get(User, link.owner_id)
    studio_logo_url = owner.avatar_url if owner else None

    # Sub-folders of this folder that are in scope
    child_folders = db.execute(
        select(Folder).where(
            Folder.parent_id == folder_id,
            Folder.deleted_at.is_(None),
        )
    ).scalars().all()
    in_scope_children = [f for f in child_folders if _folder_in_scope(db, link, f.id)]

    if in_scope_children:
        cf_ids = [f.id for f in in_scope_children]
        album_counts_raw = db.execute(
            select(Album.folder_id, func.count(Album.id))
            .where(Album.folder_id.in_(cf_ids), Album.deleted_at.is_(None))
            .group_by(Album.folder_id)
        ).all()
        album_counts = {row[0]: row[1] for row in album_counts_raw}
        media_counts_raw = db.execute(
            select(Media.folder_id, func.count(Media.id))
            .where(
                Media.folder_id.in_(cf_ids),
                Media.album_id.is_(None),
                Media.is_deleted.is_(False),
            )
            .group_by(Media.folder_id)
        ).all()
        media_counts = {row[0]: row[1] for row in media_counts_raw}
    else:
        album_counts = {}
        media_counts = {}

    folder_summaries = [
        PublicFolderSummary(
            id=f.id,
            name=f.name,
            gradient_argb=_split_csv(getattr(f, 'gradient_argb', None)),
            album_count=album_counts.get(f.id, 0),
            item_count=media_counts.get(f.id, 0),
        )
        for f in in_scope_children
    ]

    # Albums in this folder
    if include_all:
        album_rows = db.execute(
            select(Album).where(Album.folder_id == folder_id, Album.deleted_at.is_(None))
        ).scalars().all()
        folder_albums = [a for a in album_rows if is_visible_to_client(db, album_id=a.id)]
    else:
        album_rows = db.execute(
            select(Album)
            .join(ShareLinkAlbum, ShareLinkAlbum.album_id == Album.id)
            .where(
                ShareLinkAlbum.share_link_id == link.id,
                Album.folder_id == folder_id,
                Album.deleted_at.is_(None),
            )
            .order_by(ShareLinkAlbum.display_order.asc())
        ).scalars().all()
        folder_albums = [a for a in album_rows if is_visible_to_client(db, album_id=a.id)]

    album_summaries = [
        PublicAlbumSummary(
            id=a.id,
            name=a.name,
            description=a.description,
            gradient_argb=_split_csv(a.gradient_argb),
        )
        for a in folder_albums
    ]

    # Loose media in this folder
    loose_media = db.execute(
        select(Media).where(
            Media.folder_id == folder_id,
            Media.album_id.is_(None),
            Media.is_deleted.is_(False),
        ).order_by(Media.created_at.desc())
    ).scalars().all()
    # Only return loose media if this folder is fully in scope
    if not (include_all or _folder_in_scope(db, link, folder_id)):
        loose_media = []

    return PublicShareLinkRead(
        token=link.token,
        albums=album_summaries,
        folders=folder_summaries,
        media=[MediaRead.from_model(m) for m in loose_media],
        current_folder=CurrentFolderInfo(
            id=current_folder_obj.id,
            name=current_folder_obj.name,
            parent_id=current_folder_obj.parent_id,
        ),
        allow_download=link.allow_download,
        show_watermark=link.show_watermark,
        requires_password=link.password_hash is not None,
        requires_pin=link.pin_hash is not None,
        studio_logo_url=studio_logo_url,
        kind=link.kind,
    )


@public_router.get("/{token}/albums/{album_id}", response_model=PublicShareLinkRead)
def view_shared_gallery_album(
    token: str,
    album_id: uuid.UUID,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    """Fetches a specific album within a multi-album (Folder) share link."""
    link = _verify_link_access(db, token, user, password, pin, True, request)

    if link.source_folder_id is None:
        raise HTTPException(status_code=400, detail="Not a multi-album link")

    album = db.get(Album, album_id)
    if album is None or not is_visible_to_client(db, album_id=album.id):
        raise HTTPException(status_code=404, detail="Album not found")

    # Verify album is in scope for this link (handles include_all, share_link_albums, and subtree)
    include_all = getattr(link, 'include_all', False)
    if not include_all:
        link_album = db.execute(
            select(ShareLinkAlbum).where(ShareLinkAlbum.share_link_id == link.id, ShareLinkAlbum.album_id == album_id)
        ).scalar_one_or_none()
        if link_album is None:
            # Also check if album's folder is in scope (for folder-subtree shares)
            if album.folder_id is None or not _folder_in_scope(db, link, album.folder_id):
                raise HTTPException(status_code=404, detail="Album not found in this share")
    else:
        # include_all: album must be in the subtree of source_folder_id
        if album.folder_id is None or not _folder_in_scope(db, link, album.folder_id):
            raise HTTPException(status_code=404, detail="Album not found in this share")
        
    link.views_count += 1
    link.last_viewed_at = datetime.now(timezone.utc)
    db.add(GalleryViewEvent(
        owner_id=link.owner_id,
        share_link_id=link.id,
        album_id=album.id,
        viewer_id=user.id if user else None
    ))
    db.commit()

    from app.models.gallery import ShareLinkKind, ShareLinkMedia
    if link.kind == ShareLinkKind.face_search:
        media = []
    elif link.kind == ShareLinkKind.selection:
        media = db.execute(
            select(Media)
            .join(ShareLinkMedia, ShareLinkMedia.media_id == Media.id)
            .where(ShareLinkMedia.share_link_id == link.id, Media.album_id == album.id, Media.is_deleted.is_(False))
            .order_by(Media.created_at.desc())
        ).scalars().all()
    else:
        media = db.execute(
            select(Media)
            .where(Media.album_id == album.id, Media.is_deleted.is_(False))
            .order_by(Media.created_at.desc())
        ).scalars().all()

    owner = db.get(User, link.owner_id)
    studio_logo_url = owner.avatar_url if owner else None

    return PublicShareLinkRead(
        token=link.token,
        album=PublicAlbumSummary(
            id=album.id,
            name=album.name,
            description=album.description,
            gradient_argb=_split_csv(album.gradient_argb),
        ),
        media=[MediaRead.from_model(m) for m in media],
        allow_download=link.allow_download,
        show_watermark=link.show_watermark,
        requires_password=link.password_hash is not None,
        requires_pin=link.pin_hash is not None,
        studio_logo_url=studio_logo_url,
        kind=link.kind,
    )


@public_router.post("/{token}/download", response_model=MessageResponse)
def record_shared_download(
    token: str,
    request: Request,
    payload: PublicShareLinkUnlockRequest,
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Called by the client right before it actually downloads a photo
    from a shared gallery. Keeps `downloads_count` accurate and, when
    `media_id` is supplied, writes a Download History row (Task 22) so
    the studio can see who downloaded what and when. Re-validates the
    password so a direct hit on this endpoint can't bypass gallery
    protection.
    """
    link = _verify_link_access(db, token, user, payload.password, payload.pin, True, request)

    if not link.allow_download:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Downloads are disabled for this share link.",
        )

    if payload.media_id is not None:
        media = db.get(Media, payload.media_id)
        if media is None or media.is_deleted:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Media not found.",
            )

        # Use the unified scope helper so loose items and include_all links work too.
        if not _media_in_scope(db, link, media):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Media not found in this shared gallery.",
            )
        record_download_event(
            db,
            media=media,
            source=DownloadSource.share_link,
            share_link_id=link.id,
            downloader_label=payload.downloader_label,
        )

    link.downloads_count += 1
    link.last_downloaded_at = datetime.now(timezone.utc)
    db.add(ShareLinkEvent(
        share_link_id=link.id,
        event_type=ShareLinkEventType.download,
    ))
    db.commit()
    return MessageResponse(message="Download recorded.")




@public_router.post("/{token}/face-search", response_model=FaceSearchResponse)
async def face_search_shared_gallery(
    token: str,
    request: Request,
    email: EmailStr | None = Form(default=None),
    phone: str | None = Form(default=None),
    file: UploadFile = File(...),
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    face_index: int | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> FaceSearchResponse:
    """"Find my photos" for a guest viewing a shared gallery — no
    account needed, same as viewing the gallery itself. The guest
    uploads a selfie and gets back every photo in *this* shared album
    whose best face match clears the studio's configured threshold.
    Mirrors the public search flow from `event_face_finder_api`, just
    scoped to a PicGallery share link's single album instead of a
    standalone "event".
    """
    link = _verify_link_access(db, token, user, password, pin, True, request)

    ip = request.client.host if request.client else "unknown"
    ip_hash = hashlib.sha256(ip.encode('utf-8')).hexdigest()
    now = datetime.now(timezone.utc)
    from datetime import timedelta
    
    # Clean up old records periodically? Let's just query what we need.
    hour_ago = now - timedelta(hours=1)
    day_ago = now - timedelta(days=1)
    
    recent_link_attempts = db.execute(
        select(func.count(FaceSearchAttempt.id)).where(
            FaceSearchAttempt.share_link_id == link.id,
            FaceSearchAttempt.ip_hash == ip_hash,
            FaceSearchAttempt.created_at >= hour_ago
        )
    ).scalar() or 0
    
    if recent_link_attempts >= 5:
        raise HTTPException(status_code=429, detail="Too many face searches for this link. Try again later.")
        
    recent_daily_attempts = db.execute(
        select(func.count(FaceSearchAttempt.id)).where(
            FaceSearchAttempt.ip_hash == ip_hash,
            FaceSearchAttempt.created_at >= day_ago
        )
    ).scalar() or 0
    
    if recent_daily_attempts >= 20:
        raise HTTPException(status_code=429, detail="Daily face search limit reached.")

    db.add(FaceSearchAttempt(share_link_id=link.id, ip_hash=ip_hash))
    # db.commit() happens further down

    try:
        faces = await extract_query_faces(file)
        chosen_index, chosen_face = resolve_query_face(faces, face_index)
    except HTTPException:
        raise
    except Exception as exc:
        import traceback
        logger.error("Face extraction failed: %s\n%s", exc, traceback.format_exc())
        raise HTTPException(status_code=500, detail="Face detection failed on the server. Please try again with a clearer photo.")

    authorized_album_ids = set()
    authorized_folder_ids = set()

    if link.source_folder_id:
        if getattr(link, 'include_all', False):
            # Authorize all subfolders in the subtree and their albums
            from app.api.routes.share_links import _get_subtree_folder_ids
            all_folders = _get_subtree_folder_ids(db, link.source_folder_id)
            all_folders.add(link.source_folder_id)
            authorized_folder_ids = {f for f in all_folders if is_visible_to_client(db, folder_id=f)}
            
            if authorized_folder_ids:
                rows = db.execute(
                    select(Album.id).where(Album.folder_id.in_(authorized_folder_ids), Album.deleted_at.is_(None))
                ).scalars().all()
                authorized_album_ids = {a_id for a_id in rows if is_visible_to_client(db, album_id=a_id)}
        else:
            # Explicitly shared folders and albums
            f_rows = db.execute(
                select(ShareLinkFolder.folder_id).where(ShareLinkFolder.share_link_id == link.id)
            ).scalars().all()
            authorized_folder_ids = {f for f in f_rows if is_visible_to_client(db, folder_id=f)}
            # The root folder is always authorized for loose media if we have shared albums/folders inside it?
            # Actually, loose media in the root folder itself is only shared if include_all is true.
            # But let's check explicitly shared albums
            a_rows = db.execute(
                select(ShareLinkAlbum.album_id).where(ShareLinkAlbum.share_link_id == link.id)
            ).scalars().all()
            authorized_album_ids = {a_id for a_id in a_rows if is_visible_to_client(db, album_id=a_id)}
            
    elif link.album_id:
        authorized_album_ids = {link.album_id} if is_visible_to_client(db, album_id=link.album_id) else set()

    from app.core.face_index import search_client_faces
    matches = search_client_faces(
        db,
        query_embedding=chosen_face["embedding"],
        authorized_album_ids=authorized_album_ids,
        authorized_folder_ids=authorized_folder_ids,
    )

    db.add(ShareLinkEvent(
        share_link_id=link.id,
        event_type=ShareLinkEventType.face_search,
    ))
    db.add(FaceSearchEmail(
        share_link_id=link.id,
        email=email or "guest@anonymous.com",
        phone=phone
    ))
    db.commit()

    return FaceSearchResponse(
        detected_faces=[
            DetectedFaceRead(face_index=i, box=FaceBoxRead(**f["box"]), confidence=f["confidence"])
            for i, f in enumerate(faces)
        ],
        searched_face_index=chosen_index,
        matches=[FaceMatchRead(media=MediaRead.from_model(m), similarity=round(s, 4)) for m, s in matches],
    )


@public_router.post("/{token}/request-private-link", response_model=PublicShareLinkRead)
def request_private_link(
    token: str,
    payload: PrivateLinkRequest,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    link = _verify_link_access(db, token, user, password, pin, True, request)

    from app.models.gallery import ShareLinkKind

    if not payload.media_ids:
        raise HTTPException(status_code=400, detail="No media IDs provided")
        
    valid_media = db.execute(
        select(Media.id).where(Media.id.in_(payload.media_ids), Media.owner_id == link.owner_id, Media.is_deleted.is_(False))
    ).scalars().all()
    if len(valid_media) != len(set(payload.media_ids)):
        raise HTTPException(status_code=422, detail="One or more media IDs are invalid")

    new_token = _generate_unique_token(db)
    from datetime import timedelta
    new_link = ShareLink(
        owner_id=link.owner_id,
        album_id=link.album_id,
        source_folder_id=link.source_folder_id,
        token=new_token,
        kind=ShareLinkKind.selection,
        expires_at=datetime.now(timezone.utc) + timedelta(days=30),
        allow_download=link.allow_download,
        show_watermark=link.show_watermark,
    )
    db.add(new_link)
    db.flush()

    for m_id in payload.media_ids:
        db.add(ShareLinkMedia(share_link_id=new_link.id, media_id=m_id))

    if payload.email:
        db.add(ShareLinkEvent(
            share_link_id=link.id,
            event_type=ShareLinkEventType.email_submit,
        ))
        
        # Notify owner
        db.add(Notification(
            user_id=link.owner_id,
            type=NotificationType.gallery,
            title="Private Link Requested",
            subtitle=f"{payload.email} requested their face search matches.",
            data={"share_link_id": str(link.id)}
        ))
        owner = db.get(User, link.owner_id)
        if owner:
            send_push_if_enabled(
                user=owner,
                title="Private Link Requested",
                body=f"{payload.email} requested their face search matches.",
                data={"type": "gallery", "share_link_id": str(link.id)}
            )

    db.commit()
    db.refresh(new_link)
    
    return view_shared_gallery(token=new_token, password=None, pin=None, user=None, request=request, db=db)


@public_router.post("/{token}/favourites", response_model=MessageResponse)
def toggle_favourite(
    token: str,
    payload: ShareLinkFavouriteRequest,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Toggles the favourite status of a media item for a guest."""
    link = _verify_link_access(db, token, user, password, pin, True, request)

    media = db.get(Media, payload.media_id)
    if not media or media.is_deleted or media.owner_id != link.owner_id:
        raise HTTPException(status_code=404, detail="Media not found")

    # Validate the media is actually in scope for this link
    if not _media_in_scope(db, link, media):
        raise HTTPException(status_code=404, detail="Media not found in this shared gallery")

    existing = db.execute(
        select(ShareLinkFavourite).where(
            ShareLinkFavourite.share_link_id == link.id,
            ShareLinkFavourite.media_id == media.id,
            ShareLinkFavourite.guest_identifier == payload.guest_identifier,
        )
    ).scalar_one_or_none()

    if existing:
        db.delete(existing)
        db.commit()
        return MessageResponse(message="Removed from favourites.")
    else:
        fav = ShareLinkFavourite(
            share_link_id=link.id,
            media_id=media.id,
            guest_identifier=payload.guest_identifier,
        )
        db.add(fav)
        db.add(ShareLinkEvent(
            share_link_id=link.id,
            event_type=ShareLinkEventType.favourite,
        ))
        db.commit()
        return MessageResponse(message="Added to favourites.")



public_galleries_router = APIRouter(prefix="/public/galleries", tags=["public-galleries"])


class GalleryAccessPayload(BaseModel):
    password: str | None = None
    pin: str | None = None


@public_galleries_router.get("/{token}", response_model=PublicShareLinkRead)
@public_galleries_router.get("/{token}/", response_model=PublicShareLinkRead, include_in_schema=False)
def get_public_gallery(
    token: str,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    return view_shared_gallery(token=token, request=request, password=password, pin=pin, user=user, db=db)

@public_galleries_router.get("/{token}/albums/{album_id}", response_model=PublicShareLinkRead)
@public_galleries_router.get("/{token}/albums/{album_id}/", response_model=PublicShareLinkRead, include_in_schema=False)
def get_public_gallery_album(
    token: str,
    album_id: uuid.UUID,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    return view_shared_gallery_album(token=token, album_id=album_id, request=request, password=password, pin=pin, user=user, db=db)


@public_galleries_router.get("/{token}/folders/{folder_id}", response_model=PublicShareLinkRead)
@public_galleries_router.get("/{token}/folders/{folder_id}/", response_model=PublicShareLinkRead, include_in_schema=False)
def get_public_gallery_folder(
    token: str,
    folder_id: uuid.UUID,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    return view_shared_gallery_folder(token=token, folder_id=folder_id, request=request, password=password, pin=pin, user=user, db=db)


@public_galleries_router.post("/{token}/access")
@public_galleries_router.post("/{token}/access/", include_in_schema=False)
def access_public_gallery(
    token: str,
    request: Request,
    payload: GalleryAccessPayload,
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> dict:
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_client_authorized(link, user)
    _assert_credentials_ok(db, link, payload.password, payload.pin, request)

    # For folder links, there may be no single album — use source folder for rules.
    if link.album_id:
        album = db.get(Album, link.album_id)
        folder_id_for_rules = album.folder_id if album else None
        gallery_id = str(album.id) if album else str(link.id)
        gallery_name = album.name if album else "Gallery"
    else:
        folder_id_for_rules = link.source_folder_id
        folder = db.get(Folder, link.source_folder_id) if link.source_folder_id else None
        gallery_id = str(link.source_folder_id) if link.source_folder_id else str(link.id)
        gallery_name = folder.name if folder else "Gallery"

    session_token = secrets.token_urlsafe(32)
    effective_rules = get_effective_rules(db, folder_id_for_rules, link)
    return {
        "success": True,
        "token": token,
        "session": session_token,
        "gallery": {
            "id": gallery_id,
            "name": gallery_name,
        },
        "access": {
            "password_required": link.password_hash is not None,
            "pin_required": link.pin_hash is not None,
            "allow_download": effective_rules["allow_download"],
            "watermark_enabled": effective_rules["show_watermark"],
        },
    }


@public_galleries_router.get("/{token}/download-zip")
@public_router.get("/{token}/download-zip")
def download_zip_shared_gallery(
    token: str,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    album_id: uuid.UUID | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
):
    link = _verify_link_access(db, token, user, password, pin, True, request)

    target_album, target_folder = _get_share_target(db, link)
    folder_id = target_album.folder_id if target_album else target_folder.id if target_folder else None
    effective_rules = get_effective_rules(db, folder_id, link)

    if not effective_rules["allow_download"]:
        raise HTTPException(status_code=403, detail="Downloads are disabled for this link.")
    if effective_rules["show_watermark"]:
        raise HTTPException(status_code=403, detail="ZIP downloads are disabled while watermark is enabled.")

    from app.models.gallery import ShareLinkKind, ShareLinkMedia
    
    if link.kind == ShareLinkKind.face_search:
        raise HTTPException(status_code=400, detail="Cannot download face search links as zip directly.")
    
    if target_album:
        if link.kind == ShareLinkKind.selection:
            media = db.execute(
                select(Media)
                .join(ShareLinkMedia, ShareLinkMedia.media_id == Media.id)
                .where(ShareLinkMedia.share_link_id == link.id, Media.is_deleted.is_(False))
            ).scalars().all()
        else:
            media = db.execute(
                select(Media)
                .where(Media.album_id == target_album.id, Media.is_deleted.is_(False))
            ).scalars().all()
        zip_name = f"{target_album.name}.zip"
    else:
        # Folder sharing
        if album_id:
            # Verify album is part of the folder share
            valid = db.execute(
                select(ShareLinkAlbum)
                .where(ShareLinkAlbum.share_link_id == link.id, ShareLinkAlbum.album_id == album_id)
            ).scalar_one_or_none()
            
            if not valid:
                raise HTTPException(status_code=404, detail="Album not found in this share.")
            
            media = db.execute(
                select(Media)
                .where(Media.album_id == album_id, Media.is_deleted.is_(False))
            ).scalars().all()
            
            album = db.get(Album, album_id)
            zip_name = f"{album.name}.zip"
        else:
            # Download entire folder - include all in-scope albums AND loose items
            include_all = getattr(link, 'include_all', False)
            include_folder_items = getattr(link, 'include_folder_items', False)

            # Albums via share_link_albums (explicit) or the whole subtree (include_all)
            if include_all:
                subtree = _get_subtree_folder_ids(db, target_folder.id)
                album_rows = db.execute(
                    select(Album).where(
                        Album.folder_id.in_(subtree),
                        Album.deleted_at.is_(None),
                    )
                ).scalars().all()
                in_scope_albums = [a for a in album_rows if is_visible_to_client(db, album_id=a.id)]
            else:
                album_rows = db.execute(
                    select(Album)
                    .join(ShareLinkAlbum, ShareLinkAlbum.album_id == Album.id)
                    .where(ShareLinkAlbum.share_link_id == link.id, Album.deleted_at.is_(None))
                ).scalars().all()
                in_scope_albums = [a for a in album_rows if is_visible_to_client(db, album_id=a.id)]

            album_ids_list = [a.id for a in in_scope_albums]
            album_media = []
            if album_ids_list:
                album_media = db.execute(
                    select(Media).where(Media.album_id.in_(album_ids_list), Media.is_deleted.is_(False))
                ).scalars().all()

            # Loose items
            loose_items = []
            if include_all or include_folder_items:
                if include_all:
                    scope_folder_ids = _get_subtree_folder_ids(db, target_folder.id)
                else:
                    scope_folder_ids = {target_folder.id}
                loose_items = db.execute(
                    select(Media).where(
                        Media.folder_id.in_(scope_folder_ids),
                        Media.album_id.is_(None),
                        Media.is_deleted.is_(False),
                    )
                ).scalars().all()

            media = list(album_media) + list(loose_items)
            zip_name = f"{target_folder.name}.zip"

    if not media:
        raise HTTPException(status_code=404, detail="No photos to download.")

    from app.core.storage import _storage_root
    storage_root = _storage_root()

    fd, path = tempfile.mkstemp(suffix=".zip")
    with os.fdopen(fd, 'wb') as f:
        with zipfile.ZipFile(f, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for m in media:
                if m.file_path:
                    file_full_path = storage_root / m.file_path
                    if file_full_path.exists():
                        zipf.write(file_full_path, arcname=m.file_name)

    db.add(ShareLinkEvent(
        share_link_id=link.id,
        event_type=ShareLinkEventType.download,
    ))

    # Notify owner
    db.add(Notification(
        user_id=link.owner_id,
        type=NotificationType.gallery,
        title="Gallery ZIP Downloaded",
        subtitle="A guest downloaded a ZIP of a shared gallery.",
        data={"share_link_id": str(link.id)}
    ))
    owner = db.get(User, link.owner_id)
    if owner:
        send_push_if_enabled(
            user=owner,
            title="Gallery ZIP Downloaded",
            body="A guest downloaded a ZIP of a shared gallery.",
            data={"type": "gallery", "share_link_id": str(link.id)}
        )

    db.commit()

    return FileResponse(
        path=path,
        media_type="application/zip",
        filename=zip_name,
        background=BackgroundTask(os.unlink, path)
    )

@public_galleries_router.post("/{token}/download", response_model=MessageResponse)
@public_galleries_router.post("/{token}/download/", response_model=MessageResponse, include_in_schema=False)
def download_public_gallery(
    token: str,
    request: Request,
    payload: PublicShareLinkUnlockRequest,
    db: Session = Depends(get_db),
) -> MessageResponse:
    return record_shared_download(token=token, request=request, payload=payload, user=None, db=db)


@public_galleries_router.get("/{token}/media/{media_id}/original-url")
@public_router.get("/{token}/media/{media_id}/original-url")
def get_public_gallery_media_original_url(
    token: str,
    media_id: uuid.UUID,
    request: Request,
    password: str | None = Query(default=None),
    pin: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
):
    raise HTTPException(
        status_code=403, 
        detail="Originals are no longer available for direct public download."
    )



@public_galleries_router.get("/{token}/status", response_model=ShareLinkStatusRead)
@public_galleries_router.get("/{token}/status/", response_model=ShareLinkStatusRead, include_in_schema=False)
def status_public_gallery(
    token: str,
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> ShareLinkStatusRead:
    return get_share_link_status(token=token, user=user, db=db)
