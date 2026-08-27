---
name: ad-poller
description: Scrape all competitor ads from the Meta Ad Library. Detects new ads, flags 30d+ validated winners, marks killed ads, and sends Slack alerts. Run daily or manually.
---

# Daily Ad Poller

You are a competitive ad intelligence scraper. You pull every active Meta ad from tracked competitors, dedup against existing records, update longevity tiers, and push new ads to the Ad Swipe File.

**What you produce:** New competitor ad records in Airtable with copy, media URLs, and metadata -- ready for `/ad-analyzer` to enrich.

---

## Prerequisites

1. **Airtable MCP** connected (run `/ads-setup` if not)
2. **Relevance AI credentials** in `.env` (`RELEVANCE_API_KEY`, `RELEVANCE_PROJECT`). No Apify account needed -- see [`docs/ad-library-access.md`](../../docs/ad-library-access.md)
3. **Competitors table** populated with at least 1 competitor with a Facebook Page ID
4. **CLAUDE.md** configured with Airtable base ID and table IDs

---

## Config

Read these from CLAUDE.md:

```
Airtable Base ID: YOUR_AIRTABLE_BASE_ID
Competitors Table: YOUR_COMPETITORS_TABLE_ID
Ad Swipe File Table: YOUR_SWIPE_FILE_TABLE_ID
```

---

## Step 1: Load Active Competitors

Fetch all records from Competitors table where `Status = Active`:

```
Use Airtable MCP: list_records
  base_id: {from CLAUDE.md}
  table_id: {Competitors table ID}
  filter: {Status} = 'Active'
  fields: Name, Facebook Page ID
```

Each competitor MUST have a `Facebook Page ID`. Skip any without one and warn the user.

Print the competitor list:
```
Found {N} active competitors:
  1. {Name} ({Page ID})
  2. {Name} ({Page ID})
  ...
```

If no competitors found, tell the user to populate the Competitors table first or run `/ads-setup`.

---

## Step 1b: Resolve Page IDs (if needed)

If any competitor has a Facebook Page URL but no numeric Page ID, resolve it. Batch up to 25
URLs per call:

```bash
scripts/adlib.sh resolve_page --urls "https://www.facebook.com/{slug1}/,https://www.facebook.com/{slug2}/"
```

Each record in `records[]` gives you:

- `ad_library_id` -- **this is the Page ID to store.** It is not the profile id; the helper
  already picks the right one for you.
- `title` -- confirmed page name
- `is_running_ads` -- boolean, already handles the "isn't currently running ads" wording
- `website`, `category`, `followers` -- useful metadata

Update the Competitors table with `ad_library_id`.

If a page cannot be resolved, tell the user to find it manually: facebook.com/ads/library >
search the page name > copy `view_all_page_id=` from the URL.

---

## Step 2: Scrape Each Competitor

For each competitor, scrape ALL ads (active + inactive/historical) from the Meta Ad Library.

```bash
scripts/adlib.sh scrape_ads --page-url {PAGE_URL} --limit 100
```

**Prefer `--page-url`.** If you only have the Ad Library id, use `--page-id {PAGE_ID}` instead --
but the page URL is measurably more reliable: the `view_all_page_id` URL form often returns an
empty result set for pages that do have ads.

The helper handles the actor, the Ad Library URL, active+historical status, impression sorting,
and result normalisation. It prints one JSON object -- see
[`docs/ad-library-access.md`](../../docs/ad-library-access.md) for the full contract.

### Retries

If a scrape returns a non-empty `actor_errors`, retry the same competitor with another scraper:

```bash
scripts/adlib.sh scrape_ads --page-url {PAGE_URL} --limit 100 --variant fallback1
scripts/adlib.sh scrape_ads --page-id  {PAGE_ID}  --limit 100 --variant fallback2
```

`fallback2` requires `--page-id`. Log which variant succeeded for each competitor.

### Scraping rules

- Run competitors in sequence, not parallel
- Each scrape takes roughly 30-120 seconds depending on ad count
- Print progress after each: `[{N}/{total}] {Name}: {count} ads scraped`
- An empty `records[]` with an empty `actor_errors` means the page genuinely has no ads in the
  Library -- that is not a failure, do not retry it
- Runs are capped at `ADLIB_MAX_RECORDS` records (default 50). If a scrape comes back with a
  `limit_notice`, relay it to the user verbatim -- it tells them the cap is configurable and how
  to raise it. Do not silently raise it yourself
- Keep `--limit` tight on daily polls. Cost is roughly 3.3 Relevance credits per ad returned

---

## Step 3: Dedup Against Existing Records

Before inserting, fetch existing Ad Archive IDs from the Swipe File:

```
Use Airtable MCP: list_records
  base_id: {from CLAUDE.md}
  table_id: {Swipe File table ID}
  fields: Ad Archive ID, Status, Start Date, Ad Active Status
```

Build a set of existing Ad Archive IDs.

**Dedup logic:**
- Ad in new scrape but NOT in Airtable = INSERT as new record
- Ad in new scrape AND already in Airtable = update `Ad Active Status` if changed (active -> inactive or vice versa), otherwise skip
- Ad in Airtable (Status = Active) but NOT in any new scrape AND was previously active = mark `Status` -> `Killed`, set `End Date` to today

**IMPORTANT:** When scraping with `active_status=all`, the source data includes both active and inactive ads. The `Ad Active Status` field tracks the Meta status. The `Status` field tracks YOUR status (Active, Killed, Winner, Starred). These are different things:
- `Ad Active Status` = what Meta says (Active or Inactive)
- `Status` = your classification (Active in swipe file, Killed from swipe file, Winner, Starred)

---

## Step 4: Transform and Insert New Ads

For each new ad, transform a record from `records[]` into an Airtable record.

The helper normalises every scraper into one shape, so there is a single mapping regardless of
which actor ran:

| Swipe File Field | Source | Notes |
|-----------------|--------|-------|
| Ad Archive ID | `ad_archive_id` | String. Primary dedup key. |
| Competitor | Competitor name from your table | Not in the scrape output -- you add this |
| Page Name | `page_name` | |
| Ad Library URL | `ad_library_url` | Already constructed |
| Status | `Active` | Your classification -- always start as Active |
| Ad Active Status | `is_active` (boolean) | `true` = Active, `false` = Inactive. Convert to text |
| Start Date | `start_date` | ISO 8601 |
| End Date | `end_date` | ISO 8601 |
| Display Format | `display_format` | `VIDEO`, `IMAGE`, `DPA`, `CAROUSEL`. Map to title case |
| Body Text | `body_text` | Full ad copy |
| Title | `title` | Already `null` when the ad used a `{{product.name}}` placeholder |
| CTA Type | `cta_type` | e.g. `LEARN_MORE`, `SIGN_UP` |
| CTA Text | `cta_text` | e.g. `Learn more` |
| Link URL | `link_url` | |
| Video URL | `video_url` | Already falls back through HD -> SD -> first card |
| Image URL | `image_url` | Already falls back to the first card for carousel/DPA |
| Publisher Platforms | `publisher_platforms` | Array |
| Impressions Rank | `impressions_rank` | Position in the result set |
| Word Count | Count words in `body_text` | |
| Hook Copy | First line of `body_text` (up to first period or newline) | |
| Scrape Date | Today's date | |
| Scrape Batch ID | `{competitor_name}-{YYYY-MM-DD}` | |
| Is Analyzed | false | |

**DPA / DCO ads:** when `display_format` is `DPA` or `DCO`, Meta assembles the creative
dynamically and `title` comes back `null`. The real copy is in `cards[]` and `extra_texts[]`.
Read `cards[].body` and `cards[].title` first, then `extra_texts[]`.

**Carousel ads:** each entry in `cards[]` has its own `body`, `title`, `cta_type`, `image_url`,
`video_url`, `link_url`.

Only send fields that have values. Do not send null or empty fields.

**Insert in batches of 10** (Airtable limit per request).

Only send fields that have values. Do not send null or empty fields.

---

## Step 5: Update Longevity Tiers

After all inserts, recalculate longevity tiers for ALL active ads in the Swipe File:

```python
from datetime import date

today = date.today()
for ad in all_ads:
    end = ad.end_date or today  # Active ads use today
    days = (end - ad.start_date).days
    if days >= 60:
        tier = "Long-Runner"
    elif days >= 30:
        tier = "Performer"
    elif days >= 14:
        tier = "Solid"
    elif days >= 7:
        tier = "Testing"
    else:
        tier = "Killed"
    ad.longevity_tier = tier
    ad.days_active = days
```

**Days Active IS the grade.** No composite scoring. The market already graded every ad by how long the advertiser kept spending on it. Everything else (format, angle, hook, CTA) is a filter for browsing, not a scoring factor.

Update records in batches of 10 where the tier has changed.

---

## Step 6: Slack Alert (Optional)

If `SLACK_WEBHOOK_URL` is configured in `.env` or Slack MCP is connected, send a daily summary:

```
Ad Poller Complete

{N} competitors scraped
{new_count} new ads found
{killed_count} ads killed (disappeared)
{winner_count} validated winners (30d+)

Top new hooks:
1. "{first line of highest word-count new ad}"
2. "{second}"
3. "{third}"

Run /ad-analyzer to process {unanalyzed_count} unanalyzed ads.
```

If Slack is not configured, skip this step silently.

---

## Step 7: Print Summary

```
=== Ad Poller Complete ===

Competitors scraped: {N}
Total ads found: {total}
  New ads added: {new}
  Already existed: {existing}
  Marked killed: {killed}

Longevity breakdown:
  Long-Runners (60d+): {count} -- PROVEN WINNERS
  Performers (30-59d): {count}
  Solid (14-29d): {count}
  Testing (7-13d): {count}
  Killed (<7d): {count}

By competitor:
  {Name}: {count} ads ({video} video, {image} image, {dco} DCO)
  ...

Unanalyzed ads: {count}
Next step: Run /ad-analyzer to transcribe and classify new ads.
```

---

## CRITICAL RULES

1. **All Ad Library access goes through `scripts/adlib.sh`.** Never call Apify directly and never ask the user for an Apify token -- there isn't one. The scraper runs on Relevance's platform key.
2. **Active and historical ads are both pulled by default.** Inactive ads that ran 60+ days are proven winners, so never filter them out.
3. **Dates arrive as ISO 8601 strings.** The helper normalises unix timestamps for you.
4. **DPA/DCO ads may have no top-level media.** The helper falls back to the first card. Still insert the record -- the copy is useful.
5. **Dedup on Ad Archive ID.** Same ad can appear in multiple scrapes.
6. **Airtable batch limit is 10 records per request.** Always batch creates and updates.
7. **Facebook Page ID vs Profile ID:** The Competitors table stores the Ad Library page ID, NOT the profile ID. Use `scripts/adlib.sh resolve_page` and store the `ad_library_id` it returns.
8. **Run competitors in sequence.** Parallel scraping hits upstream rate limits.
9. **Never delete records.** Mark killed ads as Killed with an End Date. History matters.
10. **Ad Active Status vs Status:** `Ad Active Status` is what Meta reports (Active/Inactive). `Status` is your swipe file classification (Active, Killed, Winner, Starred). An ad can be `Ad Active Status = Inactive` but `Status = Winner` -- that means it ran successfully and was turned off after scaling.
11. **If a scrape reports `actor_errors`**, retry once, then `--variant fallback1`, then `--variant fallback2` (which needs `--page-id`). Log which variant worked. An empty `records[]` with no errors is not a failure.
12. **Fallback if every scraper is down:** browse the Meta Ad Library at facebook.com/ads/library and add records to the Swipe File via Airtable directly. The rest of the pipeline (analyzer, ideator, scripter) still works.
