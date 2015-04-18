create schema matview;

create materialized view matview.account_balances as
select
  name,
  coalesce(sum(amount) filter (where post_time <= current_timestamp), 0) as balance
from accounts
  left join transactions using(name)
group by name;

create index on matview.account_balances (name);
create index on matview.account_balances (balance);
