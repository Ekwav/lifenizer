# SQLite upgrades

The API applies EF Core migrations at startup. The first migration adopts both
previously shipped `EnsureCreated` schemas: the original users/sync/usage tables
and the later image/quota schema. It adds `Users.StorageUsedBytes` with zero for
legacy accounts and creates missing tables/indexes without replacing existing
rows. Account IDs, vault salts, ciphertext, usage records and existing image
metadata are preserved. The migration history records the baseline, so future
schema changes use normal EF migrations. Baseline rollback is deliberately
rejected because it would delete adopted user data.

Back up the SQLite file and its associated image directory before an upgrade.
Keep one API instance writing to a SQLite database while applying migrations.
Restarting on an already upgraded database is safe. Do not delete the database
to fix schema failures.

To add future migrations after changing the data model:

```sh
dotnet ef migrations add Name --project backend/Lifenizer.Api
dotnet test backend/Lifenizer.Tests/Lifenizer.Tests.csproj
```

Regression coverage creates fresh databases and both prior schemas, upgrades
them twice, and checks preservation of encrypted records and vault identity.
