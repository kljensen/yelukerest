# Student Artifacts

Yelukerest stores artifact metadata in PostgreSQL and keeps binary objects outside the database. A row in `api.artifacts` represents one student-visible file or link, such as a scanned paper quiz, graded PDF, or feedback packet.

The `url` column is the link shown to students. It should be durable for the period students need access. If storage uses private S3 objects and presigned URLs, either point `url` at a durable redirect service or refresh the row before the URL expires. The optional `storage_uri` column is for the durable object address, such as an S3 URI, and is not itself rendered by the Elm client.

Students and TAs can read only their own rows where `is_user_visible = true`. Faculty can create, inspect, update, and delete all artifact metadata through `api.artifacts`. Object storage permissions remain outside Yelukerest and must be configured so that artifact URLs do not expose other students' files.

Useful metadata:

- `quiz_id`: set this when the artifact belongs to a paper quiz and should appear in the quiz grade table.
- `content_type`: MIME type such as `application/pdf`.
- `content_length`: object size in bytes.
- `checksum_sha256`: lowercase SHA-256 hex digest for integrity checks.
