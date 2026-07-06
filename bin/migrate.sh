#!/bin/sh
./bin/sqitch.sh -C db/migrations deploy --verify 'db:pg://superuser@localhost:5432/app'
