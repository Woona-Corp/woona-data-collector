# Android migration fixture provenance

Versions 5–8 contain the actual `onCreate` SQL from commits 73a0beb, 594d336,
d584261 and ccc97d3. These text fixtures are created on an empty database;
they are not current databases with a lower `user_version`.

The accessible repository starts at schema 5. Original release DDL/databases
for versions 1–4 are unavailable. Their fixtures are explicitly reconstructed
compatibility inputs from the published upgrade routines and existing v2 test:
versions 1/2 exercise legacy table rebuilding, while 3/4 exercise missing-sync
and canonical-hash repairs. They prove those migration branches and preservation
for these constructed inputs, not acceptance of every historical phone database.

All records, UUIDs, questionnaires and packet/video bytes in the matrix are
synthetic. Test assertions cover row identities, original files, nullable end
bounds, capture errors, sync integers, upload offsets, account ownership and
SQLite integrity/foreign keys before reopening the migrated database.
