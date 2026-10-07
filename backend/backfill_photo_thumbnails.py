import os
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from app.db.session import SessionLocal
from app.models.gallery import Media, MediaType
from app.core.storage import make_thumbnail
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("backfill")

def main():
    db = SessionLocal()
    try:
        photos = db.query(Media).filter(Media.media_type == MediaType.photo).all()
        logger.info(f"Found {len(photos)} photos to process.")
        
        for p in photos:
            if p.file_path:
                logger.info(f"Generating 1080px thumbnail for {p.id}")
                new_thumb = make_thumbnail(
                    owner_id=p.owner_id,
                    media_id=p.id,
                    original_relative_path=p.file_path
                )
                if new_thumb and new_thumb != p.thumbnail_path:
                    p.thumbnail_path = new_thumb
                    db.commit()
    except Exception as e:
        logger.error(f"Error: {e}")
    finally:
        db.close()

if __name__ == "__main__":
    main()
