# Ad Library Access

Every Meta Ad Library call in this repo goes through **one helper**: `scripts/adlib.sh`.

There is no Apify account, no `APIFY_TOKEN`, and no Apify MCP server. The helper calls a
Relevance AI tool ("Meta Ad Library Scraper") over plain HTTPS. Relevance runs the Apify
actors on **its own platform key** and bills Relevance credits to whoever owns the API key
in `.env`.

## Setup

Four values in `.env`:

```
RELEVANCE_API_KEY=sk-...
RELEVANCE_PROJECT=<project id>
RELEVANCE_REGION=f1db6c
RELEVANCE_ADLIB_STUDIO_ID=ef522aa0-5a0c-4847-83de-b1220de49a08
ADLIB_MAX_RECORDS=50
```

`ADLIB_MAX_RECORDS` is the per-run ceiling on returned records. It defaults to **50** to
protect credits and can be raised up to an absolute maximum of 250. A value set in the
environment wins over `.env`, so a one-off override works:

```bash
ADLIB_MAX_RECORDS=150 scripts/adlib.sh scrape_ads --page-url <url> --limit 150
```

## The three operations

```bash
# Pull a competitor's ads (active + historical)
scripts/adlib.sh scrape_ads --page-url https://www.facebook.com/SHEINOFFICIAL --limit 100

# Same, from an Ad Library page id
scripts/adlib.sh scrape_ads --page-id 380039845369159 --limit 100

# Turn Facebook page URLs into Ad Library page ids (up to 25 at a time)
scripts/adlib.sh resolve_page --urls "https://www.facebook.com/a/,https://www.facebook.com/b/"

# Find pages in a niche that are running ads
scripts/adlib.sh discover --query "boxing gym" --location "Belfast" --limit 20
```

Prefer `--page-url` over `--page-id`. Verified behaviour: the Ad Library `view_all_page_id`
URL form frequently returns an empty result set for pages that *do* have ads, while the
plain page URL returns them.

## Output

One JSON object on stdout:

```json
{
  "records": [ ... ],
  "count": 2,
  "limit_notice": null,
  "max_records": 50,
  "total_scraped": 10,
  "total_available": null,
  "actor_errors": [],
  "operation": "scrape_ads",
  "actor_used": "apify/facebook-ads-scraper",
  "credits_cost": 6.6
}
```

`count` is what you got back. `total_scraped` is what the actor actually fetched and billed --
it can be higher, because some scrapers refuse to run below a floor of 10 results.

`limit_notice` is `null` unless the per-run ceiling actually bit. When it does, it reads:

```
Requested 200 records but this run is capped at 50. This is a configurable limit --
raise ADLIB_MAX_RECORDS in .env (absolute maximum 250).
```

The helper also prints that line to stderr, so it is visible without parsing the JSON.

`actor_errors` is non-empty when the scraper itself reported a problem (for example
`no_items: Empty or private data for provided input`). An empty `records` array with an
empty `actor_errors` means the page genuinely has no ads in the Library.

### `records` for `scrape_ads`

The tool normalises every scraper into one shape, so there is exactly **one** field mapping
to maintain no matter which actor ran:

| Field | Notes |
|---|---|
| `ad_archive_id` | String. Primary dedup key. |
| `ad_library_url` | Built from the archive id. |
| `page_name`, `page_id` | |
| `is_active` | Boolean. |
| `start_date`, `end_date` | ISO 8601. Drives the Days Active grade. |
| `display_format` | `VIDEO` / `IMAGE` / `DPA` / `CAROUSEL`. |
| `body_text` | Primary text. |
| `title` | `null` when the ad used a `{{product.name}}`-style placeholder. |
| `cta_type`, `cta_text`, `link_url` | |
| `video_url`, `image_url` | For DPA/carousel these fall back to the first card. |
| `publisher_platforms`, `page_categories` | Arrays. |
| `impressions_rank` | Position in the result set. |
| `cards[]` | Carousel/DPA children: `body`, `title`, `cta_type`, `image_url`, `video_url`, `link_url`. |
| `extra_texts[]` | Additional DCO copy variants. |

### `records` for `resolve_page`

`page_url`, `ad_library_id`, `title`, `website`, `category`, `followers`, `ad_status`,
`is_running_ads`.

Use `ad_library_id` as the Page ID everywhere. It is **not** the profile id.

### `records` for `discover`

`name`, `page_url`, `category`, `followers`, `ad_status`, `is_running_ads`.

> **`discover` is best-effort and currently unreliable.** The upstream
> `apify/facebook-search-scraper` actor returns
> `no_items: Empty or private data for provided input` most of the time, including for its
> own documented example inputs. It has been observed working, so the input format here is
> correct -- the actor itself is intermittent, most likely because Facebook blocks the
> shared proxy pool it uses.
>
> Treat competitor discovery as a convenience. When it returns nothing, ask the user for
> competitor Facebook page URLs directly and run `resolve_page` on them. `scrape_ads` and
> `resolve_page` -- the two operations the pipeline actually depends on -- are reliable.

## Retries

If `scrape_ads` errors, retry the same page with a different scraper:

```bash
scripts/adlib.sh scrape_ads --page-url <url> --variant fallback1
scripts/adlib.sh scrape_ads --page-id  <id>  --variant fallback2   # needs --page-id
```

## Cost

Roughly **3.3 Relevance credits per ad** returned, plus 3 credits base per run. A 100-ad
scrape is around 330 credits. `--limit` is clamped to `ADLIB_MAX_RECORDS` (default 50, absolute maximum 250) and floored at
10 when talking to the actor, because some scrapers refuse to run below that. Extra rows are
trimmed before you see them, so `count` honours your limit while `total_scraped` shows what was
actually fetched and billed. At roughly 3.3 credits per ad, the default ceiling puts a single
run at about 165 credits worst case. Keep limits tight on
daily polls: after the first backfill, daily runs only need to catch new ads.
