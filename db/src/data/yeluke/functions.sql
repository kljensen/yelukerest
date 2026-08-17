-- The timestamp to stamp on a row that is being changed now.
--
-- Every table with an `updated_at` also carries
-- `CHECK (updated_at >= created_at)`, and the obvious implementation --
-- `NEW.updated_at = current_timestamp` -- can violate it. `current_timestamp`
-- is *transaction start*, not statement time. So a transaction that updates a
-- row created by a transaction which started later writes an `updated_at`
-- earlier than that row's `created_at`, and the CHECK rejects it:
--
--     ERROR: new row for relation "assignment_grade_exception" violates check
--            constraint "updated_after_created"
--     DETAIL: ... created_at 05:21:53.415842, updated_at 05:21:53.079110
--
-- Two concurrent writes to one row, where the second transaction opened first,
-- are enough. It surfaces as a 500 rather than as quiet corruption, but it is a
-- 500 a faculty member hits while granting an extension or importing grades.
--
-- `GREATEST` is used rather than `clock_timestamp()` on purpose. Both close the
-- hole, but `clock_timestamp()` advances during a transaction, so a fresh
-- insert would get `updated_at > created_at` and every row would look edited
-- the moment it was created. `GREATEST(current_timestamp, ...)` leaves the
-- ordinary case byte-identical to the old behaviour -- on insert both columns
-- are `current_timestamp`, so they stay equal -- and differs only in the
-- pathological case it exists to fix.
--
-- `prior_updated_at` exists because `updated_at` is not only a record of when a
-- row changed -- on `assignment_field_submission` it is also the optimistic
-- concurrency token. A client sends back the `updated_at` it last read, and the
-- trigger rejects the write if it no longer matches. A token that fails to
-- advance is therefore worse than a wrong timestamp: a client holding the
-- pre-update value would pass the staleness check and silently overwrite
-- somebody else's concurrent change.
--
-- Clamping alone can do exactly that. On insert `updated_at` equals
-- `created_at`, so an update that clamps back up to `created_at` returns the
-- value already stored and the token stands still. Passing the previous value
-- and stepping one microsecond past it -- the resolution of `timestamptz` --
-- guarantees a strict advance while keeping the result equal to
-- `current_timestamp` in the ordinary case, since that is already the greatest.
--
-- This also closes a smaller pre-existing hole: two updates inside one
-- transaction used to receive the same token, because `current_timestamp` does
-- not move within a transaction.
--
-- `GREATEST` ignores NULLs, so callers on INSERT simply omit the argument.
--
-- Takes its inputs rather than reading them, so it works for callers whose row
-- variable is not named `NEW`.
CREATE OR REPLACE FUNCTION touched_at(
    row_created_at TIMESTAMP WITH TIME ZONE,
    prior_updated_at TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TIMESTAMP WITH TIME ZONE AS $$
    SELECT GREATEST(
        current_timestamp,
        row_created_at,
        prior_updated_at + interval '1 microsecond'
    );
$$ LANGUAGE sql STABLE;

-- If there is an `updated_at` column on the model, set it to the
-- current timestamp with timezone. This is used so that we know
-- when a row was last changed.
--
-- Function taken from https://gist.github.com/logrusorgru/82b002b8807253b2adef
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
