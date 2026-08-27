# n8n Automated Ad Poller

Runs daily at 6am. Scrapes all your tracked competitors from Meta Ad Library, deduplicates against your existing swipe file, calculates Days Active and Longevity Tier, and pushes new ads to Airtable automatically.

## Default Setup

The workflow ships with **Alex Hormozi** as the default aspirational hook farm. He tests 200 ads at any time -- the Long-Runners are proven winners.

**Cost warning:** Hormozi has 2000+ ads in the Ad Library. The first scrape pulls all of them (~330 Relevance credits per 100 ads). After that, daily runs only find new ads so costs drop sharply. Cost scales with ads returned, so keep `MAX_ADS` tight on daily runs.

You can add or change competitors anytime by editing your Competitors table in Airtable. The workflow scrapes whatever is there.

## Setup (5 minutes)

### 1. Import the workflow

- Open your n8n instance
- Go to Workflows > Import from File
- Select `ad-poller-workflow.json`

### 2. Set your credentials

**Airtable:**
- Go to n8n Credentials > Add New > Airtable Personal Access Token
- Paste your Airtable PAT
- Name it "Airtable Token"

**Relevance AI** (this is what scrapes the Ad Library -- there is no Apify account):
- In n8n, go to Settings > Variables (or use Environment Variables)
- Add `RELEVANCE_API_KEY` = your Relevance AI API key (starts with `sk-`)
- Add `RELEVANCE_PROJECT` = your Relevance AI project id
- Add `RELEVANCE_REGION` = your region code (e.g. `f1db6c`)
- Add `RELEVANCE_ADLIB_STUDIO_ID` = `ef522aa0-5a0c-4847-83de-b1220de49a08`

### 3. Update the placeholder IDs

Open the workflow and update these in the Airtable nodes:

| Placeholder | Where to find it |
|---|---|
| `YOUR_AIRTABLE_BASE_ID` | Airtable > Your base URL contains `app...` |
| `YOUR_COMPETITORS_TABLE_ID` | Airtable > Table URL contains `tbl...` |
| `YOUR_SWIPE_FILE_TABLE_ID` | Airtable > Table URL contains `tbl...` |

These appear in 3 nodes: "Read Competitors", "Read Existing Ads", and "Write to Airtable".

### 4. Add Hormozi to your Competitors table

Add this row to your Competitors table in Airtable:

| Name | Facebook Page ID | Niche Tier | Status |
|---|---|---|---|
| Alex Hormozi | 116482854782233 | Aspirational | Active |

Want more? Add any competitor -- just need their name and Ad Library Page ID. Run `/ads-setup` in Claude Code to auto-resolve Page IDs from Facebook URLs.

### 5. Activate

Toggle the workflow ON. It runs daily at 6am. You can also trigger it manually anytime.

## How it works

```
Daily 6am
  |
  v
Read active competitors from Airtable
  |
  v
Read existing ads (for dedup)
  |
  v
For each competitor: build Ad Library URL
  |
  v
Call the Relevance Ad Library tool (active + inactive ads, sorted by impressions)
  |
  v
Dedup, calculate Days Active, assign Longevity Tier
  |
  v
Push new ads to Airtable in batches of 10
```

## Longevity Tiers (auto-calculated)

| Days Active | Tier |
|---|---|
| 60+ | Long-Runner (proven winner) |
| 30-59 | Performer |
| 14-29 | Solid |
| 7-13 | Testing |
| <7 | Killed |

## Changing competitors

Just edit your Competitors table in Airtable. The workflow reads it fresh every run. Add rows, change status to "Paused" to skip, or remove them entirely.

To add a new competitor without knowing their Page ID, run `/ads-setup` or `/ad-poller` in Claude Code -- it auto-resolves Page IDs from Facebook page URLs.

## Optional: Add Slack alerts

Add a Slack node after "Write to Airtable" to get a daily summary in your channel. Use the "Build Summary" node output for the message.

## Customization

- **Change scrape time:** Edit the cron in "Daily 6am" node (e.g. `0 9 * * *` for 9am)
- **Change country:** In "Build Scrape URLs" code node, change `const COUNTRY = 'ALL'` to `'GB'`, `'US'`, etc.
- **Change max ads per competitor:** In the same code node, change `const MAX_ADS = 50`
- **Run twice daily:** Change cron to `0 6,18 * * *`
