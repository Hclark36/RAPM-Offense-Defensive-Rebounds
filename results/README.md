# Results and player reports

The pipeline writes generated files to **`output/r/full/`**. This directory holds curated exports from the completed three-season run:

- `player_ratings.csv`: historical refit ratings for all players.
- `model_comparison.csv`: frozen held-out test metrics.
- `test_brier_comparison.csv`: conditional game-bootstrap comparison.
- `validation_scores.csv`, `splits.csv`, `coverage.csv`: penalty selection and dataset summaries.
- `figures/example_player_ratings.png`: Mitchell Robinson’s adjusted ratings.
- `players/1629011/`: Robinson’s report, summary, raw season context, and charts.

These replace the original empty scaffold placeholders. The CSV values and figures were copied from the saved R outputs. Generated output remains ignored by Git; curated snapshots are tracked here. Re-running the pipeline does not automatically refresh this curated directory.

## Generate outputs

From the repository root:

```r
source("scripts/run.R")
```

This collects data using caches, loads player names, fits and evaluates the models, creates historical ratings and raw season summaries, exports the analysis, and generates the configured player's report. The default player is set in `config.R`.

## Full analysis files

| File under `output/r/full/` | Contents |
| --- | --- |
| `analysis.rds` | Complete fitted analysis bundle |
| `historical_refit_player_ratings.csv` | Player ratings from the separate all-season historical refit |
| `training_player_ratings.csv` | Ratings from the frozen training context model |
| `validation_scores.csv` | Validation scores for each model and penalty |
| `test_metrics.csv` | Frozen-model and baseline held-out metrics |
| `test_brier_comparison.csv` | Game-bootstrap Brier difference and interval |
| `test_predictions.csv.gz` | Actual test outcomes and four prediction series |
| `splits.csv` | Seasons, dates, games, and opportunities by split |
| `coverage.csv` | Season-level coverage and retained fractions |
| `game_audit.csv` | Per-game coverage and exclusions |
| `player_season_context.csv` | Raw team recovery rates by player, role, and season |
| `findings.md` | Generated findings and limitations |
| `session-info.txt` | R and package environment recorded at fitting |

## Generate another player's report

After a full run has saved `analysis.rds`:

```r
source("scripts/player_report.R")
player_report("Mitchell Robinson")
player_report("Bam Adebayo")
player_report(1629011)
```

This reads the saved model without refitting. Each player's files are saved under `output/r/full/players/<NBA_ID>/`:

- `summary.csv`: offensive/defensive effects, exposure, raw rates, eligibility, and ranks.
- `season_context.csv`: raw season rates and opportunity counts.
- `ratings.png`: pooled adjusted offensive/defensive effects.
- `season_context.png`: raw team recovery rates across seasons.
- `report.md`: interpretation and linked charts.

Ranks use the role-specific eligibility threshold from the saved fit (500 opportunities in the current configuration). Ties share a rank. Players below the threshold still receive estimates but no rank.

## Interpretation and current findings

Positive ratings mean better team recovery in both roles. Units are team recoveries per 100 eligible missed-shot opportunities relative to the role's opportunity-weighted modeled average. Raw team recovery rates are not individual rebound percentages. Offensive recoveries extend possessions rather than being counted as new possessions.

In the completed 2025–26 test evaluation, context-adjusted RAPM had Brier score 0.2074319 versus 0.2082234 for context only, a relative reduction of approximately 0.38%. The conditional game-bootstrap difference was −0.0007915 with a 95% interval [−0.0009689, −0.0006070]. The primary model underpredicted mean offensive recovery: 28.11% predicted versus 29.88% observed.

Mitchell Robinson's historical offensive rating was +3.45 across 2,214 opportunities, ranking fourth of 546 eligible offensive players. His defensive rating was +0.16 across 2,034 opportunities, ranking 182nd of 537 eligible defensive players.

Test metrics evaluate frozen training models. Player reports use a separate three-season refit and must not be described as out-of-sample player estimates. The bootstrap interval is for the model-performance comparison, not an individual player's effect. Player-level uncertainty intervals have not been computed; these observational estimates do not guarantee future or causal impact.

## Interactive dashboard

[Explore the dashboard](https://hclark36.github.io/RAPM-Offense-Defensive-Rebounds/) or [open Mitchell Robinson directly](https://hclark36.github.io/RAPM-Offense-Defensive-Rebounds/#player=1629011).

GitHub Pages serves a standalone HTML snapshot from `docs/index.html`. After saving the R analysis, run `source("scripts/build_dashboard.R")` to rebuild the HTML using `dashboard/template.html`. Verify, commit, and push `docs/index.html` to `main` to publish the update. The full run script does not deploy automatically.
