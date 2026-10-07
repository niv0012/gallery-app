"""Add deleted_at to folders and albums

Revision ID: 3aeb4c1f2fa9
Revises: 179dc5601926
Create Date: 2026-10-01 12:48:30.765563

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '3aeb4c1f2fa9'
down_revision: Union[str, None] = '179dc5601926'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('albums', sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('folders', sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('folders', 'deleted_at')
    op.drop_column('albums', 'deleted_at')
    # ### end Alembic commands ###
