"""m11_share_link_pins

Revision ID: 105bd59d5486
Revises: 9d007f586068
Create Date: 2026-10-01 17:45:04.123300

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '105bd59d5486'
down_revision: Union[str, None] = '9d007f586068'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('share_links', sa.Column('pin_hash', sa.String(length=255), nullable=True))
    op.create_table(
        'share_link_pin_attempts',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('share_link_id', sa.UUID(), nullable=False),
        sa.Column('ip_hash', sa.String(length=64), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['share_link_id'], ['share_links.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_share_link_pin_attempts_created_at'), 'share_link_pin_attempts', ['created_at'], unique=False)
    op.create_index(op.f('ix_share_link_pin_attempts_ip_hash'), 'share_link_pin_attempts', ['ip_hash'], unique=False)
    op.create_index(op.f('ix_share_link_pin_attempts_share_link_id'), 'share_link_pin_attempts', ['share_link_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_share_link_pin_attempts_share_link_id'), table_name='share_link_pin_attempts')
    op.drop_index(op.f('ix_share_link_pin_attempts_ip_hash'), table_name='share_link_pin_attempts')
    op.drop_index(op.f('ix_share_link_pin_attempts_created_at'), table_name='share_link_pin_attempts')
    op.drop_table('share_link_pin_attempts')
    op.drop_column('share_links', 'pin_hash')
