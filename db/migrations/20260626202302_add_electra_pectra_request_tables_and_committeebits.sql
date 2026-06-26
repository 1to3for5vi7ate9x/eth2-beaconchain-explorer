-- +goose Up
-- +goose StatementBegin
-- Electra/Pectra schema needed by the /slot and /validator pages (and parts of the API).
-- These objects belong to gobitfly's external "v2 data-platform" and are referenced by
-- handlers/slot.go, handlers/validator.go, handlers/api.go, db/db.go and exporter/queues.go,
-- but upstream ships no DDL for them. They are created EMPTY here (read-only in OSS code) so
-- the pages render; the Electra "request" sub-sections show empty until populated externally.
-- Also adds the Electra attestation committee_bits column read by handlers/slot.go (upstream
-- commit fdc622628) whose INSERT/migration were never shipped.

ALTER TABLE blocks_attestations ADD COLUMN IF NOT EXISTS committeebits bytea;

CREATE TABLE IF NOT EXISTS blocks_deposit_requests_v2 (
    id bigint,
    status text,
    pubkey bytea,
    withdrawal_credentials bytea,
    amount bigint,
    signature bytea,
    slot_processed bigint,
    index_processed bigint,
    block_processed_root bytea,
    slot_queued bigint,
    index_queued bigint
);

CREATE TABLE IF NOT EXISTS blocks_withdrawal_requests_v2 (
    status text,
    validator_pubkey bytea,
    amount bigint,
    slot_processed bigint,
    index_processed bigint,
    block_processed_root bytea
);

CREATE TABLE IF NOT EXISTS blocks_withdrawal_requests (
    block_slot bigint,
    block_root bytea,
    request_index bigint,
    source_address bytea
);

CREATE TABLE IF NOT EXISTS blocks_consolidation_requests_v2 (
    status text,
    source_pubkey bytea,
    target_pubkey bytea,
    amount_consolidated bigint,
    slot_processed bigint,
    index_processed bigint,
    block_processed_root bytea
);

CREATE TABLE IF NOT EXISTS blocks_switch_to_compounding_requests_v2 (
    status text,
    validator_pubkey bytea,
    slot_processed bigint,
    index_processed bigint,
    block_processed_root bytea
);

CREATE TABLE IF NOT EXISTS blocks_switch_to_compounding_requests (
    block_slot bigint,
    block_root bytea,
    request_index bigint,
    address bytea
);

CREATE TABLE IF NOT EXISTS blocks_exit_requests (
    status text,
    validator_pubkey bytea,
    slot_processed bigint,
    index_processed bigint,
    block_processed_root bytea,
    reject_reason text
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS blocks_deposit_requests_v2;
DROP TABLE IF EXISTS blocks_withdrawal_requests_v2;
DROP TABLE IF EXISTS blocks_withdrawal_requests;
DROP TABLE IF EXISTS blocks_consolidation_requests_v2;
DROP TABLE IF EXISTS blocks_switch_to_compounding_requests_v2;
DROP TABLE IF EXISTS blocks_switch_to_compounding_requests;
DROP TABLE IF EXISTS blocks_exit_requests;
ALTER TABLE blocks_attestations DROP COLUMN IF EXISTS committeebits;
-- +goose StatementEnd
