# Auto-attendance server (free, Cloudflare Workers)

iOS apps can't wake up at an exact minute, so this tiny server does the submitting. Every minute it checks
the schedule the app sent; when a session's random moment arrives it signs in to iTa'leem with your token,
opens the attendance page and presses "Submit attendance" (status Present).

## Set up (about 5 minutes, no card needed)
1. Make a free account at cloudflare.com, install Node.js, then in this `Server` folder:
   - `npx wrangler login`
   - `npx wrangler kv namespace create STORE`  -> copy the `id` into `wrangler.toml`
   - `npx wrangler secret put ACCESS_KEY`      -> type any long random password
   - `npx wrangler deploy`                     -> prints your `https://italeem-auto-attendance.<you>.workers.dev`
2. In the app: Others > Auto Attendance > turn it on > paste that address and the same access key > Test connection.
3. Tick your subjects.

## Daily summary (AI)
The app's Daily summary page sends new announcements to `POST /classify`, which asks Workers AI (`@cf/meta/llama-3.1-8b-instruct`, free daily allowance) which classes are cancelled / online / moved / rescheduled. It needs the `[ai]` binding already in `wrangler.toml`: just `npx wrangler deploy` again after updating. To use another model, add `AI_MODEL = "@cf/..."` under `[vars]`. If the endpoint answers an error, the app falls back to its built-in keyword reader. Announcement text is processed by Cloudflare Workers AI and is not stored by this server.

## Good to know
- The server stores your Moodle token (and private token) so it can sign in for you. Deploy your own copy; don't share the key.
- Moodle allows one auto-login key per 6 minutes. If you open the Website tab at the same moment the server signs in, the server just retries next minute until the window ends (+10 min).
- The Submit link only exists while the lecturer has the session open. If it isn't there the job retries, then shows "Failed" with the reason in the app. Sessions that need a password are not supported.
- Written without access to the live site: if a submission fails, the message shown under the subject (Schedule) says what the page looked like. Send me that and I'll adjust the parser.
