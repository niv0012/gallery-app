with open('app/api/routes/folders.py', 'r', encoding='utf-8') as f:
    code = f.read()

new_endpoint = '''
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
    counts = _folder_counts(db, current_user.id)

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

    return FolderContentsRead(
        folders=[
            FolderRead.from_model(
                f,
                album_count=counts.get(f.id, {}).get("album_count", 0),
                photo_count=counts.get(f.id, {}).get("photo_count", 0),
                video_count=counts.get(f.id, {}).get("video_count", 0),
                preview_thumbnails=counts.get(f.id, {}).get("preview_thumbnails", []),
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
'''

with open('app/api/routes/folders.py', 'a', encoding='utf-8') as f:
    f.write(new_endpoint)
