begin;
select plan(18);

SELECT view_owner_is(
    'api', 'artifacts', 'api',
    'api.artifacts view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'artifacts', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.artifacts"'
);

SELECT table_privs_are(
    'api', 'artifacts', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.artifacts"'
);

SELECT table_privs_are(
    'data', 'artifact', 'faculty', ARRAY[]::text[],
    'faculty should not be granted direct privileges on "data.artifact"'
);

SELECT col_not_null(
    'data', 'artifact', 'is_user_visible',
    'data.artifact.is_user_visible should be NOT NULL'
);

SELECT col_has_default(
    'data', 'artifact', 'is_user_visible',
    'data.artifact.is_user_visible should default to visible'
);

SELECT col_default_is(
    'data', 'artifact', 'is_user_visible', 'true',
    'data.artifact.is_user_visible should default to true'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.artifacts',
    ARRAY[0],
    'students should not be able to see artifacts for other students'
);

set request.jwt.claim.user_id = '1';
SELECT set_eq(
    'SELECT slug FROM api.artifacts ORDER BY slug',
    ARRAY['quiz-1-scan'],
    'students should be able to see their own visible artifacts only'
);

SELECT throws_like(
    $$
        INSERT INTO api.artifacts (user_id, slug, title, url) VALUES (1, 'student-created', 'Nope', 'https://example.com/nope.pdf')
    $$,
    '%permission denied%',
    'students should not be able to create artifacts'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.artifacts',
    ARRAY[3],
    'faculty should be able to see all artifacts'
);

SELECT set_eq(
    $$
        WITH inserted_rows AS (
            INSERT INTO api.artifacts (user_id, quiz_id, slug, title, url)
            VALUES (1, 1, 'faculty-created', 'Faculty Created', 'https://example.com/faculty-created.pdf')
            RETURNING id
        )
        SELECT COUNT(id) FROM inserted_rows
    $$,
    ARRAY[1],
    'faculty should be able to insert artifacts'
);

SELECT set_eq(
    $$
        WITH updated_rows AS (
            UPDATE api.artifacts
            SET title = 'Updated Quiz 1 scan'
            WHERE user_id = 1 AND slug = 'quiz-1-scan'
            RETURNING id
        )
        SELECT COUNT(id) FROM updated_rows
    $$,
    ARRAY[1],
    'faculty should be able to update artifacts'
);

SELECT set_eq(
    $$
        WITH deleted_rows AS (
            DELETE FROM api.artifacts
            WHERE user_id = 1 AND slug = 'faculty-created'
            RETURNING id
        )
        SELECT COUNT(id) FROM deleted_rows
    $$,
    ARRAY[1],
    'faculty should be able to delete artifacts'
);

SELECT throws_like(
    $$
        INSERT INTO api.artifacts (user_id, quiz_id, slug, title, url)
        VALUES (1, 1, 'bad-url', 'Bad URL', 'not-a-url')
    $$,
    '%violates check constraint "artifact_url_check"%',
    'artifact URLs should look like URLs'
);

SELECT throws_like(
    $$
        INSERT INTO api.artifacts (user_id, quiz_id, slug, title, url, content_length)
        VALUES (1, 1, 'bad-length', 'Bad Length', 'https://example.com/bad.pdf', -1)
    $$,
    '%violates check constraint "artifact_content_length_check"%',
    'artifact content length should be non-negative'
);

SELECT throws_like(
    $$
        INSERT INTO api.artifacts (user_id, quiz_id, slug, title, url, checksum_sha256)
        VALUES (1, 1, 'bad-checksum', 'Bad Checksum', 'https://example.com/bad.pdf', 'abc')
    $$,
    '%violates check constraint "artifact_checksum_sha256_check"%',
    'artifact checksums should be lowercase sha256 hex'
);

SELECT throws_like(
    $$
        INSERT INTO api.artifacts (user_id, quiz_id, slug, title, url, content_type)
        VALUES (1, 1, 'bad-content-type', 'Bad Content Type', 'https://example.com/bad.pdf', 'not-a-mime-type')
    $$,
    '%violates check constraint "artifact_content_type_check"%',
    'artifact content type should look like a MIME type'
);

select * from finish();
rollback;
