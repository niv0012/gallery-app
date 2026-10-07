from fastapi import APIRouter, Depends, File, Query, UploadFile
from sqlalchemy.orm import Session

from app.api.deps import get_current_client_user
from app.core.album_sharing import active_shares_for_client
from app.core.face_index import extract_query_faces, resolve_query_face, search_client_faces
from app.core.visibility import is_visible_to_client
from app.db.session import get_db
from app.models.user import User
from app.schemas.face import DetectedFaceRead, FaceBoxRead, FaceMatchRead, FaceSearchResponse
from app.schemas.gallery import MediaRead

router = APIRouter(prefix="/client/faces", tags=["client-face-search"])


def _to_detected_face_reads(faces) -> list[DetectedFaceRead]:
    return [
        DetectedFaceRead(face_index=i, box=FaceBoxRead(**face["box"]), confidence=face["confidence"])
        for i, face in enumerate(faces)
    ]


@router.post("/search", response_model=FaceSearchResponse)
async def search_by_face(
    file: UploadFile = File(...),
    face_index: int | None = None,
    threshold: float | None = Query(default=None, ge=0.0, le=1.0),
    current_user: User = Depends(get_current_client_user),
    db: Session = Depends(get_db),
) -> FaceSearchResponse:
    """Uploads a selfie and returns every indexed photo across all of
    the client's active shared albums whose best face match clears
    `threshold` (defaults to `settings.FACE_MATCH_THRESHOLD`). If the
    selfie has more than one face, pass the `face_index` from a first
    call's `detected_faces` on a follow-up call to search using a
    specific one instead of the largest.
    """
    shared_album_ids = {
        a_id for a_id in active_shares_for_client(db, client_id=current_user.id)
        if is_visible_to_client(db, album_id=a_id)
    }

    faces = await extract_query_faces(file)
    chosen_index, chosen_face = resolve_query_face(faces, face_index)

    matches = search_client_faces(
        db,
        query_embedding=chosen_face["embedding"],
        authorized_album_ids=shared_album_ids,
        threshold=threshold,
    )

    return FaceSearchResponse(
        detected_faces=_to_detected_face_reads(faces),
        searched_face_index=chosen_index,
        matches=[FaceMatchRead(media=MediaRead.from_model(m), similarity=round(s, 4)) for m, s in matches],
    )
