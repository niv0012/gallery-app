with open('app/api/routes/folders.py', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace(
"""        folder,
        album_count=c.get("album_count", 0),
        photo_count=c.get("photo_count", 0),
        video_count=c.get("video_count", 0),
    )""",
"""        folder,
        album_count=c.get("album_count", 0),
        photo_count=c.get("photo_count", 0),
        video_count=c.get("video_count", 0),
        preview_thumbnails=c.get("preview_thumbnails", []),
    )"""
)
text = text.replace(
"""    return FolderRead.from_model(folder, album_count=0, photo_count=0, video_count=0)""",
"""    return FolderRead.from_model(folder, album_count=0, photo_count=0, video_count=0, preview_thumbnails=[])"""
)

with open('app/api/routes/folders.py', 'w', encoding='utf-8') as f:
    f.write(text)
