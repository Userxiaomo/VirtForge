CREATE TABLE images (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 80),
    file_name TEXT NOT NULL UNIQUE CHECK (length(file_name) BETWEEN 1 AND 80),
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX images_enabled_idx ON images(enabled);
