import logging
import os
import tempfile
import uuid
import zipfile

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from fastapi.responses import FileResponse
from sqlalchemy import func, select
import sqlalchemy as sa
from sqlalchemy.orm import Session
from sqlalchemy.orm import aliased

from app.api.deps import get_current_studio_user, require_active_plan
from app.db.session import get_db
from app.models.gallery import Album, Folder, Media
from app.models.user import User
from app.schemas.gallery import FolderCreate, FolderRead, FolderStatsRead, FolderUpdate
from app.schemas.user import MessageResponse
from app.core.storage import _fetch_to_temp

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/folders", tags=["gallery-folders"])


def _get_owned_folder(db: Session, folder_id: uuid.UUID, owner_id: uuid.UUID) -> Folder:
    folder = db.get(Folder, folder_id)
    if folder is None or folder.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Folder not found")
    return folder


def _folder_counts(db: Session, owner_id: uuid.UUID) -> dict[uuid.UUID, dict[str, int]]:
    """Computes recursive counts (album_count, photo_count, video_count)
    for every folder owned by this studio, accumulating counts through
    all descendant sub-folders.
    """
    folders = db.execute(
        select(Folder.id, Folder.parent_id).where(Folder.owner_id == owner_id)
    ).all()
    if not folders:
        return {}

    # Map direct albums per folder
    album_rows = db.execute(
        select(Album.id, Album.folder_id)
        .where(Album.owner_id == owner_id, Album.folder_id.isnot(None))
    ).all()

    folder_to_albums: dict[uuid.UUID, set[uuid.UUID]] = {}
    album_to_folder: dict[uuid.UUID, uuid.UUID] = {}
    for album_id, f_id in album_rows:
        if f_id is not None:
            folder_to_albums.setdefault(f_id, set()).add(album_id)
            album_to_folder[album_id] = f_id

    # Map direct media (photos/videos) per folder (either via folder_id or album's folder_id)
    media_rows = db.execute(
        select(Media.id, Media.folder_id, Media.album_id, Media.media_type)
        .where(Media.owner_id == owner_id, Media.is_deleted.is_(False))
    ).all()

    folder_to_photos: dict[uuid.UUID, set[uuid.UUID]] = {}
    folder_to_videos: dict[uuid.UUID, set[uuid.UUID]] = {}

    for m_id, m_f_id, m_a_id, m_type in media_rows:
        target_folders: set[uuid.UUID] = set()
        if m_f_id is not None:
            target_folders.add(m_f_id)
        if m_a_id is not None and m_a_id in album_to_folder:
            target_folders.add(album_to_folder[m_a_id])

        type_str = m_type.value if hasattr(m_type, "value") else str(m_type)
        for f_id in target_folders:
            if type_str == "photo":
                folder_to_photos.setdefault(f_id, set()).add(m_id)
            elif type_str == "video":
                folder_to_videos.setdefault(f_id, set()).add(m_id)

    # Build parent -> children map
    children_map: dict[uuid.UUID, list[uuid.UUID]] = {}
    for f_id, parent_id in folders:
        if parent_id is not None:
            children_map.setdefault(parent_id, []).append(f_id)

    memo_albums: dict[uuid.UUID, set[uuid.UUID]] = {}
    memo_photos: dict[uuid.UUID, set[uuid.UUID]] = {}
    memo_videos: dict[uuid.UUID, set[uuid.UUID]] = {}

    def get_folder_contents(f_id: uuid.UUID, visited: set[uuid.UUID]) -> tuple[set[uuid.UUID], set[uuid.UUID], set[uuid.UUID]]:
        if f_id in memo_albums:
            return memo_albums[f_id], memo_photos[f_id], memo_videos[f_id]
        if f_id in visited:
            return set(), set(), set()

        visited.add(f_id)

        albums = set(folder_to_albums.get(f_id, set()))
        photos = set(folder_to_photos.get(f_id, set()))
        videos = set(folder_to_videos.get(f_id, set()))

        for child_id in children_map.get(f_id, []):
            c_albums, c_photos, c_videos = get_folder_contents(child_id, visited.copy())
            albums.update(c_albums)
            photos.update(c_photos)
            videos.update(c_videos)

        memo_albums[f_id] = albums
        memo_photos[f_id] = photos
        memo_videos[f_id] = videos
        return albums, photos, videos

    results: dict[uuid.UUID, dict[str, int]] = {}
    for f_id, _ in folders:
        albums, photos, videos = get_folder_contents(f_id, set())
        results[f_id] = {
            "album_count": len(albums),
            "photo_count": len(photos),
            "video_count": len(videos),
        }

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
    return FolderRead.from_model(folder, album_count=0, photo_count=0, video_count=0)


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
    query = select(Folder).where(Folder.owner_id == current_user.id)
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
    counts = _folder_counts(db, current_user.id)
    return [
        FolderRead.from_model(
            f,
            album_count=counts.get(f.id, {}).get("album_count", 0),
            photo_count=counts.get(f.id, {}).get("photo_count", 0),
            video_count=counts.get(f.id, {}).get("video_count", 0),
        )
        for f in folders
    ]


@router.get("/stats", response_model=FolderStatsRead)
def get_folder_stats(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FolderStatsRead:
    folders = db.execute(select(Folder).where(Folder.owner_id == current_user.id)).scalars().all()
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
    counts = _folder_counts(db, current_user.id)
    c = counts.get(folder.id, {})
    return FolderRead.from_model(
        folder,
        album_count=c.get("album_count", 0),
        photo_count=c.get("photo_count", 0),
        video_count=c.get("video_count", 0),
    )


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

    db.commit()
    db.refresh(folder)
    counts = _folder_counts(db, current_user.id)
    c = counts.get(folder.id, {})
    return FolderRead.from_model(
        folder,
        album_count=c.get("album_count", 0),
        photo_count=c.get("photo_count", 0),
        video_count=c.get("video_count", 0),
    )


@router.delete("/{folder_id}", response_model=MessageResponse)
def delete_folder(
    folder_id: uuid.UUID,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Deletes the folder and, via DB cascade, any sub-folders nested
    under it. Albums that were filed in this folder are NOT deleted —
    they become unfiled (`folder_id` set to NULL by the FK's
    ON DELETE SET NULL), matching how removing a folder shouldn't
    silently destroy someone's photos. Use the Album delete endpoint if
    you actually want the albums gone too.
    """
    folder = _get_owned_folder(db, folder_id, current_user.id)
    db.delete(folder)
    db.commit()
    return MessageResponse(message="Folder deleted.")


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
    folder_map = {f.id: f for f in db.execute(select(Folder).where(Folder.id.in_(all_folder_ids_list))).scalars().all()}
    album_map = {a.id: a for a in db.execute(select(Album).where(Album.id.in_(album_ids_list))).scalars().all()}

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

