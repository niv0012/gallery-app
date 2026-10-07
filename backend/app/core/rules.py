import uuid
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.models.gallery import Folder, ShareLink

def resolve_folder_rules(db: Session, folder_id: uuid.UUID | None) -> dict:
    """
    Walks up the folder tree from folder_id to the root to find the nearest
    explicit rule for `allow_download` and `show_watermark`. If none is found,
    the defaults are `allow_download = True` and `show_watermark = False`.
    """
    allow_download = None
    show_watermark = None

    if folder_id is not None:
        # Use a recursive CTE to walk up the tree and find the rules
        query = text("""
            WITH RECURSIVE folder_tree AS (
                SELECT id, parent_id, allow_download, show_watermark, 0 AS depth
                FROM folders
                WHERE id = :start_id

                UNION ALL

                SELECT f.id, f.parent_id, f.allow_download, f.show_watermark, ft.depth + 1
                FROM folders f
                JOIN folder_tree ft ON f.id = ft.parent_id
            )
            SELECT allow_download, show_watermark
            FROM folder_tree
            ORDER BY depth ASC
        """)
        result = db.execute(query, {"start_id": folder_id}).fetchall()
        for row in result:
            if allow_download is None and row.allow_download is not None:
                allow_download = row.allow_download
            if show_watermark is None and row.show_watermark is not None:
                show_watermark = row.show_watermark
            
            if allow_download is not None and show_watermark is not None:
                break

    return {
        "allow_download": allow_download if allow_download is not None else True,
        "show_watermark": show_watermark if show_watermark is not None else False,
    }


def resolve_folder_rules_with_source(db: Session, folder_id: uuid.UUID | None) -> dict:
    """
    Like resolve_folder_rules but also returns which ancestor folder contributed
    each rule value. Used by GET /folders/{id}/effective-rules to populate the
    "Inherited from X" label in the Flutter settings UI.

    Returns:
        allow_download          bool   – effective value
        show_watermark          bool   – effective value
        allow_download_source   dict | None  – {id, name} of the folder that set it, None if default
        show_watermark_source   dict | None  – {id, name} of the folder that set it, None if default
    """
    allow_download = None
    show_watermark = None
    allow_download_source = None
    show_watermark_source = None

    if folder_id is not None:
        query = text("""
            WITH RECURSIVE folder_tree AS (
                SELECT id, name, parent_id, allow_download, show_watermark, 0 AS depth
                FROM folders
                WHERE id = :start_id

                UNION ALL

                SELECT f.id, f.name, f.parent_id, f.allow_download, f.show_watermark, ft.depth + 1
                FROM folders f
                JOIN folder_tree ft ON f.id = ft.parent_id
            )
            SELECT id, name, allow_download, show_watermark, depth
            FROM folder_tree
            ORDER BY depth ASC
        """)
        result = db.execute(query, {"start_id": folder_id}).fetchall()
        for row in result:
            if allow_download is None and row.allow_download is not None:
                allow_download = row.allow_download
                if row.depth > 0:  # Only report as "inherited" if from an ancestor, not self
                    allow_download_source = {"id": str(row.id), "name": row.name}
            if show_watermark is None and row.show_watermark is not None:
                show_watermark = row.show_watermark
                if row.depth > 0:
                    show_watermark_source = {"id": str(row.id), "name": row.name}

            if allow_download is not None and show_watermark is not None:
                break

    return {
        "allow_download": allow_download if allow_download is not None else True,
        "show_watermark": show_watermark if show_watermark is not None else False,
        "allow_download_source": allow_download_source,
        "show_watermark_source": show_watermark_source,
    }


def get_effective_rules(db: Session, folder_id: uuid.UUID | None, link: ShareLink | None) -> dict:
    """
    Calculates the effective rules by combining the resolved folder rules and
    the share link rules (if any). The link can be stricter than the folder
    but not looser.
    """
    folder_rules = resolve_folder_rules(db, folder_id)

    if link:
        # A link's allow_download applies if it's False, or if it's True and the folder allows it.
        effective_allow = folder_rules["allow_download"] and link.allow_download
        # A link's show_watermark applies if it's True, or if it's False and the folder enforces it.
        effective_watermark = folder_rules["show_watermark"] or link.show_watermark
    else:
        effective_allow = folder_rules["allow_download"]
        effective_watermark = folder_rules["show_watermark"]

    return {
        "allow_download": effective_allow,
        "show_watermark": effective_watermark,
    }
