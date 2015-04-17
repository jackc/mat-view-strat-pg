# Materialized View Strategies Using PostgreSQL

Aggregate, summary, and computed data are frequently needed in application development. However, calculating them in real-time can be computationaly impractical. In this article we will explore various materialization techniques using PostgreSQL.

## Example Domain

We will examine different approaches using the sample domain of a simplified account system. Accounts can have many transactions. Transactions can be recorded ahead of time and only take effect at post time. e.g. A debit that is effective on March 9 can be entered on March 1. The summary data we need is account balance.

```sql
create table accounts(
  name varchar primary key
);

create table transactions(
  id serial primary key,
  name varchar not null references accounts on update cascade on delete cascade,
  amount numeric(9,2) not null,
  post_time timestamptz not null
);

create index on transactions (name);
create index on transactions (post_time);
```

## Sample Data and Queries

For this example, we will create 30,000 accounts with an average of 50 transactions each.

TODO - link to sample data scripts

Our query that we will optimize for is finding the balance of accounts.

```sql
select
  name,
  coalesce(sum(amount) filter (where post_time <= current_timestamp), 0) as balance
from accounts
  left join transactions using(name)
group by name;
```

Note that this uses an aggregate filter clause, an awesome feature [introduced in PostgreSQL 9.4](https://wiki.postgresql.org/wiki/What%27s_new_in_PostgreSQL_9.4#Aggregate_FILTER_clause)

This takes TODO time.

We are going to examine multiple solutions. To keep them namespaced we will create separate schemas for each approach.

```sql
create schema matview;
create schema eager;
create schema lazy;
```

## PostgreSQL Materialized Views

The simplest way to improve performance is to use a [materialized view](http://www.postgresql.org/docs/9.4/static/rules-materializedviews.html). A materialized view is a snapshot of a query.

```sql
create materialized view matview.account_balances as
select
  name,
  coalesce(sum(amount) filter (where post_time <= current_timestamp), 0) as balance
from accounts
  left join transactions using(name)
group by name;

create index on matview.account_balances (name);
```

The performance impact is impressive. It now only takes TODO time to retrieve the balance for every account. Unfortunately, these materialized views have two substantial limitations. First, they are only updated on demand. Second, the whole materialized view must be updated; there is no way to only update a single stale row.

```sql
refresh materialized view matview.account_balances;
```

In the case where possibly stale data is acceptable, they are an excellent solution. But if data must always be fresh they are not a solution.

## Eager Materialized View

Our next approach is to use a table that is eagerly updated by triggers.

First, we create the table to store the materialized rows.

```sql
create table eager.account_balances(
  name varchar primary key references accounts on update cascade on delete cascade,
  balance numeric(9,2) not null default 0
);
```

Now we need to think of every way that account_balances could become stale.

1. An account could be inserted.
2. An account could be updated.
3. An account could be deleted.
4. A transaction could be inserted.
5. A transaction could be updated.
6. A transaction could be deleted.

On account insertion we need to create a account_balances record with a zero balance for the new account.

```sql
create function eager.account_insert() returns trigger
  security definer
  language plpgsql
as $$
  begin
    insert into eager.account_balances(name) values(new.name);
    return new;
  end;
$$;

create trigger eager.account_insert after insert on accounts
    for each row execute procedure eager.account_insert();
```

Account update and deletion will be handled by the the foreign key cascades.

Transaction insert, update, and delete all have one thing in common: they invalidate the account balance. So the first step is to define a refresh account balance function.

```sql
create function eager.refresh_account_balance(_name varchar) returns void
  security definer
  language plpgsql
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
```

Next we can create trigger function that calls ```refresh_account_balance``` whenever a transaction is inserted.

```sql
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
```

For the update of a transaction, we have to account for the possibility that the account the transaction belongs to was changed. This would mean two account balances are invalidated and need to be refreshed.

```
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
```

For the delete of a transaction we only get the old row.

```sql
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
```

Finally, with all this set up we need to initialize the account balances table.

```sql
insert into eager.account_balances(name)
select name from accounts;

select eager.refresh_account_balance(name)
from accounts;
```

TODO - performance

This is really fast. Unfortunately, this strategy doesn't account for one key requirement -- row invalidation by the passage of time.

## Lazy Materialized View

The previous solution was not bad. It was just incomplete. The full solution lazily refreshes the materialized rows as needed.

As with the eager materialization strategy, our first step is to create a table to store the materialized rows. The difference is we add an expiration time column.

```sql
create table lazy.account_balances_mat(
  name varchar primary key references accounts on update cascade on delete cascade,
  balance numeric(9,2) not null default 0,
  expiration_time timestamptz not null
);

create index on lazy.account_balances_mat (expiration_time);
```

We will create the initial rows for ```lazy.account_balances_mat``` with ```expiration_time``` as ```-Infinity``` to mark them as dirty.

```sql
insert into lazy.account_balances_mat(name, expiration_time)
select name, '-Infinity'
from accounts;
```

The same data changes that could invalidate materialized rows in the eager strategy must be handled with the lazy strategy. The difference is that the triggers will only update ```expiration_time``` -- they will not actually recalculate the data.

1. An account could be inserted.
2. An account could be updated.
3. An account could be deleted.
4. A transaction could be inserted.
5. A transaction could be updated.
6. A transaction could be deleted.

As with the eager strategy, on account insertion we need to create a ```_account_balances``` record with a zero balance for the new account. But we also need to provide an ```expiration_time```. The balance for an account with no transactions will be valid forever, so we provide the special PostgreSQL value ```Infinity``` as the ```expiration_time```. ```Infinity``` is defined as greater than any other value.

```sql
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
```

As before, account update and deletion will be handled by the the foreign key cascades.

For the insert of a transaction, we update the ```expiration_time``` if the ```post_time``` of the transaction is less than the current ```expiration_time```.

```sql
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
```

When a transaction is updated, it may not be possible to compute the new account ```expiration_time``` without reading the account's transactions. Rather than try to determine whether or not it is possible, we will simply set ```expiration_time``` to ```-Infinity```, a special value defined as being less than all other values. This ensures that the row will be considered stale.

```
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
```

For transaction deletion, we invalidate the row if the ```post_time``` is less than or equal to the current ```expiration_time```. But if at is after the current ```expiration_time``` we do not have to do anything.

```sql
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
```

The penultimate step is to define a function to refresh a materialized row.

```sql
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
```

Finally, we define the ```account_balances``` view. It reads fresh rows from ```account_balances_mat``` and refreshes rows that are stale.

```sql
create view lazy.account_balances as
select name, balance
from lazy.account_balances_mat
where current_timestamp < expiration_time
union all
select r.name, r.balance
from lazy.account_balances_mat abm
  cross join lazy.refresh_account_balance(abm.name) r
where abm.expiration_time <= current_timestamp;
```

## References

* http://dan.chak.org/enterprise-rails/chapter-12-materialized-views/
* http://www.pgcon.org/2008/schedule/attachments/64_BSDCan2008-MaterializedViews-paper.pdf
* http://tech.jonathangardner.net/wiki/PostgreSQL/Materialized_Views
