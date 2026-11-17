# Data sources and collection

The R pipeline creates one row per eligible team recovery after a missed field goal. It reconstructs the ten players on court from period-starter inference and substitutions, then links the rebound to its shot using `shotActionNumber`.

## Sources

- [SportsDataverse NBA archive](https://github.com/sportsdataverse/hoopR-nba-stats-raw/tree/0bca6cf72d9f879140148882657affc1591efd13): schedule, NBA player-name catalogue, and rotation records used for reference corrections. The archive commit is pinned in `config.R`.
- NBA live play-by-play JSON: `https://nba-prod-us-east-1-mediaops-stats.s3.amazonaws.com/NBA/liveData/playbyplay/playbyplay_<GAME_ID>.json`.

These are event-level records and derived lineup information, not raw frame-by-frame tracking or Synergy data. The live play-by-play source is not commit-pinned. Download metadata records the source URL, retrieval time, and SHA-256 checksum; existing cached files are checked before reuse rather than automatically refreshed.

## Directories

| Directory | Contents | Git policy |
| --- | --- | --- |
| `raw/schedule/` | Downloaded schedule parquet and metadata | Ignored |
| `raw/pbp/` | Downloaded game JSON and metadata | Ignored |
| `raw/player_names.json` | Full NBA player-name catalogue | Ignored |
| `processed/r/games/` | Parsed per-game RDS caches and signatures | Ignored |
| `processed/r/` | Combined full/pilot datasets and audit files | Ignored |
| `reference/` | Starter corrections and provenance | Tracked |

The `.gitkeep` files preserve empty cache directories in Git. Do not commit the downloaded or processed datasets. Do commit populated reference files; the collection function requires them.

## Reference corrections

`reference/period_starters.json` contains period/team starting lineups for seven games. It is indexed by game ID, period, and team ID. A correction is used only when event inference does not produce exactly five players for that team. A period still lacking valid lineups is excluded.

`reference/period_starters.metadata.json` records the archive commit, rotation source URLs, and the correction file's SHA-256. `read_starter_overrides()` verifies that checksum. Do not manually reformat or change the correction file without reviewing provenance and updating its recorded checksum: the checksum covers file bytes, including whitespace.

## Eligibility and exclusions

Collection selects regular-season schedule entries with game IDs beginning `002`. The parser requires a complete game and valid team assignments, infers period starters, tracks substitutions, and stores the lineup at each field-goal attempt.

Retained rows require a linked missed two- or three-point attempt, one retained recovery per shot, five distinct players per side, and consistent shooter/rebounder membership. Recoveries with changed lineups between shot and rebound are excluded. Free-throw rebounds, dead-ball qualifiers, specified administrative team-rebound placeholders, and invalid shot links are excluded. Eligible team rebounds are included.

The game audit records invalid links and lineups, membership exclusions, substitution recoveries, placeholders, team rebounds, excluded periods, and unresolved misses. Some exclusions are checked sequentially, so the counters should not be treated as an independent exhaustive partition of all misses.

## Opportunity fields

| Fields | Meaning |
| --- | --- |
| `game_id`, `game_date`, `season`, `period` | Game and period identifiers |
| `shot_event_id`, `rebound_event_id` | Linked play-by-play events |
| `offense_team_id`, `defense_team_id` | Teams at the missed shot |
| `off_1` through `off_5` | Offensive player IDs at the shot |
| `def_1` through `def_5` | Defensive player IDs at the shot |
| `oreb` | 1 for offensive recovery; 0 for defensive recovery |
| `three`, `blocked`, `offense_home` | Binary model controls |
| `rebounder_id`, `team_rebound` | Individual rebounder, or team-rebound flag |

Player-column ordering does not represent basketball positions. On-floor opportunities are not individual tracking-defined rebound chances.

## Completed full-run coverage

| Season | Games | Missed field goals | Retained opportunities | Retained fraction | Excluded periods |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2023–24 | 1,230 | 114,954 | 112,991 | 98.29% | 8 |
| 2024–25 | 1,230 | 116,963 | 114,960 | 98.29% | 7 |
| 2025–26 | 1,230 | 115,931 | 114,374 | 98.66% | 5 |

## Collection and cache reuse

Run `source("scripts/run.R")` from the project root for the full workflow. For a collection-only pilot, load setup, configuration, and `R/data.R`, then use `collect_r(config, limit_per_season = 5L)`.

Processed game signatures include `parser_version`, correction contents, source-file checksum, and relevant schedule fields. Changing those inputs triggers reprocessing of affected caches. Increase `parser_version` when changing parsing rules. Collection stops on failed games and writes a failures CSV; successful game caches remain available for the next run.

The combined full dataset is saved as `data/processed/r/full_data.rds`. Generated model outputs are documented in [results/README.md](../results/README.md).
