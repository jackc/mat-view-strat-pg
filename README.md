# Materialized View Strategies Using PostgreSQL

This repository contains the test data and code for this blog post: http://hashrocket.com/blog/posts/materialized-view-strategies-using-postgresql

To load test data:

    createdb pg_cache_demo
    psql -f accounts.sql pg_cache_demo
    psql -f transactions.sql pg_cache_demo
    psql -f postgresql_view.sql pg_cache_demo
    psql -f postgresql_mat_view.sql pg_cache_demo
    psql -f eager_mat_view.sql pg_cache_demo
    psql -f lazy_mat_view.sql pg_cache_demo
