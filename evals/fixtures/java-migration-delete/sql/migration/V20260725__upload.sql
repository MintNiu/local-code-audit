-- Versioned migration for existing databases.
ALTER TABLE sys_file ADD COLUMN upload_session_id VARCHAR(36);
