create view account_balances as
select
  name,
  coalesce(sum(amount) filter (where post_time <= current_timestamp), 0) as balance
from accounts
  left join transactions using(name)
group by name;
