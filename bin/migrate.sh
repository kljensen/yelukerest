#!/bin/sh
./bin/sqitch.sh -C db/migrations deploy 'db:pg://superuser@localhost:5432/app'
