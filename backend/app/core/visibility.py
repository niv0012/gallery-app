import uuid
from sqlalchemy.orm import Session
from app.models.gallery import Folder, Album

def is_visible_to_client(db: Session, *, folder_id: uuid.UUID | None = None, album_id: uuid.UUID | None = None) -> bool:
    """
    Returns True if the item and all its ancestor folders are NOT hidden.
    Used to enforce privacy (Task 4.5). Hidden items should return 404 or be 
    omitted from lists for clients.
    """
    current_folder_id = folder_id

    if album_id is not None:
        album = db.get(Album, album_id)
        if album is None:
            return False
        current_folder_id = album.folder_id

    # Walk up the folder tree
    seen_ids = set()
    while current_folder_id is not None:
        if current_folder_id in seen_ids:
            break # Prevent infinite loop on bad data
        seen_ids.add(current_folder_id)
        
        folder = db.get(Folder, current_folder_id)
        if folder is None:
            return False
        if getattr(folder, "is_hidden", False):
            return False
            
        current_folder_id = folder.parent_id

    return True
