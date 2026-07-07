\echo # Loading settings schema
drop schema if exists settings cascade;
create schema settings;

create table settings.secrets (
	key    text primary key,
	value  text not null
);


create or replace function settings.get(text) returns text
security definer
stable
language sql
set search_path = pg_catalog, settings, pg_temp
return (select value from settings.secrets where key = $1);

create or replace function settings.set(text, text) returns void
security definer
language sql
set search_path = pg_catalog, settings, pg_temp
begin atomic
	insert into settings.secrets (key, value)
	values ($1, $2)
	on conflict (key) do update
	set value = $2;
end;
