import logging
import os
import tempfile
import uuid
import zipfile
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from fastapi.responses import FileResponse
from sqlalchemy import func, select, update
import sqlalchemy as sa
from sqlalchemy.orm import Session
from sqlalchemy.orm import aliased

from app.api.deps import get_current_studio_user, require_active_plan
from app.db.session import get_db
from app.models.gallery import Album, Folder, Media, ShareLink
from app.models.album_share import AlbumClientShare
from app.models.user import User
from app.schemas.gallery import (
    AlbumRead,
    DeleteMode,
    DeletePreviewResponse,
    FolderContentsRead,
    FolderCreate,
    FolderRead,
    FolderStatsRead,
    FolderUpdate,
    MediaRead,
    RestoreResponse,
    TrashedFolderRead,
)
from app.schemas.user import MessageResponse
from app.core.storage import _fetch_to_temp
from app.core.rules import resolve_folder_rules, resolve_folder_rules_with_source

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/folders", tags=["gallery-folders"])


def _get_owned_folder(db: Session, folder_id: uuid.UUID, owner_id: uuid.UUID, allow_deleted: bool = False) -> Folder:
    folder = db.get(Folder, folder_id)
    if folder is None or folder.owner_id != owner_id or (not allow_deleted and folder.deleted_at is not None):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Folder not found")
    return folder


def _collect_folder_tree_ids(db: Session, root_folder_id: uuid.UUID) -> list[uuid.UUID]:
    folder_cte = select(Folder.id).where(Folder.id == root_folder_id).cte(name="folder_cte", recursive=True)
    folder_alias = aliased(Folder)
    folder_cte = folder_cte.union_all(
        select(folder_alias.id).where(folder_alias.parent_id == folder_cte.c.id)
    )
    return list(db.execute(select(folder_cte.c.id)).scalars().all())


def _folder_has_hidden_ancestor(db: Session, folder: Folder) -> bool:
    current = folder
    seen: set[uuid.UUID] = set()
    while current is not None:
        if current.id in seen:
            break
        seen.add(current.id)
        if current.is_hidden:
            return True
        if current.parent_id is None:
            break
        parent = db.get(Folder, current.parent_id)
        if parent is None or parent.owner_id != folder.owner_id or getattr(parent, "deleted_at", None) is not None:
            break
        current = parent
    return False


def _next_unique_folder_name(
    db: Session,
    *,
    owner_id: uuid.UUID,
    parent_id: uuid.UUID | None,
    preferred_name: str,
    exclude_id: uuid.UUID | None = None,
) -> str:
    sibling_query = select(Folder.name).where(
        Folder.owner_id == owner_id,
        Folder.deleted_at.is_(None),
    )
    if parent_id is None:
        sibling_query = sibling_query.where(Folder.parent_id.is_(None))
    else:
        sibling_query = sibling_query.where(Folder.parent_id == parent_id)
    if exclude_id is not None:
        sibling_query = sibling_query.where(Folder.id != exclude_id)

    existing_names = set(db.execute(sibling_query).scalars().all())
    if preferred_name not in existing_names:
        return preferred_name

    suffix = 2
    while True:
        candidate = f"{preferred_name} ({suffix})"
        if candidate not in existing_names:
            return candidate
        suffix += 1


def _next_unique_album_name(
    db: Session,
    *,
    owner_id: uuid.UUID,
    folder_id: uuid.UUID | None,
    preferred_name: str,
    exclude_id: uuid.UUID | None = None,
) -> str:
    sibling_query = select(Album.name).where(
        Album.owner_id == owner_id,
        Album.deleted_at.is_(None),
    )
    if folder_id is None:
        sibling_query = sibling_query.where(Album.folder_id.is_(None))
    else:
        sibling_query = sibling_query.where(Album.folder_id == folder_id)
    if exclude_id is not None:
        sibling_query = sibling_query.where(Album.id != exclude_id)

    existing_names = set(db.execute(sibling_query).scalars().all())
    if preferred_name not in existing_names:
        return preferred_name

    suffix = 2
    while True:
        candidate = f"{preferred_name} ({suffix})"
        if candidate not in existing_names:
            return candidate
        suffix += 1


def _days_left_before_purge(deleted_at: datetime, purge_days: int = 30) -> int:
    cutoff = deleted_at + timedelta(days=purge_days)
    remaining = cutoff - datetime.now(timezone.utc)
    return max(0, int(remaining.total_seconds() // 86400))


def _folder_counts(db: Session, owner_id: uuid.UUID, folder_ids: list[uuid.UUID] | None = None) -> dict[uuid.UUID, dict]:
    """Computes recursive counts (album_count, photo_count, video_count)
    and up to 4 preview thumbnails for every folder owned by this studio,
    accumulating counts through all descendant sub-folders.
    """
    if folder_ids is not None and not folder_ids:
        return {}

    album_sql = """
    WITH RECURSIVE folder_tree AS (
        SELECT id AS ancestor_id, id AS descendant_id
        FROM folders
        WHERE owner_id = :owner_id AND deleted_at IS NULL
        {folder_filter}
        UNION
        SELECT ft.ancestor_id, f.id
        FROM folder_tree ft
        JOIN folders f ON f.parent_id = ft.descendant_id
        WHERE f.deleted_at IS NULL
    )
    SELECT ft.ancestor_id, count(DISTINCT a.id) as album_count
    FROM folder_tree ft
    JOIN albums a ON a.folder_id = ft.descendant_id
    WHERE a.deleted_at IS NULL
    GROUP BY ft.ancestor_id
    """
    
    media_sql = """
    WITH RECURSIVE folder_tree AS (
        SELECT id AS ancestor_id, id AS descendant_id
        FROM folders
        WHERE owner_id = :owner_id AND deleted_at IS NULL
        {folder_filter}
        UNION
        SELECT ft.ancestor_id, f.id
        FROM folder_tree ft
        JOIN folders f ON f.parent_id = ft.descendant_id
        WHERE f.deleted_at IS NULL
    ),
    ancestor_media AS (
        SELECT ft.ancestor_id, m.id, m.media_type, COALESCE(m.thumbnail_path, m.file_path) as path, m.created_at
        FROM folder_tree ft
        JOIN media m ON m.folder_id = ft.descendant_id
        WHERE m.is_deleted = false
        UNION
        SELECT ft.ancestor_id, m.id, m.media_type, COALESCE(m.thumbnail_path, m.file_path) as path, m.created_at
        FROM folder_tree ft
        JOIN albums a ON a.folder_id = ft.descendant_id
        JOIN media m ON m.album_id = a.id
        WHERE a.deleted_at IS NULL AND m.is_deleted = false
    )
    SELECT ancestor_id,
           SUM(CASE WHEN media_type = 'photo' THEN 1 ELSE 0 END) as photo_count,
           SUM(CASE WHEN media_type = 'video' THEN 1 ELSE 0 END) as video_count
    FROM ancestor_media
    GROUP BY ancestor_id
    """
    
    preview_sql = """
    WITH RECURSIVE folder_tree AS (
        SELECT id AS ancestor_id, id AS descendant_id
        FROM folders
        WHERE owner_id = :owner_id AND deleted_at IS NULL
        {folder_filter}
        UNION
        SELECT ft.ancestor_id, f.id
        FROM folder_tree ft
        JOIN folders f ON f.parent_id = ft.descendant_id
        WHERE f.deleted_at IS NULL
    ),
    ancestor_media AS (
        SELECT ft.ancestor_id, m.id, m.media_type, m.thumbnail_path as path, m.created_at
        FROM folder_tree ft
        JOIN media m ON m.folder_id = ft.descendant_id
        WHERE m.is_deleted = false AND m.thumbnail_path IS NOT NULL
        UNION
        SELECT ft.ancestor_id, m.id, m.media_type, m.thumbnail_path as path, m.created_at
        FROM folder_tree ft
        JOIN albums a ON a.folder_id = ft.descendant_id
        JOIN media m ON m.album_id = a.id
        WHERE a.deleted_at IS NULL AND m.is_deleted = false AND m.thumbnail_path IS NOT NULL
    )
    SELECT ancestor_id, path
    FROM (
        SELECT ancestor_id, path,
               ROW_NUMBER() OVER(PARTITION BY ancestor_id ORDER BY created_at DESC) as rn
        FROM ancestor_media
    ) sub
    WHERE rn <= 4
    ORDER BY ancestor_id, rn
    """
    
    folder_filter = "AND id = ANY(:folder_ids)" if folder_ids else ""
    params = {"owner_id": owner_id}
    if folder_ids:
        params["folder_ids"] = list(folder_ids)

    results = {}
    
    if folder_ids:
        for f in folder_ids:
            results[f] = {"album_count": 0, "photo_count": 0, "video_count": 0, "preview_thumbnails": []}
    else:
        folders = db.execute(sa.text("SELECT id FROM folders WHERE owner_id = :owner_id AND deleted_at IS NULL"), {"owner_id": owner_id}).fetchall()
        for row in folders:
            results[row[0]] = {"album_count": 0, "photo_count": 0, "video_count": 0, "preview_thumbnails": []}

    for row in db.execute(sa.text(album_sql.format(folder_filter=folder_filter)), params):
        results[row.ancestor_id]["album_count"] = row.album_count

    for row in db.execute(sa.text(media_sql.format(folder_filter=folder_filter)), params):
        results[row.ancestor_id]["photo_count"] = int(row.photo_count or 0)
        results[row.ancestor_id]["video_count"] = int(row.video_count or 0)

    from app.core.storage import build_media_url
    for row in db.execute(sa.text(preview_sql.format(folder_filter=folder_filter)), params):
        results[row.ancestor_id]["preview_thumbnails"].append(build_media_url(row.path))

    return results

def _album_counts(db: Session, owner_id: uuid.UUID) -> dict[uuid.UUID, int]:
    """Backwards compatible helper returning folder_id -> recursive album count."""
    counts = _folder_counts(db, owner_id)
    return {f_id: res["album_count"] for f_id, res in counts.items()}


def _would_create_cycle(db: Session, folder_id: uuid.UUID, new_parent_id: uuid.UUID) -> bool:
    """Walks up from `new_parent_id` to the root; True if `folder_id`
    appears anywhere in that chain (which would make the tree circular).
    """
    current_id: uuid.UUID | None = new_parent_id
    seen: set[uuid.UUID] = set()
    while current_id is not None:
        if current_id == folder_id:
            return True
        if current_id in seen:
            break
        seen.add(current_id)
        parent = db.get(Folder, current_id)
        current_id = parent.parent_id if parent else None
    return False


@router.post("", response_model=FolderRead, status_code=status.HTTP_201_CREATED)
def create_folder(
    payload: FolderCreate,
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
) -> FolderRead:
    if payload.parent_id is not None:
        _get_owned_folder(db, payload.parent_id, current_user.id)

    folder = Folder(
        owner_id=current_user.id,
        name=payload.name,
        parent_id=payload.parent_id,
        gradient_argb=",".join(str(v) for v in payload.gradient_argb) if payload.gradient_argb else None,
    )
    db.add(folder)
    db.commit()
    db.refresh(folder)
    return FolderRead.from_model(folder, album_count=0, photo_count=0, video_count=0, preview_thumbnails=[])


def _get_active_share_folder_ids(db: Session, folder_ids: list[uuid.UUID]) -> set[uuid.UUID]:
    if not folder_ids:
        return set()
    now = datetime.now(timezone.utc)
    return set(
        db.execute(
            select(ShareLink.source_folder_id)
            .where(
                ShareLink.source_folder_id.in_(folder_ids),
                ShareLink.is_revoked.is_(False),
                (ShareLink.expires_at.is_(None)) | (ShareLink.expires_at > now)
            )
        ).scalars().all()
    )


@router.get("", response_model=list[FolderRead])
def list_folders(
    parent_id: uuid.UUID | None = None,
    root_only: bool = False,
    favorites_only: bool = False,
    include_hidden: bool = True,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[FolderRead]:
    """`root_only=true` returns top-level folders (parent_id IS NULL),
    which takes precedence over `parent_id` if both are somehow passed.
    """
    query = select(Folder).where(Folder.deleted_at.is_(None), Folder.owner_id == current_user.id)
    if root_only:
        query = query.where(Folder.parent_id.is_(None))
    elif parent_id is not None:
        query = query.where(Folder.parent_id == parent_id)
    if favorites_only:
        query = query.where(Folder.is_favorite.is_(True))
    if not include_hidden:
        query = query.where(Folder.is_hidden.is_(False))
    query = query.order_by(Folder.created_at.desc())

    folders = db.execute(query).scalars().all()
    folder_ids = [f.id for f in folders]
    counts = _folder_counts(db, current_user.id, folder_ids=folder_ids)
    active_shares = _get_active_share_folder_ids(db, folder_ids)
    return [
        FolderRead.from_model(
            f,
            album_count=counts.get(f.id, {}).get("album_count", 0),
            photo_count=counts.get(f.id, {}).get("photo_count", 0),
            video_count=counts.get(f.id, {}).get("video_count", 0),
            preview_thumbnails=counts.get(f.id, {}).get("preview_thumbnails", []),
            has_share_link=f.id in active_shares,
        )
        for f in folders
    ]


@router.get("/trash", response_model=list[TrashedFolderRead])
def list_trashed_folders(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[TrashedFolderRead]:
    deleted_folders = db.execute(
        select(Folder).where(
            Folder.owner_id == current_user.id,
            Folder.deleted_at.isnot(None),
        )
    ).scalars().all()
    if not deleted_folders:
        return []

    folder_by_id = {f.id: f for f in deleted_folders}
    root_deleted_folders = [
        f
        for f in deleted_folders
        if f.parent_id is None
        or f.parent_id not in folder_by_id
        or folder_by_id[f.parent_id].deleted_at != f.deleted_at
    ]

    return [
        TrashedFolderRead(
            id=f.id,
            name=f.name,
            deleted_at=f.deleted_at,
            days_left=_days_left_before_purge(f.deleted_at),
        )
        for f in sorted(root_deleted_folders, key=lambda item: item.deleted_at, reverse=True)
    ]


@router.get("/stats", response_model=FolderStatsRead)
def get_folder_stats(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FolderStatsRead:
    folders = db.execute(select(Folder).where(Folder.deleted_at.is_(None), Folder.owner_id == current_user.id)).scalars().all()
    if not folders:
        return FolderStatsRead(
            total_folders=0,
            root_folder_count=0,
            hidden_folder_count=0,
            favorite_folder_count=0,
            max_depth=0,
            average_albums_per_folder=0,
        )

    by_id = {f.id: f for f in folders}

    def depth_of(folder: Folder) -> int:
        depth = 1
        current = folder
        seen = {current.id}
        while current.parent_id is not None:
            parent = by_id.get(current.parent_id)
            if parent is None or parent.id in seen:
                break
            current = parent
            seen.add(current.id)
            depth += 1
        return depth

    # Calculate total unique albums associated with any folder owned by this user
    total_albums_in_folders = (
        db.execute(
            select(func.count(func.distinct(Album.id)))
            .where(Album.owner_id == current_user.id, Album.folder_id.isnot(None))
        ).scalar()
        or 0
    )

    return FolderStatsRead(
        total_folders=len(folders),
        root_folder_count=sum(1 for f in folders if f.parent_id is None),
        hidden_folder_count=sum(1 for f in folders if f.is_hidden),
        favorite_folder_count=sum(1 for f in folders if f.is_favorite),
        max_depth=max(depth_of(f) for f in folders),
        average_albums_per_folder=total_albums_in_folders / len(folders),
    )


@router.get("/{folder_id}", response_model=FolderRead)
def get_folder(
    folder_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FolderRead:
    folder = _get_owned_folder(db, folder_id, current_user.id)
    counts = _folder_counts(db, current_user.id, folder_ids=[folder.id])
    c = counts.get(folder.id, {})
    return FolderRead.from_model(
        folder,
        album_count=c.get("album_count", 0),
        photo_count=c.get("photo_count", 0),
        video_count=c.get("video_count", 0),
        preview_thumbnails=c.get("preview_thumbnails", []),
    )


@router.get("/{folder_id}/effective-rules")
def get_effective_rules(
    folder_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> dict:
    """Returns the computed (inherited) allow_download and show_watermark values
    for this folder, walking up the tree to find the nearest explicit ancestor.
    A `null` own value means the rule is purely inherited.

    Response includes `allow_download_source` / `show_watermark_source`:
    each is either null (rule is set on this folder or is the system default)
    or {"id": ..., "name": ...} pointing to the ancestor that provides the rule.
    """
    folder = _get_owned_folder(db, folder_id, current_user.id)
    effective = resolve_folder_rules_with_source(db, folder.id)
    return {
        "own_allow_download": folder.allow_download,
        "own_show_watermark": folder.show_watermark,
        "effective_allow_download": effective["allow_download"],
        "effective_show_watermark": effective["show_watermark"],
        "allow_download_source": effective["allow_download_source"],
        "show_watermark_source": effective["show_watermark_source"],
    }


@router.patch("/{folder_id}", response_model=FolderRead)
def update_folder(
    folder_id: uuid.UUID,
    payload: FolderUpdate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FolderRead:
    folder = _get_owned_folder(db, folder_id, current_user.id)
    updates = payload.model_dump(exclude_unset=True, exclude={"clear_parent"})

    if payload.clear_parent:
        folder.parent_id = None
    elif "parent_id" in updates and updates["parent_id"] is not None:
        new_parent_id = updates["parent_id"]
        if new_parent_id == folder.id:
            raise HTTPException(status_code=400, detail="A folder cannot be its own parent")
        _get_owned_folder(db, new_parent_id, current_user.id)
        if _would_create_cycle(db, folder.id, new_parent_id):
            raise HTTPException(status_code=400, detail="That move would create a circular folder tree")
        folder.parent_id = new_parent_id

    if "name" in updates and updates["name"] is not None:
        folder.name = updates["name"]
    if "is_hidden" in updates and updates["is_hidden"] is not None:
        folder.is_hidden = updates["is_hidden"]
    if "is_favorite" in updates and updates["is_favorite"] is not None:
        folder.is_favorite = updates["is_favorite"]
    if "gradient_argb" in updates and updates["gradient_argb"] is not None:
        folder.gradient_argb = ",".join(str(v) for v in updates["gradient_argb"])
    # Phase 3: nullable rule fields — None means "inherit from parent"
    if "allow_download" in updates:
        folder.allow_download = updates["allow_download"]
    if "show_watermark" in updates:
        folder.show_watermark = updates["show_watermark"]

    db.commit()
    db.refresh(folder)
    counts = _folder_counts(db, current_user.id, folder_ids=[folder.id])
    c = counts.get(folder.id, {})
    return FolderRead.from_model(
        folder,
        album_count=c.get("album_count", 0),
        photo_count=c.get("photo_count", 0),
        video_count=c.get("video_count", 0),
        preview_thumbnails=c.get("preview_thumbnails", []),
    )



@router.get("/{folder_id}/delete-preview", response_model=DeletePreviewResponse)
def preview_delete_folder(
    folder_id: uuid.UUID,
    mode: DeleteMode = DeleteMode.move_up,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> DeletePreviewResponse:
    _get_owned_folder(db, folder_id, current_user.id)
    all_folder_ids = _collect_folder_tree_ids(db, folder_id)
    album_ids = list(
        db.execute(
            select(Album.id).where(
                Album.owner_id == current_user.id,
                Album.folder_id.in_(all_folder_ids),
            )
        ).scalars().all()
    )
    albums_affected = len(album_ids)
    media_affected = db.execute(
        select(sa.func.count(Media.id)).where(
            Media.owner_id == current_user.id,
            sa.or_(Media.folder_id.in_(all_folder_ids), Media.album_id.in_(album_ids)),
        )
    ).scalar() or 0

    return DeletePreviewResponse(
        mode=mode,
        folders_affected=len(all_folder_ids),
        albums_affected=albums_affected,
        media_affected=media_affected
    )

@router.delete("/{folder_id}", response_model=MessageResponse)
def delete_folder(
    folder_id: uuid.UUID,
    mode: DeleteMode = DeleteMode.move_up,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Deletes a folder according to the requested mode in a single transaction."""
    folder = _get_owned_folder(db, folder_id, current_user.id)
    all_folder_ids = _collect_folder_tree_ids(db, folder_id)

    parent_id = folder.parent_id
    now = datetime.now(timezone.utc)

    if mode == DeleteMode.move_up:
        if _folder_has_hidden_ancestor(db, folder):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Cannot move up a hidden folder or one inside a hidden path.",
            )
        # Move up child folders that are direct children of the deleted folder
        child_folders = db.execute(
            select(Folder).where(Folder.parent_id == folder_id, Folder.deleted_at.is_(None))
        ).scalars().all()
        for c_f in child_folders:
            c_f.parent_id = parent_id
            c_f.name = _next_unique_folder_name(db, owner_id=current_user.id, parent_id=parent_id, preferred_name=c_f.name, exclude_id=c_f.id)

        # Move up only direct child albums.
        child_albums = db.execute(
            select(Album).where(Album.folder_id == folder_id, Album.deleted_at.is_(None))
        ).scalars().all()
        for c_a in child_albums:
            c_a.folder_id = parent_id
            c_a.name = _next_unique_album_name(db, owner_id=current_user.id, folder_id=parent_id, preferred_name=c_a.name, exclude_id=c_a.id)

        # Move up only direct loose media.
        db.execute(
            update(Media).where(Media.folder_id == folder_id).values(folder_id=parent_id)
        )
        # Finally delete just the root folder being deleted (since others moved up)
        folder.deleted_at = now
        
        # Revoke the folder's own link
        db.execute(
            update(ShareLink)
            .where(ShareLink.source_folder_id == folder_id)
            .values(is_revoked=True)
        )

    else:
        # delete_all: Mark all as deleted
        album_ids = list(
            db.execute(
                select(Album.id).where(
                    Album.owner_id == current_user.id,
                    Album.folder_id.in_(all_folder_ids),
                )
            ).scalars().all()
        )
        db.execute(
            update(Media)
            .where(
                Media.owner_id == current_user.id,
                Media.is_deleted.is_(False),
                sa.or_(
                    Media.folder_id.in_(all_folder_ids),
                    Media.album_id.in_(album_ids),
                ),
            )
            .values(deleted_at=now, is_deleted=True)
        )
        db.execute(
            update(Album)
            .where(
                Album.owner_id == current_user.id,
                Album.folder_id.in_(all_folder_ids),
                Album.deleted_at.is_(None),
            )
            .values(deleted_at=now)
        )
        db.execute(
            update(Folder)
            .where(
                Folder.owner_id == current_user.id,
                Folder.id.in_(all_folder_ids),
                Folder.deleted_at.is_(None),
            )
            .values(deleted_at=now)
        )
        
        # Revoke the folder's own link, and any album links inside the folder
        db.execute(
            update(ShareLink)
            .where(
                sa.or_(
                    ShareLink.source_folder_id.in_(all_folder_ids),
                    ShareLink.album_id.in_(album_ids)
                )
            )
            .values(is_revoked=True)
        )
        db.execute(
            update(AlbumClientShare)
            .where(AlbumClientShare.album_id.in_(album_ids))
            .values(revoked_at=now)
        )

    db.commit()
    return MessageResponse(message=f"Folder deleted successfully (mode: {mode.value}).")


@router.post("/{folder_id}/restore", response_model=RestoreResponse)
def restore_folder(
    folder_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> RestoreResponse:
    folder = _get_owned_folder(db, folder_id, current_user.id, allow_deleted=True)
    if folder.deleted_at is None:
        raise HTTPException(status_code=400, detail="Folder is not deleted")

    deleted_at_marker = folder.deleted_at
    all_folder_ids = _collect_folder_tree_ids(db, folder_id)
    restored_to_root = False

    if folder.parent_id is not None:
        parent = db.get(Folder, folder.parent_id)
        if parent is None or parent.owner_id != current_user.id or parent.deleted_at is not None:
            folder.parent_id = None
            restored_to_root = True

    folder.name = _next_unique_folder_name(
        db,
        owner_id=current_user.id,
        parent_id=folder.parent_id,
        preferred_name=folder.name,
        exclude_id=folder.id,
    )

    folder_ids_to_restore = list(
        db.execute(
            select(Folder.id).where(
                Folder.owner_id == current_user.id,
                Folder.id.in_(all_folder_ids),
                Folder.deleted_at == deleted_at_marker,
            )
        ).scalars().all()
    )
    album_ids_to_restore = list(
        db.execute(
            select(Album.id).where(
                Album.owner_id == current_user.id,
                Album.folder_id.in_(folder_ids_to_restore),
                Album.deleted_at == deleted_at_marker,
            )
        ).scalars().all()
    )

    if folder_ids_to_restore:
        db.execute(
            update(Folder)
            .where(
                Folder.owner_id == current_user.id,
                Folder.id.in_(folder_ids_to_restore),
                Folder.deleted_at == deleted_at_marker,
            )
            .values(deleted_at=None)
        )
    if album_ids_to_restore:
        db.execute(
            update(Album)
            .where(
                Album.owner_id == current_user.id,
                Album.id.in_(album_ids_to_restore),
                Album.deleted_at == deleted_at_marker,
            )
            .values(deleted_at=None)
        )
        db.execute(
            update(Media)
            .where(
                Media.owner_id == current_user.id,
                Media.album_id.in_(album_ids_to_restore),
                Media.deleted_at == deleted_at_marker,
            )
            .values(deleted_at=None, is_deleted=False)
        )
    if folder_ids_to_restore:
        db.execute(
            update(Media)
            .where(
                Media.owner_id == current_user.id,
                Media.folder_id.in_(folder_ids_to_restore),
                Media.deleted_at == deleted_at_marker,
            )
            .values(deleted_at=None, is_deleted=False)
        )

    db.commit()
    message = "Folder restored"
    if restored_to_root:
        message = "Folder restored to root because its parent is unavailable."
    return RestoreResponse(message=message, restored_to_root=restored_to_root)


@router.get("/{folder_id}/zip", response_class=FileResponse)
def download_folder_zip(
    folder_id: uuid.UUID,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FileResponse:
    folder = _get_owned_folder(db, folder_id, current_user.id)

    # 1. Recursive CTE for sub-folders
    folder_cte = select(Folder.id).where(Folder.id == folder_id).cte(name="folder_cte", recursive=True)
    folder_alias = aliased(Folder)
    folder_cte = folder_cte.union_all(
        select(folder_alias.id).where(folder_alias.parent_id == folder_cte.c.id)
    )
    all_folder_ids_list = db.execute(select(folder_cte.c.id)).scalars().all()

    if not all_folder_ids_list:
        raise HTTPException(status_code=404, detail="Folder not found")

    # 2. Get albums in these folders
    album_ids_list = db.execute(
        select(Album.id).where(Album.folder_id.in_(all_folder_ids_list))
    ).scalars().all()

    # 3. Get Media
    media_items = db.execute(
        select(Media).where(
            Media.is_deleted.is_(False),
            Media.owner_id == current_user.id,
            sa.or_(
                Media.folder_id.in_(all_folder_ids_list),
                Media.album_id.in_(album_ids_list)
            )
        )
    ).scalars().all()

    if not media_items:
        raise HTTPException(status_code=404, detail="No media found in folder")

    # 4. Build names map
    folder_map = {f.id: f for f in db.execute(select(Folder).where(Folder.deleted_at.is_(None), Folder.id.in_(all_folder_ids_list))).scalars().all()}
    album_map = {a.id: a for a in db.execute(select(Album).where(Album.deleted_at.is_(None), Album.id.in_(album_ids_list))).scalars().all()}

    def build_path(m: Media) -> str:
        parts = []
        if m.album_id and m.album_id in album_map:
            album = album_map[m.album_id]
            parts.append(album.name)
            fid = album.folder_id
        else:
            fid = m.folder_id

        while fid and fid in folder_map:
            parts.append(folder_map[fid].name)
            if fid == folder_id:
                break
            fid = folder_map[fid].parent_id

        parts.reverse()
        return "/".join(parts) + "/" + m.file_name

    # 5. Create Temp ZIP
    tmp = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
    tmp_path = tmp.name
    tmp.close()
    background_tasks.add_task(os.remove, tmp_path)

    with zipfile.ZipFile(tmp_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        added_paths = set()
        for m in media_items:
            try:
                local_f = _fetch_to_temp(m.file_path)
            except Exception as e:
                logger.error(f"Failed to fetch {m.file_path}: {e}")
                continue

            arcname = build_path(m)
            base_arcname = arcname
            counter = 1
            while arcname in added_paths:
                parts = base_arcname.rsplit('.', 1)
                if len(parts) == 2:
                    arcname = f"{parts[0]}_{counter}.{parts[1]}"
                else:
                    arcname = f"{base_arcname}_{counter}"
                counter += 1
            added_paths.add(arcname)

            zf.write(local_f, arcname)
            
            if tempfile.gettempdir() in str(local_f):
                os.remove(local_f)

    safe_name = folder.name.replace(" ", "_")
    return FileResponse(
        tmp_path,
        media_type="application/zip",
        filename=f"{safe_name}.zip"
    )


@router.get("/{folder_id}/contents", response_model=FolderContentsRead)
def get_folder_contents(
    folder_id: str,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FolderContentsRead:
    parsed_folder_id = None
    if folder_id != "root":
        try:
            parsed_folder_id = uuid.UUID(folder_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid folder_id format")
        _get_owned_folder(db, parsed_folder_id, current_user.id)

    # 1. Folders
    folder_query = select(Folder).where(
        Folder.deleted_at.is_(None), 
        Folder.owner_id == current_user.id
    )
    if parsed_folder_id is None:
        folder_query = folder_query.where(Folder.parent_id.is_(None))
    else:
        folder_query = folder_query.where(Folder.parent_id == parsed_folder_id)
    
    # Sort folders
    folder_query = folder_query.order_by(Folder.created_at.desc())
    folders = db.execute(folder_query).scalars().all()
    counts = _folder_counts(db, current_user.id, folder_ids=[f.id for f in folders])

    # 2. Albums
    album_query = select(Album).where(
        Album.deleted_at.is_(None),
        Album.owner_id == current_user.id
    )
    if parsed_folder_id is None:
        album_query = album_query.where(Album.folder_id.is_(None))
    else:
        album_query = album_query.where(Album.folder_id == parsed_folder_id)
    
    album_query = album_query.order_by(Album.display_order.asc(), Album.created_at.desc())
    albums = db.execute(album_query).scalars().all()
    
    from app.api.routes.albums import _media_counts, _cover_thumbnails
    album_media_counts = _media_counts(db, current_user.id)
    covers = _cover_thumbnails(db, current_user.id)

    # 3. Media
    media_query = select(Media).where(
        Media.is_deleted.is_(False),
        Media.owner_id == current_user.id
    )
    if parsed_folder_id is None:
        media_query = media_query.where(Media.folder_id.is_(None), Media.album_id.is_(None))
    else:
        # Note: media can only be in a folder if it has NO album. If it's in an album, it belongs to the album.
        media_query = media_query.where(Media.folder_id == parsed_folder_id, Media.album_id.is_(None))

    media_query = media_query.order_by(Media.created_at.desc())
    media_items = db.execute(media_query).scalars().all()

    from app.api.routes.media import _like_info_for, _comment_count_for
    media_ids = [m.id for m in media_items]
    like_counts, liked = _like_info_for(db, media_ids, current_user.id)
    comments = _comment_count_for(db, media_ids)

    folder_ids = [f.id for f in folders]
    active_shares = _get_active_share_folder_ids(db, folder_ids)

    return FolderContentsRead(
        folders=[
            FolderRead.from_model(
                f,
                album_count=counts.get(f.id, {}).get("album_count", 0),
                photo_count=counts.get(f.id, {}).get("photo_count", 0),
                video_count=counts.get(f.id, {}).get("video_count", 0),
                preview_thumbnails=counts.get(f.id, {}).get("preview_thumbnails", []),
                has_share_link=f.id in active_shares,
            )
            for f in folders
        ],
        albums=[
            AlbumRead.from_model(
                a,
                photo_count=album_media_counts.get(a.id, (0, 0))[0],
                video_count=album_media_counts.get(a.id, (0, 0))[1],
                cover_thumbnail_url=covers.get(a.id),
            )
            for a in albums
        ],
        media=[
            MediaRead.from_model(
                m,
                like_count=like_counts.get(m.id, 0),
                is_liked_by_me=m.id in liked,
                comment_count=comments.get(m.id, 0),
            )
            for m in media_items
        ]
    )
