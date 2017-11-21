# Lightway

Lightway provides PowerShell scripting assistance for implementing a hybrid **model-and-migrations database change workflow**. This workflow combines the benefits of model-based _development_ with the reliability and control of a migrations-based _deployment_ process.

Lightway basically has two parts:

### Create Migration
A script to create migrations, based on the model (and the previous migration point). There's a version of this for SSDT projects, and version that works with RedGate Schema Compare for Oracle.

### Upgrade Database
A script to _execute_ a series of database migration scripts against a database, tracking what version the database has got up to so far.

## Background - why a hybrid approach?
The model-centric approach, present in tools like Sql Server Database Tools (SSDT) or RedGate Schema Compare, allows you to make database changes to a logical, source controlled model. These changes can be made directly on the model, or against a database and then syncronised back into the model. Because objects in the model are (typically) stored as individual files, it's very easy to track how objects have changed by looking at their invididual source control history.

However, when it comes to deployment, there are some problems. Leaving aside whether your DBAs are happy with tools directly making changes to the database, there are some serious interpretation issues to deal with. Typically the only context is the source and target database schema, so some changes become a set of 'good guesses'. If a column exists in one and not the other, and vice-versa, has one column been dropped and another added, or has the original column been renamed. And if it _is_ a new column, how is it to be populated? Your model represents the end-state, but doesn't describe any interim states needed to get there.

As a result, many turn instead to a _migrations-based_ process, where each change to the database is scripted out, and those scripts stored in a library folder. To upgrade any database you just have to then run all the scripts between 'then' and 'now', in order, and all the intermediate transitions happen as they should have done. Tools like DbUp, Flyway and EF Migrations use this approach (one of the original authors of DbUp, Paul Stovell, wrote a good argument for this approach on his blog: http://paulstovell.com/blog/database-deployment ).

The problem here, however, is the loss of utility:
- you have to write _all_ those migrations yourself
- the journal-of-changes structure makes it really hard to track the sequence of changes on an individual object (eg to see when a bug was introduced)
- merging conflicting changes across branches is a nightmare

The hybrid approach that Lightway uses is a combination of both, and is more-or-less equivilent to how RedGate ReadyRoll works. The model gets used for development, and to track overall history in source control, but a _seperate_ of migration scripts is used for deployment. Migrations can be built by hand, but would more commonly be based on the comparison between the model and current set of migrations to date.

As a result you get all the control and dependability of a migrations-based approach, with the simplicity and convenience of the model-based approach. Everyone wins!