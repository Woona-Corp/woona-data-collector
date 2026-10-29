"""Coordinate bounded checksum-audit admission across API workers."""
from alembic import op

revision = '0009'
down_revision = '0008'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE IF NOT EXISTS integrity_check_budget (
        id smallint PRIMARY KEY CHECK (id = 1),
        next_allowed_at timestamptz NOT NULL
    )''')


def downgrade():
    op.execute('DROP TABLE IF EXISTS integrity_check_budget')
