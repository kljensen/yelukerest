COMMENT ON VIEW artifacts IS
    'Student-visible files or links associated with a user and, optionally, a quiz';
COMMENT ON COLUMN artifacts.id IS 'Unique artifact id';
COMMENT ON COLUMN artifacts.user_id IS 'The user this artifact belongs to';
COMMENT ON COLUMN artifacts.quiz_id IS 'The quiz this artifact is associated with, if any';
COMMENT ON COLUMN artifacts.slug IS 'Stable short identifier for this artifact within the user account';
COMMENT ON COLUMN artifacts.title IS 'Human-readable title for this artifact';
COMMENT ON COLUMN artifacts.description IS 'Additional context shown with the artifact';
COMMENT ON COLUMN artifacts.url IS 'HTTP URL where the artifact can be viewed or downloaded';
COMMENT ON COLUMN artifacts.storage_uri IS 'Internal storage location for the artifact, if managed by Yelukerest';
COMMENT ON COLUMN artifacts.content_type IS 'Media type for the artifact content, if known';
COMMENT ON COLUMN artifacts.content_length IS 'Size of the artifact in bytes, if known';
COMMENT ON COLUMN artifacts.checksum_sha256 IS 'SHA-256 checksum for the artifact content, if known';
COMMENT ON COLUMN artifacts.is_user_visible IS 'Whether the artifact should be visible to the affected student';
COMMENT ON COLUMN artifacts.created_at IS 'When this artifact row was created';
COMMENT ON COLUMN artifacts.updated_at IS 'When this artifact row was last updated';

COMMENT ON VIEW assignments IS
    'Assignments that students can view or submit, with draft rows reserved for faculty';
COMMENT ON COLUMN assignments.slug IS 'Short identifier for the assignment';
COMMENT ON COLUMN assignments.points_possible IS 'Maximum score for the assignment';
COMMENT ON COLUMN assignments.is_draft IS 'Whether the assignment is still hidden from students and TAs';
COMMENT ON COLUMN assignments.is_markdown IS 'Whether the assignment body should be rendered as Markdown';
COMMENT ON COLUMN assignments.is_team IS 'Whether submissions are made by teams instead of individuals';
COMMENT ON COLUMN assignments.title IS 'Human-readable assignment title';
COMMENT ON COLUMN assignments.body IS 'Assignment instructions or content';
COMMENT ON COLUMN assignments.closed_at IS 'Deadline after which normal submissions are closed';
COMMENT ON COLUMN assignments.created_at IS 'When this assignment row was created';
COMMENT ON COLUMN assignments.updated_at IS 'When this assignment row was last updated';
COMMENT ON COLUMN assignments.is_open IS 'Whether the assignment is published and still open for normal submission';

COMMENT ON VIEW assignment_fields IS
    'Input fields students fill out when submitting an assignment';
COMMENT ON COLUMN assignment_fields.slug IS 'Short identifier for the field within an assignment';
COMMENT ON COLUMN assignment_fields.assignment_slug IS 'Assignment this field belongs to';
COMMENT ON COLUMN assignment_fields.label IS 'Short label displayed for the field';
COMMENT ON COLUMN assignment_fields.help IS 'Help text displayed with the field';
COMMENT ON COLUMN assignment_fields.placeholder IS 'Placeholder text displayed before a value is entered';
COMMENT ON COLUMN assignment_fields.is_url IS 'Whether submitted values must look like URLs';
COMMENT ON COLUMN assignment_fields.is_multiline IS 'Whether the field accepts multiline text';
COMMENT ON COLUMN assignment_fields.display_order IS 'Ordering hint for displaying fields within an assignment';
COMMENT ON COLUMN assignment_fields.pattern IS 'Validation pattern submitted values must match';
COMMENT ON COLUMN assignment_fields.example IS 'Example value that satisfies the validation pattern';
COMMENT ON COLUMN assignment_fields.created_at IS 'When this assignment field row was created';
COMMENT ON COLUMN assignment_fields.updated_at IS 'When this assignment field row was last updated';

COMMENT ON VIEW assignment_submissions IS
    'Submitted assignment attempts by individual students or teams';
COMMENT ON COLUMN assignment_submissions.id IS 'Unique assignment submission id';
COMMENT ON COLUMN assignment_submissions.assignment_slug IS 'Assignment this submission answers';
COMMENT ON COLUMN assignment_submissions.is_team IS 'Whether this submission belongs to a team';
COMMENT ON COLUMN assignment_submissions.user_id IS 'Student who owns an individual submission';
COMMENT ON COLUMN assignment_submissions.team_nickname IS 'Team that owns a team submission';
COMMENT ON COLUMN assignment_submissions.submitter_user_id IS 'User who created the submission';
COMMENT ON COLUMN assignment_submissions.created_at IS 'When this submission row was created';
COMMENT ON COLUMN assignment_submissions.updated_at IS 'When this submission row was last updated';

COMMENT ON VIEW assignment_field_submissions IS
    'Values submitted for individual assignment fields';
COMMENT ON COLUMN assignment_field_submissions.assignment_submission_id IS 'Submission this field value belongs to';
COMMENT ON COLUMN assignment_field_submissions.assignment_field_slug IS 'Assignment field this value answers';
COMMENT ON COLUMN assignment_field_submissions.assignment_slug IS 'Assignment this field value belongs to';
COMMENT ON COLUMN assignment_field_submissions.assignment_field_is_url IS 'Copied URL-validation setting for the field';
COMMENT ON COLUMN assignment_field_submissions.assignment_field_pattern IS 'Copied validation pattern for the field';
COMMENT ON COLUMN assignment_field_submissions.body IS 'Submitted field value';
COMMENT ON COLUMN assignment_field_submissions.submitter_user_id IS 'User who submitted this field value';
COMMENT ON COLUMN assignment_field_submissions.created_at IS 'When this field submission row was created';
COMMENT ON COLUMN assignment_field_submissions.updated_at IS 'When this field submission row was last updated';

COMMENT ON VIEW assignment_grades IS
    'Grades assigned to submitted assignments';
COMMENT ON COLUMN assignment_grades.assignment_slug IS 'Assignment this grade belongs to';
COMMENT ON COLUMN assignment_grades.points_possible IS 'Maximum score for the assignment';
COMMENT ON COLUMN assignment_grades.assignment_submission_id IS 'Submission this grade evaluates';
COMMENT ON COLUMN assignment_grades.points IS 'Points awarded for the submission';
COMMENT ON COLUMN assignment_grades.description IS 'Optional grading note or explanation';
COMMENT ON COLUMN assignment_grades.created_at IS 'When this grade row was created';
COMMENT ON COLUMN assignment_grades.updated_at IS 'When this grade row was last updated';

COMMENT ON VIEW assignment_grade_exceptions IS
    'Per-user or per-team assignment deadline and credit exceptions';
COMMENT ON COLUMN assignment_grade_exceptions.id IS 'Unique assignment grade exception id';
COMMENT ON COLUMN assignment_grade_exceptions.assignment_slug IS 'Assignment this exception applies to';
COMMENT ON COLUMN assignment_grade_exceptions.is_team IS 'Whether this exception applies to a team';
COMMENT ON COLUMN assignment_grade_exceptions.user_id IS 'Student this individual exception applies to';
COMMENT ON COLUMN assignment_grade_exceptions.team_nickname IS 'Team this team exception applies to';
COMMENT ON COLUMN assignment_grade_exceptions.fractional_credit IS 'Fraction of normal credit available under this exception';
COMMENT ON COLUMN assignment_grade_exceptions.closed_at IS 'Exception-specific deadline';
COMMENT ON COLUMN assignment_grade_exceptions.created_at IS 'When this exception row was created';
COMMENT ON COLUMN assignment_grade_exceptions.updated_at IS 'When this exception row was last updated';

COMMENT ON VIEW engagements IS
    'Attendance and participation records for users at class meetings';
COMMENT ON COLUMN engagements.user_id IS 'User whose participation is recorded';
COMMENT ON COLUMN engagements.meeting_slug IS 'Meeting this engagement record belongs to';
COMMENT ON COLUMN engagements.participation IS 'Recorded participation status';
COMMENT ON COLUMN engagements.created_at IS 'When this engagement row was created';
COMMENT ON COLUMN engagements.updated_at IS 'When this engagement row was last updated';

COMMENT ON VIEW grades IS
    'Per-student grade values within named grade snapshots';
COMMENT ON COLUMN grades.points IS 'Grade points recorded in the snapshot';
COMMENT ON COLUMN grades.snapshot_slug IS 'Grade snapshot this row belongs to';
COMMENT ON COLUMN grades.user_id IS 'User whose snapshot grade is recorded';
COMMENT ON COLUMN grades.description IS 'Optional note explaining the snapshot grade';
COMMENT ON COLUMN grades.created_at IS 'When this grade snapshot row was created';
COMMENT ON COLUMN grades.updated_at IS 'When this grade snapshot row was last updated';

COMMENT ON VIEW quizzes IS
    'Paper quiz metadata and availability windows';
COMMENT ON COLUMN quizzes.id IS 'Unique quiz id';
COMMENT ON COLUMN quizzes.meeting_slug IS 'Meeting associated with the quiz';
COMMENT ON COLUMN quizzes.points_possible IS 'Maximum score for the quiz';
COMMENT ON COLUMN quizzes.is_offline IS 'Whether the quiz is administered outside the online app';
COMMENT ON COLUMN quizzes.is_draft IS 'Whether the quiz is still hidden from students and TAs';
COMMENT ON COLUMN quizzes.duration IS 'Nominal time available to complete the quiz';
COMMENT ON COLUMN quizzes.open_at IS 'When the quiz becomes available';
COMMENT ON COLUMN quizzes.closed_at IS 'When the quiz closes';
COMMENT ON COLUMN quizzes.created_at IS 'When this quiz row was created';
COMMENT ON COLUMN quizzes.updated_at IS 'When this quiz row was last updated';
COMMENT ON COLUMN quizzes.is_open IS 'Whether the quiz is published and currently open';

COMMENT ON VIEW quiz_submissions IS
    'Student records indicating a quiz submission exists';
COMMENT ON COLUMN quiz_submissions.quiz_id IS 'Quiz this submission belongs to';
COMMENT ON COLUMN quiz_submissions.user_id IS 'Student who submitted the quiz';
COMMENT ON COLUMN quiz_submissions.created_at IS 'When this quiz submission row was created';
COMMENT ON COLUMN quiz_submissions.updated_at IS 'When this quiz submission row was last updated';

COMMENT ON VIEW quiz_grades IS
    'Grades assigned to quizzes';
COMMENT ON COLUMN quiz_grades.quiz_id IS 'Quiz this grade belongs to';
COMMENT ON COLUMN quiz_grades.points IS 'Points awarded for the quiz';
COMMENT ON COLUMN quiz_grades.points_possible IS 'Maximum score for the quiz';
COMMENT ON COLUMN quiz_grades.description IS 'Optional grading note or explanation';
COMMENT ON COLUMN quiz_grades.user_id IS 'Student whose quiz grade is recorded';
COMMENT ON COLUMN quiz_grades.created_at IS 'When this quiz grade row was created';
COMMENT ON COLUMN quiz_grades.updated_at IS 'When this quiz grade row was last updated';

COMMENT ON VIEW quiz_grade_exceptions IS
    'Per-user quiz deadline and credit exceptions';
COMMENT ON COLUMN quiz_grade_exceptions.id IS 'Unique quiz grade exception id';
COMMENT ON COLUMN quiz_grade_exceptions.quiz_id IS 'Quiz this exception applies to';
COMMENT ON COLUMN quiz_grade_exceptions.user_id IS 'Student this exception applies to';
COMMENT ON COLUMN quiz_grade_exceptions.fractional_credit IS 'Fraction of normal credit available under this exception';
COMMENT ON COLUMN quiz_grade_exceptions.closed_at IS 'Exception-specific quiz deadline';
COMMENT ON COLUMN quiz_grade_exceptions.created_at IS 'When this quiz grade exception row was created';
COMMENT ON COLUMN quiz_grade_exceptions.updated_at IS 'When this quiz grade exception row was last updated';

COMMENT ON VIEW teams IS
    'Student teams used for team assignments';
COMMENT ON COLUMN teams.nickname IS 'Unique team nickname';
COMMENT ON COLUMN teams.created_at IS 'When this team row was created';
COMMENT ON COLUMN teams.updated_at IS 'When this team row was last updated';

COMMENT ON VIEW ui_elements IS
    'Editable pieces of user-interface copy exposed through the API';
COMMENT ON COLUMN ui_elements.key IS 'Unique key for the UI element';
COMMENT ON COLUMN ui_elements.body IS 'Body text for the UI element';
COMMENT ON COLUMN ui_elements.is_markdown IS 'Whether the body should be rendered as Markdown';
COMMENT ON COLUMN ui_elements.created_at IS 'When this UI element row was created';
COMMENT ON COLUMN ui_elements.updated_at IS 'When this UI element row was last updated';

COMMENT ON VIEW users IS
    'Course users and their public course metadata';
COMMENT ON COLUMN users.id IS 'Unique user id';
COMMENT ON COLUMN users.email IS 'User email address';
COMMENT ON COLUMN users.netid IS 'University netid for the user';
COMMENT ON COLUMN users.name IS 'Given name for the user';
COMMENT ON COLUMN users.lastname IS 'Family name for the user';
COMMENT ON COLUMN users.organization IS 'Organization or school associated with the user';
COMMENT ON COLUMN users.known_as IS 'Preferred display name for the user';
COMMENT ON COLUMN users.nickname IS 'Pseudonymous nickname used in class-facing displays';
COMMENT ON COLUMN users.role IS 'Course role assigned to the user';
COMMENT ON COLUMN users.created_at IS 'When this user row was created';
COMMENT ON COLUMN users.updated_at IS 'When this user row was last updated';
COMMENT ON COLUMN users.team_nickname IS 'Team nickname assigned to the user, if any';

COMMENT ON VIEW user_secrets IS
    'Per-user or per-team secret values managed by course staff';
COMMENT ON COLUMN user_secrets.id IS 'Unique user secret id';
COMMENT ON COLUMN user_secrets.slug IS 'Stable short identifier for the secret';
COMMENT ON COLUMN user_secrets.body IS 'Secret value';
COMMENT ON COLUMN user_secrets.is_user_visible IS 'Whether the affected student may read the secret value';
COMMENT ON COLUMN user_secrets.user_id IS 'User this secret belongs to';
COMMENT ON COLUMN user_secrets.team_nickname IS 'Team this secret belongs to';
COMMENT ON COLUMN user_secrets.created_at IS 'When this user secret row was created';
COMMENT ON COLUMN user_secrets.updated_at IS 'When this user secret row was last updated';

COMMENT ON VIEW user_jwts IS
    'JWT helper view for authenticated users and auth application flows';
COMMENT ON COLUMN user_jwts.jwt IS 'Signed JWT for the row user when the requester is allowed to receive it';
COMMENT ON COLUMN user_jwts.id IS 'Unique user id';
COMMENT ON COLUMN user_jwts.email IS 'User email address';
COMMENT ON COLUMN user_jwts.netid IS 'University netid for the user';
COMMENT ON COLUMN user_jwts.name IS 'Given name for the user';
COMMENT ON COLUMN user_jwts.lastname IS 'Family name for the user';
COMMENT ON COLUMN user_jwts.organization IS 'Organization or school associated with the user';
COMMENT ON COLUMN user_jwts.known_as IS 'Preferred display name for the user';
COMMENT ON COLUMN user_jwts.nickname IS 'Pseudonymous nickname used in class-facing displays';
COMMENT ON COLUMN user_jwts.role IS 'Course role assigned to the user';
COMMENT ON COLUMN user_jwts.created_at IS 'When this user row was created';
COMMENT ON COLUMN user_jwts.updated_at IS 'When this user row was last updated';
COMMENT ON COLUMN user_jwts.team_nickname IS 'Team nickname assigned to the user, if any';
