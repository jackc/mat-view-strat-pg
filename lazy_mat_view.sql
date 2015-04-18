create schema lazy;

create table lazy.account_balances_mat(
  name varchar primary key references accounts on update cascade on delete cascade,
  balance numeric(9,2) not null default 0,
  expiration_time timestamptz not null
);

create index on lazy.account_balances_mat (balance);
create index on lazy.account_balances_mat (expiration_time);

insert into lazy.account_balances_mat(name, expiration_time)
select name, '-Infinity'
from accounts;

create function lazy.account_insert() returns trigger
  security definer
  language plpgsql
as $$
  begin
    insert into lazy.account_balances_mat(name, expiration_time) values(new.name, 'Infinity');
    return new;
  end;
$$;

create trigger lazy_account_insert after insert on accounts
    for each row execute procedure lazy.account_insert();

create function lazy.transaction_insert() returns trigger
  security definer
  language plpgsql
as $$
  begin
    update lazy.account_balances_mat
    set expiration_time=new.post_time
    where name=new.name
      and new.post_time < expiration_time;
    return new;
  end;
$$;

create trigger lazy_transaction_insert after insert on transactions
    for each row execute procedure lazy.transaction_insert();

create function lazy.transaction_update() returns trigger
  security definer
  language plpgsql
as $$
  begin
    update accounts
    set expiration_time='-Infinity'
    where name in(old.name, new.name)
      and expiration_time<>'-Infinity';

    return new;
  end;
$$;

create trigger lazy_transaction_update after update on transactions
    for each row execute procedure lazy.transaction_update();

create function lazy.transaction_delete() returns trigger
  security definer
  language plpgsql
as $$
  begin
    update lazy.account_balances_mat
    set expiration_time='-Infinity'
    where name=old.name
      and old.post_time <= expiration_time;

    return old;
  end;
$$;

create trigger lazy_transaction_delete after delete on transactions
    for each row execute procedure lazy.transaction_delete();

create function lazy.refresh_account_balance(_name varchar) returns lazy.account_balances_mat
  security definer
  language sql
as $$
  with t as (
    select
      coalesce(sum(amount) filter (where post_time <= current_timestamp), 0) as balance,
      coalesce(min(post_time) filter (where current_timestamp < post_time), 'Infinity') as expiration_time
    from transactions
    where name=_name
  )
  update lazy.account_balances_mat
  set balance = t.balance,
    expiration_time = t.expiration_time
  from t
  where name=_name
  returning account_balances_mat.*;
$$;

create view lazy.account_balances as
select name, balance
from lazy.account_balances_mat
where current_timestamp < expiration_time
union all
select r.name, r.balance
from lazy.account_balances_mat abm
  cross join lazy.refresh_account_balance(abm.name) r
where abm.expiration_time <= current_timestamp;
