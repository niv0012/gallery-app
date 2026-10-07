"""Shared helpers for `AlbumClientShare` lookups.

Kept out of any single route module because both the studio-side
sharing endpoints (`api/routes/studio_shares.py`) and the client-side
read endpoints (`api/routes/client_gallery.py`) need the same "is this
album currently shared with this client" and "which albums does this
client currently have access to" logic — an active share always means
`revoked_at IS NULL`, and that rule should only be encoded once.

Public share link implicit access
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A "public" share link (no password, not revoked, not expired) created by
a studio that the client has an *accepted* connection with is treated as
an implicit share — the client can see those albums in their Shared
Galleries without the studio having to add an explicit `AlbumClientShare`
row.  Both helpers below implement this rule so every downstream caller
(list_shared_studios, list_shared_folders, list_shared_albums, etc.) picks
it up automatically.
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import and_, select
from sqlalchemy.orm import Session

from app.models.album_share import AlbumClientShare
from app.models.connection import ConnectionStatus, StudioClientConnection
from app.models.gallery import ShareLink


def is_shared_with(db: Session, *, album_id: uuid.UUID, client_id: uuid.UUID) -> bool:
    """True if `album_id` currently has an active (non-revoked) explicit
    share with `client_id` (via AlbumClientShare or direct ShareLink.client_id).
    """
    now = datetime.now(timezone.utc)

    # 1. Explicit per-album share row.
    stmt = select(AlbumClientShare.id).where(
        AlbumClientShare.album_id == album_id,
        AlbumClientShare.client_id == client_id,
        AlbumClientShare.revoked_at.is_(None),
    )
    if db.execute(stmt).first() is not None:
        return True

    # 2. Direct ShareLink assigned to client_id.
    direct_link = db.execute(
        select(ShareLink.id).where(
            ShareLink.album_id == album_id,
            ShareLink.client_id == client_id,
            ShareLink.is_revoked.is_(False),
            and_(
                ShareLink.expires_at.is_(None)
                | (ShareLink.expires_at > now)  # type: ignore[operator]
            ),
        )
    ).first()
    
    return direct_link is not None


def active_shares_for_client(db: Session, *, client_id: uuid.UUID) -> list[uuid.UUID]:
    """Every `album_id` currently accessible to `client_id`, across all
    studios — union of explicit AlbumClientShare rows and direct ShareLink rows.
    """
    now = datetime.now(timezone.utc)

    # 1. Explicit shares in AlbumClientShare.
    explicit = set(
        db.execute(
            select(AlbumClientShare.album_id).where(
                AlbumClientShare.client_id == client_id,
                AlbumClientShare.revoked_at.is_(None),
            )
        ).scalars().all()
    )

    # 2. Direct ShareLink assigned to client_id.
    direct = set(
        db.execute(
            select(ShareLink.album_id).where(
                ShareLink.client_id == client_id,
                ShareLink.is_revoked.is_(False),
                and_(
                    ShareLink.expires_at.is_(None)
                    | (ShareLink.expires_at > now)  # type: ignore[operator]
                ),
            )
        ).scalars().all()
    )

    return list(explicit | direct)