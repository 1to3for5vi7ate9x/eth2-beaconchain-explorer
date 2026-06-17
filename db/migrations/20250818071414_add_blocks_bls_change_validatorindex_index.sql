-- +goose NO TRANSACTION

-- +goose Up
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_blocks_bls_change_validatorindex ON blocks_bls_change (validatorindex);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX IF EXISTS idx_blocks_bls_change_validatorindex;
-- +goose StatementEnd
