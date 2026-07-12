# Deployment & keeping the free tier awake

How the backend is hosted, and how we avoid the free-tier cold start.

- **Backend:** Node + Express on **Render** (free plan), deployed from `render.yaml`
  (`rootDir: backend`, `npm start`). Auto-deploys on every push to `main`.
- **Database:** **Neon** Postgres (free plan, 0.5 GB), external — so accounts
  survive Render deploys/restarts.
- **Live URL:** `https://diet-planner-backend-qnux.onrender.com`

---

## The cold-start problem

Render's **free** web service **sleeps after ~15 min idle**; the next request
pays a **30–50 s** wake-up (Node boot + first DB connect). Separately, Neon's
**free** DB **auto-suspends after ~5 min idle**, adding a smaller (~0.5–2 s)
first-query delay.

## The fix — an external cron ping every 10 min

A scheduler hits `/health` every 10 minutes so neither the web service nor the
DB ever goes idle.

`/health` runs a `SELECT 1`, so a single ping keeps **both** warm:

```jsonc
GET /health  →  200 {"ok":true,"db":"up","maxPlanDays":7}   // DB reachable
             →  503 {"ok":false,"db":"down", ...}           // DB unreachable
```

The 503-on-DB-failure means the pinger's "job failed" email doubles as free
**DB-down monitoring**.

### cron-job.org setup (free, no card)

1. Sign up at <https://cron-job.org> and verify your email.
2. **Cronjobs → Create cronjob.**
3. **Title:** `Keep ilAI backend awake`
   **URL:** `https://diet-planner-backend-qnux.onrender.com/health`
4. **Schedule:** every **10 minutes** (`*/10`). Don't go slower than 12 min.
5. **Request method:** GET. Treat HTTP **200** as success.
6. Enable **"Notify me when the job fails"** → free uptime alerts.
7. Save, then **Test run** and confirm a green **200** in History.

> UptimeRobot (5-min interval) works the same way if you prefer an uptime dashboard.

### Caveats

- Render free = **750 instance-hours/month**; one always-awake service (~730 h)
  fits, but you can't keep two free services warm this way.
- The very first request after a fresh deploy is still cold (the pinger hasn't
  run yet) — harmless, affects only you.

---

## Database — is 0.5 GB enough?

**Yes, easily.** The DB stores only two tiny tables — `users` (email, hash,
credits, sub status) and `transactions` (credit/billing ledger). **Generated
diet plans are NOT stored** — they're produced on the fly and returned to the
app. At ~a few KB/user, **0.5 GB ≈ ~100k users**. Storage is not the constraint.

On Neon free the limit that bites first is **compute** (auto-suspend + monthly
compute hours), which the keep-warm ping already helps with.

### If you ever outgrow it (keeps the `pg` driver, little/no code change)

| Option | Free storage | Notes |
| --- | --- | --- |
| **Stay on Neon** | 0.5 GB | Fine. Paid **Launch $19/mo → 10 GB**, zero migration. |
| **CockroachDB Basic** | **10 GB free** | Biggest free jump; Postgres-wire compatible. Not 100% SQL parity (`SERIAL`/sequences, some funcs) — test first. |
| **Supabase** | 500 MB | Bundles auth/storage/realtime. Free projects pause after 1 wk of *no* activity (traffic prevents it). |
| **Aiven for PostgreSQL** | 1 GB | Real managed Postgres, free hobby plan. |
| **Oracle Cloud Always Free** | Huge | Self-host Postgres on the always-free ARM VM; truly free & always-on, but you manage it. |

> **Rule if you add history/images later:** never store **images** in Postgres —
> use object storage (Cloudflare R2 free 10 GB, or Supabase Storage) and keep
> only the URL in the DB. That's what would actually blow past 0.5 GB.

---

## Alternatives to Render (if you want no cold start at all)

| Host | Cold start | Free? | Effort |
| --- | --- | --- | --- |
| **Render Starter** | None (always on) | $7/mo | Zero — just upgrade the plan |
| **Google Cloud Run** | ~1–3 s (0 with `min-instances=1`) | Generous always-free | Add a small Dockerfile |
| **Fly.io** | 0 with `min_machines_running=1` | Small allowance, then cheap | `fly launch` |
| **Oracle Cloud Always Free** | **None — truly always on** | Free forever (ARM) | ~1 hr, you manage a VM |
| **Railway** | None (doesn't sleep) | ~$5/mo usage after trial credit | Easy |

**Avoid** Vercel/Netlify *functions* for this backend: the plan/meal routes call
the LLM for many seconds, and serverless function timeouts + streaming limits
fight a long-running Express server. Keep it as a persistent server.

**Recommendation:** the cron ping fully solves the everyday cold start for free.
If you later want it rock-solid, upgrade to **Render Starter ($7/mo)** or move to
**Cloud Run with `min-instances=1`**.
