create schema eager;

create table eager.account_balances(
  name varchar primary key references accounts on update cascade on delete cascade,
  balance numeric(9,2) not null default 0
);

create index on eager.account_balances (balance);

create function eager.account_insert() returns trigger
  security definer
  language plpgsql
as $$
  begin
    insert into eager.account_balances(name) values(new.name);
    return new;
  end;
$$;

create trigger account_insert after insert on accounts
    for each row execute procedure eager.account_insert();

create function eager.refresh_account_balance(_name varchar) returns void
  security definer
  language sql
as $$
  update eager.account_balances
  set balance=
    (
      select sum(amount)
      from transactions
      where account_balances.name=transactions.name
        and post_time <= current_timestamp
    )
  where name=_name;
$$;

create function eager.transaction_insert() returns trigger
  security definer
  language plpgsql
as $$
  begin
    perform eager.refresh_account_balance(new.name);
    return new;
  end;
$$;

create trigger eager_transaction_insert after insert on transactions
    for each row execute procedure eager.transaction_insert();

create function eager.transaction_delete() returns trigger
  security definer
  language plpgsql
as $$
  begin
    perform eager.refresh_account_balance(old.name);
    return old;
  end;
$$;

create trigger eager_transaction_delete after delete on transactions
    for each row execute procedure eager.transaction_delete();

create function eager.transaction_update() returns trigger
  security definer
  language plpgsql
as $$
  begin
    if old.name!=new.name then
      perform eager.refresh_account_balance(old.name);
    end if;

    perform eager.refresh_account_balance(new.name);
    return new;
  end;
$$;

create trigger eager_transaction_update after update on transactions
    for each row execute procedure eager.transaction_update();

-- Create the balance rows
insert into eager.account_balances(name)
select name from accounts;

-- Refresh the balance rows
select eager.refresh_account_balance(name)
from accounts;
