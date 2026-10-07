"""m1_media_indexes

Revision ID: b121d8387ad9
Revises: c7998e7a6968
Create Date: 2026-10-02 00:17:22.256002

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b121d8387ad9'
down_revision: Union[str, None] = 'c7998e7a6968'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index('ix_media_owner_album_del_created', 'media', ['owner_id', 'album_id', 'is_deleted', 'created_at'])
    op.create_index('ix_media_owner_folder_del_created', 'media', ['owner_id', 'folder_id', 'is_deleted', 'created_at'])

def downgrade() -> None:
    op.drop_index('ix_media_owner_folder_del_created', table_name='media')
    op.drop_index('ix_media_owner_album_del_created', table_name='media')
