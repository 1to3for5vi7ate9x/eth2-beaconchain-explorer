-- +goose NO TRANSACTION

-- +goose Up
SELECT 'creating idx_blocks_withdrawals_validatorindex_slot';
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_blocks_withdrawals_validatorindex_slot ON blocks_withdrawals (validatorindex, block_slot DESC);
-- +goose StatementEnd

-- +goose Down
SELECT 'dropping idx_blocks_withdrawals_validatorindex_slot';
-- +goose StatementBegin
DROP INDEX IF EXISTS idx_blocks_withdrawals_validatorindex_slot;
-- +goose StatementEnd
