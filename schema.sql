create table accounts(
  name varchar primary key
);

create table transactions(
  id serial primary key,
  name varchar not null references accounts,
  amount numeric(9,2) not null,
  post_time timestamptz not null
);

create index on transactions (name);
create index on transactions (post_time);
