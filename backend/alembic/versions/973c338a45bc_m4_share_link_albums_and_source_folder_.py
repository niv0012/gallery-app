"""M4 share_link_albums and source_folder_id auto_include_new

Revision ID: 973c338a45bc
Revises: 1390f65d278c
Create Date: 2026-10-01 13:56:26.039711

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = '973c338a45bc'
down_revision: Union[str, None] = '1390f65d278c'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ### M4: share_link_albums table + source_folder_id/auto_include_new on share_links ###
    op.create_table(
        'share_link_albums',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('share_link_id', sa.UUID(), nullable=False),
        sa.Column('album_id', sa.UUID(), nullable=False),
        sa.Column('display_order', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['album_id'], ['albums.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['share_link_id'], ['share_links.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('share_link_id', 'album_id', name='uq_share_link_albums_link_album'),
    )
    op.create_index(op.f('ix_share_link_albums_album_id'), 'share_link_albums', ['album_id'], unique=False)
    op.create_index(op.f('ix_share_link_albums_share_link_id'), 'share_link_albums', ['share_link_id'], unique=False)
    op.add_column('share_links', sa.Column('source_folder_id', sa.UUID(), nullable=True))
    op.add_column('share_links', sa.Column('auto_include_new', sa.Boolean(), nullable=False, server_default=sa.text('false')))
    op.create_index(op.f('ix_share_links_source_folder_id'), 'share_links', ['source_folder_id'], unique=False)
    op.create_foreign_key('fk_share_links_source_folder_id', 'share_links', 'folders', ['source_folder_id'], ['id'], ondelete='SET NULL')
    # ### end Alembic commands ###


def downgrade() -> None:
    # ### M4 rollback ###
    op.drop_constraint('fk_share_links_source_folder_id', 'share_links', type_='foreignkey')
    op.drop_index(op.f('ix_share_links_source_folder_id'), table_name='share_links')
    op.drop_column('share_links', 'auto_include_new')
    op.drop_column('share_links', 'source_folder_id')
    op.drop_index(op.f('ix_share_link_albums_share_link_id'), table_name='share_link_albums')
    op.drop_index(op.f('ix_share_link_albums_album_id'), table_name='share_link_albums')
    op.drop_table('share_link_albums')
    # ### end Alembic commands ###
