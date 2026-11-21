# Changelog

All changes to the standalone Printer Buddy AI, newest first.

################################2026-11-20 sterling m fix################################

## Simpler service stop

The init.d `stop` case uses a single `pkill -f pb_ai.py` instead of two separate patterns. *Why:* one pattern reliably matches the process.

Lines changed:
- `install.sh` — 86 collapse the two `pkill` patterns into one

################################end of entry################################
