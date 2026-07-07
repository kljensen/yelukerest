create table todo (
	id    serial primary key,
	todo  text not null,
	private boolean default true,  
	owner_id int references "user"(id)
		ON UPDATE CASCADE ON DELETE CASCADE
		default request.user_id()
);

DROP INDEX IF EXISTS idx_todo_owner_id_fk;
CREATE INDEX idx_todo_owner_id_fk ON todo (owner_id);
