"""m5_backfill_share_link_albums

Revision ID: 2feb42b58f9a
Revises: 973c338a45bc
Create Date: 2026-10-01 14:11:21.015593

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '2feb42b58f9a'
down_revision: Union[str, None] = '973c338a45bc'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Migrate single-album share links
    op.execute(
        """
        INSERT INTO share_link_albums (id, share_link_id, album_id, display_order, created_at)
        SELECT gen_random_uuid(), sl.id, sl.album_id, 0, sl.created_at
        FROM share_links sl
        WHERE sl.album_id IS NOT NULL
        """
    )
    
    # Migrate collection-based share links
    op.execute(
        """
        INSERT INTO share_link_albums (id, share_link_id, album_id, display_order, created_at)
        SELECT gen_random_uuid(), sl.id, ci.album_id, ci.position, sl.created_at
        FROM share_links sl
        JOIN collection_items ci ON sl.collection_id = ci.collection_id
        WHERE sl.collection_id IS NOT NULL
        """
    )

def downgrade() -> None:
    # Reverse the data migration (though normally data migrations like this might just be left alone or we TRUNCATE if we want)
    pass
