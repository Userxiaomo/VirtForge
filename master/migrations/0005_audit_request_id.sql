ALTER TABLE audit_logs
ADD COLUMN request_id TEXT;

CREATE INDEX audit_logs_request_id_idx ON audit_logs(request_id);
