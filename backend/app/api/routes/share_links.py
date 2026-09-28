import logging
import secrets
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from pydantic import BaseModel

from app.api.deps import get_current_studio_user, get_optional_current_user
from app.core.download_log import record_download_event
from app.core.face_index import extract_query_faces, resolve_query_face, search_faces
from app.core.security import hash_password, verify_password
from app.db.session import get_db
from app.models.gallery import Album, DownloadSource, Media, ShareLink, GalleryCollection, GalleryViewEvent
from app.models.user import User
from app.schemas.face import DetectedFaceRead, FaceBoxRead, FaceMatchRead, FaceSearchResponse
from app.schemas.gallery import (
    MediaRead,
    PublicAlbumSummary,
    PublicShareLinkRead,
    PublicShareLinkUnlockRequest,
    ShareLinkCreate,
    ShareLinkRead,
    ShareLinkStatusRead,
    ShareLinkUpdate,
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
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Share link not found")
    return link


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
        if album is None or album.owner_id != current_user.id:
            raise HTTPException(status_code=404, detail="Album not found")
    elif payload.collection_id:
        # Import Collection model at top of file, or assume it's imported?
        # Actually GalleryCollection is imported in app.models.gallery
        collection = db.get(GalleryCollection, payload.collection_id)
        if collection is None or collection.owner_id != current_user.id:
            raise HTTPException(status_code=404, detail="Collection not found")

    link = ShareLink(
        owner_id=current_user.id,
        album_id=payload.album_id,
        collection_id=payload.collection_id,
        token=_generate_unique_token(db),
        client_id=payload.client_id,
        password_hash=hash_password(payload.password) if payload.password else None,
        expires_at=payload.expires_at,
        allow_download=payload.allow_download,
        show_watermark=payload.show_watermark,
    )
    db.add(link)
    db.commit()
    db.refresh(link)
    return ShareLinkRead.from_model(link)


@router.get("", response_model=list[ShareLinkRead])
def list_share_links(
    album_id: uuid.UUID | None = None,
    collection_id: uuid.UUID | None = None,
    active_only: bool = False,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[ShareLinkRead]:
    query = select(ShareLink).where(ShareLink.owner_id == current_user.id)
    if album_id is not None:
        query = query.where(ShareLink.album_id == album_id)
    if collection_id is not None:
        query = query.where(ShareLink.collection_id == collection_id)
    if active_only:
        query = query.where(ShareLink.is_revoked.is_(False))
    query = query.order_by(ShareLink.created_at.desc())

    links = db.execute(query).scalars().all()
    results = [ShareLinkRead.from_model(link) for link in links]
    return [r for r in results if not active_only or r.is_active]


@router.get("/{link_id}", response_model=ShareLinkRead)
def get_share_link(
    link_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> ShareLinkRead:
    link = _get_owned_link(db, link_id, current_user.id)
    return ShareLinkRead.from_model(link)


@router.patch("/{link_id}", response_model=ShareLinkRead)
def update_share_link(
    link_id: uuid.UUID,
    payload: ShareLinkUpdate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> ShareLinkRead:
    link = _get_owned_link(db, link_id, current_user.id)
    updates = payload.model_dump(exclude_unset=True, exclude={"clear_password", "clear_expiry", "clear_client"})

    if payload.clear_client:
        link.client_id = None
    elif "client_id" in updates and updates["client_id"] is not None:
        link.client_id = updates["client_id"]

    if payload.clear_password:
        link.password_hash = None
    elif "password" in updates and updates["password"] is not None:
        link.password_hash = hash_password(updates["password"])

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

    db.commit()
    db.refresh(link)
    return ShareLinkRead.from_model(link)


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
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="This shared link does not exist.")
    logger.info(f"[SHARE_LOOKUP_DEBUG] Share record found: id='{link.id}', albumId='{link.album_id}', is_revoked={link.is_revoked}")
    return link


def _assert_link_reachable(link: ShareLink) -> None:
    if link.is_revoked:
        logger.warning(f"[SHARE_LOOKUP_DEBUG] Share link '{link.token}' has been revoked.")
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail={"code": "GALLERY_REVOKED", "message": "This gallery link has been revoked."},
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


def _get_share_target(db: Session, link: ShareLink) -> tuple[Album | None, GalleryCollection | None]:
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
        return album, None
    elif link.collection_id:
        logger.info(f"[SHARE_LOOKUP_DEBUG] Collection lookup request for collectionId='{link.collection_id}' (from share token='{link.token}')")
        collection = db.get(GalleryCollection, link.collection_id)
        if collection is None:
            logger.error(f"[SHARE_LOOKUP_DEBUG] Linked collectionId='{link.collection_id}' NOT found in database for share token='{link.token}')")
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "COLLECTION_NOT_FOUND", "message": "This shared collection is no longer available."},
            )
        logger.info(f"[SHARE_LOOKUP_DEBUG] Collection found: name='{collection.name}', owner_id='{collection.owner_id}')")
        return None, collection
    
    raise HTTPException(status_code=500, detail="Invalid share link target")


def _assert_password_ok(link: ShareLink, password: str | None) -> None:
    if link.password_hash is None:
        return
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
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_client_authorized(link, user)
    _get_share_target(db, link)
    active = not link.is_revoked and not _is_expired(link)
    return ShareLinkStatusRead(requires_password=link.password_hash is not None, is_active=active, client_id=link.client_id)


@public_router.get("/{token}", response_model=PublicShareLinkRead)
def view_shared_gallery(
    token: str,
    password: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    """Fetches the shared album + its media. Requires authorized client check
    and the correct `password` query param if the link is protected. Each
    successful call counts as one view for analytics.
    """
    logger.info(f"[SHARE_LOOKUP_DEBUG] Public view gallery request for token='{token}'")
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_client_authorized(link, user)
    _assert_password_ok(link, password)
    album, collection = _get_share_target(db, link)

    link.views_count += 1
    link.last_viewed_at = datetime.now(timezone.utc)
    db.add(GalleryViewEvent(
        owner_id=link.owner_id,
        share_link_id=link.id,
        album_id=album.id if album else None,
        viewer_id=user.id if user else None
    ))
    db.commit()
    
    from app.schemas.gallery import PublicCollectionSummary

    if album:
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
            studio_logo_url=studio_logo_url,
        )
    else:
        # Collection sharing
        from app.models.gallery import CollectionItem
        rows = db.execute(
            select(Album)
            .join(CollectionItem, CollectionItem.album_id == Album.id)
            .where(CollectionItem.collection_id == collection.id)
            .order_by(CollectionItem.position.asc())
        ).scalars().all()
        
        albums = [
            PublicAlbumSummary(
                id=a.id,
                name=a.name,
                description=a.description,
                gradient_argb=_split_csv(a.gradient_argb),
            )
            for a in rows
        ]
        
        owner = db.get(User, link.owner_id)
        studio_logo_url = owner.avatar_url if owner else None

        return PublicShareLinkRead(
            token=link.token,
            collection=PublicCollectionSummary(
                id=collection.id,
                name=collection.name,
            ),
            albums=albums,
            allow_download=link.allow_download,
            show_watermark=link.show_watermark,
            requires_password=link.password_hash is not None,
            studio_logo_url=studio_logo_url,
        )


@public_router.post("/{token}/download", response_model=MessageResponse)
def record_shared_download(
    token: str,
    payload: PublicShareLinkUnlockRequest,
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Called by the client right before it actually downloads a photo
    from a shared gallery. Keeps `downloads_count` accurate and, when
    `media_id` is supplied, writes a Download History row (Task 22) so
    the studio can see who downloaded what and when. Re-validates the
    password so a direct hit on this endpoint can't bypass gallery
    protection.
    """
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_password_ok(link, payload.password)

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
            
        # Ensure media belongs to the album or a collection's album
        is_valid_media = False
        if link.album_id:
            is_valid_media = media.album_id == link.album_id
        elif link.collection_id:
            from app.models.gallery import CollectionItem
            exists = db.execute(
                select(CollectionItem.id)
                .where(CollectionItem.collection_id == link.collection_id, CollectionItem.album_id == media.album_id)
            ).scalar_one_or_none()
            is_valid_media = exists is not None

        if not is_valid_media:
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
    db.commit()
    return MessageResponse(message="Download recorded.")


@public_router.post("/{token}/face-search", response_model=FaceSearchResponse)
async def face_search_shared_gallery(
    token: str,
    file: UploadFile = File(...),
    password: str | None = Query(default=None),
    face_index: int | None = Query(default=None),
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
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_password_ok(link, password)

    faces = await extract_query_faces(file)
    chosen_index, chosen_face = resolve_query_face(faces, face_index)

    matches = search_faces(
        db,
        query_embedding=chosen_face["embedding"],
        owner_id=link.owner_id,
        album_id=link.album_id,
    )

    return FaceSearchResponse(
        detected_faces=[
            DetectedFaceRead(face_index=i, box=FaceBoxRead(**f["box"]), confidence=f["confidence"])
            for i, f in enumerate(faces)
        ],
        searched_face_index=chosen_index,
        matches=[FaceMatchRead(media=MediaRead.from_model(m), similarity=round(s, 4)) for m, s in matches],
    )


@public_router.get("/{token}/albums/{album_id}", response_model=PublicShareLinkRead)
def view_shared_collection_album(
    token: str,
    album_id: uuid.UUID,
    password: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    """Fetches a specific album within a shared collection.
    Requires that the token belongs to a collection that contains the album.
    """
    logger.info(f"[SHARE_LOOKUP_DEBUG] Public view collection album request for token='{token}', albumId='{album_id}'")
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_client_authorized(link, user)
    _assert_password_ok(link, password)
    
    if link.collection_id is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="This token is not a collection share link.",
        )
        
    from app.models.gallery import CollectionItem
    exists = db.execute(
        select(CollectionItem.id)
        .where(CollectionItem.collection_id == link.collection_id, CollectionItem.album_id == album_id)
    ).scalar_one_or_none()
    
    if exists is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Album not found in this shared collection.",
        )
        
    album = db.get(Album, album_id)
    if album is None:
         raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Album not found.",
        )
        
    media = db.execute(
        select(Media)
        .where(Media.album_id == album.id, Media.is_deleted.is_(False))
        .order_by(Media.created_at.desc())
    ).scalars().all()

    link.views_count += 1
    link.last_viewed_at = datetime.now(timezone.utc)
    db.add(GalleryViewEvent(
        owner_id=link.owner_id,
        share_link_id=link.id,
        album_id=album.id if album else None,
        viewer_id=user.id if user else None
    ))
    db.commit()

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
        studio_logo_url=studio_logo_url,
    )


public_galleries_router = APIRouter(prefix="/public/galleries", tags=["public-galleries"])


class GalleryAccessPayload(BaseModel):
    password: str | None = None


@public_galleries_router.get("/{token}", response_model=PublicShareLinkRead)
@public_galleries_router.get("/{token}/", response_model=PublicShareLinkRead, include_in_schema=False)
def get_public_gallery(
    token: str,
    password: str | None = Query(default=None),
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> PublicShareLinkRead:
    return view_shared_gallery(token=token, password=password, user=user, db=db)


@public_galleries_router.post("/{token}/access")
@public_galleries_router.post("/{token}/access/", include_in_schema=False)
def access_public_gallery(
    token: str,
    payload: GalleryAccessPayload,
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> dict:
    link = _get_link_by_token_or_404(db, token)
    _assert_link_reachable(link)
    _assert_client_authorized(link, user)
    _assert_password_ok(link, payload.password)
    album = _assert_album_exists(db, link)

    session_token = secrets.token_urlsafe(32)
    return {
        "success": True,
        "token": token,
        "session": session_token,
        "gallery": {
            "id": str(album.id),
            "name": album.name,
        },
        "access": {
            "password_required": link.password_hash is not None,
            "allow_download": link.allow_download,
            "watermark_enabled": link.show_watermark,
        },
    }


@public_galleries_router.post("/{token}/download", response_model=MessageResponse)
@public_galleries_router.post("/{token}/download/", response_model=MessageResponse, include_in_schema=False)
def download_public_gallery(
    token: str,
    payload: PublicShareLinkUnlockRequest,
    db: Session = Depends(get_db),
) -> MessageResponse:
    return record_shared_download(token=token, payload=payload, db=db)


@public_galleries_router.get("/{token}/status", response_model=ShareLinkStatusRead)
@public_galleries_router.get("/{token}/status/", response_model=ShareLinkStatusRead, include_in_schema=False)
def status_public_gallery(
    token: str,
    user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> ShareLinkStatusRead:
    return get_share_link_status(token=token, user=user, db=db)
