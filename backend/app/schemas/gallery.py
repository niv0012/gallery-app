import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.gallery import MediaType

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _split_csv(value: str | None) -> list[int]:
    if not value:
        return []
    return [int(v) for v in value.split(",") if v]


def _join_csv(values: list[int] | None) -> str | None:
    if not values:
        return None
    return ",".join(str(v) for v in values)


# ---------------------------------------------------------------------------
# Folders
# ---------------------------------------------------------------------------


class FolderCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    parent_id: uuid.UUID | None = None
    gradient_argb: list[int] | None = None


class FolderUpdate(BaseModel):
    """Only fields actually present in the request are touched
    (`model_dump(exclude_unset=True)`), same convention as `UserUpdate`.
    """

    name: str | None = Field(default=None, min_length=1, max_length=150)
    parent_id: uuid.UUID | None = None
    clear_parent: bool = False
    is_hidden: bool | None = None
    is_favorite: bool | None = None
    gradient_argb: list[int] | None = None


class FolderRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    parent_id: uuid.UUID | None
    is_hidden: bool
    is_favorite: bool
    created_at: datetime
    updated_at: datetime

    # Computed, never stored — see Folder model docstring.
    album_count: int = 0
    photo_count: int = 0
    video_count: int = 0
    gradient_argb: list[int] = []

    @classmethod
    def from_model(
        cls,
        folder,
        album_count: int = 0,
        photo_count: int = 0,
        video_count: int = 0,
    ) -> "FolderRead":
        return cls(
            id=folder.id,
            name=folder.name,
            parent_id=folder.parent_id,
            is_hidden=folder.is_hidden,
            is_favorite=folder.is_favorite,
            created_at=folder.created_at,
            updated_at=folder.updated_at,
            album_count=album_count,
            photo_count=photo_count,
            video_count=video_count,
            gradient_argb=_split_csv(folder.gradient_argb),
        )


class FolderStatsRead(BaseModel):
    total_folders: int
    root_folder_count: int
    hidden_folder_count: int
    favorite_folder_count: int
    max_depth: int
    average_albums_per_folder: float


# ---------------------------------------------------------------------------
# Albums
# ---------------------------------------------------------------------------


class AlbumCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    description: str | None = None
    folder_id: uuid.UUID | None = None
    gradient_argb: list[int] | None = None


class AlbumUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=150)
    description: str | None = None
    clear_description: bool = False
    folder_id: uuid.UUID | None = None
    clear_folder: bool = False
    is_favorite: bool | None = None
    display_order: int | None = None
    gradient_argb: list[int] | None = None


class AlbumReorderItem(BaseModel):
    id: uuid.UUID
    display_order: int


class AlbumReorderRequest(BaseModel):
    items: list[AlbumReorderItem]


class AlbumRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    description: str | None
    folder_id: uuid.UUID | None
    display_order: int
    is_favorite: bool
    created_at: datetime
    updated_at: datetime

    # Computed, never stored — see Album model docstring.
    photo_count: int = 0
    video_count: int = 0
    folder_count: int = 0
    gradient_argb: list[int] = []
    # Servable URL for the most-recently-added active media item in this
    # album (thumbnail if one exists, else the original file). None for
    # empty albums — callers should fall back to the gradient placeholder.
    cover_thumbnail_url: str | None = None

    @classmethod
    def from_model(
        cls,
        album,
        photo_count: int = 0,
        video_count: int = 0,
        cover_thumbnail_url: str | None = None,
    ) -> "AlbumRead":
        return cls(
            id=album.id,
            name=album.name,
            description=album.description,
            folder_id=album.folder_id,
            display_order=album.display_order,
            is_favorite=album.is_favorite,
            created_at=album.created_at,
            updated_at=album.updated_at,
            photo_count=photo_count,
            video_count=video_count,
            folder_count=1 if album.folder_id else 0,
            gradient_argb=_split_csv(album.gradient_argb),
            cover_thumbnail_url=cover_thumbnail_url,
        )


class ConnectedAlbumRead(BaseModel):
    """Read-only album view for a client browsing a *connected* studio's
    gallery (`GET /albums/shared-with-me`). Same album fields as
    `AlbumRead`, minus the studio-internal `folder_id`/`folder_count`
    (a studio's folder structure is its own private organization, not
    something a client needs), plus the owning studio's public
    identity — a client's shared view spans every studio they're
    connected to, not just one, so each album needs to say whose it is.
    """

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    description: str | None
    display_order: int
    is_favorite: bool
    created_at: datetime
    updated_at: datetime

    photo_count: int = 0
    video_count: int = 0
    gradient_argb: list[int] = []
    cover_thumbnail_url: str | None = None

    studio_id: uuid.UUID
    studio_name: str | None
    studio_avatar_url: str | None

    # True when this album also has an active, password-protected public
    # `ShareLink`. Purely informational — a `ShareLink` password never
    # gates *this* client's own access, which is granted directly via
    # `AlbumClientShare` (no password concept exists there at all). This
    # just tells the client "a protected public link exists too", not
    # "you need a password". Every call site (`GET /albums/shared-with-me`)
    # already passes `has_protected_share_link=` into `from_model` below —
    # this field/param was simply missing here, so the call raised a
    # TypeError (surfaced to the client as a 500) on every request.
    has_protected_share_link: bool = False

    @classmethod
    def from_model(
        cls,
        album,
        studio,
        photo_count: int = 0,
        video_count: int = 0,
        cover_thumbnail_url: str | None = None,
        has_protected_share_link: bool = False,
    ) -> "ConnectedAlbumRead":
        return cls(
            id=album.id,
            name=album.name,
            description=album.description,
            display_order=album.display_order,
            is_favorite=album.is_favorite,
            created_at=album.created_at,
            updated_at=album.updated_at,
            photo_count=photo_count,
            video_count=video_count,
            gradient_argb=_split_csv(album.gradient_argb),
            cover_thumbnail_url=cover_thumbnail_url,
            studio_id=studio.id,
            studio_name=studio.studio_name or studio.full_name,
            studio_avatar_url=studio.avatar_url,
            has_protected_share_link=has_protected_share_link,
        )


class AlbumStatsRead(BaseModel):
    total_albums: int
    total_photos: int
    total_favorites: int
    average_photos_per_album: float
    most_recent_album_id: uuid.UUID | None
    largest_album_id: uuid.UUID | None
    unfiled_album_count: int


# ---------------------------------------------------------------------------
# Media
# ---------------------------------------------------------------------------


class MediaUpdate(BaseModel):
    album_id: uuid.UUID | None = None
    clear_album: bool = False
    folder_id: uuid.UUID | None = None
    clear_folder: bool = False
    is_favorite: bool | None = None
    file_name: str | None = None
    edit_recipe: dict | None = None
    clear_edit_recipe: bool = False


class MediaRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    type: MediaType = Field(validation_alias="media_type")
    file_name: str
    album_id: uuid.UUID | None
    folder_id: uuid.UUID | None
    size_bytes: int
    width: int | None
    height: int | None
    duration_ms: int | None
    is_favorite: bool
    is_deleted: bool
    edit_recipe: dict | None
    created_at: datetime
    updated_at: datetime

    # Built from storage-relative paths — never exposed directly.
    file_url: str
    thumbnail_url: str | None

    # True once this media has been destructively overwritten at least
    # once (pre_edit_file_path is set on the model) — tells the client
    # whether "Revert to Original" has anything to restore, without
    # leaking the internal backup storage keys themselves.
    can_revert: bool = False

    # Seeded by the route from a batch like-lookup (see
    # app.api.routes.media._like_info_for) so the like button shows the
    # right count/state on first render instead of defaulting to 0/false.
    like_count: int = 0
    is_liked_by_me: bool = False

    # Seeded by the route from a batch comment-count lookup (see
    # app.api.routes.media._comment_count_for). Every call site already
    # passes `comment_count=` into `from_model` below and the Flutter
    # `MediaModel` already parses `comment_count` from the response —
    # this field was simply missing here, which meant `from_model`
    # rejected the keyword argument outright (TypeError -> 500) on
    # every media-listing endpoint that uses it.
    comment_count: int = 0

    @classmethod
    def from_model(
        cls,
        media,
        *,
        like_count: int = 0,
        is_liked_by_me: bool = False,
        comment_count: int = 0,
    ) -> "MediaRead":
        from app.core.storage import build_media_url

        return cls(
            id=media.id,
            media_type=media.media_type,
            file_name=media.file_name,
            album_id=media.album_id,
            folder_id=media.folder_id,
            size_bytes=media.size_bytes,
            width=media.width,
            height=media.height,
            duration_ms=media.duration_ms,
            is_favorite=media.is_favorite,
            is_deleted=media.is_deleted,
            edit_recipe=media.edit_recipe,
            created_at=media.created_at,
            updated_at=media.updated_at,
            file_url=build_media_url(media.file_path),
            thumbnail_url=build_media_url(media.thumbnail_path),
            can_revert=media.pre_edit_file_path is not None,
            like_count=like_count,
            is_liked_by_me=is_liked_by_me,
            comment_count=comment_count,
        )


# ---------------------------------------------------------------------------
# Share Links
# ---------------------------------------------------------------------------


class ShareLinkCreate(BaseModel):
    album_id: uuid.UUID | None = None
    collection_id: uuid.UUID | None = None
    client_id: uuid.UUID | None = None
    # Plain-text passcode from the studio, e.g. "1234" — hashed with
    # the same bcrypt helpers as user passwords before it ever touches
    # the DB (see core/security.py). Omit/None means the link is public.
    password: str | None = Field(default=None, min_length=4, max_length=100)
    expires_at: datetime | None = None
    allow_download: bool = True
    show_watermark: bool = False

    @model_validator(mode='after')
    def check_target(self) -> 'ShareLinkCreate':
        if (self.album_id is None and self.collection_id is None) or (self.album_id is not None and self.collection_id is not None):
            raise ValueError('Exactly one of album_id or collection_id must be provided')
        return self


class ShareLinkUpdate(BaseModel):
    client_id: uuid.UUID | None = None
    clear_client: bool = False
    password: str | None = Field(default=None, min_length=4, max_length=100)
    clear_password: bool = False
    expires_at: datetime | None = None
    clear_expiry: bool = False
    allow_download: bool | None = None
    show_watermark: bool | None = None
    is_revoked: bool | None = None


class ShareLinkRead(BaseModel):
    """Owner-facing view — includes analytics counters but never the
    password itself, only whether one is set (`has_password`).
    """

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    album_id: uuid.UUID | None = None
    collection_id: uuid.UUID | None = None
    token: str
    share_url: str
    client_id: uuid.UUID | None = None
    has_password: bool
    expires_at: datetime | None
    allow_download: bool
    show_watermark: bool
    is_revoked: bool
    is_expired: bool
    is_active: bool

    views_count: int
    downloads_count: int
    last_viewed_at: datetime | None
    last_downloaded_at: datetime | None

    created_at: datetime
    updated_at: datetime

    @classmethod
    def from_model(cls, link) -> "ShareLinkRead":
        from app.core.storage import build_share_url

        now = datetime.now(link.created_at.tzinfo) if link.created_at.tzinfo else datetime.utcnow()
        is_expired = link.expires_at is not None and link.expires_at <= now
        return cls(
            id=link.id,
            album_id=link.album_id,
            collection_id=getattr(link, 'collection_id', None),
            token=link.token,
            share_url=build_share_url(link.token),
            client_id=link.client_id,
            has_password=link.password_hash is not None,
            expires_at=link.expires_at,
            allow_download=link.allow_download,
            show_watermark=link.show_watermark,
            is_revoked=link.is_revoked,
            is_expired=is_expired,
            is_active=(not link.is_revoked) and (not is_expired),
            views_count=link.views_count,
            downloads_count=link.downloads_count,
            last_viewed_at=link.last_viewed_at,
            last_downloaded_at=link.last_downloaded_at,
            created_at=link.created_at,
            updated_at=link.updated_at,
        )


class PublicShareLinkUnlockRequest(BaseModel):
    """Body for verifying a password-protected share link, and (on the
    download endpoint) for identifying what's being downloaded so it
    can be recorded in Download History (Task 22).
    """

    password: str | None = None
    # Which media is being downloaded. Optional so the endpoint stays
    # backwards compatible, but omitting it means this download won't
    # get a Download History row — only the link's own counter bumps.
    media_id: uuid.UUID | None = None
    # Free-text "who" when the viewer has no account, e.g. a name
    # entered on the passcode screen.
    downloader_label: str | None = Field(default=None, max_length=150)


class PublicAlbumSummary(BaseModel):
    id: uuid.UUID
    name: str
    description: str | None
    gradient_argb: list[int] = []


class PublicCollectionSummary(BaseModel):
    id: uuid.UUID
    name: str


class PublicShareLinkRead(BaseModel):
    """What a client sees when viewing a shared gallery — no owner_id,
    no password hash, no internal `id`; the token is the only handle
    they ever need.
    """

    token: str
    album: PublicAlbumSummary | None = None
    collection: PublicCollectionSummary | None = None
    media: list[MediaRead] | None = None
    albums: list[PublicAlbumSummary] | None = None
    allow_download: bool
    show_watermark: bool
    requires_password: bool
    studio_logo_url: str | None = None


class ShareLinkStatusRead(BaseModel):
    """Lightweight pre-check so a client can render the passcode
    screen before fetching (and counting a view for) the full gallery.
    """

    requires_password: bool
    is_active: bool
    client_id: uuid.UUID | None = None


# ---------------------------------------------------------------------------
# Gallery Collections
# ---------------------------------------------------------------------------


class CollectionCreate(BaseModel):
    name: str = Field(min_length=1, max_length=150)


class CollectionUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=150)
    display_order: int | None = None


class CollectionReorderItem(BaseModel):
    id: uuid.UUID
    display_order: int


class CollectionReorderRequest(BaseModel):
    """Reorders collections relative to each other — same shape as
    `AlbumReorderRequest`.
    """

    items: list[CollectionReorderItem]


class CollectionAlbumAddRequest(BaseModel):
    """Appends one or more albums to the end of a collection. Albums
    already present, or not owned by the caller, are silently skipped
    rather than rejecting the whole batch.
    """

    album_ids: list[uuid.UUID] = Field(min_length=1)


class CollectionAlbumReorderRequest(BaseModel):
    """Full replacement of the album order within one collection —
    must contain exactly the album ids currently in the collection,
    just in the desired new order.
    """

    album_ids: list[uuid.UUID]


class CollectionRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    display_order: int
    created_at: datetime
    updated_at: datetime

    # Ordered by CollectionItem.position — never stored on this row,
    # same "computed, never cached" reasoning as Album/Folder counts.
    gallery_ids: list[uuid.UUID] = []
    album_count: int = 0

    @classmethod
    def from_model(cls, collection, gallery_ids: list[uuid.UUID] | None = None) -> "CollectionRead":
        ids = gallery_ids or []
        return cls(
            id=collection.id,
            name=collection.name,
            display_order=collection.display_order,
            created_at=collection.created_at,
            updated_at=collection.updated_at,
            gallery_ids=ids,
            album_count=len(ids),
        )


# ---------------------------------------------------------------------------
# Download History
# ---------------------------------------------------------------------------


class DownloadEventCreate(BaseModel):
    """Body for logging an authenticated in-app download (a studio
    downloading their own original/edited copy). Public share-link
    downloads are logged automatically by the share-link download
    endpoint instead — see `PublicShareLinkUnlockRequest`.
    """

    media_id: uuid.UUID


class DownloadEventRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    media_id: uuid.UUID | None
    album_id: uuid.UUID | None
    share_link_id: uuid.UUID | None
    file_name: str
    media_type: MediaType
    size_bytes: int
    source: str
    # Resolved server-side: the user's full name, the free-text
    # downloader_label, "Shared link viewer", or "Unknown" — never the
    # raw nullable columns, so callers don't have to do this fallback
    # logic themselves.
    downloaded_by: str
    downloaded_at: datetime
    # Resolved server-side from the still-live `Media` row (null if the
    # media was hard-deleted since). Lets the Download History list
    # render a real thumbnail directly, without the client having to
    # cross-reference its own media list — which for a client account
    # never contains another studio's media in the first place, so it
    # always fell back to a broken-image placeholder before this.
    thumbnail_url: str | None = None
    file_url: str | None = None

    @classmethod
    def from_model(
        cls,
        event,
        downloaded_by: str,
        *,
        thumbnail_url: str | None = None,
        file_url: str | None = None,
    ) -> "DownloadEventRead":
        return cls(
            id=event.id,
            media_id=event.media_id,
            album_id=event.album_id,
            share_link_id=event.share_link_id,
            file_name=event.file_name,
            media_type=event.media_type,
            size_bytes=event.size_bytes,
            source=event.source.value if hasattr(event.source, "value") else event.source,
            downloaded_by=downloaded_by,
            downloaded_at=event.downloaded_at,
            thumbnail_url=thumbnail_url,
            file_url=file_url,
        )


class DownloadHistoryStatsRead(BaseModel):
    total_downloads: int
    downloads_via_app: int
    downloads_via_share_link: int


# ---------------------------------------------------------------------------
# Media Likes & Comments (Task 23)
# ---------------------------------------------------------------------------


class MediaLikeToggleResponse(BaseModel):
    """Response for POST /media/{id}/like — tells the client whether the
    like was added or removed, plus the new total count so the UI can
    update the heart icon and count in one go without re-fetching.
    """

    liked: bool
    like_count: int


class MediaLikeRead(BaseModel):
    """Read model for a single like entry — used by GET /media/{id}/likes."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    media_id: uuid.UUID
    user_id: uuid.UUID
    created_at: datetime
    
    # Resolved on read: the like author's display name. Filled by
    # the route, never stored on this model.
    user_full_name: str = ""

    @classmethod
    def from_model(cls, like, user_full_name: str = "") -> "MediaLikeRead":
        return cls(
            id=like.id,
            media_id=like.media_id,
            user_id=like.user_id,
            created_at=like.created_at,
            user_full_name=user_full_name,
        )


class MediaCommentCreate(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    parent_id: uuid.UUID | None = None


class MediaCommentUpdate(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class MediaCommentRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    media_id: uuid.UUID
    user_id: uuid.UUID
    parent_id: uuid.UUID | None
    text: str
    created_at: datetime
    updated_at: datetime

    # Resolved on read: the comment author's display name. Filled by
    # the route, never stored on this model.
    user_full_name: str = ""

    @classmethod
    def from_model(cls, comment, user_full_name: str = "") -> "MediaCommentRead":
        return cls(
            id=comment.id,
            media_id=comment.media_id,
            user_id=comment.user_id,
            parent_id=comment.parent_id,
            text=comment.text,
            created_at=comment.created_at,
            updated_at=comment.updated_at,
            user_full_name=user_full_name,
        )