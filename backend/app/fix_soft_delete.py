import os
import re

def process_file(filepath):
    if not os.path.exists(filepath):
        print(f"Skipping {filepath} (does not exist)")
        return
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    # We want to replace `select(Folder).where(` with `select(Folder).where(Folder.deleted_at.is_(None), `
    # but be careful not to double replace.
    if "select(Folder).where(Folder.deleted_at.is_(None)" not in content:
        content = content.replace("select(Folder).where(", "select(Folder).where(Folder.deleted_at.is_(None), ")
    
    if "select(Album).where(Album.deleted_at.is_(None)" not in content:
        content = content.replace("select(Album).where(", "select(Album).where(Album.deleted_at.is_(None), ")

    # We also need to fix `_get_owned_folder` and `_get_owned_album` in folders.py and albums.py
    # They do: db.execute(select(Folder).where(Folder.id == folder_id, Folder.owner_id == owner_id))
    # This will be replaced by the above logic.

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Processed {filepath}")

files = [
    "app/api/routes/folders.py",
    "app/api/routes/albums.py",
    "app/api/routes/client_gallery.py",
    "app/api/routes/search.py",
    "app/api/routes/studio_shares.py",
    "app/api/routes/share_links.py",
    "app/api/routes/admin_dashboard.py",
]

for file in files:
    process_file(file)
