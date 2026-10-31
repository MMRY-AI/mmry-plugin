Start and use a database in your AI database: set one up, list them, add, find and correct entries, see an entry's history, and retire or restore a database.

Usage: `/mmry:database create "what you want to keep track of"` | `/mmry:database list [database]` | `/mmry:database add <database> "the entry, in your words"` | `/mmry:database find <database> [field=value ...]` | `/mmry:database correct <database> <entry> "what changes"` | `/mmry:database history <database> <entry>` | `/mmry:database retire <database>` | `/mmry:database restore <database>`

## What This Does

Your AI database is a set of databases your assistant keeps for you as you talk: every migraine
and what preceded it, every expense, every job application. A **database** is one of those; each
item in it is an **entry**; its named values are **fields**. Use these words with the customer.
The script names and flags below (`--database-id`, `--entry-id`) say the same thing; you need
not read them out to the customer.

**This command is a shortcut, not the only way.** Asking in plain words ("keep track of my
migraines", "how many expenses over 50 this month?") does exactly the same, through the same
scripts. Nothing here is required.

## How to Run It

Every subcommand runs one script, `database.sh`, with the subcommand first:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" <subcommand> [arguments]
```

Take the subcommand and its words from `$ARGUMENTS`. If `$ARGUMENTS` is empty or names no
subcommand below, do not guess: show the Usage line above and ask what they want to do.

**Print what the script prints,** then say in one or two plain sentences what happened. Every
successful run ends with the line naming `https://mmryai.com/databases`, the account page where the
customer sees their databases and corrects any entry themselves: keep that line in your answer.
On an error, pass the script's message through; do not report success.

**A database is named by its id.** Where the customer names a database by its name ("my migraine
log"), run `list` first and use the id it shows. Where they name an entry ("the second one",
"the Acme lead"), run `find` first and use the entry's id. Never guess an id.

### create

Set up a new database for something the customer will keep track of again and again.

1. Run `list` first. If a database for the same thing already exists, say so and offer to use it
   rather than setting up a second one.
2. From the customer's description, design the fields, using their words as the labels. Each field
   has a key, an optional label and a type: text, number, date, bool, enum (with options) or list
   (with "of").
3. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" create --name "<name, in their words>" \
    --description "<what it is for, in their words>" \
    --fields '[{"key":"severity","label":"Severity","type":"number"}]' \
    [--mode append|keyed|singleton] [--identity-field <key>] [--match-hints "a, b, c"] [--visibility private|global]
```

`--mode append` (the default) is for a log where every entry is new. `keyed` is for named things
that each change on their own (tasks, contacts, leads); give `--identity-field` too. A database is
private unless the customer asks for everyone on the account to see it.

### list

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" list
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" list --id <database>          # one database in full, with its fields
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" list --include-retired        # include retired databases
```

### add

Save a new entry. Run `list --id <database>` first unless you set it up in this conversation, so
the field keys you send are the ones it declares. Read the values out of the customer's words.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" add --database-id <database> \
    --content "<the customer's own words, verbatim>" --fields '{"severity":7}' [--entry-name "<name>"]
```

Report the outcome the script prints, not the one you expected: `structured.created` is a new
entry, `structured.updated` means an existing entry changed, and `text.degraded` means the words
were saved as an ordinary memory and the fields were not; say that plainly.

### find

Read the entries of a database, filtered on their fields. Filters are ANDed. On a database with
many fields, `--fields <key>,<key>` returns only the fields the question needs and `--no-note`
leaves out each entry's words, so a page holds more entries; filters and order may use any field.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" find --database-id <database> \
    [--filter <key>=<value>]... [--order "<key> desc"] [--page N] [--page-size N] \
    [--fields <key>,<key>] [--no-note]
```

### correct

Change an entry already saved. Only the fields you send change; the rest keep their values.
`--content` becomes the entry's words, so send the entry as it should now read ("Migraine on
Tuesday after red wine, a 5"), not only the change; the earlier words stay in its history.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" correct --database-id <database> --entry-id <entry> \
    --content "<the entry, as it should now read>" --fields '{"severity":5}'
```

### history

What an entry held before, and when each value changed, oldest first.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" history --database-id <database> --entry-id <entry>
```

### retire

Stop a database collecting new entries. **Nothing is deleted**: every entry stays readable,
searchable and in the customer's export. Say that, because "retire" sounds destructive and is not.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" retire --id <database>
```

### restore

Start a retired database collecting again. Find its id with `list --include-retired`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/database.sh" restore --id <database>
```

## Renaming And Changing Fields

These are not subcommands; ask in plain words. To rename a database, change its description or
the words that help choose it, run `rename-database.sh --id <database> --name "<new name>"`. To add a
field, run `revise-database.sh --id <database> --fields '<the whole field list>'`: read the database
first with `list --id`, because `--fields` replaces the list. Both are described in the memory
skill.
