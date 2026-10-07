"""m12_face_search_emails

Revision ID: c7998e7a6968
Revises: 105bd59d5486
Create Date: 2026-10-01 17:49:45.906141

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c7998e7a6968'
down_revision: Union[str, None] = '105bd59d5486'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'face_search_emails',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('share_link_id', sa.UUID(), nullable=False),
        sa.Column('email', sa.String(length=255), nullable=False),
        sa.Column('phone', sa.String(length=50), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['share_link_id'], ['share_links.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_face_search_emails_created_at'), 'face_search_emails', ['created_at'], unique=False)
    op.create_index(op.f('ix_face_search_emails_share_link_id'), 'face_search_emails', ['share_link_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_face_search_emails_share_link_id'), table_name='face_search_emails')
    op.drop_index(op.f('ix_face_search_emails_created_at'), table_name='face_search_emails')
    op.drop_table('face_search_emails')
