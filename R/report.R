# ------------------------------------------------------------
# Load full player names from the pinned NBA archive
# ------------------------------------------------------------

player_names_r <- function(cfg, fallback) {

  seasons <- c(
    cfg$training_seasons,
    cfg$validation_seasons,
    cfg$test_seasons
  )

  year <- max(
    as.integer(substr(seasons, 1L, 4L))
  ) + 1L

  path <- "data/raw/player_names.json"

  fetch_cached(
    paste0(
      "https://raw.githubusercontent.com/",
      "sportsdataverse/hoopR-nba-stats-raw/",
      cfg$schedule_commit,
      "/nba_stats/json/commonallplayers/",
      year,
      ".json"
    ),
    path
  )

  source <- jsonlite::fromJSON(
    path,
    simplifyVector = FALSE
  )

  expected <- sprintf(
    "%d-%02d",
    year - 1L,
    year %% 100L
  )

  if (!identical(source$parameters$Season, expected)) {
    stop("Player catalogue season mismatch.")
  }

  catalogue <- source$resultSets[[1L]]
  headers <- unlist(catalogue$headers)

  id_column <- match("PERSON_ID", headers)
  name_column <- match("DISPLAY_FIRST_LAST", headers)

  if (anyNA(c(id_column, name_column))) {
    stop("Player catalogue schema mismatch.")
  }

  ids <- vapply(
    catalogue$rowSet,
    function(row) {
      as.character(row[[id_column]])
    },
    character(1)
  )

  labels <- lapply(
    catalogue$rowSet,
    function(row) {
      as.character(row[[name_column]])
    }
  )

  if (anyDuplicated(ids)) {
    stop("Duplicate NBA IDs in name catalogue.")
  }

  fallback[ids] <- labels

  fallback
}


# ------------------------------------------------------------
# Find one player by full name, partial name, or NBA ID
# ------------------------------------------------------------

resolve_player_r <- function(selection, ratings) {

  query <- trimws(
    as.character(selection)
  )

  if (
    length(query) != 1L ||
    is.na(query) ||
    !nzchar(query)
  ) {
    stop("Supply one player name or NBA ID.")
  }

  if (grepl("^[0-9]+$", query)) {

    matches <- which(
      as.character(ratings$player_id) == query
    )

  } else {

    normalize_name <- function(value) {

      value <- iconv(
        enc2utf8(value),
        from = "UTF-8",
        to = "ASCII//TRANSLIT"
      )

      value[is.na(value)] <- ""

      gsub(
        "[^a-z0-9]",
        "",
        tolower(value)
      )
    }

    normalized_query <- normalize_name(query)

    if (!nzchar(normalized_query)) {
      stop("Supply a player name or NBA ID.")
    }

    normalized_names <- normalize_name(
      ratings$player_name
    )

    # Prefer an exact normalized name match.
    matches <- which(
      normalized_names == normalized_query
    )

    # Otherwise, try a partial name match.
    if (!length(matches)) {
      matches <- which(
        grepl(
          normalized_query,
          normalized_names,
          fixed = TRUE
        )
      )
    }
  }

  if (!length(matches)) {
    stop(
      "Player has no eligible observations in these seasons: ",
      query
    )
  }

  if (length(matches) > 1L) {

    options <- paste0(
      ratings$player_name[matches],
      " (",
      ratings$player_id[matches],
      ")"
    )

    stop(
      "Name is ambiguous. Use an NBA ID from these matches: ",
      paste(options, collapse = ", ")
    )
  }

  ratings[matches, , drop = FALSE]
}

# ------------------------------------------------------------
# Calculate raw team recovery rates by player, season, and role
# ------------------------------------------------------------

player_seasons_r <- function(data, players) {

  rows <- list()

  for (season in unique(data$season)) {

    frame <- data[
      data$season == season,
      ,
      drop = FALSE
    ]

    for (role in names(role_columns)) {

      ids <- as.vector(
        t(
          as.matrix(
            frame[role_columns[[role]]]
          )
        )
      )

      positions <- match(ids, players)

      opportunities <- tabulate(
        positions,
        nbins = length(players)
      )

      outcome <- if (role == "off") {
        frame$oreb
      } else {
        1 - frame$oreb
      }

      recoveries <- tabulate(
        positions[
          rep(outcome == 1L, each = 5L)
        ],
        nbins = length(players)
      )

      rows[[length(rows) + 1L]] <- data.frame(
        player_id = players,
        season = season,
        role = role,
        opportunities = opportunities,

        team_recovery_pct = ifelse(
          opportunities > 0L,
          100 * recoveries / opportunities,
          NA_real_
        )
      )
    }
  }

  do.call(rbind, rows)
}

# ------------------------------------------------------------
# Save the complete analysis and results tables
# ------------------------------------------------------------

save_analysis_r <- function(bundle, output) {

  dir.create(
    output,
    recursive = TRUE,
    showWarnings = FALSE
  )

  tables <- list(
    historical_refit_player_ratings = bundle$ratings,
    training_player_ratings = bundle$training_ratings,
    test_metrics = bundle$metrics,
    validation_scores = bundle$validation_scores,
    test_brier_comparison = bundle$comparison,
    splits = bundle$splits,
    coverage = bundle$coverage,
    game_audit = bundle$audit,
    player_season_context = bundle$player_seasons
  )

  # Save each results table as a CSV.
  for (name in names(tables)) {

    write.csv(
      tables[[name]],
      file.path(
        output,
        paste0(name, ".csv")
      ),
      row.names = FALSE,
      fileEncoding = "UTF-8"
    )
  }

  # Save test predictions as a compressed CSV.
  connection <- gzfile(
    file.path(output, "test_predictions.csv.gz"),
    open = "wt",
    encoding = "UTF-8"
  )

  tryCatch(
    write.csv(
      bundle$test_predictions,
      connection,
      row.names = FALSE
    ),
    finally = close(connection)
  )

  # Save the complete R analysis object.
  temporary <- file.path(
    output,
    "analysis.rds.tmp"
  )

  saveRDS(bundle, temporary)

  if (
    !file.rename(
      temporary,
      file.path(output, "analysis.rds")
    )
  ) {
    stop("Cannot save R model bundle.")
  }

  # Record the R version and package environment.
  writeLines(
    bundle$session_info,
    file.path(output, "session-info.txt")
  )

  primary <- bundle$metrics[
    bundle$metrics$model == "context_rapm",
    ,
    drop = FALSE
  ]

  baseline <- bundle$metrics[
    bundle$metrics$model == "miss_context",
    ,
    drop = FALSE
  ]

  comparison <- bundle$comparison

  findings <- c(
    "# Rebounding RAPM results",
    "",

    sprintf(
      "The pipeline retained %s eligible rebound opportunities.",
      format(
        sum(bundle$splits$opportunities),
        big.mark = ","
      )
    ),

    "",

    paste(
      "Training seasons:",
      paste(bundle$config$training_seasons, collapse = ", ")
    ),

    paste(
      "Validation seasons:",
      paste(bundle$config$validation_seasons, collapse = ", ")
    ),

    paste(
      "Test seasons:",
      paste(bundle$config$test_seasons, collapse = ", ")
    ),

    "",

    sprintf(
      paste(
        "Held-out Brier score: %.6f for context-adjusted RAPM",
        "and %.6f for the context-only baseline."
      ),
      primary$brier,
      baseline$brier
    ),

    sprintf(
      paste(
        "The game-bootstrap Brier difference is %.6f,",
        "with a conditional 95%% interval from %.6f to %.6f."
      ),
      comparison$brier_difference,
      comparison$lower_95,
      comparison$upper_95
    ),

    sprintf(
      paste(
        "Average predicted offensive recovery: %.2f%%.",
        "Observed offensive recovery: %.2f%%."
      ),
      100 * primary$predicted_oreb_rate,
      100 * primary$observed_oreb_rate
    ),

    "",

    paste(
      "Player reports use a separate historical refit across",
      "all included seasons. Positive ratings indicate better",
      "team recovery in both roles. Each role is centered on",
      "its opportunity-weighted average player."
    ),

    "",

    paste(
      "Season-by-season recovery percentages are raw on-floor",
      "team rates, not seasonal adjusted player effects."
    ),

    "",

    paste(
      "These are observational estimates.",
      "Eligible team rebounds are included after placeholder",
      "filtering. Invalid lineups and unresolved recoveries",
      "are audited and excluded."
    ),

    "",

    paste(
      "The bootstrap interval describes test-performance",
      "uncertainty with the fitted models held fixed.",
      "Player-level uncertainty intervals and sensitivity",
      "analyses remain future work."
    )
  )

  writeLines(
    findings,
    file.path(output, "findings.md"),
    useBytes = TRUE
  )

  invisible(output)
}

# ------------------------------------------------------------
# Generate a player's results, charts, and Markdown report
# ------------------------------------------------------------

report_player_r <- function(bundle, selection, output) {

  player <- resolve_player_r(
    selection,
    bundle$ratings
  )

  directory <- file.path(
    output,
    "players",
    as.character(player$player_id)
  )

  dir.create(
    directory,
    recursive = TRUE,
    showWarnings = FALSE
  )

  # Summarize adjusted effects and eligible-player ranks.
  summary <- do.call(
    rbind,
    lapply(
      c("off", "def"),
      function(role) {

        effect <- paste0(role, "_rapm_per100")

        eligible <- bundle$ratings[[
          paste0(role, "_display_eligible")
        ]]

        values <- bundle$ratings[[effect]][eligible]

        enough <- player[[
          paste0(role, "_display_eligible")
        ]]

        rank <- if (enough) {
          1L + sum(values > player[[effect]])
        } else {
          NA_integer_
        }

        data.frame(
          player_id = player$player_id,
          player_name = player$player_name,

          role = if (role == "off") {
            "Offensive rebounding"
          } else {
            "Defensive rebounding"
          },

          rapm_per100 = player[[effect]],

          opportunities = player[[
            paste0(role, "_opportunities")
          ]],

          on_floor_team_recovery_pct = player[[
            paste0(role, "_on_floor_rebound_pct")
          ]],

          display_eligible = enough,
          rank = rank,
          eligible_players = length(values)
        )
      }
    )
  )

  season_rows <- bundle$player_seasons[
    bundle$player_seasons$player_id == player$player_id &
      bundle$player_seasons$opportunities > 0,
    ,
    drop = FALSE
  ]

  write.csv(
    summary,
    file.path(directory, "summary.csv"),
    row.names = FALSE,
    fileEncoding = "UTF-8"
  )

  write.csv(
    season_rows,
    file.path(directory, "season_context.csv"),
    row.names = FALSE
  )

  # Chart the pooled adjusted ratings.
  rating_plot <- ggplot2::ggplot(
    summary,
    ggplot2::aes(
      x = role,
      y = rapm_per100,
      fill = role
    )
  ) +
    ggplot2::geom_hline(
      yintercept = 0,
      color = "grey65"
    ) +
    ggplot2::geom_col(
      width = 0.55,
      show.legend = FALSE
    ) +
    ggplot2::geom_text(
      ggplot2::aes(
        label = sprintf("%+.2f", rapm_per100)
      ),
      vjust = ifelse(
        summary$rapm_per100 >= 0,
        -0.5,
        1.4
      ),
      size = 5
    ) +
    ggplot2::scale_fill_manual(
      values = c(
        "Offensive rebounding" = "#147d92",
        "Defensive rebounding" = "#bc5a37"
      )
    ) +
    ggplot2::scale_y_continuous(
      expand = ggplot2::expansion(mult = 0.22)
    ) +
    ggplot2::labs(
      title = paste(
        player$player_name,
        "- adjusted team rebounding"
      ),

      subtitle = paste(
        "Historical refit:",
        paste(
          unique(bundle$player_seasons$season),
          collapse = ", "
        )
      ),

      x = NULL,
      y = "Team recoveries per 100 eligible misses relative to average",

      caption = paste(
        "Positive is better in both roles. Observational estimates.",
        "\nPlayer-level uncertainty intervals have not been computed."
      )
    ) +
    ggplot2::theme_minimal(base_size = 12)

  ggplot2::ggsave(
    filename = file.path(directory, "ratings.png"),
    plot = rating_plot,
    width = 9,
    height = 5.5,
    dpi = 180
  )

  # Chart raw season-by-season team recovery rates.
  context_plot <- ggplot2::ggplot(
    season_rows,
    ggplot2::aes(
      x = season,
      y = team_recovery_pct,
      group = role,
      color = role
    )
  ) +
    ggplot2::geom_line() +
    ggplot2::geom_point(size = 3) +
    ggplot2::scale_color_manual(
      values = c(
        off = "#147d92",
        def = "#bc5a37"
      ),
      labels = c(
        off = "Offensive recovery",
        def = "Defensive recovery"
      )
    ) +
    ggplot2::labs(
      title = paste(
        player$player_name,
        "- on-floor team recovery"
      ),
      subtitle = "Raw season rates provide context for the pooled adjusted ratings",
      x = NULL,
      y = "Team recovery percentage",
      color = NULL,

      caption = paste(
        "These season rates are unadjusted.",
        "They are not individual rebound percentages."
      )
    ) +
    ggplot2::theme_minimal(base_size = 12)

  ggplot2::ggsave(
    filename = file.path(directory, "season_context.png"),
    plot = context_plot,
    width = 9,
    height = 5.5,
    dpi = 180
  )

  # Write a readable report.
  lines <- c(
    paste0(
      "# ",
      player$player_name,
      " - rebounding RAPM"
    ),
    "",

    paste(
      "These ratings use a league-wide historical refit.",
      "They estimate association with team recovery, adjusting",
      "for teammates, opponents, missed two versus three,",
      "blocked shots, and home offense."
    ),

    ""
  )

  for (i in seq_len(nrow(summary))) {

    row <- summary[i, , drop = FALSE]

    standing <- if (row$display_eligible) {

      sprintf(
        "Rank %d of %d eligible players.",
        row$rank,
        row$eligible_players
      )

    } else {

      paste(
        "Exposure is below the display threshold,",
        "so no rank is assigned."
      )
    }

    lines <- c(
      lines,

      sprintf(
        paste(
          "%s: %+.2f team recoveries per 100 eligible misses",
          "relative to average, across %s opportunities. %s"
        ),
        row$role,
        row$rapm_per100,
        format(row$opportunities, big.mark = ","),
        standing
      ),

      ""
    )
  }

  lines <- c(
    lines,

    paste(
      "A +2 rating represents an estimated two additional",
      "team recoveries per 100 eligible opportunities relative",
      "to the modeled average player in that role.",
      "This can include boxing out for a teammate."
    ),

    "",

    paste(
      "The model does not identify a causal training effect",
      "or a specific skill intervention. Shared minutes and",
      "team scheme can affect estimates. Player-level",
      "uncertainty intervals have not been computed."
    ),

    "",
    "![Adjusted ratings](ratings.png)",
    "",
    "![Season context](season_context.png)"
  )

  writeLines(
    lines,
    file.path(directory, "report.md"),
    useBytes = TRUE
  )

  print(summary, row.names = FALSE)

  message(
    "Player report saved to ",
    normalizePath(directory)
  )

  invisible(summary)
}


# ------------------------------------------------------------
# Retrieve any player's report from the saved analysis
# ------------------------------------------------------------

player_report <- function(player, pilot = FALSE) {

  output <- file.path(
    "output/r",
    if (pilot) "pilot" else "full"
  )

  path <- file.path(
    output,
    "analysis.rds"
  )

  if (!file.exists(path)) {
    stop("Fit and save the league analysis before generating reports.")
  }

  report_player_r(
    bundle = readRDS(path),
    selection = player,
    output = output
  )
}
