import asyncio
import contextlib
import mimetypes
import re
from pathlib import Path
from typing import Iterator

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, StreamingResponse

from app.api.routes import api_router
from app.api.routes.zip_jobs import restart_interrupted_jobs
from app.core.auto_delete import auto_delete_loop
from app.core.config import settings



@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan — starts the auto-delete background scheduler on
    server boot and cancels it cleanly on shutdown."""
    await asyncio.to_thread(restart_interrupted_jobs)
    task = asyncio.create_task(auto_delete_loop(), name="auto_delete_scheduler")
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


app = FastAPI(title=settings.PROJECT_NAME, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global exception handler — ensures ALL unhandled exceptions return JSON
# instead of plain-text "Internal Server Error" (which confuses the JS client).
from fastapi import Request as _Request
from fastapi.responses import JSONResponse as _JSONResponse
import logging as _logging
_main_logger = _logging.getLogger("app.main")

@app.exception_handler(Exception)
async def _global_exception_handler(_req: _Request, exc: Exception) -> _JSONResponse:
    import traceback
    _main_logger.error(
        "Unhandled exception on %s %s: %s\n%s",
        _req.method, _req.url.path, exc, traceback.format_exc()
    )
    return _JSONResponse(
        status_code=500,
        content={"detail": "An internal server error occurred. Please try again."},
    )

app.include_router(api_router, prefix=settings.API_V1_PREFIX)

# Serve static assets (og-default.png, etc.) at /static/
_static_dir = Path(__file__).parent / "static"
_static_dir.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(_static_dir)), name="static")

# Serves every uploaded original/thumbnail under MEDIA_URL_PREFIX, e.g.
# a file saved at "<owner_id>/<media_id>/original.jpg" becomes reachable
# at f"{APP_PUBLIC_URL}{MEDIA_URL_PREFIX}/<owner_id>/<media_id>/original.jpg".
# See core/storage.py for the write side of this. Only needed for the
# "local" storage backend — when STORAGE_BACKEND="r2", files are served
# directly from R2_PUBLIC_URL instead, bypassing this process entirely.
if settings.STORAGE_BACKEND == "local":
    _media_root = Path(settings.MEDIA_STORAGE_DIR)
    _media_root.mkdir(parents=True, exist_ok=True)

    @app.api_route(
        f"{settings.MEDIA_URL_PREFIX}/{{file_path:path}}",
        methods=["GET", "HEAD"],
        include_in_schema=False,
    )
    async def serve_media_file(request: Request, file_path: str):
        """Serve media with HTTP ranges so large video players can stream."""
        root = _media_root.resolve()
        target = (root / file_path).resolve()
        if target != root and root not in target.parents:
            raise HTTPException(status_code=404, detail="Media file not found")
        if not target.is_file():
            raise HTTPException(status_code=404, detail="Media file not found")

        size = target.stat().st_size
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        range_header = request.headers.get("range")
        if not range_header:
            response = FileResponse(target, media_type=content_type)
            response.headers["Accept-Ranges"] = "bytes"
            response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
            response.headers["Pragma"] = "no-cache"
            return response

        match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
        if match is None:
            raise HTTPException(status_code=416, detail="Invalid byte range")

        start_text, end_text = match.groups()
        if not start_text and not end_text:
            raise HTTPException(status_code=416, detail="Invalid byte range")
        if start_text:
            start = int(start_text)
            end = int(end_text) if end_text else size - 1
        else:
            suffix_length = int(end_text)
            if suffix_length <= 0:
                raise HTTPException(status_code=416, detail="Invalid byte range")
            start = max(size - suffix_length, 0)
            end = size - 1

        if start >= size or start > end:
            raise HTTPException(status_code=416, detail="Range not satisfiable")
        end = min(end, size - 1)
        length = end - start + 1

        def iter_file() -> Iterator[bytes]:
            with target.open("rb") as media_file:
                media_file.seek(start)
                remaining = length
                while remaining:
                    chunk = media_file.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    yield chunk

        headers = {
            "Accept-Ranges": "bytes",
            "Content-Range": f"bytes {start}-{end}/{size}",
            "Content-Length": str(length),
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache",
        }
        if request.method == "HEAD":
            return StreamingResponse(
                content=iter(()),
                status_code=206,
                media_type=content_type,
                headers=headers,
            )
        return StreamingResponse(
            content=iter_file(),
            status_code=206,
            media_type=content_type,
            headers=headers,
        )

    app.mount(settings.MEDIA_URL_PREFIX, StaticFiles(directory=str(_media_root)), name="media")


@app.get("/health", tags=["health"])
def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/.well-known/assetlinks.json", include_in_schema=False)
def get_asset_links():
    """Serves the Android Digital Asset Links file for Android App Link verification.
    NOTE: For Play Store builds, add the Google Play App Signing SHA-256 fingerprint here
    and in web/.well-known/assetlinks.json. Get it from: Play Console -> Setup -> App integrity -> App signing.
    Without the correct Play signing cert, autoVerify will fail for release builds."""
    from fastapi.responses import JSONResponse

    return JSONResponse(
        content=[
            {
                "relation": ["delegate_permission/common.handle_all_urls"],
                "target": {
                    "namespace": "android_app",
                    "package_name": "com.mk.picgallery",
                    "sha256_cert_fingerprints": [
                        "B6:C8:1E:76:C4:04:9E:19:4D:7C:1D:88:D7:30:E0:D1:F5:3A:DA:BB:A7:12:FA:BC:3B:21:CB:CF:E2:59:72:7B",
                        "FA:C6:17:45:DC:09:03:78:6F:B9:ED:E6:2A:96:2B:39:9F:73:48:F0:BB:6F:89:9B:83:32:66:75:91:03:3B:9C",
                        "E7:A9:B2:91:6F:F9:70:70:DA:55:6E:81:61:90:72:7E:19:AF:CE:13:3B:A0:8F:72:55:77:89:C4:2F:2A:78:52",
                        "E7:C9:61:2B:CC:98:71:7F:96:54:71:93:A3:FC:91:65:27:24:AA:4C:D1:30:B3:2B:70:5E:A9:57:47:06:96:73"
                    ],
                },
            }
        ]
    )


from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session
from app.db.session import get_db
from app.models.gallery import ShareLink
from app.models.user import User
import logging as _og_logger
_og_log = _og_logger.getLogger("app.og_debug")

@app.get("/debug/og/{share_id}", include_in_schema=False)
def debug_og(share_id: str, db: Session = Depends(get_db)):
    """Temporary debug endpoint — shows what OG data would be injected for a share link."""
    from fastapi.responses import JSONResponse
    try:
        link = db.query(ShareLink).filter(ShareLink.token == share_id).first()
        if not link:
            return JSONResponse({"error": "share link not found", "token": share_id})
        owner = db.query(User).filter(User.id == link.owner_id).first()
        if not owner:
            return JSONResponse({"error": "owner not found", "owner_id": str(link.owner_id)})
        return JSONResponse({
            "token": share_id,
            "studio_name": owner.studio_name,
            "full_name": owner.full_name,
            "avatar_url": owner.avatar_url,
            "cover_image_url": owner.cover_image_url,
        })
    except Exception as e:
        return JSONResponse({"error": str(e)})

@app.get("/shared/{share_id}", include_in_schema=False)
@app.get("/gallery/{share_id}", include_in_schema=False)
def shared_web_fallback(share_id: str, db: Session = Depends(get_db)):
    
    # Defaults
    studio_name = "PicGallery"
    og_title = "PicGallery — Client Gallery"
    og_desc = "Shared via PicGallery • View, download & select your favourites"
    # Default OG image — shown when the studio hasn't uploaded a cover photo yet
    og_image = "https://api.picgallery.in/static/og-default.png"

    try:
        link = db.query(ShareLink).filter(ShareLink.token == share_id).first()
        if link:
            owner = db.query(User).filter(User.id == link.owner_id).first()
            if owner:
                studio_name = owner.studio_name or owner.full_name or "Studio"
                og_title = f"{studio_name} — Client Gallery"
                og_desc = f"Your photos from {studio_name} are ready. View, download & select your favourites."
                if owner.cover_image_url:
                    og_image = owner.cover_image_url
                elif owner.avatar_url:
                    og_image = owner.avatar_url
    except Exception:
        pass  # Silently fall back to defaults — never crash the page load
    
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{og_title}</title>
  <meta property="og:title" content="{og_title}">
  <meta property="og:description" content="{og_desc}">
  <meta property="og:image" content="{og_image}">
  <meta property="og:type" content="website">
  <meta property="twitter:card" content="summary_large_image">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0b0f19; color: #f8fafc; min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: flex-start; }}
    .header {{ width: 100%; max-width: 1200px; padding: 1.25rem 1.5rem; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #1e293b; background: #0f172a; position: sticky; top: 0; z-index: 50; }}
    .brand {{ display: flex; align-items: center; gap: 0.75rem; text-decoration: none; color: #fff; font-weight: 800; font-size: 1.25rem; }}
    .brand-icon {{ width: 36px; height: 36px; background: linear-gradient(135deg, #6366f1, #a855f7); border-radius: 10px; display: flex; align-items: center; justify-content: center; font-size: 1.2rem; }}
    .btn-app {{ background: rgba(99, 102, 241, 0.15); border: 1px solid rgba(99, 102, 241, 0.4); color: #818cf8; text-decoration: none; padding: 0.5rem 1rem; border-radius: 0.5rem; font-size: 0.85rem; font-weight: 700; transition: all 0.2s; }}
    .btn-app:hover {{ background: rgba(99, 102, 241, 0.25); color: #fff; }}

    .main-container {{ width: 100%; max-width: 1200px; padding: 2rem 1.5rem; flex: 1; display: flex; flex-direction: column; align-items: center; }}
    .card {{ background: #1e293b; border: 1px solid #334155; padding: 2.5rem 2rem; border-radius: 1.25rem; max-width: 440px; width: 100%; box-shadow: 0 20px 40px rgba(0,0,0,0.6); text-align: center; margin-top: 3rem; }}
    .card-icon {{ font-size: 3rem; margin-bottom: 1rem; display: block; }}
    .card h2 {{ font-size: 1.5rem; color: #fff; margin-bottom: 0.5rem; font-weight: 800; }}
    .card p {{ font-size: 0.9rem; color: #94a3b8; margin-bottom: 1.5rem; line-height: 1.5; }}
    
    .form-group {{ display: flex; flex-direction: column; gap: 0.75rem; width: 100%; text-align: left; }}
    .form-group label {{ font-size: 0.8rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: #94a3b8; }}
    .input-field {{ background: #0f172a; border: 1px solid #334155; color: #fff; padding: 0.8rem 1rem; border-radius: 0.5rem; font-size: 1rem; outline: none; width: 100%; transition: border-color 0.2s; }}
    .input-field:focus {{ border-color: #6366f1; }}
    .btn-submit {{ background: linear-gradient(135deg, #6366f1, #a855f7); color: #fff; border: none; padding: 0.85rem 1.5rem; border-radius: 0.5rem; font-size: 0.95rem; font-weight: 700; cursor: pointer; width: 100%; margin-top: 0.5rem; transition: opacity 0.2s; }}
    .btn-submit:hover {{ opacity: 0.9; }}
    .error-msg {{ color: #f87171; font-size: 0.85rem; font-weight: 600; margin-top: 0.5rem; display: none; }}

    .gallery-header {{ width: 100%; text-align: left; margin-bottom: 2rem; border-bottom: 1px solid #1e293b; padding-bottom: 1.5rem; }}
    .gallery-header h1 {{ font-size: 2rem; font-weight: 800; color: #fff; margin-bottom: 0.5rem; }}
    .gallery-header p {{ color: #94a3b8; font-size: 0.95rem; line-height: 1.5; }}
    .gallery-stats {{ margin-top: 0.75rem; font-size: 0.85rem; font-weight: 600; color: #818cf8; display: inline-block; background: rgba(99,102,241,0.12); padding: 0.3rem 0.75rem; border-radius: 1rem; }}

    .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 0.5rem; width: 100%; }}
    .grid-item {{ aspect-ratio: 1 / 1; border-radius: 0.5rem; overflow: hidden; background: #1e293b; position: relative; cursor: pointer; border: 1px solid #334155; transition: transform 0.2s, box-shadow 0.2s; }}
    .grid-item:hover {{ transform: translateY(-2px); box-shadow: 0 8px 16px rgba(0,0,0,0.5); }}
    .grid-item img {{ width: 100%; height: 100%; object-fit: cover; }}

    .lightbox {{ display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.92); z-index: 100; align-items: center; justify-content: center; flex-direction: column; padding: 1.5rem; }}
    .lightbox img {{ max-width: 90vw; max-height: 80vh; object-fit: contain; border-radius: 0.5rem; }}
    .lightbox-close {{ position: absolute; top: 1.5rem; right: 1.5rem; color: #fff; font-size: 2rem; cursor: pointer; border: none; background: none; }}
    .spinner {{ width: 40px; height: 40px; border: 4px solid rgba(255,255,255,0.1); border-left-color: #6366f1; border-radius: 50%; animation: spin 1s linear infinite; margin-top: 4rem; }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  </style>
</head>
<body>
  <header class="header">
    <a href="#" class="brand">
      <div class="brand-icon">📷</div>
      <span>PicGallery</span>
    </a>
    <!-- Button hidden by default, shown by JS only on mobile devices -->
    <a id="open-app-btn" href="intent://api.picgallery.in/gallery/{share_id}#Intent;scheme=https;package=com.mk.picgallery;end" class="btn-app" style="display:none;">Open in App</a>
  </header>

  <main class="main-container">
    <div id="loader" class="spinner"></div>

    <div id="card-view" class="card" style="display:none;">
      <span id="card-icon" class="card-icon">🔒</span>
      <h2 id="card-title">Private Gallery</h2>
      <p id="card-desc">Enter the passcode provided by the studio to view this gallery.</p>

      <form id="passcode-form" class="form-group" style="display:none;" onsubmit="handleUnlock(event)">
        <label for="passcode-input">Passcode</label>
        <input type="password" id="passcode-input" class="input-field" placeholder="Enter gallery passcode" required autocomplete="off" />
        <button type="submit" class="btn-submit">Unlock Gallery</button>
        <div id="error-msg" class="error-msg">Incorrect passcode. Please try again.</div>
      </form>
      
      <div id="face-search-prompt" style="display:none; flex-direction: column; gap: 0.75rem; width: 100%; margin-top: 1rem;">
        <input type="file" id="face-search-input-card" accept="image/*" style="display:none" onchange="runFaceSearch(event)" />
        <input type="file" id="face-search-camera-card" accept="image/*" capture="user" style="display:none" onchange="runFaceSearch(event)" />
        <button class="btn-submit" onclick="document.getElementById('face-search-input-card').click()">🖼️ Upload Selfie</button>
        <button class="btn-submit" onclick="document.getElementById('face-search-camera-card').click()" style="background: rgba(99,102,241,0.15); color: #818cf8; border: 1px solid rgba(99,102,241,0.4);">📷 Take Selfie</button>
        <div id="face-search-status-card" class="error-msg" style="color: #94a3b8; display: block; font-weight: normal; margin-top: 0.75rem;"></div>
      </div>
    </div>

    <div id="gallery-view" style="display:none; width: 100%;">
      <div class="gallery-header">
        <div id="gallery-header-top" style="display: flex; align-items: center; gap: 1rem; margin-bottom: 0.5rem;">
          <button id="back-btn" class="btn-app" style="display:none; cursor: pointer;">← Back</button>
          <h1 id="gallery-title" style="margin-bottom: 0;">Gallery</h1>
        </div>
        <p id="gallery-desc"></p>
        <div>
          <div id="gallery-count" class="gallery-stats">0 photos</div>
          <button id="download-all-btn" class="btn-app" style="display:none; margin-left: 0.5rem; cursor: pointer; padding: 0.3rem 0.75rem; font-size: 0.85rem;">📦 Download All</button>
        </div>
        <div id="face-search-container" style="display:none; margin-top: 1rem;">
          <input type="file" id="face-search-input" accept="image/*" style="display:none" onchange="runFaceSearch(event)" />
          <input type="file" id="face-search-camera" accept="image/*" capture="user" style="display:none" onchange="runFaceSearch(event)" />
          <button class="btn-app" style="cursor:pointer; margin-right: 0.5rem;" onclick="document.getElementById('face-search-input').click()">🖼️ Find My Photos</button>
          <button class="btn-app" style="cursor:pointer;" onclick="document.getElementById('face-search-camera').click()">📷 Take Selfie</button>
          <div id="face-search-status" style="font-size:0.85rem; color:#94a3b8; margin-top:0.75rem;"></div>
        </div>
      </div>
      <div id="photo-grid" class="grid"></div>
    </div>
  </main>

  <div id="lightbox" class="lightbox" onclick="closeLightbox(event)">
    <button class="lightbox-close" onclick="closeLightbox(event)">&times;</button>
    <img id="lightbox-img" src="" alt="Full preview" />
    <div id="lightbox-actions" style="position: absolute; bottom: 2rem; display: flex; gap: 1rem;">
      <a id="lightbox-download-btn" href="#" download class="btn-app" style="display:none; padding: 0.75rem 1.5rem; text-decoration: none;" onclick="event.stopPropagation()">⬇️ Download Photo</a>
    </div>
  </div>

  <script>
    const shareToken = "{share_id}";
    const apiBase = "/api/v1/public/galleries/";

    // Only show "Open in App" button on mobile devices
    const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
    if (isMobile) {{
      const appBtn = document.getElementById('open-app-btn');
      appBtn.style.display = 'inline-block';
      // For iOS, change the href to the custom scheme since intent:// is Android only
      if (/iPhone|iPad|iPod/i.test(navigator.userAgent)) {{
        appBtn.href = "picgallery://gallery/" + shareToken;
      }}
    }}

    async function loadGallery(password = "") {{
      const loader = document.getElementById("loader");
      const cardView = document.getElementById("card-view");
      const galleryView = document.getElementById("gallery-view");
      const errorMsg = document.getElementById("error-msg");

      loader.style.display = "block";
      cardView.style.display = "none";
      galleryView.style.display = "none";

      try {{
        let url = apiBase + shareToken;
        if (password) url += "?password=" + encodeURIComponent(password);
        
        const res = await fetch(url);
        const data = await res.json();

        loader.style.display = "none";

        if (res.status === 401) {{
          // Password required or invalid password
          cardView.style.display = "block";
          document.getElementById("passcode-form").style.display = "flex";
          if (password) {{
            errorMsg.style.display = "block";
            errorMsg.innerText = "Incorrect passcode. Please try again.";
          }}
          return;
        }}

        if (res.status === 410) {{
          cardView.style.display = "block";
          document.getElementById("card-icon").innerText = "⏳";
          document.getElementById("card-title").innerText = "Gallery Unavailable";
          document.getElementById("card-desc").innerText = data.detail || "This gallery link has expired or been revoked.";
          return;
        }}

        if (res.status === 404) {{
          cardView.style.display = "block";
          document.getElementById("card-icon").innerText = "🔍";
          document.getElementById("card-title").innerText = "Gallery Not Found";
          document.getElementById("card-desc").innerText = "This gallery link is invalid or no longer exists.";
          return;
        }}

        if (res.status === 403) {{
          cardView.style.display = "block";
          document.getElementById("card-icon").innerText = "📱";
          document.getElementById("card-title").innerText = "Private Client Album";
          
          if (isMobile) {{
            document.getElementById("card-desc").innerText = "This album is private and shared specifically with a client. Tap 'Open in App' above to view it in the PicGallery app.";
          }} else {{
            document.getElementById("card-desc").innerText = "This album is private and can only be viewed in the PicGallery mobile app. Please open this link on your phone.";
          }}
          return;
        }}

        if (!res.ok) {{
          cardView.style.display = "block";
          document.getElementById("card-title").innerText = "Error Loading Gallery";
          document.getElementById("card-desc").innerText = data.detail || "Could not load gallery. Please try again.";
          return;
        }}

        // Successfully loaded gallery!
        currentGalleryData = data;
        
        if (data.kind === 'face_search' && (!data.media || data.media.length === 0)) {{
           cardView.style.display = "block";
           document.getElementById("card-icon").innerText = "👤";
           document.getElementById("card-title").innerText = "Find My Photos";
           document.getElementById("card-desc").innerText = "This gallery uses face search. Upload a selfie to find all your photos.";
           document.getElementById("passcode-form").style.display = "none";
           document.getElementById("face-search-prompt").style.display = "flex";
        }} else {{
           renderGallery(data);
        }}

      }} catch (e) {{
        loader.style.display = "none";
        cardView.style.display = "block";
        document.getElementById("card-title").innerText = "Connection Error";
        document.getElementById("card-desc").innerText = "Failed to connect to the server. Check your connection.";
      }}
    }}

    function handleUnlock(e) {{
      e.preventDefault();
      const pwd = document.getElementById("passcode-input").value;
      if (pwd) loadGallery(pwd);
    }}

    let currentGalleryData = null;
    let isFolderRoot = false;

    async function loadAlbum(albumId, password = "") {{
      const loader = document.getElementById("loader");
      const galleryView = document.getElementById("gallery-view");
      const errorMsg = document.getElementById("error-msg");
      
      galleryView.style.display = "none";
      loader.style.display = "block";
      
      try {{
        let url = apiBase + shareToken + "/albums/" + albumId;
        if (password) url += "?password=" + encodeURIComponent(password);
        
        const res = await fetch(url);
        const data = await res.json();
        loader.style.display = "none";
        
        if (res.ok) {{
          renderGallery(data, true);
        }} else {{
          alert("Failed to load album.");
          galleryView.style.display = "block";
        }}
      }} catch (e) {{
        loader.style.display = "none";
        alert("Connection error.");
      }}
    }}

    function renderGallery(data, fromFolder = false) {{
      currentGalleryData = data;
      document.getElementById("gallery-view").style.display = "block";
      
      if (!fromFolder && data.albums && data.albums.length > 0) {{
         isFolderRoot = true;
      }}
      
      const backBtn = document.getElementById("back-btn");
      if (fromFolder && isFolderRoot) {{
        backBtn.style.display = "inline-block";
        backBtn.onclick = () => {{
           loadGallery(document.getElementById("passcode-input").value);
        }};
      }} else {{
        backBtn.style.display = "none";
      }}

      document.getElementById("gallery-title").innerText = data.album ? data.album.name : "Shared Gallery";
      document.getElementById("gallery-desc").innerText = data.album && data.album.description ? data.album.description : "";
      
      const mediaList = data.media || [];
      const albumList = data.albums || [];
      
      if (!fromFolder && albumList.length > 0) {{
         document.getElementById("gallery-count").innerText = albumList.length + " albums";
      }} else {{
         document.getElementById("gallery-count").innerText = mediaList.length + " photos";
      }}
      
      if (data.allow_download) {{
        document.getElementById("lightbox-download-btn").style.display = "block";
        document.getElementById("download-all-btn").style.display = "inline-block";
        document.getElementById("download-all-btn").onclick = () => {{
          let dlUrl = "/api/v1/public/share-links/" + shareToken + "/download-zip";
          const pwd = document.getElementById("passcode-input").value;
          if (pwd) dlUrl += "?password=" + encodeURIComponent(pwd);
          if (data.album) dlUrl += (dlUrl.includes("?") ? "&" : "?") + "album_id=" + data.album.id;
          window.location.href = dlUrl;
        }};
      }}
      
      document.getElementById("face-search-container").style.display = "block";

      const grid = document.getElementById("photo-grid");
      grid.innerHTML = "";

      if (!fromFolder && albumList.length > 0) {{
        albumList.forEach(a => {{
          const item = document.createElement("div");
          item.className = "grid-item";
          item.style.display = "flex";
          item.style.alignItems = "center";
          item.style.justifyContent = "center";
          item.style.flexDirection = "column";
          item.style.padding = "1rem";
          item.style.background = "linear-gradient(135deg, #1e293b, #0f172a)";
          item.innerHTML = `<span style="font-size: 2.5rem; margin-bottom: 0.5rem;">📁</span><span style="font-weight: 600; text-align: center; color: #f8fafc; font-size: 0.9rem;">${{a.name}}</span>`;
          item.onclick = () => loadAlbum(a.id, document.getElementById("passcode-input").value);
          grid.appendChild(item);
        }});
      }} else {{
        mediaList.forEach(m => {{
          const item = document.createElement("div");
          item.className = "grid-item";
          const imgUrl = m.thumbnail_url || m.file_url;
          item.innerHTML = `<img src="${{imgUrl}}" alt="${{m.file_name}}" loading="lazy" decoding="async" />`;
          item.onclick = () => openLightbox(m.file_url, m.id);
          grid.appendChild(item);
        }});
      }}
    }}

    function openLightbox(url, mediaId) {{
      document.getElementById("lightbox-img").src = url;
      const dlBtn = document.getElementById("lightbox-download-btn");
      dlBtn.href = url;
      dlBtn.onclick = (e) => {{
         e.stopPropagation();
         // Optionally hit the /download endpoint here to record it
         fetch("/api/v1/public/share-links/" + shareToken + "/download", {{
           method: "POST",
           headers: {{"Content-Type": "application/json"}},
           body: JSON.stringify({{media_id: mediaId, downloader_label: "Web Guest"}})
         }}).catch(err => console.error("Could not record download", err));
      }};
      document.getElementById("lightbox").style.display = "flex";
    }}

    function closeLightbox(e) {{
      if (e.target.id === "lightbox-img" || e.target.id === "lightbox-download-btn") return;
      document.getElementById("lightbox").style.display = "none";
    }}

    async function runFaceSearch(event) {{
      const file = event.target.files[0];
      if (!file) return;
      
      const statusDiv = document.getElementById("face-search-status");
      const statusCardDiv = document.getElementById("face-search-status-card");
      if (statusDiv) statusDiv.innerText = "Searching for your face... Please wait.";
      if (statusCardDiv) statusCardDiv.innerText = "Searching for your face... Please wait.";
      
      const formData = new FormData();
      formData.append("file", file);
      
      try {{
        let url = "/api/v1/public/share-links/" + shareToken + "/face-search";
        const pwd = document.getElementById("passcode-input").value;
        if (pwd) url += "?password=" + encodeURIComponent(pwd);
        
        const res = await fetch(url, {{
          method: "POST",
          body: formData
        }});
        
        // Safely parse JSON — if the server crashes it may return HTML
        let data = null;
        const contentType = res.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {{
          try {{
            data = await res.json();
          }} catch (parseErr) {{
            console.error("Failed to parse JSON:", parseErr);
          }}
        }} else {{
          // Server returned HTML (e.g. 500/502/504 gateway error)
          const text = await res.text();
          console.error("Non-JSON response:", res.status, text.substring(0, 200));
        }}
        
        if (!res.ok) {{
          let errMsg = "Face search failed (server error " + res.status + "). Please try again.";
          if (data && typeof data.detail === 'string') errMsg = data.detail;
          else if (data && Array.isArray(data.detail) && data.detail.length > 0 && data.detail[0].msg) errMsg = data.detail[0].msg;
          
          if (statusDiv) statusDiv.innerText = errMsg;
          if (statusCardDiv) statusCardDiv.innerText = errMsg;
          return;
        }}
        
        if (!data) {{
          if (statusDiv) statusDiv.innerText = "Unexpected server response. Please try again.";
          if (statusCardDiv) statusCardDiv.innerText = "Unexpected server response. Please try again.";
          return;
        }}
        
        if (data.matches && data.matches.length > 0) {{
           if (statusDiv) statusDiv.innerText = `Found ${{data.matches.length}} photo(s) with your face!`;
           if (statusCardDiv) statusCardDiv.innerText = "";
           
           // Hide card view if it was showing
           const cardView = document.getElementById("card-view");
           if (cardView) cardView.style.display = "none";
           
           // re-render the grid with just the matches
           if (!currentGalleryData) currentGalleryData = {{}};
           currentGalleryData.media = data.matches.map(m => m.media);
           
           // Ensure it shows photos, not albums
           currentGalleryData.albums = []; 
           
           renderGallery(currentGalleryData);
           
           // add a reset button
           const faceContainer = document.getElementById("face-search-container");
           if (faceContainer && !document.getElementById("reset-search-btn")) {{
             const resetBtn = document.createElement("button");
             resetBtn.id = "reset-search-btn";
             resetBtn.innerText = "✖ Clear Search";
             resetBtn.className = "btn-app";
             resetBtn.style.cursor = "pointer";
             resetBtn.style.marginLeft = "10px";
             resetBtn.onclick = () => {{ 
                resetBtn.remove(); 
                if (statusDiv) statusDiv.innerText = ""; 
                loadGallery(pwd); 
             }};
             faceContainer.appendChild(resetBtn);
           }}
        }} else {{
           if (statusDiv) statusDiv.innerText = "No matches found. Make sure you upload a clear, front-facing photo.";
           if (statusCardDiv) statusCardDiv.innerText = "No matches found. Try a clearer selfie.";
        }}
      }} catch (e) {{
        console.error("Face search error:", e);
        const msg = e.message || "Unknown error";
        if (statusDiv) statusDiv.innerText = "Error: " + msg;
        if (statusCardDiv) statusCardDiv.innerText = "Error: " + msg;
      }}
    }}

    // Initial load
    loadGallery();
  </script>
</body>
</html>"""
    response = HTMLResponse(content=html_content)
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response