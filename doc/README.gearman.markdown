Media Cloud + Gearman interoperability
======================================

Media Cloud uses [Gearman](http://gearman.org/) and [Gearman::JobScheduler](https://github.com/pypt/p5-Gearman-JobScheduler) for scheduling, enqueueing and running various background processes.


Installing Gearman
------------------

On Ubuntu, install Gearman with:

    apt-get install gearman

On OS X, install Gearman with:

    brew install gearman


Configuring Gearman to use PostgreSQL for storing the job queue
---------------------------------------------------------------

You might want Gearman to [store its job queue in PostgreSQL](http://gearman.org/manual:job_server#postgresql).

To do that, create a PostgreSQL database `gearman` for storing the queue, and allow user `gearman` to access it:

    # sudo -u postgres createuser -D -A -P gearman
    Enter password for new role: 
    Enter it again: 
    Shall the new role be allowed to create more new roles? (y/n) n
    # sudo -u postgres createdb -O gearman gearman

Then, edit `/etc/default/gearman-job-server`:

    vim /etc/default/gearman-job-server

and append PostgreSQL connection properties to `PARAMS` so that it reads something like this:

    # Parameters to pass to gearmand.
    PARAMS="--listen=127.0.0.1"

    # Use PostgreSQL for storing a job queue
    export PGHOST=127.0.0.1
    export PGPORT=5432
    export PGUSER=gearman
    export PGPASSWORD="correct horse battery staple"
    export PGDATABASE=gearman
    PARAMS="$PARAMS --queue-type Postgres"
    PARAMS="$PARAMS --libpq-table=queue"
    PARAMS="$PARAMS --verbose DEBUG"

Lastly, restart `gearmand`:

    # service gearman-job-server restart
     * Stopping Gearman Server gearmand    [ OK ] 
     * Starting Gearman Server gearmand    [ OK ] 


Testing Gearman
---------------

To try things out, start a test Gearman worker which will count the lines of the input:

    $ gearman -w -f wc -- wc -l

Then run the job in the worker:

    $ gearman -f wc < /etc/group
    61

Ensure that the job queue is being stored in PostgreSQL:

    # sudo -u postgres psql gearman
    gearman=# \dt
            List of relations
     Schema | Name  | Type  |  Owner  
    --------+-------+-------+---------
     public | queue | table | gearman
    (1 row)

Submit a test background job to Gearman:

    $ gearman -b -f wc < /etc/passwd

and make sure it is being stored in the queue:

    gearman=# SELECT COUNT(*) FROM queue;
     count 
    -------
         1
    (1 row)


Monitoring Gearman
------------------

To monitor Gearman, you can use either the `gearadmin` tool or the "Gearman-Monitor" PHP script.


### `gearadmin`

For example:

    $ gearadmin --status
    wc  2   0   0

(Function "wc", 2 jobs enqueued, 0 currently running, 0 workers registered)

Run `gearadmin --help` for more options.


### "Gearman-Monitor"

[Gearman-Monitor](https://github.com/yugene/Gearman-Monitor) is a tool to watch Gearman servers. 

Screenshots: http://imgur.com/a/RjJWc