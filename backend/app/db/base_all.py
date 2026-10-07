# Import all models here so Base.metadata is aware of them for Alembic
# autogenerate and for Base.metadata.create_all() during local dev.
from app.db.base import Base  # noqa: F401
from app.models.user import User  # noqa: F401
from app.models.gallery import (
    Album,
    DownloadEvent,
    Folder,
    Media,
    MediaComment,
    MediaLike,
    ShareLink,
)  # noqa: F401
from app.models.favorite import StudioFavorite  # noqa: F401
from app.models.album_share import AlbumClientShare  # noqa: F401
from app.models.notification import Notification  # noqa: F401
from app.models.connection import StudioClientConnection  # noqa: F401
from app.models.email_invitation import EmailInvitation  # noqa: F401
from app.models.chat import ChatThread, ChatMessage  # noqa: F401
from app.models.face import FaceEmbedding  # noqa: F401
from app.models.activity_log import ActivityLog  # noqa: F401
from app.models.studio_portfolio import StudioPortfolioImage  # noqa: F401
from app.models.studio_backup import StudioBackup  # noqa: F401
from app.models.job import Job  # noqa: F401