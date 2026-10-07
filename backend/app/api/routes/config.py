from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter(prefix="/config", tags=["config"])

class ConfigResponse(BaseModel):
    min_app_version: str
    flags: dict[str, bool]

@router.get("", response_model=ConfigResponse)
def get_config():
    """
    Returns global app configuration, including the minimum required app version
    and current feature flags for the v2.0 rollout phases.
    """
    return ConfigResponse(
        min_app_version="1.0.0+42",  # Will raise for v2.0 after release
        flags={
            "fast_media": True,
            "folder_explorer": True,
            "multi_album_links": True,
            "zip_jobs": True,
            "signed_originals": True,
            "face_links": False,
            "link_extras": True,
        }
    )
