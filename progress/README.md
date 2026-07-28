# Progress entries

This directory is the project progress log. Each completed branch adds one
entry file. Do not edit another branch's entry unless you correct its record.

Use [TEMPLATE.md](TEMPLATE.md) for each new entry. Name the file with the
commit timestamp and a short slug:

`YYYY-MM-DDTHHMMSSZ-short-description.md`

Use UTC in the filename. Lexical ascending order gives oldest first. Reverse
lexical order gives newest first.

The migrated entries keep their original narrative. Their front matter records
the Git commit timestamp. If Git has no matching commit, the entry records a
synthetic migration-order timestamp.
