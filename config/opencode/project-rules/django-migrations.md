<!-- Project rule: never hand-write migrations; always use the ORM generator.
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array. -->

# Database Migrations

Never write or edit migration files by hand. Always use the ORM's migration generator so the framework tracks state correctly and produces deterministic output.

## Django

```bash
python manage.py makemigrations
```

For custom data migrations, generate an empty migration first, then fill in the operation logic:

```bash
python manage.py makemigrations <app_name> --empty -n <descriptive_name>
```
