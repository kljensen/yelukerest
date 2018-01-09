create or replace view ui_elements as
    select * from data.ui_element;

-- it is important to set the correct owner so the RLS policy kicks in
alter view ui_elements owner to api;