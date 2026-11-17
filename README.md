# NBA Rebounding RAPM

An independent basketball analytics project in R estimating players' adjusted contributions to **team offensive and defensive rebound recovery**. Each player receives separate offensive and defensive ratings, accounting for the other players on court and selected shot context.

[Explore the interactive dashboard](https://hclark36.github.io/RAPM-Offense-Defensive-Rebounds/) · [View Mitchell Robinson](https://hclark36.github.io/RAPM-Offense-Defensive-Rebounds/#player=1629011)

The dashboard is a published snapshot of the historical results. Running the R pipeline creates local results. Rebuild the HTML with `source("scripts/build_dashboard.R")`, then commit and push `docs/index.html` to update GitHub Pages.

## Research question

Which players are associated with better team recovery of missed shots, after accounting for teammates, opponents, and context? Counting individual rebounds can miss contributions such as boxing out so a teammate can recover the ball. This model uses the team's recovery outcome while each player is on court.

## Data and evaluation design

The completed run covers 3,690 regular-season games and 342,325 eligible missed-field-goal opportunities.

| Split | Season | Games | Opportunities | Purpose |
| --- | --- | ---: | ---: | --- |
| Training | 2023–24 | 1,230 | 112,991 | Fit coefficients |
| Validation | 2024–25 | 1,230 | 114,960 | Select ridge penalties |
| Test | 2025–26 | 1,230 | 114,374 | Evaluate frozen models |

Source records are NBA event-level play-by-play, with a schedule and player catalogue from the SportsDataverse archive. They are not frame-by-frame tracking or Synergy data. See [data documentation](data/README.md) for sources, lineup reconstruction, filters, and reference corrections.

## Model

Each retained recovery is one row. The response is `oreb = 1` if the offense recovers the miss and `0` if the defense recovers it. Five offensive player indicators receive `+1`; five defensive indicators receive `-1`. Each player has a separate coefficient in each role.

The context-adjusted model also includes whether the missed shot was a three-pointer, whether it was blocked, and whether the offense was at home. A linear ridge model minimizes:

```text
sum((oreb - prediction)^2) + penalty * sum(player_coefficients^2)
```

The intercept and context coefficients are unpenalized. Candidate penalties are selected separately for lineup-only and context-adjusted RAPM using validation Brier score; exact ties favor the larger penalty. Test outcomes are not used to fit or select the frozen models.

After testing, a **separate descriptive historical model** is fitted across all three seasons. Its penalty is scaled by the ratio of all-data to training observations. Reports and dashboard player ratings use this historical refit; the reported test scores belong to the frozen training models.

### Reading a player rating

Ratings are multiplied by 100 and centered separately within each role using opportunity weights. Positive is better in both roles. A rating of `+3.45` means an estimated 3.45 additional **team recoveries per 100 eligible missed-shot opportunities**, relative to the modeled average player in that role.

The denominator is eligible misses, not all shots or offensive possessions. Offensive rebounds generally extend existing possessions. Raw on-floor team recovery percentages are not individual rebound percentages or adjusted effects. Season summaries show raw rates, not separately fitted seasonal RAPM.

A minimum of 500 opportunities in a role is required for its displayed rank. This does not exclude low-exposure players from fitting. A player absent from training receives zero raw player coefficients when predicting held-out opportunities.

## Held-out results

Lower Brier score and log loss are better. Results below are from the completed 2025–26 test evaluation.

| Model | Brier score | Log loss |
| --- | ---: | ---: |
| Training recovery average | 0.2098564 | 0.6106730 |
| Context only | 0.2082234 | 0.6070172 |
| Lineup RAPM | 0.2090664 | 0.6087979 |
| Context-adjusted RAPM | **0.2074319** | **0.6051035** |

Context-adjusted RAPM reduced Brier score by approximately 0.38% relative to context only. The difference was −0.0007915, with a whole-game bootstrap 95% interval of [−0.0009689, −0.0006070] from 2,000 resamples. This interval is conditional on the fitted models and is not a player-rating uncertainty interval.

The primary model predicted a mean offensive recovery rate of 28.11%, versus 29.88% observed: an underprediction of 1.77 percentage points. None of its test predictions were outside [0, 1].

Mitchell Robinson's three-season historical offensive rating is +3.45 across 2,214 opportunities, ranking fourth among 546 eligible offensive players. This is a descriptive association, not a guaranteed effect in another lineup.

## Run the project

Clone the repository and open `NBA-Rebounding-RAPM.Rproj` in RStudio. Run commands from the repository root. R and internet access are required; no Python runtime is used. Setup checks or installs `jsonlite`, `arrow`, `curl`, `digest`, `Matrix`, and `ggplot2`, and adds the project-local `.Rlib` to the library search path.

Set seasons, candidate penalties, the default player, worker count, and seed in `config.R`. Keep the two populated reference JSON files in `data/reference/`.

```r
# Full collection, fitting, evaluation, and default player report:
source("scripts/run.R")
```

The initial collection downloads thousands of game files. Subsequent runs reuse verified downloads and compatible processed game caches, but the run script still fits the models again. macOS/Linux can collect in parallel; Windows uses sequential collection.

For a small collection check before a full run:

```r
source("scripts/setup.R")
source("config.R")
source("R/data.R")
source("R/model.R")

pilot <- collect_r(config, limit_per_season = 5L)
validate_opportunities_r(pilot$opportunities)
```

A pilot checks collection and structure; it is not suitable for published player rankings.

Once the full analysis has been saved, generate another player's report without refitting:

```r
source("scripts/player_report.R")
player_report("Mitchell Robinson")
player_report("Bam Adebayo")
player_report(1629011)
```

Full names, unique partial names, and NBA IDs are accepted. Ambiguous names produce a list of matches. Reports are written under `output/r/full/players/<NBA_ID>/`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `config.R` | Analysis settings |
| `R/data.R` | Downloads, caching, lineup reconstruction, opportunity collection |
| `R/model.R` | Validation, sparse matrices, ridge fitting, evaluation, ratings |
| `R/report.R` | Name lookup, season summaries, exports, player reports |
| `scripts/setup.R` | Dependency setup |
| `scripts/run.R` | Full pipeline entry point |
| `scripts/player_report.R` | Load reporting functions in a fresh session |
| `data/reference/` | Tracked lineup corrections and provenance |
| `data/raw/`, `data/processed/` | Ignored local downloads and caches |
| `output/r/full/` | Ignored generated analysis and reports |
| `results/` | Reserved for curated, intentionally published results |
| `scripts/build_dashboard.R`, `dashboard/template.html` | Rebuild the dashboard from saved R results |
| `docs/index.html` | Standalone dashboard published through GitHub Pages |

See [output documentation](results/README.md) for generated filenames. Run `Rscript tests/test-r.R` from the repository root to check the ridge solution, role signs, shrinkage, validation, unseen-player behavior, player lookup, and a period-starter regression case. These focused checks are not exhaustive parser validation.

## Refresh the dashboard

After saving a complete analysis with season summaries:

```r
source("scripts/build_dashboard.R")
```

The builder embeds the saved R results into `dashboard/template.html` and writes the standalone `docs/index.html`. Commit and push the rebuilt HTML to `main`; GitHub Pages publishes from `/docs`.

## Limitations

- These are observational team-rebounding associations. Shared minutes, team scheme, omitted context, and lineup reconstruction can affect estimates; the model does not establish causal player effects or prescribe a skill intervention.
- Opportunities cover eligible linked recoveries after missed field goals. Free-throw rebounds, unresolved recoveries, invalid lineups, and specified placeholder events are excluded. These are not tracking-defined individual rebound chances.
- The linear model can produce predictions outside [0, 1]. Scoring clips predictions and reports their out-of-range count.
- The test-season mean recovery rate was underpredicted. Good relative predictive performance does not guarantee calibration in every season or subgroup.
- Player-level uncertainty intervals, alternative fitting windows, and sensitivity analyses excluding team rebounds remain future work.
- Archive versions and downloaded checksums are recorded, but dependency versions are not locked. `session-info.txt` records the environment of each saved fit.

Independent research by Hunter Clark; not an official NBA or team product.
