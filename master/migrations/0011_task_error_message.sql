ALTER TABLE tasks
    ADD COLUMN error_message TEXT CHECK (
        error_message IS NULL
        OR length(error_message) BETWEEN 1 AND 4096
    );
