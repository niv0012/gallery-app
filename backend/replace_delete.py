import uuid
from datetime import datetime, timezone
from sqlalchemy import select, update
from app.schemas.gallery import DeleteMode, DeletePreviewResponse

new_code = '''
@router.get("/{folder_id}/delete-preview", response_model=DeletePreviewResponse)
def preview_delete_folder(
    folder_id: uuid.UUID,
    mode: DeleteMode = DeleteMode.move_up,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> DeletePreviewResponse:
    folder = _get_owned_folder(db, folder_id, current_user.id)
    
    folder_cte = select(Folder.id).where(Folder.id == folder_id).cte(name="folder_cte", recursive=True)
    folder_alias = aliased(Folder)
    folder_cte = folder_cte.union_all(
        select(folder_alias.id).where(folder_alias.parent_id == folder_cte.c.id)
    )
    all_folder_ids = db.execute(select(folder_cte.c.id)).scalars().all()
    
    albums_affected = db.execute(select(sa.func.count(Album.id)).where(Album.folder_id.in_(all_folder_ids))).scalar() or 0
    media_affected = db.execute(select(sa.func.count(Media.id)).where(Media.folder_id.in_(all_folder_ids))).scalar() or 0
    
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
    
    folder_cte = select(Folder.id).where(Folder.id == folder_id).cte(name="folder_cte", recursive=True)
    folder_alias = aliased(Folder)
    folder_cte = folder_cte.union_all(
        select(folder_alias.id).where(folder_alias.parent_id == folder_cte.c.id)
    )
    all_folder_ids = db.execute(select(folder_cte.c.id)).scalars().all()
    
    parent_id = folder.parent_id
    now = datetime.now(timezone.utc)
    
    if mode == DeleteMode.move_up:
        # Move up child folders that are direct children of the deleted folder
        db.execute(
            update(Folder).where(Folder.parent_id == folder_id).values(parent_id=parent_id)
        )
        # Move up albums
        db.execute(
            update(Album).where(Album.folder_id.in_(all_folder_ids)).values(folder_id=parent_id)
        )
        # Move up media
        db.execute(
            update(Media).where(Media.folder_id.in_(all_folder_ids)).values(folder_id=parent_id)
        )
        # Finally delete just the root folder being deleted (since others moved up)
        folder.deleted_at = now
    else:
        # delete_all: Mark all as deleted
        db.execute(
            update(Media).where(Media.folder_id.in_(all_folder_ids), Media.is_deleted.is_(False)).values(deleted_at=now, is_deleted=True)
        )
        db.execute(
            update(Album).where(Album.folder_id.in_(all_folder_ids), Album.deleted_at.is_(None)).values(deleted_at=now)
        )
        db.execute(
            update(Folder).where(Folder.id.in_(all_folder_ids), Folder.deleted_at.is_(None)).values(deleted_at=now)
        )
        
    db.commit()
    return MessageResponse(message=f"Folder deleted successfully (mode: {mode.value}).")
'''

import re
with open('app/api/routes/folders.py', 'r', encoding='utf-8') as f:
    code = f.read()

# Replace the old delete_folder method
start_match = re.search(r'@router\.delete\("/\{folder_id\}", response_model=MessageResponse\)', code)
if start_match:
    start_idx = start_match.start()
    end_idx = code.find('@router.get("/{folder_id}/zip"', start_idx)
    if end_idx != -1:
        new_code = code[:start_idx] + new_code + '\n\n' + code[end_idx:]
        
        # ensure DeleteMode and DeletePreviewResponse are imported
        if 'DeleteMode' not in new_code:
            new_code = new_code.replace('FolderContentsRead, AlbumRead, MediaRead', 'FolderContentsRead, AlbumRead, MediaRead, DeleteMode, DeletePreviewResponse')
            
        with open('app/api/routes/folders.py', 'w', encoding='utf-8') as f:
            f.write(new_code)
        print("Replaced delete_folder.")
    else:
        print("Could not find end index for replacement.")
else:
    print("Could not find start index for replacement.")
