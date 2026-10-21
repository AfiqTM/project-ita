// iTa'leem auto-attendance server (Cloudflare Workers, free plan).
// The app sends it: your Moodle token + the list of sessions to auto-submit, each with a 15-minute window.
// The server picks a random moment inside each window and, when it comes, signs in to the website and presses
// "Submit attendance" for you (status: Present). Needed because iOS cannot run the app at an exact time.
//
// Free-plan friendly: the once-a-minute cron only READS from KV; it writes only when a job actually runs.

const UA = "Mozilla/5.0 (Linux; Android 13) MoodleMobile";
const GRACE = 10 * 60 * 1000;         // keep retrying this long after the window ends
const COOLDOWN = 6.5 * 60 * 1000;     // Moodle gives one auto-login key per 6 minutes

const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

export default {
  async fetch(req, env) {
    if (req.headers.get("x-key") !== env.ACCESS_KEY) return json({ error: "bad key" }, 401);
    const url = new URL(req.url);
    if (url.pathname === "/ping") return json({ ok: true, now: Date.now() });

    if (url.pathname === "/sync" && req.method === "POST") {
      const b = await req.json();
      const site = (env.SITE || "").replace(/\/$/, "");
      if (!b.userid || !b.token || !String(b.site || "").startsWith(site)) return json({ error: "bad request" }, 400);
      const id = "u:" + b.userid;
      const old = JSON.parse((await env.STORE.get(id)) || "null") || { jobs: [] };
      const oldByKey = new Map(old.jobs.map(j => [j.key, j]));
      const now = Date.now();
      const jobs = [];
      for (const j of b.jobs || []) {
        const o = oldByKey.get(j.key);
        if (o && o.from === j.from && o.to === j.to) { jobs.push(o); continue; }
        jobs.push({ ...j, fireAt: Math.floor(j.from + Math.random() * (j.to - j.from)), state: "pending", tries: 0 });
      }
      const keep = new Set(jobs.map(j => j.key));
      for (const o of old.jobs) if (!keep.has(o.key) && o.state !== "pending" && o.to > now - 3 * 864e5) jobs.push(o);
      await env.STORE.put(id, JSON.stringify({
        site: site, userid: b.userid, token: b.token, privateToken: b.privateToken || "",
        cookies: old.cookies || null, lastLogin: old.lastLogin || 0, jobs,
      }));
      const idx = JSON.parse((await env.STORE.get("index")) || "[]");
      if (!idx.includes(b.userid)) { idx.push(b.userid); await env.STORE.put("index", JSON.stringify(idx)); }
      return json({ ok: true, scheduled: jobs.filter(j => j.state === "pending").length });
    }

    if (url.pathname === "/sync" && req.method === "DELETE") {
      const uid = url.searchParams.get("userid");
      await env.STORE.delete("u:" + uid);
      const idx = JSON.parse((await env.STORE.get("index")) || "[]").filter(x => String(x) !== uid);
      await env.STORE.put("index", JSON.stringify(idx));
      return json({ ok: true });
    }

    if (url.pathname === "/classify" && req.method === "POST") {
      if (!env.AI) return json({ error: "AI binding missing: add [ai] binding = \"AI\" to wrangler.toml and redeploy" }, 501);
      const b = await req.json();
      const items = (b.items || []).slice(0, 6);
      const results = {}, failed = [];
      await Promise.all(items.map(async it => {
        try { results[it.id] = await classifyOne(env, b.today, it); } catch (e) { failed.push(it.id); }
      }));
      return json({ results, failed });
    }

    if (url.pathname === "/status") {
      const u = JSON.parse((await env.STORE.get("u:" + url.searchParams.get("userid"))) || "null");
      return json({ jobs: (u?.jobs || []).map(({ key, cmid, from, to, fireAt, state, msg }) => ({ key, cmid, from, to, fireAt, state, msg })) });
    }
    return json({ error: "not found" }, 404);
  },

  async scheduled(_e, env, ctx) { ctx.waitUntil(runDue(env)); },
};

async function runDue(env) {
  const idx = JSON.parse((await env.STORE.get("index")) || "[]");
  const now = Date.now();
  for (const uid of idx) {
    const u = JSON.parse((await env.STORE.get("u:" + uid)) || "null");
    if (!u) continue;
    let changed = false;
    const due = [];
    for (const j of u.jobs) {
      if (j.state !== "pending") continue;
      if (now > j.to + GRACE) { j.state = "failed"; j.msg = (j.msg || "Window passed") + " (gave up)"; changed = true; }
      else if (j.fireAt <= now) due.push(j);
    }
    for (const j of due) {
      try {
        const r = await submit(u, j);
        j.tries++;
        if (r.ok) { j.state = "done"; j.msg = r.msg; } else { j.msg = r.msg; }
      } catch (e) { j.tries++; j.msg = "Error: " + e.message; }
      changed = true;
    }
    if (changed) await env.STORE.put("u:" + uid, JSON.stringify(u));
  }
}

// ---------- tiny cookie-aware fetch ----------
function jarHeader(jar) { return Object.entries(jar).map(([k, v]) => k + "=" + v).join("; "); }
function eat(jar, res) {
  const list = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
  for (const c of list) { const [kv] = c.split(";"); const i = kv.indexOf("="); if (i > 0) jar[kv.slice(0, i).trim()] = kv.slice(i + 1).trim(); }
}
async function go(url, jar, init = {}) {
  let method = init.method || "GET", body = init.body;
  for (let i = 0; i < 8; i++) {
    const res = await fetch(url, {
      method, body, redirect: "manual",
      headers: { "user-agent": UA, cookie: jarHeader(jar), ...(init.headers || {}) },
    });
    eat(jar, res);
    const loc = res.headers.get("location");
    if (res.status >= 300 && res.status < 400 && loc) {
      url = new URL(loc, url).toString();
      if (res.status !== 307 && res.status !== 308) { method = "GET"; body = undefined; }
      continue;
    }
    return { url, status: res.status, text: await res.text() };
  }
  throw new Error("too many redirects");
}
const decode = s => s.replace(/&amp;/g, "&").replace(/&#0*38;/g, "&").replace(/&quot;/g, '"').replace(/&#0*39;/g, "'");

async function login(u, jar) {
  if (Date.now() - u.lastLogin < COOLDOWN) throw new Error("waiting for auto-login cooldown");
  u.lastLogin = Date.now();
  const r = await fetch(`${u.site}/webservice/rest/server.php?wstoken=${u.token}&wsfunction=tool_mobile_get_autologin_key&moodlewsrestformat=json`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "user-agent": UA },
    body: "privatetoken=" + encodeURIComponent(u.privateToken),
  });
  const k = await r.json();
  if (!k.key) throw new Error("no auto-login key: " + (k.message || k.error || "token expired? open the app"));
  const target = encodeURIComponent(u.site + "/my/");
  const res = await go(`${k.autologinurl}?userid=${u.userid}&key=${k.key}&urltogo=${target}`, jar);
  if (res.url.includes("/login/")) throw new Error("auto-login was refused");
  u.cookies = { ...jar };
}

const submitLinks = html => {
  const out = [], re = /href="([^"]*attendance\.php\?[^"]*sessid=\d+[^"]*)"/gi; let m;
  while ((m = re.exec(html))) out.push({ href: decode(m[1]), at: m.index });
  return out;
};

async function attendancePage(u, jar, j) {
  for (const extra of ["", "&view=4"]) {
    const res = await go(j.url + extra, jar);
    if (res.url.includes("/login/")) return null;
    if (submitLinks(res.text).length || extra) return res;
  }
  return null;
}

async function submit(u, j) {
  const jar = { ...(u.cookies || {}) };
  let page = Object.keys(jar).length ? await attendancePage(u, jar, j) : null;
  if (!page) { for (const k of Object.keys(jar)) delete jar[k]; await login(u, jar); page = await attendancePage(u, jar, j); }
  if (!page) return { ok: false, msg: "Couldn't open the attendance page" };

  const links = submitLinks(page.text);
  if (!links.length) return { ok: false, msg: "No \"Submit attendance\" link yet (not open, already taken, or not self-submission)" };

  // several sessions on the page: take the one whose row shows today's date
  const d = new Date(j.from + 8 * 3600e3);   // site time (Malaysia, UTC+8)
  const mon = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][d.getUTCMonth()];
  const dayRe = new RegExp(`\\b${d.getUTCDate()}\\s*${mon}`, "i");
  let pick = links[0];
  for (const l of links) {
    const rowStart = page.text.lastIndexOf("<tr", l.at);
    const rowEnd = page.text.indexOf("</tr>", l.at);
    if (rowStart >= 0 && dayRe.test(page.text.slice(rowStart, rowEnd).replace(/<[^>]+>/g, " "))) { pick = l; break; }
  }

  const form = await go(new URL(pick.href, page.url).toString(), jar);
  const f = form.text.match(/<form[^>]*action="([^"]*attendance\.php[^"]*)"[^>]*>([\s\S]*?)<\/form>/i);
  if (!f) return { ok: false, msg: "Submit form not found" };
  const action = new URL(decode(f[1]), form.url).toString();
  const inner = f[2];
  if (/name="studentpassword"/i.test(inner)) return { ok: false, msg: "This session needs a password; auto-submit can't do that", fatal: true };

  const fields = [];
  let status = null, firstRadio = null, m;
  const inputRe = /<input\b[^>]*>/gi;
  while ((m = inputRe.exec(inner))) {
    const t = m[0];
    const attr = n => (t.match(new RegExp(`\\b${n}="([^"]*)"`, "i")) || [])[1];
    const type = (attr("type") || "text").toLowerCase(), name = attr("name"), value = decode(attr("value") || "");
    if (!name) continue;
    if (type === "hidden") fields.push([name, value]);
    else if (type === "submit") fields.push([name, value || "Submit"]);
    else if (type === "radio" && name === "status") {
      if (!firstRadio) firstRadio = value;
      const id = attr("id");
      let label = "";
      if (id) { const lm = inner.match(new RegExp(`<label[^>]*for="${id}"[^>]*>([\\s\\S]*?)</label>`, "i")); if (lm) label = lm[1]; }
      if (!label) label = inner.slice(m.index + t.length, m.index + t.length + 120);
      if (!status && /present/i.test(label.replace(/<[^>]+>/g, " "))) status = value;
    }
  }
  const chosen = status || firstRadio;
  if (!chosen) return { ok: false, msg: "No status options on the form" };
  fields.push(["status", chosen]);

  const post = await go(action, jar, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: fields.map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&"),
  });
  if (post.status >= 400) return { ok: false, msg: "Site answered " + post.status };

  // verify: the link for this session should be gone
  const after = await attendancePage(u, jar, j);
  const sess = pick.href.match(/sessid=(\d+)/)[1];
  if (after && submitLinks(after.text).some(l => l.href.includes("sessid=" + sess))) {
    return { ok: false, msg: "Sent, but the site still shows the Submit link" };
  }
  return { ok: true, msg: "Submitted at " + new Date().toISOString() };
}

// ---------- Daily Info: read one announcement with Workers AI ----------
const KINDS = ["cancelled", "online", "venue", "rescheduled", "note"];
const SCHEMA = {
  type: "object",
  properties: {
    changes: {
      type: "array",
      items: {
        type: "object",
        properties: {
          kind: { type: "string", enum: KINDS },
          classDate: { type: "string" },
          startTime: { type: "string" },
          newDate: { type: "string" },
          newStartTime: { type: "string" },
          venue: { type: "string" },
          summary: { type: "string" },
        },
        required: ["kind", "summary"],
      },
    },
  },
  required: ["changes"],
};

const SYSTEM = `You read a university lecturer's announcement and list ONLY changes to a scheduled class, lab, tutorial, test or exam.
Kinds: "cancelled" (class will not be held), "online" (class moved online; venue = platform such as Zoom), "venue" (same time, different room; venue = the new room), "rescheduled" (moved to another day or time), "note" (short schedule-related notice that fits none of the others, e.g. bring a laptop to the next class).
Rules:
- Ignore assignments, grades, deadlines, reading material and anything that is not about when/where/how a class meets. If there is nothing, return {"changes": []}.
- Dates are YYYY-MM-DD. Times are 24-hour HH:MM. Work out relative dates ("tomorrow", "next Monday") from the posted date given. Malaysian dates are day first (05/10 = 5 October).
- classDate/startTime = the original class. For "rescheduled", newDate/newStartTime = where it moved to. For other kinds leave newDate and newStartTime empty.
- Leave a field as "" when the announcement does not say it. Never guess.
- summary: one short sentence in English.`;

async function classifyOne(env, today, it) {
  const user = `Today: ${today}\nSubject: ${it.course}\nPosted: ${it.posted}\nTitle: ${it.title}\n\n${String(it.text || "").slice(0, 3000)}`;
  const out = await env.AI.run(env.AI_MODEL || "@cf/meta/llama-3.1-8b-instruct", {
    messages: [{ role: "system", content: SYSTEM }, { role: "user", content: user }],
    response_format: { type: "json_schema", json_schema: SCHEMA },
    max_tokens: 600,
    temperature: 0,
  });
  let r = out && out.response;
  if (typeof r === "string") {
    const m = r.match(/\{[\s\S]*\}/);
    r = JSON.parse(m ? m[0] : r);
  }
  if (!r || !Array.isArray(r.changes)) throw new Error("bad AI answer");
  return r.changes.filter(c => c && KINDS.includes(c.kind)).slice(0, 4);
}
