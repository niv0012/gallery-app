"""ZIP-job endpoints (Phase 4 – 7.3).

POST /zip-jobs        – queue a ZIP job for a folder or album.
GET  /zip-jobs/{id}  – poll job status / get result URL.
GET  /zip-jobs        – list the caller's recent jobs.
DELETE /zip-jobs/{id} – cancel a pending/processing job.

Rules enforced:
* Max 2 simultaneous active (pending/processing) jobs per user.
* ZIP_STORED (no re-compression): deflate level 0.
* Result URL is a 24-hour signed link (R2) or a local download URL.
* A cleanup background task marks expired jobs and purges their ZIPs.
"""
from __future__ import annotations

import logging
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import and_, func, select
from sqlalchemy.orm import Session

from app.api.deps import require_active_plan
from app.core.config import settings
from app.core.storage import _r2_client, _storage_root, _use_r2
from app.core.visibility import is_visible_to_client
from app.db.session import SessionLocal, get_db
from app.models.gallery import Album, Folder, Media
from app.models.job import Job, JobStatus
from app.models.notification import Notification, NotificationType
from app.models.user import User
from app.core.notification_service import send_push_if_enabled


router = APIRouter(prefix="/zip-jobs", tags=["zip-jobs"])
logger = logging.getLogger(__name__)

_JOB_EXPIRY_HOURS = 24
_MAX_ACTIVE_JOBS = 2
_ZIP_DIR_NAME = "zip_jobs"


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class ZipJobCreate(BaseModel):
    kind: Literal["zip_folder", "zip_album"]
    target_id: uuid.UUID


class ZipJobRead(BaseModel):
    id: uuid.UUID
    kind: str
    status: JobStatus
    progress: int
    result_url: str | None
    error_message: str | None
    created_at: datetime
    updated_at: datetime
    expires_at: datetime | None

    @classmethod
    def from_model(cls, j: Job) -> "ZipJobRead":
        return cls(
            id=j.id,
            kind=j.kind,
            status=j.status,
            progress=j.progress,
            result_url=j.result_url,
            error_message=j.error_message,
            created_at=j.created_at,
            updated_at=j.updated_at,
            expires_at=j.expires_at,
        )


# ---------------------------------------------------------------------------
# Background worker
# ---------------------------------------------------------------------------

def _build_zip(job_id: uuid.UUID, owner_id: uuid.UUID) -> None:
    """Runs in a FastAPI BackgroundTask thread – builds the ZIP and updates the job."""
    with SessionLocal() as db:
        job = db.get(Job, job_id)
        if job is None or job.status != JobStatus.pending:
            return

        job.status = JobStatus.processing
        db.commit()

        try:
            if job.kind == "zip_folder":
                media_rows = (
                    db.execute(
                        select(Media)
                        .join(Folder, Media.folder_id == Folder.id)
                        .where(
                            Media.folder_id == job.target_id,
                            Folder.owner_id == owner_id,
                            Media.is_deleted == False,  # noqa: E712
                        )
                    )
                    .scalars()
                    .all()
                )
                target_name = (
                    db.execute(select(Folder.name).where(Folder.id == job.target_id)).scalar_one_or_none()
                    or "folder"
                )
            else:  # zip_album
                media_rows = (
                    db.execute(
                        select(Media)
                        .join(Album, Media.album_id == Album.id)
                        .where(
                            Media.album_id == job.target_id,
                            Album.owner_id == owner_id,
                            Media.is_deleted == False,  # noqa: E712
                        )
                    )
                    .scalars()
                    .all()
                )
                target_name = (
                    db.execute(select(Album.name).where(Album.id == job.target_id)).scalar_one_or_none()
                    or "album"
                )

            if not media_rows:
                job.status = JobStatus.failed
                job.error_message = "No media found to zip."
                db.commit()
                return

            total = len(media_rows)
            safe_name = "".join(c if c.isalnum() or c in "-_ " else "_" for c in target_name)
            zip_filename = f"{safe_name}_{job_id.hex[:8]}.zip"

            if _use_r2():
                # Build ZIP in a temp file, then upload to R2
                import tempfile
                with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
                    tmp_path = Path(tmp.name)

                _build_zip_local(tmp_path, media_rows, db, total, job, owner_id)

                s3 = _r2_client()
                r2_key = f"zip_jobs/{owner_id}/{zip_filename}"
                s3.upload_file(str(tmp_path), settings.R2_BUCKET_NAME, r2_key)
                tmp_path.unlink(missing_ok=True)

                # 24-hour presigned URL
                result_url = s3.generate_presigned_url(
                    "get_object",
                    Params={"Bucket": settings.R2_BUCKET_NAME, "Key": r2_key},
                    ExpiresIn=_JOB_EXPIRY_HOURS * 3600,
                )
            else:
                zip_dir = _storage_root() / _ZIP_DIR_NAME / str(owner_id)
                zip_dir.mkdir(parents=True, exist_ok=True)
                zip_path = zip_dir / zip_filename

                _build_zip_local(zip_path, media_rows, db, total, job, owner_id)

                # Local download URL
                result_url = (
                    f"{settings.app_public_url}{settings.MEDIA_URL_PREFIX}"
                    f"/{_ZIP_DIR_NAME}/{owner_id}/{zip_filename}"
                )

            job.status = JobStatus.completed
            job.result_url = result_url
            job.progress = 100
            job.completed_at = datetime.now(timezone.utc)
            job.expires_at = datetime.now(timezone.utc) + timedelta(hours=_JOB_EXPIRY_HOURS)
            
            db.add(Notification(
                user_id=owner_id,
                type=NotificationType.system,
                title="ZIP Download Ready",
                subtitle=f"Your ZIP for '{target_name}' is ready to download.",
                data={"job_id": str(job.id)}
            ))
            
            # Send push notification if enabled
            user = db.get(User, owner_id)
            if user:
                send_push_if_enabled(
                    user=user,
                    title="ZIP Download Ready",
                    body=f"Your ZIP for '{target_name}' is ready to download.",
                    data={"type": "zip_job", "job_id": str(job.id)}
                )
            
            db.commit()

        except Exception as exc:
            logger.exception("ZIP job %s failed", job_id)
            job.status = JobStatus.failed
            job.error_message = str(exc)[:500]
            
            db.add(Notification(
                user_id=owner_id,
                type=NotificationType.system,
                title="ZIP Download Failed",
                subtitle=f"Failed to create ZIP for '{target_name}'.",
                data={"job_id": str(job.id)}
            ))
            
            # Send push notification if enabled
            user = db.get(User, owner_id)
            if user:
                send_push_if_enabled(
                    user=user,
                    title="ZIP Download Failed",
                    body=f"Failed to create ZIP for '{target_name}'.",
                    data={"type": "zip_job", "job_id": str(job.id)}
                )
            
            db.commit()


def _build_zip_local(
    zip_path: Path,
    media_rows: list,
    db: Session,
    total: int,
    job: Job,
    owner_id: uuid.UUID,
) -> None:
    storage = _storage_root()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_STORED) as zf:
        for idx, media in enumerate(media_rows, 1):
            file_path = storage / media.file_path
            if file_path.exists():
                arcname = media.file_name or file_path.name
                zf.write(file_path, arcname=arcname)
            # Update progress every 10 files to avoid excessive DB writes
            if idx % 10 == 0 or idx == total:
                job.progress = int(idx / total * 95)
                db.commit()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post("", response_model=ZipJobRead, status_code=201)
def create_zip_job(
    req: ZipJobCreate,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
) -> ZipJobRead:
    """Queue a ZIP job. Returns immediately; poll GET /zip-jobs/{id} for status."""

    # Verify target ownership
    if req.kind == "zip_folder":
        target = db.get(Folder, req.target_id)
        if target is None or target.owner_id != current_user.id or getattr(target, "deleted_at", None) is not None:
            raise HTTPException(404, "Folder not found")
        if target.is_hidden:
            raise HTTPException(403, "Cannot ZIP a hidden folder")
    else:
        target = db.get(Album, req.target_id)
        if target is None or target.owner_id != current_user.id or getattr(target, "deleted_at", None) is not None:
            raise HTTPException(404, "Album not found")
        if not is_visible_to_client(db, album_id=target.id):
            # We still allow the owner to ZIP hidden albums – visibility guard
            # is for clients. Owner can always download their own content.
            pass

    # Enforce max-active-jobs limit
    active_count = db.execute(
        select(func.count()).where(
            and_(
                Job.owner_id == current_user.id,
                Job.status.in_([JobStatus.pending, JobStatus.processing]),
            )
        )
    ).scalar_one()
    if active_count >= _MAX_ACTIVE_JOBS:
        raise HTTPException(429, "You already have 2 active ZIP jobs. Wait for one to finish.")

    job = Job(
        owner_id=current_user.id,
        kind=req.kind,
        target_id=req.target_id,
        status=JobStatus.pending,
        progress=0,
    )
    db.add(job)
    db.commit()
    db.refresh(job)

    background_tasks.add_task(_build_zip, job.id, current_user.id)

    return ZipJobRead.from_model(job)


@router.get("", response_model=list[ZipJobRead])
def list_zip_jobs(
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
) -> list[ZipJobRead]:
    """Return the caller's 20 most-recent ZIP jobs."""
    jobs = (
        db.execute(
            select(Job)
            .where(Job.owner_id == current_user.id)
            .order_by(Job.created_at.desc())
            .limit(20)
        )
        .scalars()
        .all()
    )
    return [ZipJobRead.from_model(j) for j in jobs]


@router.get("/{job_id}", response_model=ZipJobRead)
def get_zip_job(
    job_id: uuid.UUID,
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
) -> ZipJobRead:
    """Poll a specific ZIP job."""
    job = db.get(Job, job_id)
    if job is None or job.owner_id != current_user.id or getattr(job, "deleted_at", None) is not None:
        raise HTTPException(404, "Job not found")
    return ZipJobRead.from_model(job)


@router.delete("/{job_id}")
def cancel_zip_job(
    job_id: uuid.UUID,
    current_user: User = Depends(require_active_plan),
    db: Session = Depends(get_db),
):
    """Cancel a pending job (no-op if already processing/done)."""
    from fastapi.responses import Response
    job = db.get(Job, job_id)
    if job is None or job.owner_id != current_user.id or getattr(job, "deleted_at", None) is not None:
        raise HTTPException(404, "Job not found")
    if job.status == JobStatus.pending:
        job.status = JobStatus.canceled
        db.commit()
    return Response(status_code=204)


# ---------------------------------------------------------------------------
# Lifecycle and Cleanup
# ---------------------------------------------------------------------------
import threading

def restart_interrupted_jobs() -> None:
    """Marks interrupted ZIP jobs as failed and restarts pending ones on startup."""
    with SessionLocal() as db:
        processing = db.execute(
            select(Job).where(Job.status == JobStatus.processing)
        ).scalars().all()
        for job in processing:
            job.status = JobStatus.failed
            job.error_message = "Server restarted before job completed."
        
        pending = db.execute(
            select(Job).where(Job.status == JobStatus.pending)
        ).scalars().all()
        
        db.commit()

        for job in pending:
            threading.Thread(target=_build_zip, args=(job.id, job.owner_id), daemon=True).start()
        
        if pending or processing:
            logger.info("Restarted %d pending zip jobs, marked %d processing zip jobs as failed.", len(pending), len(processing))

def run_zip_cleanup() -> int:
    """Deletes expired ZIP jobs and their local files. Returns number of jobs cleaned up."""
    cutoff = datetime.now(timezone.utc)
    deleted_count = 0
    with SessionLocal() as db:
        expired = db.execute(
            select(Job).where(
                and_(
                    Job.status == JobStatus.completed,
                    Job.expires_at <= cutoff
                )
            )
        ).scalars().all()
        
        for job in expired:
            try:
                if job.result_url:
                    if not _use_r2():
                        parts = job.result_url.split(f"/{_ZIP_DIR_NAME}/")
                        if len(parts) == 2:
                            rel_path = parts[1]
                            local_file = _storage_root() / _ZIP_DIR_NAME / rel_path
                            if local_file.exists():
                                local_file.unlink()
                    else:
                        # R2 lifecycle rules usually handle file deletion based on tags/prefix
                        pass
                
                db.delete(job)
                deleted_count += 1
            except Exception:
                logger.exception("Failed to clean up expired ZIP job %s", job.id)
                
        # Also clean up failed or canceled jobs older than 1 day
        old_failed = db.execute(
            select(Job).where(
                and_(
                    Job.status.in_([JobStatus.failed, JobStatus.canceled]),
                    Job.updated_at <= cutoff - timedelta(days=1)
                )
            )
        ).scalars().all()
        for job in old_failed:
            db.delete(job)
            deleted_count += 1
            
        if deleted_count > 0:
            db.commit()
            
    return deleted_count
