#!/bin/sh

# Adding a new table to the database is always a pain. I have
# to add a new table, views, authorization, and tests. This
# requires both creating a number of files and altering other
# files. 
#
# This script helps by 1) creating scaffolding for the new
# table (the new files) and 2) altering other files to import
# the new files where required.

if [ "$#" -ne 2 ]; then
    echo "$0 NAME PLURAL_NAME"
    exit
fi

cat << EOF >  db/src/data/yeluke/$1.sql
CREATE TABLE IF NOT EXISTS $1 (
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

CREATE OR REPLACE FUNCTION fill_$1_defaults()
RETURNS TRIGGER AS \$\$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
\$\$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_$1_default ON $1;
CREATE TRIGGER tg_$1_default
    BEFORE INSERT OR UPDATE
    ON $1
    FOR EACH ROW
EXECUTE PROCEDURE fill_$1_defaults();
EOF

cat << EOF >  db/src/api/yeluke/$1.sql
create or replace view $2 as
    select * from data.$1;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view $2 owner to api;
EOF

cat << EOF > db/src/authorization/yeluke/$1.sql
grant select, insert, update, delete on data.$1 to api;

-- alter table data.$1 enable row level security;

-- create policy $1_access_policy on data.$1 to api
-- using (
--         -- The student users can see all her/his own rows.
--         (request.user_role() = ANY('{student,ta}'::text[]) and request.user_id() = user_id)
--         or
--         -- Faculty can see all
--         (request.user_role() = 'faculty')
-- ) WITH CHECK (
--     -- Only faculty can write 
--         request.user_role() = 'faculty'
-- );

grant select on api.$2 to student, ta;
grant select, insert, update, delete on api.$2 to faculty;
EOF

cat << EOF > db/src/sample_data/yeluke/$1.sql
\echo # filling table $1

-- Users 5 has an extension on quiz 3
-- COPY data.$1 (slug,description,created_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
-- after-first-exam	woot!	2019-12-27 14:55:50
-- \.

ANALYZE data.$1;
EOF

cat << EOF > tests/db/yeluke-$2.sql
begin;
select plan(5);

SELECT view_owner_is(
    'api', '$2', 'api',
    'api.$2 view should be owned by the api role'
);

SELECT table_privs_are(
    'api', '$2', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.$2"'
);

SELECT table_privs_are(
    'api', '$2', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.$2"'
);

SELECT table_privs_are(
    'data', '$1', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.$1"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.$2',
    '%permission denied%',
    'anonymous users should not be able to use the api.$2 view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


set local role faculty;
set request.jwt.claim.role = 'faculty';

select * from finish();
rollback;
EOF

# Now, ensure that these files get sourced.
# The project has a number of files that source
# the individual SQL files in order to build
# the scheme. Each of these will need to know
# the path to the new SQL files. Each has a line
# in it that looks like
# "-- KEEP ME FOR new-table.sh"
# to point out to us where we want new lines.
# The `add_line` function injects a new line right
# before that comment.

function add_line () {
    grep -qxF "$2" $1 >/dev/null
    status=$?
    if test $status -eq 0
    then
        echo "line already present"
    else
        echo "adding line"
        temp_file=$(mktemp)
        cat $1| awk \
            -v newline="$2" \
            '/^-- KEEP/{print newline}1' >$temp_file
        mv $temp_file $1
        rm -f $temp_file
    fi
}

add_line db/src/api/yeluke.sql "\\\ir ./yeluke/$1.sql"
add_line db/src/authorization/yeluke.sql "\\\ir ./yeluke/$1.sql"
add_line db/src/data/yeluke.sql "\\\ir ./yeluke/$1.sql"
add_line db/src/sample_data/yeluke/data.sql "\\\ir $1.sql"
add_line db/src/sample_data/yeluke/reset.sql "truncate data.$1 restart identity cascade";

echo "Done. Now run git diff/status to see which files have been altered."