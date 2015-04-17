create table transactions(
  id serial primary key,
  name varchar not null references accounts,
  amount numeric(9,2) not null,
  post_time timestamptz not null
);

create index on transactions (name);
create index on transactions (post_time);

select setseed(1); -- ensure reproducible data

with r as (
  select (random() * 29999)::bigint as account_offset
  from generate_series(1, 1500000)
)
insert into transactions(name, amount, post_time)
select
  (select name from accounts offset account_offset limit 1),
  ((random()-0.5)*1000)::numeric(8,2),
  current_timestamp + '90 days'::interval - (random()*1000 || ' days')::interval
from r
;
