from fastapi import APIRouter, Depends
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_studio_user
from app.db.session import get_db
from app.models.connection import ConnectionStatus, StudioClientConnection
from app.models.gallery import DownloadEvent, Media, MediaType, ShareLink, GalleryViewEvent
from app.models.user import User
from app.schemas.admin_dashboard import (
    AdminDashboardStatsRead,
    ClientStatsListRead,
    ClientStatsRead,
    DashboardAnalyticsRead,
    AnalyticsSeriesRead,
)
from datetime import datetime, timedelta, timezone

router = APIRouter(prefix="/admin-dashboard", tags=["admin-dashboard"])

_BYTES_PER_GB = 1024**3


@router.get("/stats", response_model=AdminDashboardStatsRead)
def get_admin_dashboard_stats(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> AdminDashboardStatsRead:
    """Real aggregate numbers for the Admin Dashboard header stat cards.

    Every figure is scoped to `current_user` (the logged-in studio) and
    computed live off the actual rows — no seeded/simulated data, unlike
    the old `InMemoryAdminDashboardRepository` this replaces on the
    Flutter side.
    """

    # --- Media: photo/video counts + storage, excluding trashed items ---
    media_rows = db.execute(
        select(Media.media_type, func.count(), func.coalesce(func.sum(Media.size_bytes), 0))
        .where(Media.owner_id == current_user.id, Media.is_deleted.is_(False))
        .group_by(Media.media_type)
    ).all()

    photo_count = 0
    video_count = 0
    storage_used_bytes = 0
    for media_type, count, size_sum in media_rows:
        storage_used_bytes += int(size_sum or 0)
        if media_type == MediaType.photo:
            photo_count = count
        elif media_type == MediaType.video:
            video_count = count

    # --- Clients: accepted vs pending studio<->client connections ---
    connection_rows = db.execute(
        select(StudioClientConnection.status, func.count())
        .where(StudioClientConnection.studio_id == current_user.id)
        .group_by(StudioClientConnection.status)
    ).all()
    connection_counts = {status_: count for status_, count in connection_rows}
    client_count = connection_counts.get(ConnectionStatus.accepted, 0)
    pending_client_requests = connection_counts.get(ConnectionStatus.pending, 0)

    # --- Shared galleries: active (non-revoked) share links ---
    shared_gallery_count = db.execute(
        select(func.count())
        .select_from(ShareLink)
        .where(ShareLink.owner_id == current_user.id, ShareLink.is_revoked.is_(False))
    ).scalar_one()

    # --- Gallery engagement: total views + total downloads ---
    total_gallery_views = db.execute(
        select(func.coalesce(func.sum(ShareLink.views_count), 0))
        .where(ShareLink.owner_id == current_user.id, ShareLink.is_revoked.is_(False))
    ).scalar_one() or 0

    total_gallery_downloads = db.execute(
        select(func.count())
        .select_from(DownloadEvent)
        .where(DownloadEvent.owner_id == current_user.id)
    ).scalar_one() or 0

    return AdminDashboardStatsRead(
        photo_count=photo_count,
        video_count=video_count,
        total_media_count=photo_count + video_count,
        storage_used_bytes=storage_used_bytes,
        storage_used_gb=round(storage_used_bytes / _BYTES_PER_GB, 3),
        client_count=client_count,
        pending_client_requests=pending_client_requests,
        shared_gallery_count=shared_gallery_count,
        total_gallery_views=int(total_gallery_views),
        total_gallery_downloads=int(total_gallery_downloads),
    )


@router.get("/client-stats", response_model=ClientStatsListRead)
def get_client_stats(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> ClientStatsListRead:
    """Studio-only — returns per-client download counts for the Admin
    Dashboard's Views / Downloads tabs.

    ``total_downloads``: aggregated from ``DownloadEvent`` rows where
    ``owner_id`` = current studio and ``downloaded_by_user_id`` = a
    connected client (any status — so a booking against a recently-
    disconnected client still shows its historic downloads).

    ``total_views``: the current ``ShareLink`` schema records a running
    ``views_count`` per link but does NOT store which user opened it.
    Until a per-viewer tracking table lands this field returns 0 for
    every client, and the UI should display a studio-wide total instead.

    Only returns rows for clients who have at least one download, so the
    Flutter side must treat a missing entry as zero rather than erroring.
    """
    # --- accepted connected clients (used as the "known client" set) ---
    accepted_client_rows = db.execute(
        select(StudioClientConnection.client_id).where(
            StudioClientConnection.studio_id == current_user.id,
            StudioClientConnection.status == ConnectionStatus.accepted,
        )
    ).scalars().all()

    client_ids = [c for c in accepted_client_rows]

    if not client_ids:
        return ClientStatsListRead(items=[])

    # --- downloads per client (DownloadEvent rows on studio's media) ---
    download_rows = db.execute(
        select(
            DownloadEvent.downloaded_by_user_id,
            func.count().label("cnt"),
        )
        .where(
            DownloadEvent.owner_id == current_user.id,
            DownloadEvent.downloaded_by_user_id.in_(client_ids),
        )
        .group_by(DownloadEvent.downloaded_by_user_id)
    ).all()

    downloads_by_client: dict = {str(row[0]): row[1] for row in download_rows}

    # --- assigned galleries per client ---
    from app.models.album_share import AlbumClientShare
    share_rows = db.execute(
        select(AlbumClientShare.client_id, AlbumClientShare.album_id)
        .where(
            AlbumClientShare.studio_id == current_user.id,
            AlbumClientShare.client_id.in_(client_ids),
            AlbumClientShare.revoked_at.is_(None)
        )
    ).all()

    galleries_by_client: dict[str, list[str]] = {}
    for cid, aid in share_rows:
        cid_str = str(cid)
        if cid_str not in galleries_by_client:
            galleries_by_client[cid_str] = []
        galleries_by_client[cid_str].append(str(aid))

    # --- views per client ---
    view_rows = db.execute(
        select(
            GalleryViewEvent.viewer_id,
            func.count().label("cnt"),
        )
        .where(
            GalleryViewEvent.owner_id == current_user.id,
            GalleryViewEvent.viewer_id.in_(client_ids),
        )
        .group_by(GalleryViewEvent.viewer_id)
    ).all()

    views_by_client: dict = {str(row[0]): row[1] for row in view_rows}

    items = [
        ClientStatsRead(
            client_id=str(cid),
            total_views=views_by_client.get(str(cid), 0),
            total_downloads=downloads_by_client.get(str(cid), 0),
            assigned_gallery_ids=galleries_by_client.get(str(cid), [])
        )
        for cid in client_ids
    ]

    return ClientStatsListRead(items=items)




@router.get("/analytics", response_model=DashboardAnalyticsRead)
def get_analytics(
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> DashboardAnalyticsRead:
    """Returns analytics data for the dashboard carousel."""
    now = datetime.now(timezone.utc)
    
    # 1. Uploads (Last 7 Days)
    seven_days_ago = now - timedelta(days=6) # 7 days including today
    seven_days_ago = seven_days_ago.replace(hour=0, minute=0, second=0, microsecond=0)
    
    media_rows = db.execute(
        select(Media.created_at)
        .where(Media.owner_id == current_user.id, Media.created_at >= seven_days_ago, Media.is_deleted.is_(False))
    ).scalars().all()
    
    uploads_by_day = [0] * 7
    for dt in media_rows:
        day_diff = (now.date() - dt.date()).days
        if 0 <= day_diff < 7:
            uploads_by_day[6 - day_diff] += 1

    # 2. Downloads (Last 7 Days)
    download_rows = db.execute(
        select(DownloadEvent.downloaded_at)
        .where(DownloadEvent.owner_id == current_user.id, DownloadEvent.downloaded_at >= seven_days_ago)
    ).scalars().all()

    downloads_by_day = [0] * 7
    for dt in download_rows:
        day_diff = (now.date() - dt.date()).days
        if 0 <= day_diff < 7:
            downloads_by_day[6 - day_diff] += 1

    # 3. Client Growth (Last 6 Months)
    # Using approx 180 days for the last 6 months
    six_months_ago = now - timedelta(days=180)
    client_rows = db.execute(
        select(StudioClientConnection.created_at)
        .where(StudioClientConnection.studio_id == current_user.id, 
               StudioClientConnection.status == ConnectionStatus.accepted,
               StudioClientConnection.created_at >= six_months_ago)
    ).scalars().all()
    
    clients_by_month = [0] * 6
    for dt in client_rows:
        # Calculate month difference
        month_diff = (now.year - dt.year) * 12 + now.month - dt.month
        if 0 <= month_diff < 6:
            clients_by_month[5 - month_diff] += 1

    # 4. Views (Last 7 Days)
    view_rows = db.execute(
        select(GalleryViewEvent.viewed_at)
        .where(GalleryViewEvent.owner_id == current_user.id, GalleryViewEvent.viewed_at >= seven_days_ago)
    ).scalars().all()

    views_by_day = [0] * 7
    for dt in view_rows:
        day_diff = (now.date() - dt.date()).days
        if 0 <= day_diff < 7:
            views_by_day[6 - day_diff] += 1

    return DashboardAnalyticsRead(
        series=[
            AnalyticsSeriesRead(
                title="Gallery Views",
                subtitle="Last 7 Days",
                values=views_by_day,
                gradient=[0xFF7C5CFF, 0xFFA855F7],
                isBar=True
            ),
            AnalyticsSeriesRead(
                title="Uploads",
                subtitle="Last 7 Days",
                values=uploads_by_day,
                gradient=[0xFF7C5CFF, 0xFFA855F7], # ARGB
                isBar=True
            ),
            AnalyticsSeriesRead(
                title="Downloads",
                subtitle="Last 7 Days",
                values=downloads_by_day,
                gradient=[0xFFEC4899, 0xFFF472B6],
                isBar=True
            ),
            AnalyticsSeriesRead(
                title="Client Growth",
                subtitle="Last 6 Months",
                values=clients_by_month,
                gradient=[0xFFF59E0B, 0xFF7C5CFF],
                isBar=False
            ),
            AnalyticsSeriesRead(
                title="Gallery Views",
                subtitle="Trend unavailable",
                values=[0, 0, 0, 0, 0, 0, 0],
                gradient=[0xFF10B981, 0xFF34D399],
                isBar=False
            )
        ]
    )


@router.post("/trigger-auto-delete")
def trigger_auto_delete(
    current_user: User = Depends(get_current_studio_user),
) -> dict:
    """Manually triggers one sweep of the auto-delete scheduler immediately.
    Useful for testing — normally the scheduler runs automatically every hour.
    Only accessible to authenticated studio users.
    """
    from app.core.auto_delete import run_auto_delete
    deleted = run_auto_delete()
    return {"deleted_count": deleted, "message": f"Auto-delete sweep complete. {deleted} item(s) permanently deleted."}
