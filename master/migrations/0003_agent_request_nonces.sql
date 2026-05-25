CREATE TABLE agent_request_nonces (
    node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    nonce TEXT NOT NULL CHECK (length(nonce) BETWEEN 16 AND 128),
    seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (node_id, nonce)
);

CREATE INDEX agent_request_nonces_seen_at_idx ON agent_request_nonces(seen_at);
