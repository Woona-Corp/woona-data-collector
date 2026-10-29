-- Reconstructed minimal compatibility schema, NOT original release DDL.
-- Based on published onUpgrade/migrateV2ToV3 and the existing v2 fixture.
CREATE TABLE dog_profiles(id TEXT PRIMARY KEY,number_or_name TEXT NOT NULL,questionnaire_json TEXT NOT NULL,created_at_utc TEXT NOT NULL,updated_at_utc TEXT NOT NULL);
CREATE TABLE recordings(id TEXT PRIMARY KEY,profile_id TEXT NOT NULL REFERENCES dog_profiles(id),source TEXT NOT NULL,status TEXT NOT NULL,started_at_utc TEXT NOT NULL,ended_at_utc TEXT,timezone TEXT NOT NULL,questionnaire_json TEXT,relative_directory TEXT NOT NULL UNIQUE);
CREATE TABLE artifacts(id TEXT PRIMARY KEY,recording_id TEXT NOT NULL REFERENCES recordings(id),type TEXT NOT NULL,relative_path TEXT NOT NULL,size_bytes INTEGER NOT NULL,created_at_utc TEXT NOT NULL,UNIQUE(recording_id,relative_path));
PRAGMA user_version=2;
