from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Central app configuration, loaded from environment variables / .env."""

    model_config = SettingsConfigDict(env_file=str(__import__("pathlib").Path(__file__).parent.parent.parent / ".env"), env_file_encoding="utf-8", extra="ignore")

    # App
    PROJECT_NAME: str = "PicGallery API"
    API_V1_PREFIX: str = "/api/v1"
    ENVIRONMENT: str = "development"

    # Database
    POSTGRES_USER: str = "postgres"
    POSTGRES_PASSWORD: str = "postgres"
    POSTGRES_HOST: str = "localhost"
    POSTGRES_PORT: int = 5432
    POSTGRES_DB: str = "picgallery"

    # Auth
    SECRET_KEY: str = "change-this-secret-key-in-production"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 15  # Short-lived access token (15 minutes)
    REFRESH_TOKEN_EXPIRE_DAYS: int = 7     # Long-lived refresh token (7 days)

    # CORS
    CORS_ORIGINS: list[str] = ["*"]

    # Sign in with Google — the OAuth client ID(s) allowed as the `aud`
    # claim on a Google ID token. Google issues a different client ID
    # per platform (Android, iOS, Web), and the Flutter google_sign_in
    # plugin sends whichever one matches the platform it's running on,
    # so every client ID created in Google Cloud Console for this app
    # needs to be listed here.
    GOOGLE_CLIENT_IDS: list[str] = []

    # Sign in with Apple — the Services ID (web/Android via the
    # backend-mediated flow) and/or the app's Bundle ID (native iOS),
    # whichever appear as the `aud` claim on the identity token Apple
    # issues. Same reasoning as GOOGLE_CLIENT_IDS: list every one used.
    APPLE_CLIENT_IDS: list[str] = []

    # Email (SMTP) — used to actually deliver the verification link and
    # password-reset link. Leave SMTP_HOST empty to disable real sending
    # (the token is still generated/stored, it just won't be emailed —
    # useful for local dev without mail credentials).
    SMTP_HOST: str = ""
    SMTP_PORT: int = 587
    SMTP_USERNAME: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_USE_TLS: bool = True
    SMTP_FROM_EMAIL: str = ""
    SMTP_FROM_NAME: str = "PicGallery Support"

    # Gallery media storage — local disk backend (Task: Gallery Backend).
    # MEDIA_STORAGE_DIR is a path on the server's filesystem (relative
    # paths resolve against the backend's working directory); every
    # uploaded original/thumbnail lives under
    # <MEDIA_STORAGE_DIR>/<owner_id>/<media_id>/. MEDIA_URL_PREFIX is the
    # path main.py mounts that directory at via StaticFiles, so a stored
    # file becomes reachable at f"{APP_PUBLIC_URL}{MEDIA_URL_PREFIX}/<rel path>".
    # Kept behind this settings indirection (rather than hardcoded) so
    # swapping to S3/cloud storage later is a new StorageBackend
    # implementation, not a rewrite of every route that touches files.
    MEDIA_STORAGE_DIR: str = "media_storage"
    MEDIA_URL_PREFIX: str = "/media"
    # None = no per-file size limit (studio use — large RAW/video files are
    # expected). Set to an int (bytes) to re-enable a cap if ever needed.
    MAX_UPLOAD_SIZE_BYTES: int | None = None

    # "local" (default, unchanged behavior above) or "r2" — flip this
    # once R2_* below are filled in. This is the only switch storage.py
    # reads; every route/schema is untouched either way.
    STORAGE_BACKEND: str = "local"

    # --- Cloudflare R2 (S3-compatible object storage) ---
    # Only required when STORAGE_BACKEND="r2". R2_ENDPOINT_URL is
    # f"https://{account_id}.r2.cloudflarestorage.com". R2_PUBLIC_URL is
    # whatever serves the bucket publicly — either the bucket's r2.dev
    # URL or your own custom domain connected to it — no trailing slash;
    # build_media_url() does f"{R2_PUBLIC_URL}/{relative_path}".
    R2_ENDPOINT_URL: str = ""
    R2_ACCESS_KEY_ID: str = ""
    R2_SECRET_ACCESS_KEY: str = ""
    R2_BUCKET_NAME: str = ""
    R2_PUBLIC_URL: str = ""

    # Path/name of the ffmpeg binary used to grab a video's poster frame
    # for thumbnail generation (see storage.make_video_thumbnail). Only
    # needs changing if ffmpeg isn't on PATH under the name "ffmpeg".
    FFMPEG_BINARY: str = "ffmpeg"

    # Path/name of the ffprobe binary used to read a video's duration
    # at upload time (see storage.get_video_duration_ms). Ships
    # alongside ffmpeg in virtually every distribution, so this only
    # needs changing in the same situations FFMPEG_BINARY would.
    FFPROBE_BINARY: str = "ffprobe"

    # Share Links (Task 20) — SHARE_LINK_BASE_URL is where the *client
    # app* (not this API) resolves a shared-gallery link, e.g. a deep
    # link or a small web viewer. Kept separate from APP_PUBLIC_URL only
    # for the (uncommon) case where shared links are served from a
    # different host — leave unset to reuse APP_PUBLIC_URL, which is
    # what most setups want. A link's full shareable URL is
    # f"{SHARE_LINK_BASE_URL}{SHARE_LINK_PATH_PREFIX}/<token>".
    #
    # No hardcoded default (was a dev's home LAN IP, which only ever
    # worked on that one Wi-Fi network and silently broke for every
    # other device/network). See `Settings.share_link_base_url` below.
    SHARE_LINK_BASE_URL: str | None = None
    SHARE_LINK_PATH_PREFIX: str = "/gallery"

    # Base URL the backend itself is reachable at, used to build the
    # clickable verification link in the email (the Flutter app has no
    # deep-link handling yet, so the link opens a small HTML page served
    # directly by the backend instead of opening the app), and to build
    # every media file_url/thumbnail_url (see core/storage.py). Should
    # match the host/port your phone/emulator uses to reach this API —
    # e.g. ApiClient's baseUrl in api_client.dart, minus the /api/v1
    # suffix.
    #
    # Deliberately no default here (was hardcoded to a dev's home LAN IP
    # — see SHARE_LINK_BASE_URL above for why that's a problem). Must be
    # set explicitly in .env. See `Settings.app_public_url` below for the
    # error raised if this is used while unset.
    APP_PUBLIC_URL: str | None = None

    # --- Face Search ---
    # Cosine similarity (0-1) a candidate face embedding must reach
    # against the query selfie to count as a match. insightface's
    # buffalo_l embeddings are L2-normalized before comparison, so this
    # is a true cosine similarity, not a raw distance. 0.45 is a decent
    # starting point for buffalo_l; tune after testing with real photos
    # (higher = fewer false positives, lower = fewer missed matches).
    FACE_MATCH_THRESHOLD: float = 0.45
    # Detector input size — 640x640 balances accuracy vs. CPU time for
    # typical event/wedding photo resolutions. Raise if faces in your
    # photos tend to be small (large group shots).
    FACE_DETECTION_SIZE: int = 640

    # --- Auto-Delete Scheduler ---
    # When AUTO_DELETE_ENABLED is True, a background task running hourly
    # will permanently delete every Media row (and its files) whose
    # `created_at` is older than MEDIA_RETENTION_HOURS hours.
    #
    # For testing:    MEDIA_RETENTION_HOURS=1   (deletes after 1 hour)
    # For production: MEDIA_RETENTION_HOURS=8760 (deletes after 1 year)
    #
    # Set AUTO_DELETE_ENABLED=false to disable the scheduler entirely
    # without touching the retention setting (useful for maintenance /
    # bulk-import windows where you don't want freshly-uploaded files
    # swept up immediately).
    AUTO_DELETE_ENABLED: bool = True
    MEDIA_RETENTION_HOURS: int = 8760  # 8760 h = 365 days = 1 year

    @property
    def app_public_url(self) -> str:
        """[APP_PUBLIC_URL], but raises a clear, actionable error instead
        of silently building a broken URL (e.g. `"None/media/..."`) when
        it hasn't been configured — see the field's docstring above.
        """
        if not self.APP_PUBLIC_URL:
            raise RuntimeError(
                "APP_PUBLIC_URL is not set in backend/.env. A hardcoded LAN IP "
                "here only ever works from one Wi-Fi network, so this must be set "
                "explicitly: either a persistent tunnel URL (Cloudflare Tunnel / "
                "ngrok) so the app works from any network including mobile data, "
                "or a real domain in production."
            )
        return self.APP_PUBLIC_URL

    @property
    def share_link_base_url(self) -> str:
        """[SHARE_LINK_BASE_URL] if set, otherwise falls back to
        [app_public_url] (most setups serve both from the same
        tunnel/domain) — raising the same clear error as [app_public_url]
        if neither has been configured.
        """
        if self.SHARE_LINK_BASE_URL:
            return self.SHARE_LINK_BASE_URL
        return self.app_public_url

    @property
    def DATABASE_URL(self) -> str:
        # psycopg (v3) driver, used by SQLAlchemy's "postgresql+psycopg" dialect.
        #
        # NOTE: POSTGRES_USER/POSTGRES_PASSWORD in .env are expected to
        # already be percent-encoded if they contain URL-special
        # characters (this project's Supabase password intentionally
        # includes `%3F` for a literal `?`) — SQLAlchemy's create_engine()
        # decodes that automatically. Do NOT re-encode them here (e.g.
        # with quote_plus) — that double-encodes an already-encoded
        # value and silently sends the wrong password to Postgres.
        return (
            f"postgresql+psycopg://{self.POSTGRES_USER}:{self.POSTGRES_PASSWORD}"
            f"@{self.POSTGRES_HOST}:{self.POSTGRES_PORT}/{self.POSTGRES_DB}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()