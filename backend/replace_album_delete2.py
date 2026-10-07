import uuid
from datetime import datetime, timezone
from sqlalchemy import select, update
from app.schemas.gallery import DeleteMode, DeletePreviewResponse

new_code = '''
@router.get("/{album_id}/delete-preview", response_model=DeletePreviewResponse)
def preview_delete_album(
    album_id: uuid.UUID,
    mode: DeleteMode = DeleteMode.move_up,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> DeletePreviewResponse:
    album = _get_owned_album(db, album_id, current_user.id)
    
    media_affected = db.execute(select(sa.func.count(Media.id)).where(Media.album_id == album_id)).scalar() or 0
    
    return DeletePreviewResponse(
        mode=mode,
        folders_affected=0,
        albums_affected=1,
        media_affected=media_affected
    )

@router.delete("/{album_id}", response_model=MessageResponse)
def delete_album(
    album_id: uuid.UUID,
    mode: DeleteMode = DeleteMode.move_up,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Deletes an album according to the requested mode in a single transaction."""
    album = _get_owned_album(db, album_id, current_user.id)
    folder_id = album.folder_id
    now = datetime.now(timezone.utc)
    
    if mode == DeleteMode.move_up:
        # Move up media to the album's parent folder
        db.execute(
            update(Media).where(Media.album_id == album_id).values(album_id=None, folder_id=folder_id)
        )
        album.deleted_at = now
    else:
        # delete_all: Mark media as deleted
        db.execute(
            update(Media).where(Media.album_id == album_id, Media.is_deleted.is_(False)).values(deleted_at=now, is_deleted=True)
        )
        album.deleted_at = now
        
    db.commit()
    return MessageResponse(message=f"Album deleted successfully (mode: {mode.value}).")
'''

import re
with open('app/api/routes/albums.py', 'r', encoding='utf-8') as f:
    code = f.read()

# Replace the old delete_album method
start_match = re.search(r'@router\.delete\("/\{album_id\}", response_model=MessageResponse\)', code)
if start_match:
    start_idx = start_match.start()
    
    # We want to replace everything from @router.delete to the end of the delete_album function.
    # We know nothing else is at the end of the file except this function? Let's check where the function ends.
    # We can just replace from start_idx to the end of the file.
    
    new_code_text = code[:start_idx] + new_code + '\n\n'
    
    # ensure DeleteMode and DeletePreviewResponse are imported
    if 'DeleteMode' not in new_code_text:
        new_code_text = new_code_text.replace('AlbumUpdate,\n    ConnectedAlbumRead', 'AlbumUpdate,\n    ConnectedAlbumRead,\n    DeleteMode,\n    DeletePreviewResponse')
        
    with open('app/api/routes/albums.py', 'w', encoding='utf-8') as f:
        f.write(new_code_text)
    print("Replaced delete_album.")
else:
    print("Could not find start index for replacement.")
