"""DB-touching face-indexing/search helpers, shared by the auto-index
hook in `media.py`, the manual reindex endpoint, and both the
studio-authenticated and public (share-link) search endpoints in
`app/api/routes/faces.py` / `share_links.py`.

Kept separate from `core/face_recognition.py` (which has no DB/ORM
knowledge at all — just raw image-in, embeddings-out) so the pure CPU
detection logic stays easy to test/reuse on its own.
"""

from __future__ import annotations

import logging
import shutil
import tempfile
import uuid
from pathlib import Path

import sqlalchemy as sa
from fastapi import HTTPException, UploadFile
from sqlalchemy import delete, select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from app.core.config import settings
from app.core.face_recognition import DetectedFace, extract_faces
from app.db.session import SessionLocal
from app.models.face import FaceEmbedding
from app.models.gallery import Album, Media, MediaType

logger = logging.getLogger("app.face_index")


def _absolute_path(relative_path: str) -> Path:
    return Path(settings.MEDIA_STORAGE_DIR) / relative_path


def largest_face_index(faces: list[DetectedFace]) -> int:
    """Picks the most prominent face in a selfie by bounding-box area —
    used as the default when the caller doesn't specify `face_index`,
    since the person taking the selfie is almost always the largest
    face in frame.
    """

    def area(face: DetectedFace) -> int:
        box = face["box"]
        return max(0, box["right"] - box["left"]) * max(0, box["bottom"] - box["top"])

    return max(range(len(faces)), key=lambda i: area(faces[i]))


async def extract_query_faces(file: UploadFile) -> list[DetectedFace]:
    """Streams an uploaded selfie to a throwaway temp file, detects
    every face in it off the request thread, and cleans up — used by
    both `/faces/search` and the public share-link face-search route.
    """
    with tempfile.TemporaryDirectory(prefix="face-search-") as tmp_dir:
        selfie_path = Path(tmp_dir) / (file.filename or "selfie.jpg")
        with selfie_path.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        return await run_in_threadpool(extract_faces, selfie_path)


def resolve_query_face(faces: list[DetectedFace], face_index: int | None) -> tuple[int, DetectedFace]:
    if not faces:
        raise HTTPException(422, "No face was detected in the uploaded photo. Try a clearer, front-facing selfie.")
    chosen = face_index if face_index is not None else largest_face_index(faces)
    if chosen < 0 or chosen >= len(faces):
        raise HTTPException(400, f"face_index out of range (selfie has {len(faces)} face(s)).")
    return chosen, faces[chosen]


def index_media(db: Session, media: Media) -> int:
    """(Re)builds the FaceEmbedding rows for one Media photo. Safe to
    call repeatedly — always clears any existing rows for this media
    first, so it never double-indexes the same photo.
    """
    if media.media_type != MediaType.photo:
        return 0
    path = _absolute_path(media.file_path)
    if not path.exists():
        logger.warning("Skipping face index for %s — file missing on disk (%s)", media.id, path)
        return 0

    faces = extract_faces(path)

    db.execute(delete(FaceEmbedding).where(FaceEmbedding.media_id == media.id))
    for face in faces:
        db.add(
            FaceEmbedding(
                media_id=media.id,
                owner_id=media.owner_id,
                embedding=face["embedding"],
                box=face["box"],
                detection_confidence=face["confidence"],
            )
        )
    db.commit()
    return len(faces)


def index_media_background(media_id: uuid.UUID) -> None:
    """Entry point for `BackgroundTasks.add_task` — opens its own DB
    session rather than reusing the request's, since the request
    session may already be closed by the time this actually runs.
    """
    db = SessionLocal()
    try:
        media = db.get(Media, media_id)
        if media is not None:
            index_media(db, media)
    except Exception:
        logger.exception("Background face indexing failed for media %s", media_id)
    finally:
        db.close()


def reindex_owner_media(owner_id: uuid.UUID, album_id: uuid.UUID | None, force: bool) -> None:
    """Backfills face embeddings for a studio's existing photos — for
    photos uploaded before this feature existed, or after a
    `force=True` re-run (e.g. after upgrading the detection model).
    """
    db = SessionLocal()
    try:
        query = select(Media).where(
            Media.owner_id == owner_id,
            Media.media_type == MediaType.photo,
            Media.is_deleted.is_(False),
        )
        if album_id is not None:
            query = query.where(Media.album_id == album_id)
        media_list = db.execute(query).scalars().all()

        for media in media_list:
            if not force:
                already_indexed = db.execute(
                    select(FaceEmbedding.id).where(FaceEmbedding.media_id == media.id).limit(1)
                ).first()
                if already_indexed is not None:
                    continue
            try:
                index_media(db, media)
            except Exception:
                logger.exception("Reindex failed for media %s", media.id)
    finally:
        db.close()


def search_faces(
    db: Session,
    *,
    query_embedding: list[float],
    owner_id: uuid.UUID,
    album_id: uuid.UUID | None = None,
    folder_id: uuid.UUID | None = None,
    threshold: float | None = None,
    limit: int = 200,
) -> list[tuple[Media, float]]:
    """Cosine-similarity search across one owner's indexed faces,
    scoped to an optional album/folder, deduplicated to the
    best-matching face per photo. Returns (Media, similarity) pairs
    sorted by similarity descending.
    """
    threshold = settings.FACE_MATCH_THRESHOLD if threshold is None else threshold
    max_distance = 1.0 - threshold

    distance_expr = FaceEmbedding.embedding.cosine_distance(query_embedding).label("distance")
    stmt = (
        select(Media, distance_expr)
        .join(FaceEmbedding, FaceEmbedding.media_id == Media.id)
        .where(FaceEmbedding.owner_id == owner_id, Media.is_deleted.is_(False))
        .where(
            sa.or_(
                Media.album_id.is_(None),
                Media.album_id.in_(select(Album.id).where(Album.deleted_at.is_(None))),
            )
        )
    )
    if album_id is not None:
        stmt = stmt.where(Media.album_id == album_id)
    if folder_id is not None:
        from sqlalchemy import text
        # Folder scope = the folder, every sub-folder (soft-deleted ones
        # excluded), AND every album that lives anywhere in that tree.
        # Photos inside an album carry album_id but usually NO folder_id
        # (the album — not the photo — belongs to the folder), so
        # matching on Media.folder_id alone silently skipped them.
        descendant_folders = db.execute(
            text("""
                WITH RECURSIVE folder_tree AS (
                    SELECT id FROM folders WHERE id = :root_id AND deleted_at IS NULL
                    UNION
                    SELECT f.id FROM folders f
                    INNER JOIN folder_tree ft ON f.parent_id = ft.id
                    WHERE f.deleted_at IS NULL
                )
                SELECT id FROM folder_tree
            """),
            {"root_id": folder_id}
        ).scalars().all()
        tree_album_ids = select(Album.id).where(
            Album.folder_id.in_(descendant_folders),
            Album.deleted_at.is_(None),
        )
        stmt = stmt.where(
            sa.or_(
                Media.folder_id.in_(descendant_folders),
                Media.album_id.in_(tree_album_ids),
            )
        )
    stmt = stmt.where(distance_expr <= max_distance).order_by(distance_expr).limit(limit)

    best: dict[uuid.UUID, tuple[Media, float]] = {}
    for media_row, distance in db.execute(stmt).all():
        similarity = 1.0 - float(distance)
        current_best = best.get(media_row.id)
        if current_best is None or similarity > current_best[1]:
            best[media_row.id] = (media_row, similarity)

    return sorted(best.values(), key=lambda pair: pair[1], reverse=True)


def search_client_faces(
    db: Session,
    *,
    query_embedding: list[float],
    authorized_album_ids: set[uuid.UUID] | None = None,
    authorized_folder_ids: set[uuid.UUID] | None = None,
    threshold: float | None = None,
    limit: int = 200,
) -> list[tuple[Media, float]]:
    """Cosine-similarity search across all faces in authorized albums and folders,
    deduplicated to the best-matching face per photo. Returns (Media, similarity)
    pairs sorted by similarity descending.
    """
    if not authorized_album_ids and not authorized_folder_ids:
        return []

    threshold = settings.FACE_MATCH_THRESHOLD if threshold is None else threshold
    max_distance = 1.0 - threshold

    distance_expr = FaceEmbedding.embedding.cosine_distance(query_embedding).label("distance")
    
    # Build the scope condition
    scope_conditions = []
    if authorized_album_ids:
        scope_conditions.append(Media.album_id.in_(authorized_album_ids))
    if authorized_folder_ids:
        scope_conditions.append(sa.and_(Media.folder_id.in_(authorized_folder_ids), Media.album_id.is_(None)))
        
    stmt = (
        select(Media, distance_expr)
        .join(FaceEmbedding, FaceEmbedding.media_id == Media.id)
        .where(
            sa.or_(*scope_conditions),
            Media.is_deleted.is_(False),
            distance_expr <= max_distance
        )
        .order_by(distance_expr)
        .limit(limit)
    )

    best: dict[uuid.UUID, tuple[Media, float]] = {}
    for media_row, distance in db.execute(stmt).all():
        similarity = 1.0 - float(distance)
        current_best = best.get(media_row.id)
        if current_best is None or similarity > current_best[1]:
            best[media_row.id] = (media_row, similarity)

    return sorted(best.values(), key=lambda pair: pair[1], reverse=True)
