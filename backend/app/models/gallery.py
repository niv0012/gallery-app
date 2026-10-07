"""SQLAlchemy ORM models for the gallery domain — Folders, Albums,
Media, Share Links, Gallery Collections, Download Events, and Media
Likes/Comments.

Reconstructed from the Alembic migrations that actually created these
tables, column-for-column:
  - g1h2i3j4k5l6_create_gallery_tables.py       -> Folder, Album, Media
  - h4i5j6k7l8m9_create_share_links_table.py    -> ShareLink
  - i9j0k1l2m3n4_create_gallery_collections_tables.py
        -> GalleryCollection, CollectionItem
  - j5k6l7m8n9o0_create_download_events_table.py -> DownloadEvent
  - p1q2r3s4t5u6_create_media_likes_comments_tables.py
        -> MediaLike, MediaComment
  - w7x8y9z0a1b2_add_media_pre_edit_backup_fields.py
        -> Media.pre_edit_file_path / pre_edit_thumbnail_path

No `relationship()` mappings are defined — every route in this app
navigates these tables via explicit `select()`/join queries (see
`api/routes/client_gallery.py`, `media.py`, `collections.py`,
`download_history.py`), never ORM-level relationship traversal, so
none are declared here either.
"""

import enum
import uuid
from datetime import datetime

from sqlalchemy import BigInteger, JSON, Boolean, Column, DateTime, Enum, ForeignKey, Integer, String, Text, UniqueConstraint, CheckConstraint, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class MediaType(str, enum.Enum):
    """Backed by the Postgres enum `media_type`, created once in
    g1h2i3j4k5l6 and reused (create_type=False) by later migrations
    that also reference it (e.g. `download_events.media_type`).
    """

    photo = "photo"
    video = "video"


class DownloadSource(str, enum.Enum):
    """Backed by the Postgres enum `download_source`
    (j5k6l7m8n9o0) — where a download was logged from."""

    app = "app"
    share_link = "share_link"


class ShareLinkKind(str, enum.Enum):
    """Phase 5: kind of share link.
    - standard: normal link to folders/albums.
    - face_search: requires face search to view.
    - selection: explicit subset of media (e.g. 'Send me my photos').
    """
    standard = "standard"
    face_search = "face_search"
    selection = "selection"


class Folder(Base):
    __tablename__ = "folders"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(150), nullable=False)
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("folders.id", ondelete="CASCADE"), nullable=True, index=True
    )
    gradient_argb: Mapped[str | None] = mapped_column(String(255), nullable=True)
    is_hidden: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_favorite: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    allow_download: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    show_watermark: Mapped[bool | None] = mapped_column(Boolean, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Album(Base):
    __tablename__ = "albums"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    folder_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("folders.id", ondelete="SET NULL"), nullable=True, index=True
    )
    name: Mapped[str] = mapped_column(String(150), nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    display_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_favorite: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    gradient_argb: Mapped[str | None] = mapped_column(String(255), nullable=True)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Media(Base):
    __tablename__ = "media"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    album_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("albums.id", ondelete="SET NULL"), nullable=True, index=True
    )
    folder_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("folders.id", ondelete="SET NULL"), nullable=True, index=True
    )
    media_type: Mapped[MediaType] = mapped_column(Enum(MediaType, name="media_type"), nullable=False)
    file_name: Mapped[str] = mapped_column(String(255), nullable=False)
    file_path: Mapped[str] = mapped_column(String(500), nullable=False)
    thumbnail_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    content_type: Mapped[str] = mapped_column(String(100), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    width: Mapped[int | None] = mapped_column(Integer, nullable=True)
    height: Mapped[int | None] = mapped_column(Integer, nullable=True)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    is_favorite: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    edit_recipe: Mapped[dict | None] = mapped_column(JSONB, nullable=True)

    # Photo editor "Overwrite Original" / "Revert to Original"
    # (w7x8y9z0a1b2) — the storage-relative keys of the file/thumbnail
    # as they were the *first* time this item got destructively
    # overwritten. Null means "never overwritten, nothing to revert".
    pre_edit_file_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    pre_edit_thumbnail_path: Mapped[str | None] = mapped_column(String(500), nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class ShareLink(Base):
    """A public, revocable link exposing one or more Albums for client
    viewing without an account.

    Phase 3 additions (M4/5.2):
    - `source_folder_id`: when set, the link covers all (non-hidden) albums
      in this folder. Albums are tracked in `share_link_albums`.
    - `auto_include_new`: when True and `source_folder_id` is set, newly
      created albums in that folder are automatically added to the link.
    - `album_id` / `collection_id` remain for backwards-compatibility with
      the old app (v1.0.0+42); the check constraint is relaxed to allow all
      three target columns to be null (multi-album mode uses share_link_albums).
    """

    __tablename__ = "share_links"
    __table_args__ = (
        CheckConstraint(
            "(album_id IS NOT NULL AND source_folder_id IS NULL)"
            " OR (album_id IS NULL AND source_folder_id IS NOT NULL)"
            " OR (album_id IS NULL AND source_folder_id IS NULL)",
            name="chk_share_link_target",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    album_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("albums.id", ondelete="CASCADE"), nullable=True, index=True
    )
    token: Mapped[str] = mapped_column(String(64), nullable=False, unique=True, index=True)
    client_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    password_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    pin_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    allow_download: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    show_watermark: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_revoked: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    views_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    downloads_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_viewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_downloaded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Phase 3 multi-album columns
    source_folder_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("folders.id", ondelete="SET NULL"), nullable=True, index=True
    )
    auto_include_new: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    # Phase 6: folder-level sharing options (m13)
    # include_all: share everything in the folder subtree, evaluated live.
    # include_folder_items: also share loose items (album_id IS NULL) directly in source_folder_id.
    include_all: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="false")
    include_folder_items: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="false")

    # Phase 5: kind of link
    kind: Mapped[ShareLinkKind] = mapped_column(
        Enum(ShareLinkKind, name="share_link_kind", create_type=False), nullable=False, server_default="standard"
    )

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class ShareLinkAlbum(Base):
    """Many-to-many join table: which albums are included in a multi-album
    share link. A link with `source_folder_id` will have one row per
    album in that folder that was selected by the studio.

    Phase 3 (M4). Backwards-compatible: old single-album links continue
    to use `album_id` on the ShareLink row itself.
    """

    __tablename__ = "share_link_albums"
    __table_args__ = (
        UniqueConstraint("share_link_id", "album_id", name="uq_share_link_albums_link_album"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    album_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("albums.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # display_order allows the studio to reorder tabs on the client view
    display_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class ShareLinkFolder(Base):
    """Many-to-many join: which sub-folders are explicitly included in a
    folder share link. Each row means 'include everything inside this
    folder (albums, loose media, deeper sub-folders)' subject to
    is_visible_to_client checks.

    Phase 6 (m13). Not used when include_all is True.
    """

    __tablename__ = "share_link_folders"
    __table_args__ = (
        UniqueConstraint("share_link_id", "folder_id", name="uq_share_link_folders_link_folder"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    folder_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("folders.id", ondelete="CASCADE"), nullable=False, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class ShareLinkMedia(Base):
    """Mapping table for selection-based share links (Phase 5).
    Allows a share link to expose a specific subset of media items
    (e.g., 'Send me my photos' results).
    """

    __tablename__ = "share_link_media"
    __table_args__ = (
        UniqueConstraint("share_link_id", "media_id", name="uq_share_link_media_link_media"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    media_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("media.id", ondelete="CASCADE"), nullable=False, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class FaceSearchAttempt(Base):
    """Rate limiting table for face searches (Task 1.4)."""
    __tablename__ = "face_search_attempts"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    ip_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class ShareLinkPinAttempt(Base):
    """Rate limiting table for PIN attempts (Task 3.2)."""
    __tablename__ = "share_link_pin_attempts"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    ip_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)



class FaceSearchEmail(Base):
    """Stores the email/phone required for face searches (Task 5.1)."""
    __tablename__ = "face_search_emails"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    email: Mapped[str] = mapped_column(String(255), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(50), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class DownloadEvent(Base):
    """An immutable audit-log row per download (Task 22), from anywhere
    (in-app or a public Share Link) — see `core/download_log.py` for the
    single place these rows get built."""

    __tablename__ = "download_events"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    media_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("media.id", ondelete="SET NULL"), nullable=True, index=True
    )
    album_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("albums.id", ondelete="SET NULL"), nullable=True, index=True
    )
    share_link_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="SET NULL"), nullable=True, index=True
    )
    downloaded_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    downloader_label: Mapped[str | None] = mapped_column(String(150), nullable=True)
    file_name: Mapped[str] = mapped_column(String(255), nullable=False)
    media_type: Mapped[MediaType] = mapped_column(Enum(MediaType, name="media_type"), nullable=False)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    source: Mapped[DownloadSource] = mapped_column(Enum(DownloadSource, name="download_source"), nullable=False)

    downloaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class MediaLike(Base):
    """One (media, user) pair liking a photo/video (Task 23).
    `UniqueConstraint` makes liking idempotent at the DB level — a
    second like from the same user on the same media is a no-op/toggle
    in the route layer, never a duplicate row."""

    __tablename__ = "media_likes"
    __table_args__ = (UniqueConstraint("media_id", "user_id", name="uq_media_likes_media_user"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    media_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("media.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class MediaComment(Base):
    """A comment on a photo/video (Task 23), with one level of replies
    via the self-referential `parent_id` (a reply's own `parent_id`
    points at the top-level comment it replies to)."""

    __tablename__ = "media_comments"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    media_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("media.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("media_comments.id", ondelete="CASCADE"), nullable=True, index=True
    )
    text: Mapped[str] = mapped_column(Text, nullable=False)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class GalleryViewEvent(Base):
    """An immutable audit-log row per gallery view, supporting the Views analytics graph."""
    __tablename__ = "gallery_view_events"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    share_link_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="SET NULL"), nullable=True, index=True
    )
    album_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("albums.id", ondelete="SET NULL"), nullable=True, index=True
    )
    viewer_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    viewed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class ShareLinkEventType(enum.Enum):
    view = "view"
    download = "download"
    face_search = "face_search"
    favourite = "favourite"
    email_submit = "email_submit"


class ShareLinkEvent(Base):
    __tablename__ = "share_link_events"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    event_type: Mapped[ShareLinkEventType] = mapped_column(Enum(ShareLinkEventType, name="share_link_event_type"), nullable=False)
    ip_address: Mapped[str | None] = mapped_column(String(50), nullable=True)
    user_agent: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class ShareLinkFavourite(Base):
    """Guest-level 'hearts' (favourites) on a share link (Phase 5, Task 9.2)."""
    __tablename__ = "share_link_favourites"
    __table_args__ = (UniqueConstraint("share_link_id", "media_id", "guest_identifier", name="uq_sl_favourite_link_media_guest"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    share_link_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("share_links.id", ondelete="CASCADE"), nullable=False, index=True
    )
    media_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("media.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # E.g. session token, email, or name the guest entered
    guest_identifier: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)