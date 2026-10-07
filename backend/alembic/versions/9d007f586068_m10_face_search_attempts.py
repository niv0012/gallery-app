"""m10_face_search_attempts

Revision ID: 9d007f586068
Revises: 9dfed72502bb
Create Date: 2026-10-01 17:42:54.483357

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '9d007f586068'
down_revision: Union[str, None] = '7ff400b6cfe4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'face_search_attempts',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('share_link_id', sa.UUID(), nullable=False),
        sa.Column('ip_hash', sa.String(length=64), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['share_link_id'], ['share_links.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_face_search_attempts_created_at'), 'face_search_attempts', ['created_at'], unique=False)
    op.create_index(op.f('ix_face_search_attempts_ip_hash'), 'face_search_attempts', ['ip_hash'], unique=False)
    op.create_index(op.f('ix_face_search_attempts_share_link_id'), 'face_search_attempts', ['share_link_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_face_search_attempts_share_link_id'), table_name='face_search_attempts')
    op.drop_index(op.f('ix_face_search_attempts_ip_hash'), table_name='face_search_attempts')
    op.drop_index(op.f('ix_face_search_attempts_created_at'), table_name='face_search_attempts')
    op.drop_table('face_search_attempts')
