# PULSE — Mobikwik UPI Analytics Agent

**Interview deliverable · Director, Data Products · Varun Rustagi · May 2026**

This folder contains my response to the assignment: *design an LLM-powered conversational analytics agent that sits on a semantic layer over Mobikwik's UPI business*.

## What's in this folder

| File | What it is | Read in this order |
|---|---|---|
| `00_README.md` | This file | 1 |
| `01_Strategy_UPI_Analytics_Agent.md` | The strategy / architecture document — main artifact | 2 |
| `04_Metric_Catalogue_v1.yaml` | First 25 KPIs as code (referenced from §3.4 of the strategy doc) | 3 |
| `02_Sample_UPI_Database.sql` | Full DDL + seed data for raw layer + cleaned dims + marts + semantic views. Loads end-to-end into SQLite. | 4 |
| `03_PULSE_Prototype.html` | **Interactive prototype** — open this in any browser. Mirrors the conversational UI with 11 demo prompts, query-trace expanders, result tables, and "so-what" insights. | 5 — *demo this live* |
| `05_Presenter_Cheatsheet.md` | One-page talking notes for the panel session (for Varun's eyes — not for the panel) | for me |

## How to run / verify

**Strategy doc:** open `01_*.md` in any markdown viewer.

**Database:**
```bash
sqlite3 upi_demo.db < 02_Sample_UPI_Database.sql
sqlite3 upi_demo.db "SELECT * FROM vw_upi_kpi_daily ORDER BY dt DESC LIMIT 7;"
```

**Prototype:** double-click `03_PULSE_Prototype.html`. No server, no build, no API keys. Click suggested prompts or type your own — the agent matches against ~10 built-in answers covering volume, reliability, mix, risk, disputes, and a clarifying-question demo.

## Three things to look at in the prototype

1. **The DAX/SQL trace** that unfolds before each answer — that's the metric-server-compiled query, not LLM-written SQL.
2. **The "so-what" callout** under every table — what the analyst would say if asked at standup.
3. **Try the prompt "Show me success rate for HDFC"** — PULSE refuses to guess between payer-side and payee-side, and asks a clarifying question instead. That's the most important behavior in the system.
