# Materialized View Strategies Using PostgreSQL

Queries returning aggregate, summary, and computed data are frequently used in application development. Sometimes these queries are not fast enough. Caching query results using Memcached or Redis is a common approach for resolving these performance issues. However, these bring their own challenges. Before reaching for an external tool it is worth examining what techniques PostgreSQL offers for caching query results.

## Example Domain

We will examine different approaches using the sample domain of a simplified account system. Accounts can have many transactions. Transactions can be recorded ahead of time and only take effect at post time. e.g. A debit that is effective on March 9 can be entered on March 1. The summary data we need is account balance.

```sql
create table accounts(
  name varchar primary key
);

create table transactions(
  id serial primary key,
  name varchar not null references accounts
    on update cascade
    on delete cascade,
  amount numeric(9,2) not null,
  post_time timestamptz not null
);

create index on transactions (name);
create index on transactions (post_time);
```

## Sample Data and Queries

For this example, we will create 30,000 accounts with an average of 50 transactions each.

All the sample code and data is available on [Github](https://github.com/jackc/mat-view-strat-pg).

Our query that we will optimize for is finding the balance of accounts. To start we will create a view that finds balances for all accounts. A PostgreSQL [view](http://www.postgresql.org/docs/9.4/static/sql-createview.html) is a saved query. Once created, selecting from a view is exactly the same as selecting from the original query, i.e. it reruns the query each time.

```sql
create view account_balances as
select
  name,
  coalesce(
    sum(amount) filter (where post_time <= current_timestamp),
    0
  ) as balance
from accounts
  left join transactions using(name)
group by name;
```

Note that this uses an aggregate filter clause, an awesome feature [introduced in PostgreSQL 9.4](https://wiki.postgresql.org/wiki/What%27s_new_in_PostgreSQL_9.4#Aggregate_FILTER_clause).

Now we simply select all rows with negative balances.

```sql
select * from account_balances where balance < 0;
```

After several runs to warm OS and PostgreSQL caches, this query takes approximately 3850ms.

We are going to examine multiple solutions. To keep them namespaced we will create separate schemas for each approach.

```sql
create schema matview;
create schema eager;
create schema lazy;
```

## PostgreSQL Materialized Views

The simplest way to improve performance is to use a [materialized view](http://www.postgresql.org/docs/9.4/static/rules-materializedviews.html). A materialized view is a snapshot of a query saved into a table.

```sql
create materialized view matview.account_balances as
select
  name,
  coalesce(
    sum(amount) filter (where post_time <= current_timestamp),
    0
  ) as balance
from accounts
  left join transactions using(name)
group by name;
```

Because a materialized view actually is a table, we can create indexes.

```sql
create index on matview.account_balances (name);
create index on matview.account_balances (balance);
```

To retrieve the balance from each row we simple select from the materialized view.

```sql
select * from matview.account_balances where balance < 0;
```

The performance impact is impressive. It now only takes 13ms to retrieve all the accounts with negative balances -- 453x faster! Unfortunately, these materialized views have two substantial limitations. First, they are only updated on demand. Second, the whole materialized view must be updated; there is no way to only update a single stale row.

```sql
-- refresh all rows
refresh materialized view matview.account_balances;
```

In the case where possibly stale data is acceptable, they are an excellent solution. But if data must always be fresh they are not a solution.

## Eager Materialized View

Our next approach is to materialize the query into a table that is eagerly updated whenever a change occurs that would invalidate a row. We can do that with [triggers](http://www.postgresql.org/docs/9.4/static/triggers.html). A trigger is a bit of code that runs when some event such as an insert or update happens.

First, we create the table to store the materialized rows.

```sql
create table eager.account_balances(
  name varchar primary key references accounts
    on update cascade
    on delete cascade,
  balance numeric(9,2) not null default 0
);

create index on eager.account_balances (balance);
```

Now we need to think of every way that ```account_balances``` could become stale.

### An account is inserted

On account insertion we need to create a ```account_balances``` record with a zero balance for the new account.

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

create trigger account_insert after insert on accounts
    for each row execute procedure eager.account_insert();
```

The syntax for [create function](http://www.postgresql.org/docs/9.4/static/sql-createfunction.html) and [create trigger](http://www.postgresql.org/docs/9.4/static/sql-createtrigger.html) is quite extensive. Refer to the documentation for details. But the summary explanation is this: We create the function ```eager.account_insert``` as a trigger function that will run with the permissions of the user who created it (```security definer```). Inside a insert trigger function, ```new``` is a variable that holds the new record.

### An account is updated or deleted

Account update and deletion will be handled automatically because the foreign key to account is declared as ```on update cascade on delete cascade```.

### A transaction is inserted, updated, or deleted

Transaction insert, update, and delete all have one thing in common: they invalidate the account balance. So the first step is to define a refresh account balance function.

```sql
create function eager.refresh_account_balance(_name varchar)
  returns void
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
```

Next we can create trigger function that calls ```refresh_account_balance``` whenever a transaction is inserted.

```sql
create function eager.transaction_insert()
  returns trigger
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

[Perform](http://www.postgresql.org/docs/9.4/static/plpgsql-statements.html#PLPGSQL-STATEMENTS-SQL-NORESULT) is how you execute a query where you do not care about the result in PL/pgSQL.

For the delete of a transaction we only get the variable ```old``` instead of ```new``` row. ```old``` stores the previous value of the row.

```sql
create function eager.transaction_delete()
  returns trigger
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

For the update of a transaction, we have to account for the possibility that the account the transaction belongs to was changed. We use the ```old``` and ```new``` values of the row to determine which account balances are invalidated and need to be refreshed.

```sql
create function eager.transaction_update()
  returns trigger
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

Finally, with all this set up we need to initialize the ```account_balances``` table.

```sql
-- Create the balance rows
insert into eager.account_balances(name)
select name from accounts;

-- Refresh the balance rows
select eager.refresh_account_balance(name)
from accounts;
```

To query the negative account balances we simply select from the ```acount_balances``` table.

```sql
select * from eager.account_balances where balance < 0;
```

This is really fast (13ms / 453x faster) just like the materialized view. But it has the advantage of it stays fresh even when transactions change. Unfortunately, this strategy doesn't account for one key requirement -- row invalidation by the passage of time.

## Lazy Materialized View

The previous solution was not bad. It was just incomplete. The full solution lazily refreshes the materialized rows when they are stale.

As with the eager materialization strategy, our first step is to create a table to store the materialized rows. The difference is we add an expiration time column.

```sql
create table lazy.account_balances_mat(
  name varchar primary key references accounts
    on update cascade
    on delete cascade,
  balance numeric(9,2) not null default 0,
  expiration_time timestamptz not null
);

create index on lazy.account_balances_mat (balance);
create index on lazy.account_balances_mat (expiration_time);
```

We will create the initial rows for ```lazy.account_balances_mat``` with ```expiration_time``` as ```-Infinity``` to mark them as dirty.

```sql
insert into lazy.account_balances_mat(name, expiration_time)
select name, '-Infinity'
from accounts;
```

The same data changes that could invalidate materialized rows in the eager strategy must be handled with the lazy strategy. The difference is that the triggers will only update ```expiration_time``` -- they will not actually recalculate the data.

### An account is inserted

As with the eager strategy, on account insertion we need to create a ```_account_balances``` record with a zero balance for the new account. But we also need to provide an ```expiration_time```. The balance for an account with no transactions will be valid forever, so we provide the special PostgreSQL value ```Infinity``` as the ```expiration_time```. ```Infinity``` is defined as greater than any other value.

```sql
create function lazy.account_insert() returns trigger
  security definer
  language plpgsql
as $$
  begin
    insert into lazy.account_balances_mat(name, expiration_time)
      values(new.name, 'Infinity');
    return new;
  end;
$$;

create trigger lazy_account_insert after insert on accounts
    for each row execute procedure lazy.account_insert();
```

### An account is updated or deleted

As before, account update and deletion will be handled by the the foreign key cascades.

### A transaction is inserted

For the insert of a transaction, we update the ```expiration_time``` if the ```post_time``` of the transaction is less than the current ```expiration_time```. This means the update only happens when absolutely necessary. If the account will already be considered stale at the ```post_time``` of the new record we avoid the IO cost of the write.

```sql
create function lazy.transaction_insert()
  returns trigger
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

### A transaction is updated

Unlike when a transaction is inserted, when a transaction is updated, it is not possible to compute the new account ```expiration_time``` without reading the account's transactions. This makes it cheaper to simply invalidate the account balance. We will simply set ```expiration_time``` to ```-Infinity```, a special value defined as being less than all other values. This ensures that the row will be considered stale.

```sql
create function lazy.transaction_update()
  returns trigger
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

### A transaction is deleted

For transaction deletion, we invalidate the row if the ```post_time``` is less than or equal to the current ```expiration_time```. But if at is after the current ```expiration_time``` we do not have to do anything.

```sql
create function lazy.transaction_delete()
  returns trigger
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

### Final Steps

The penultimate step is to define a function to refresh a materialized row.

```sql
create function lazy.refresh_account_balance(_name varchar)
  returns lazy.account_balances_mat
  security definer
  language sql
as $$
  with t as (
    select
      coalesce(
        sum(amount) filter (where post_time <= current_timestamp),
        0
      ) as balance,
      coalesce(
        min(post_time) filter (where current_timestamp < post_time),
        'Infinity'
      ) as expiration_time
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

This function uses a [common table expression](http://www.postgresql.org/docs/9.4/static/queries-with.html) and aggregate filters to find ```balance``` and ```expiration_time``` in a single select. Then results are then used to update ```acount_balances_mat```.

Finally, we define the ```account_balances``` view. The top part of the query reads fresh rows from ```account_balances_mat```. The bottom part reads and refreshes rows that are stale.

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

To retrieve the all accounts with negative balances balances we simply select from the ```account_balances``` view.

```sql
select * from lazy.account_balances where balance < 0;
```

The first time the query is run it takes about 5900ms because it is caching the balance for all account. Subsequent runs only take about 16ms (368x faster). In general, the query run time should not be nearly so variable because only a small fraction of the rows will be refreshed in any one query.

## Comparison of Techniques

PostgreSQL's built-in materialized views offer the best performance improvement for the least work, but only if stale data is acceptable. Eager materialized views offer the absolute best read performance, but can only guarantee freshness if rows do not go stale due to the passage of time. Lazy materialized views offer almost as good read performance as eager materialized views, but they can guarantee freshness under all circumstances.

One additional consideration is read-heavy vs. write-heavy workloads. Most systems are read-heavy. But for a write-heavy load you should give consider leaning toward lazy and away from eager materialized views. The reason is that eager materialized views do the refresh calculation on every write whereas lazy materialized views only pay that cost on read.

## Final Thoughts

PostgreSQL materialization strategies can improve performance by a factor of hundreds or more. In contrast to caching in Memcachd or Redis, PostgreSQL materialization provides [ACID](http://en.wikipedia.org/wiki/ACID) guarantees. This eliminates an entire category of consistency issues that must be handled at the application layer. In addition, the infrastructure for a system as a whole is simpler with one less part.

The increased performance and system simplicity is well worth the cost of more advanced SQL.

## References

* [Example code for this post](https://github.com/jackc/mat-view-strat-pg)
* [Chapter 12 of Enterprise Rails describes materialized views](http://dan.chak.org/enterprise-rails/chapter-12-materialized-views/)
* [Materialized view talk from 2008 PGCon](http://www.pgcon.org/2008/schedule/attachments/64_BSDCan2008-MaterializedViews-paper.pdf)
* [Jonathan Gardner materialized view notes](http://tech.jonathangardner.net/wiki/PostgreSQL/Materialized_Views)
