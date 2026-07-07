\echo # filling table artifact
COPY data.artifact (id,user_id,quiz_id,slug,title,description,url,storage_uri,content_type,content_length,checksum_sha256,is_user_visible) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	1	quiz-1-scan	Quiz 1 scan	Scanned paper quiz for Alice	https://example.com/yelukerest/artifacts/quiz-1-alice.pdf	s3://yelukerest-example/quiz-1/alice.pdf	application/pdf	123456	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	TRUE
2	2	1	quiz-1-scan	Quiz 1 scan	Scanned paper quiz for Bob	https://example.com/yelukerest/artifacts/quiz-1-bob.pdf	s3://yelukerest-example/quiz-1/bob.pdf	application/pdf	234567	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	TRUE
3	1	1	hidden-quiz-1-feedback	Hidden Quiz 1 feedback	Faculty-only draft feedback	https://example.com/yelukerest/artifacts/quiz-1-alice-hidden.pdf	s3://yelukerest-example/quiz-1/alice-hidden.pdf	application/pdf	345678	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	FALSE
\.

-- restart sequences
ALTER SEQUENCE data.artifact_id_seq RESTART WITH 4;

-- analyze modified tables
ANALYZE data.artifact;
