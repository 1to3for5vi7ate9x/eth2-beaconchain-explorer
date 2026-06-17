-- +goose NO TRANSACTION

-- +goose Up

-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_blocks_finalized ON blocks (finalized);
-- +goose StatementEnd

-- +goose Down

-- +goose StatementBegin
DROP INDEX IF EXISTS idx_blocks_finalized;
-- +goose StatementEnd
