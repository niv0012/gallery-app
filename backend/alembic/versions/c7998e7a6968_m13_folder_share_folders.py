"""m13_folder_share_folders

Revision ID: c7998e7a6968_m13
Revises: 105bd59d5486
Create Date: 2026-10-05 06:00:00.000000

Adds:
  - share_links.include_all          BOOLEAN NOT NULL DEFAULT false
  - share_links.include_folder_items BOOLEAN NOT NULL DEFAULT false
  - share_link_folders table (share_link_id, folder_id, created_at)
    with UNIQUE(share_link_id, folder_id) and ON DELETE CASCADE on both FKs.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c7998e7a6968_m13'
down_revision: Union[str, None] = '105bd59d5486'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # --- share_links: add two new boolean flags ---
    op.add_column('share_links', sa.Column('include_all', sa.Boolean(), nullable=False, server_default='false'))
    op.add_column('share_links', sa.Column('include_folder_items', sa.Boolean(), nullable=False, server_default='false'))

    # --- share_link_folders join table ---
    op.create_table(
        'share_link_folders',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('share_link_id', sa.UUID(), nullable=False),
        sa.Column('folder_id', sa.UUID(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['share_link_id'], ['share_links.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['folder_id'], ['folders.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('share_link_id', 'folder_id', name='uq_share_link_folders_link_folder'),
    )
    op.create_index(
        op.f('ix_share_link_folders_share_link_id'),
        'share_link_folders', ['share_link_id'], unique=False
    )
    op.create_index(
        op.f('ix_share_link_folders_folder_id'),
        'share_link_folders', ['folder_id'], unique=False
    )


def downgrade() -> None:
    op.drop_index(op.f('ix_share_link_folders_folder_id'), table_name='share_link_folders')
    op.drop_index(op.f('ix_share_link_folders_share_link_id'), table_name='share_link_folders')
    op.drop_table('share_link_folders')
    op.drop_column('share_links', 'include_folder_items')
    op.drop_column('share_links', 'include_all')
