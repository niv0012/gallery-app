import sys
with open('app/api/routes/folders.py', 'r', encoding='utf-8') as f:
    code = f.read()

import re

# We will just rewrite _folder_counts completely.
start_idx = code.find('def _folder_counts(db: Session, owner_id: uuid.UUID)')
end_idx = code.find('def _album_counts(', start_idx)

new_func = '''def _folder_counts(db: Session, owner_id: uuid.UUID) -> dict[uuid.UUID, dict]:
    """Computes recursive counts (album_count, photo_count, video_count)
    and up to 4 preview thumbnails for every folder owned by this studio,
    accumulating counts through all descendant sub-folders.
    """
    folders = db.execute(
        select(Folder.id, Folder.parent_id).where(Folder.deleted_at.is_(None), Folder.owner_id == owner_id)
    ).all()
    if not folders:
        return {}

    album_rows = db.execute(
        select(Album.id, Album.folder_id)
        .where(Album.deleted_at.is_(None), Album.owner_id == owner_id, Album.folder_id.isnot(None))
    ).all()

    folder_to_albums: dict[uuid.UUID, set[uuid.UUID]] = {}
    album_to_folder: dict[uuid.UUID, uuid.UUID] = {}
    for album_id, f_id in album_rows:
        if f_id is not None:
            folder_to_albums.setdefault(f_id, set()).add(album_id)
            album_to_folder[album_id] = f_id

    media_rows = db.execute(
        select(Media.id, Media.folder_id, Media.album_id, Media.media_type, Media.thumbnail_path, Media.file_path, Media.created_at)
        .where(Media.owner_id == owner_id, Media.is_deleted.is_(False))
    ).all()

    folder_to_photos: dict[uuid.UUID, set[uuid.UUID]] = {}
    folder_to_videos: dict[uuid.UUID, set[uuid.UUID]] = {}
    folder_to_media_info: dict[uuid.UUID, list[tuple]] = {}

    for m_id, m_f_id, m_a_id, m_type, thumb_path, file_path, created_at in media_rows:
        target_folders: set[uuid.UUID] = set()
        if m_f_id is not None:
            target_folders.add(m_f_id)
        if m_a_id is not None and m_a_id in album_to_folder:
            target_folders.add(album_to_folder[m_a_id])

        type_str = m_type.value if hasattr(m_type, "value") else str(m_type)
        path = thumb_path if thumb_path else file_path
        
        for f_id in target_folders:
            if type_str == "photo":
                folder_to_photos.setdefault(f_id, set()).add(m_id)
            elif type_str == "video":
                folder_to_videos.setdefault(f_id, set()).add(m_id)
                
            folder_to_media_info.setdefault(f_id, []).append((created_at, path))

    children_map: dict[uuid.UUID, list[uuid.UUID]] = {}
    for f_id, parent_id in folders:
        if parent_id is not None:
            children_map.setdefault(parent_id, []).append(f_id)

    memo_albums: dict[uuid.UUID, set[uuid.UUID]] = {}
    memo_photos: dict[uuid.UUID, set[uuid.UUID]] = {}
    memo_videos: dict[uuid.UUID, set[uuid.UUID]] = {}
    memo_media_info: dict[uuid.UUID, list[tuple]] = {}

    def get_folder_contents(f_id: uuid.UUID, visited: set[uuid.UUID]):
        if f_id in memo_albums:
            return memo_albums[f_id], memo_photos[f_id], memo_videos[f_id], memo_media_info[f_id]
        if f_id in visited:
            return set(), set(), set(), []

        visited.add(f_id)

        albums = set(folder_to_albums.get(f_id, set()))
        photos = set(folder_to_photos.get(f_id, set()))
        videos = set(folder_to_videos.get(f_id, set()))
        media_info = list(folder_to_media_info.get(f_id, []))

        for child_id in children_map.get(f_id, []):
            c_albums, c_photos, c_videos, c_media = get_folder_contents(child_id, visited.copy())
            albums.update(c_albums)
            photos.update(c_photos)
            videos.update(c_videos)
            media_info.extend(c_media)

        memo_albums[f_id] = albums
        memo_photos[f_id] = photos
        memo_videos[f_id] = videos
        memo_media_info[f_id] = media_info
        return albums, photos, videos, media_info

    from app.core.storage import build_media_url

    results: dict[uuid.UUID, dict] = {}
    for f_id, _ in folders:
        albums, photos, videos, media_info = get_folder_contents(f_id, set())
        
        # Sort media_info by created_at desc, take top 4
        # Since media_info can have duplicates (if a media is mapped to both folder and album inside it, though unlikely), we use a set for paths
        unique_paths = []
        seen = set()
        for created_at, path in sorted(media_info, key=lambda x: x[0], reverse=True):
            if path not in seen:
                seen.add(path)
                unique_paths.append(build_media_url(path))
                if len(unique_paths) == 4:
                    break

        results[f_id] = {
            "album_count": len(albums),
            "photo_count": len(photos),
            "video_count": len(videos),
            "preview_thumbnails": unique_paths,
        }

    return results

'''

if start_idx != -1 and end_idx != -1:
    new_code = code[:start_idx] + new_func + code[end_idx:]
    with open('app/api/routes/folders.py', 'w', encoding='utf-8') as f:
        f.write(new_code)
    print("Replaced _folder_counts.")
else:
    print("Failed to find indices.")
