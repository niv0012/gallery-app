import uuid

import sqlalchemy as sa
from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_studio_user
from app.core.face_index import extract_query_faces, reindex_owner_media, resolve_query_face, search_faces
from app.db.session import get_db
from app.models.face import FaceEmbedding
from app.models.gallery import Album, Folder, Media, MediaType
from app.models.user import User
from app.schemas.face import DetectedFaceRead, FaceBoxRead, FaceIndexStatusRead, FaceMatchRead, FaceSearchResponse
from app.schemas.gallery import MediaRead
from app.schemas.user import MessageResponse

router = APIRouter(prefix="/faces", tags=["face-search"])


def _to_detected_face_reads(faces) -> list[DetectedFaceRead]:
    return [
        DetectedFaceRead(face_index=i, box=FaceBoxRead(**face["box"]), confidence=face["confidence"])
        for i, face in enumerate(faces)
    ]


@router.post("/search", response_model=FaceSearchResponse)
async def search_by_face(
    file: UploadFile = File(...),
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    face_index: int | None = None,
    threshold: float | None = Query(default=None, ge=0.0, le=1.0),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FaceSearchResponse:
    """Uploads a selfie and returns every indexed photo in the studio's
    own library (optionally scoped to one album/folder) whose best
    face match clears `threshold` (defaults to
    `settings.FACE_MATCH_THRESHOLD`). If the selfie has more than one
    face, pass the `face_index` from a first call's `detected_faces`
    on a follow-up call to search using a specific one instead of the
    largest.
    """
    if album_id is not None:
        album = db.get(Album, album_id)
        if album is None or album.owner_id != current_user.id or getattr(album, "deleted_at", None) is not None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")
    if folder_id is not None:
        folder = db.get(Folder, folder_id)
        if folder is None or folder.owner_id != current_user.id or getattr(folder, "deleted_at", None) is not None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Folder not found")

    faces = await extract_query_faces(file)
    chosen_index, chosen_face = resolve_query_face(faces, face_index)

    matches = search_faces(
        db,
        query_embedding=chosen_face["embedding"],
        owner_id=current_user.id,
        album_id=album_id,
        folder_id=folder_id,
        threshold=threshold,
    )

    return FaceSearchResponse(
        detected_faces=_to_detected_face_reads(faces),
        searched_face_index=chosen_index,
        matches=[FaceMatchRead(media=MediaRead.from_model(m), similarity=round(s, 4)) for m, s in matches],
    )


@router.post("/reindex", status_code=status.HTTP_202_ACCEPTED, response_model=MessageResponse)
def reindex_faces(
    background_tasks: BackgroundTasks,
    album_id: uuid.UUID | None = None,
    force: bool = False,
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Backfills face embeddings for existing photos — run this once
    after deploying this feature (no `album_id` = your whole library),
    or with `force=true` any time you want to rebuild embeddings (e.g.
    after upgrading the detection model). Runs in the background;
    check progress via `GET /faces/status`.
    """
    if album_id is not None:
        album = db.get(Album, album_id)
        if album is None or album.owner_id != current_user.id or getattr(album, "deleted_at", None) is not None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Album not found")

    background_tasks.add_task(reindex_owner_media, current_user.id, album_id, force)
    return MessageResponse(message="Face indexing started in the background.")


@router.get("/status", response_model=FaceIndexStatusRead)
def face_index_status(
    album_id: uuid.UUID | None = None,
    album_ids: list[uuid.UUID] = Query(default=[]),
    current_user: User = Depends(get_current_studio_user),
    db: Session = Depends(get_db),
) -> FaceIndexStatusRead:
    photo_query = select(Media.id).where(
        Media.owner_id == current_user.id,
        Media.media_type == MediaType.photo,
        Media.is_deleted.is_(False),
    )
    if album_id is not None:
        photo_query = photo_query.where(Media.album_id == album_id)
    elif album_ids:
        photo_query = photo_query.where(Media.album_id.in_(album_ids))
    photo_ids = db.execute(photo_query).scalars().all()

    if not photo_ids:
        return FaceIndexStatusRead(total_photos=0, indexed_photos=0, total_faces=0)

    indexed_photos = db.execute(
        select(sa.func.count(sa.func.distinct(FaceEmbedding.media_id))).where(FaceEmbedding.media_id.in_(photo_ids))
    ).scalar_one()
    total_faces = db.execute(
        select(sa.func.count()).select_from(FaceEmbedding).where(FaceEmbedding.media_id.in_(photo_ids))
    ).scalar_one()

    return FaceIndexStatusRead(total_photos=len(photo_ids), indexed_photos=indexed_photos, total_faces=total_faces)
