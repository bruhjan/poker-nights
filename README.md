# Poker Nights

A live ledger for a home poker game. Track buy-ins (and negative buy-ins), chip counts at the end, and who pays whom. Keeps history, player profiles and an all-time leaderboard across groups.

**Live app:** https://bruhjan.github.io/poker-nights/

## How it works

- No accounts. Each group has two links:
  - **Watch link** (`#/g/<code>`): anyone with it sees the table live, read-only.
  - **Edit link** (`#/g/<code>/<secret>`): anyone with it can add buy-ins and chip counts. Share it only with players.
- Open a link once and the group is remembered on that phone. The group menu switches between groups.
- Changes show up on every open phone within a second or two.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole app. Preact + htm and supabase-js load from CDNs, so there is no build step. |
| `schema.sql` | Database tables and functions. Run once in the Supabase SQL editor. |

## Security

- The tables have row level security on and no direct access for the browser. Every read and write goes through a database function.
- Reads need the group's code. Writes need the code and the edit secret.
- The key in `index.html` is Supabase's **publishable** key. It is meant to be public; it only lets the browser call the functions above.
- Anyone with an edit link can change that group. If an edit link leaks, rotate it in the SQL editor:
  ```sql
  update pn_groups set edit_secret = pn_rand(24) where code = '<code>';
  select edit_secret from pn_groups where code = '<code>';
  ```

## Running your own copy

1. Create a Supabase project and run `schema.sql` in its SQL editor.
2. In `index.html`, set `SUPABASE_URL` and `SUPABASE_KEY` (Project Settings, API Keys, publishable key).
3. Push to GitHub and enable Pages (Settings, Pages, deploy from the `main` branch, root folder).

## Notes

- Supabase's free plan pauses a project after about a week with no activity. If the app says it can't connect, open the Supabase dashboard and restore the project.
- Money is whole rupees.
