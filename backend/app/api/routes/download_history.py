import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_studio_user
from app.core.download_log import record_download_event
from app.core.storage import build_media_url
from app.db.session import get_db
from app.models.gallery import DownloadEvent, DownloadSource, Media
from app.models.user import User
from app.schemas.gallery import (
    DownloadEventCreate,
    DownloadEventRead,
    DownloadHistoryStatsRead,
)

router = APIRouter(prefix="/download-history", tags=["download-history"])


def _resolve_downloaded_by(event: DownloadEvent, full_name: str | None) -> str:
    if full_name:
        return full_name
    if event.downloader_label:
        return event.downloader_label
    if event.share_link_id is not None:
        return "Shared link viewer"
    return "Unknown"


@router.post("", response_model=DownloadEventRead, status_code=status.HTTP_201_CREATED)
def log_download(
    payload: DownloadEventCreate,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> DownloadEventRead:
    """Called by the app right before it saves a photo/video to the
    device — logs one Download History row for the studio's own
    in-app download. (Public share-link downloads are logged
    automatically by `POST /public/share-links/{token}/download`.)
    """
    media = db.get(Media, payload.media_id)
    if media is None or media.owner_id != current_user.id or getattr(media, "deleted_at", None) is not None:
        raise HTTPException(status_code=404, detail="Media not found")

    event = record_download_event(
        db,
        media=media,
        source=DownloadSource.app,
        downloaded_by_user_id=current_user.id,
    )
    db.commit()
    db.refresh(event)
    return DownloadEventRead.from_model(
        event,
        _resolve_downloaded_by(event, current_user.full_name),
        thumbnail_url=build_media_url(media.thumbnail_path) or build_media_url(media.file_path),
        file_url=build_media_url(media.file_path),
    )


@router.get("", response_model=list[DownloadEventRead])
def list_download_history(
    media_id: uuid.UUID | None = None,
    album_id: uuid.UUID | None = None,
    source: DownloadSource | None = None,
    limit: int = Query(default=100, le=500),
    offset: int = 0,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> list[DownloadEventRead]:
    """Lists this studio's download history, most recent first. One
    query with an outer join to `users` resolves the "who" label for
    every row without N+1 lookups."""
    query = (
        select(DownloadEvent, User.full_name, Media)
        .outerjoin(User, User.id == DownloadEvent.downloaded_by_user_id)
        .outerjoin(Media, Media.id == DownloadEvent.media_id)
        .where(DownloadEvent.owner_id == current_user.id)
    )
    if media_id is not None:
        query = query.where(DownloadEvent.media_id == media_id)
    if album_id is not None:
        query = query.where(DownloadEvent.album_id == album_id)
    if source is not None:
        query = query.where(DownloadEvent.source == source)

    query = query.order_by(DownloadEvent.downloaded_at.desc()).limit(limit).offset(offset)
    rows = db.execute(query).all()

    return [
        DownloadEventRead.from_model(
            event,
            _resolve_downloaded_by(event, full_name),
            thumbnail_url=(build_media_url(media.thumbnail_path) or build_media_url(media.file_path))
            if media is not None
            else None,
            file_url=build_media_url(media.file_path) if media is not None else None,
        )
        for event, full_name, media in rows
    ]


@router.get("/stats", response_model=DownloadHistoryStatsRead)
def get_download_history_stats(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> DownloadHistoryStatsRead:
    rows = db.execute(
        select(DownloadEvent.source, func.count())
        .where(DownloadEvent.owner_id == current_user.id)
        .group_by(DownloadEvent.source)
    ).all()
    counts = {src: cnt for src, cnt in rows}

    return DownloadHistoryStatsRead(
        total_downloads=sum(counts.values()),
        downloads_via_app=counts.get(DownloadSource.app, 0),
        downloads_via_share_link=counts.get(DownloadSource.share_link, 0),
    )
