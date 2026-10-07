import os
import uuid
from sqlalchemy import text
from app.db.session import SessionLocal
from app.api.routes.folders import _folder_counts as old_folder_counts

db = SessionLocal()

def new_folder_counts(db, owner_id, folder_ids=None):
    # 1. album counts
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
    
    # 2. media counts and previews
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
    SELECT ancestor_id, path
    FROM (
        SELECT ancestor_id, path,
               ROW_NUMBER() OVER(PARTITION BY ancestor_id ORDER BY created_at DESC) as rn
        FROM ancestor_media
    ) sub
    WHERE rn <= 4
    ORDER BY ancestor_id, rn
    """
    
    folder_filter = "AND id IN :folder_ids" if folder_ids else ""
    params = {"owner_id": owner_id}
    if folder_ids:
        params["folder_ids"] = tuple(folder_ids)

    results = {}
    
    # Initialize with 0 for all folders requested
    if folder_ids:
        for f in folder_ids:
            results[f] = {"album_count": 0, "photo_count": 0, "video_count": 0, "preview_thumbnails": []}
    else:
        # If no specific folders requested, we just return data for folders that have items.
        # But we actually want to initialize for ALL folders owned by the user
        folders = db.execute(text("SELECT id FROM folders WHERE owner_id = :owner_id AND deleted_at IS NULL"), {"owner_id": owner_id}).fetchall()
        for row in folders:
            results[row[0]] = {"album_count": 0, "photo_count": 0, "video_count": 0, "preview_thumbnails": []}

    for row in db.execute(text(album_sql.format(folder_filter=folder_filter)), params):
        results[row.ancestor_id]["album_count"] = row.album_count

    for row in db.execute(text(media_sql.format(folder_filter=folder_filter)), params):
        results[row.ancestor_id]["photo_count"] = int(row.photo_count or 0)
        results[row.ancestor_id]["video_count"] = int(row.video_count or 0)

    from app.core.storage import build_media_url
    for row in db.execute(text(preview_sql.format(folder_filter=folder_filter)), params):
        results[row.ancestor_id]["preview_thumbnails"].append(build_media_url(row.path))

    return results

# Pick a user with folders
user_id = db.execute(text("SELECT owner_id FROM folders LIMIT 1")).scalar()
if user_id:
    print(f"Testing for user {user_id}")
    import time
    
    t0 = time.time()
    old_res = old_folder_counts(db, user_id)
    t1 = time.time()
    print(f"Old took: {t1-t0:.3f}s")
    
    t0 = time.time()
    new_res = new_folder_counts(db, user_id)
    t1 = time.time()
    print(f"New took: {t1-t0:.3f}s")
    
    # Compare
    for k, v in old_res.items():
        if k not in new_res:
            print(f"Folder {k} missing in new")
            continue
        v2 = new_res[k]
        if v["album_count"] != v2["album_count"]:
            print(f"Mismatch album_count {k}: {v['album_count']} vs {v2['album_count']}")
        if v["photo_count"] != v2["photo_count"]:
            print(f"Mismatch photo_count {k}: {v['photo_count']} vs {v2['photo_count']}")
        if v["video_count"] != v2["video_count"]:
            print(f"Mismatch video_count {k}: {v['video_count']} vs {v2['video_count']}")
        # Previews order might differ slightly but shouldn't matter too much
    print("Done testing.")
