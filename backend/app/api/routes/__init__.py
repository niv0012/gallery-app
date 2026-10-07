# pyrefly: ignore [missing-import]
from fastapi import APIRouter

from app.api.routes import (
    activity_log,
    admin_dashboard,
    albums,
    auth,
    chat,
    chunked_upload,
    client_faces,
    client_gallery,
    config,
    connections,
    download_history,
    faces,
    folders,
    legal,
    locations,
    media,
    notifications,
    search,
    share_links,
    studio_shares,
    studios,
    users,
    zip_jobs,
)

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(locations.router)
api_router.include_router(users.router)
api_router.include_router(folders.router)
api_router.include_router(albums.router)
api_router.include_router(media.router)
api_router.include_router(faces.router)
api_router.include_router(share_links.router)
api_router.include_router(share_links.public_router)
api_router.include_router(share_links.public_galleries_router)
api_router.include_router(download_history.router)
api_router.include_router(studios.router)
api_router.include_router(studio_shares.router)
api_router.include_router(client_gallery.router)
api_router.include_router(client_faces.router)
api_router.include_router(chat.router)
api_router.include_router(chunked_upload.router)
api_router.include_router(connections.router)
api_router.include_router(legal.router)
api_router.include_router(admin_dashboard.router)
api_router.include_router(search.router)
api_router.include_router(notifications.router)
api_router.include_router(activity_log.router)
api_router.include_router(config.router)
api_router.include_router(zip_jobs.router)