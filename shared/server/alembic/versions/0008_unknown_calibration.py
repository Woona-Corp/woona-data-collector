"""Preserve missing source calibration as unknown instead of a measured zero."""
from alembic import op

revision = '0008'
down_revision = '0007'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('ALTER TABLE recording_sync ALTER COLUMN calibration_offset_ns DROP NOT NULL')


def downgrade():
    # Deliberately fail if unknown values exist rather than replacing them with false zeroes.
    op.execute('ALTER TABLE recording_sync ALTER COLUMN calibration_offset_ns SET NOT NULL')
