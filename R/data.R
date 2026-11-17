# ------------------------------------------------------------
# Data collection and lineup reconstruction
# ------------------------------------------------------------

# Increase this when parsing rules change so processed caches
# can be identified as outdated.
parser_version <- "r-2"


# ------------------------------------------------------------
# Download a file or reuse its verified cached copy
# ------------------------------------------------------------

fetch_cached <- function(url, path) {
  
  metadata_path <- paste0(path, ".metadata.json")
  
  # Reuse an existing file when its checksum matches.
  if (
    file.exists(path) &&
    file.exists(metadata_path)
  ) {
    
    metadata <- jsonlite::fromJSON(metadata_path)
    
    current_checksum <- digest::digest(
      file = path,
      algo = "sha256"
    )
    
    if (!identical(current_checksum, metadata$sha256)) {
      stop("Cached checksum mismatch: ", path)
    }
    
    return(invisible(path))
  }
  
  # Create the destination folder if needed.
  dir.create(
    dirname(path),
    recursive = TRUE,
    showWarnings = FALSE
  )
  
  # Download to a temporary file first.
  temporary <- paste0(path, ".download")
  
  on.exit(
    unlink(temporary),
    add = TRUE
  )
  
  handle <- curl::new_handle(
    connecttimeout = 10,
    timeout = 45,
    failonerror = TRUE
  )
  
  # Try downloading up to three times.
  for (attempt in seq_len(3L)) {
    
    result <- try(
      curl::curl_download(
        url,
        temporary,
        handle = handle,
        quiet = TRUE
      ),
      silent = TRUE
    )
    
    if (!inherits(result, "try-error")) {
      break
    }
    
    if (attempt == 3L) {
      stop(result)
    }
    
    Sys.sleep(2^(attempt - 1L))
  }
  
  # Move the completed download to its destination.
  if (!file.rename(temporary, path)) {
    stop("Cannot save download: ", path)
  }
  
  # Record where the file came from and its checksum.
  jsonlite::write_json(
    list(
      url = url,
      
      retrieved_utc = format(
        Sys.time(),
        tz = "UTC",
        usetz = TRUE
      ),
      
      sha256 = digest::digest(
        file = path,
        algo = "sha256"
      )
    ),
    metadata_path,
    auto_unbox = TRUE,
    pretty = TRUE
  )
  
  invisible(path)
}

# ------------------------------------------------------------
# Load verified period-starter corrections
# ------------------------------------------------------------

read_starter_overrides <- function() {
  
  path <- "data/reference/period_starters.json"
  
  metadata <- jsonlite::fromJSON(
    "data/reference/period_starters.metadata.json"
  )
  
  current_checksum <- digest::digest(
    file = path,
    algo = "sha256"
  )
  
  if (!identical(current_checksum, metadata$sha256)) {
    stop("Period-starter reference checksum mismatch.")
  }
  
  jsonlite::fromJSON(
    path,
    simplifyVector = FALSE
  )
}

# ------------------------------------------------------------
# Convert the game clock into seconds remaining
# ------------------------------------------------------------

clock_seconds <- function(clock) {
  
  minutes <- as.numeric(
    sub(
      "^PT([0-9]+)M.*$",
      "\\1",
      clock
    )
  )
  
  seconds <- as.numeric(
    sub(
      "^PT[0-9]+M([0-9.]+)S$",
      "\\1",
      clock
    )
  )
  
  minutes * 60 + seconds
}

# ------------------------------------------------------------
# Identify the five starting players for each team in a period
# ------------------------------------------------------------

period_starters <- function(events, team_map, override) {
  
  starters <- numeric()
  incoming <- numeric()
  
  for (i in seq_len(nrow(events))) {
    
    event <- events[i, , drop = FALSE]
    
    player <- event$personId
    
    # Track players who entered during the period.
    if (event$actionType == "substitution") {
      
      if (event$subType == "in") {
        incoming <- union(incoming, player)
      }
      
      # A player leaving before ever entering must have
      # been on court at the start of the period.
      if (
        event$subType == "out" &&
        !player %in% incoming
      ) {
        starters <- union(starters, player)
      }
      
      next
    }
    
    # These events can involve players who are off court.
    technical <- (
      event$actionType == "foul" &&
        grepl("technical", event$subType)
    )
    
    if (
      event$actionType %in% c("timeout", "ejection") ||
      technical
    ) {
      next
    }
    
    # Players involved in an on-court event before their
    # first substitution in are starter candidates.
    actors <- c(
      player,
      event$assistPersonId,
      event$blockPersonId,
      event$stealPersonId,
      event$foulDrawnPersonId
    )
    
    actors <- actors[
      is.finite(actors) &
        actors > 0 &
        !actors %in% incoming
    ]
    
    starters <- union(starters, actors)
  }
  
  # Separate the starter candidates by team.
  teams <- sort(
    unique(
      unname(team_map)
    )
  )
  
  lineups <- setNames(
    lapply(
      teams,
      function(team) {
        sort(
          starters[
            team_map[as.character(starters)] %in% team
          ]
        )
      }
    ),
    as.character(teams)
  )
  
  # Use a reference correction when inference does not
  # identify exactly five players for a team.
  for (team in names(lineups)) {
    
    if (
      length(lineups[[team]]) != 5L &&
      !is.null(override[[team]])
    ) {
      lineups[[team]] <- sort(
        as.numeric(override[[team]])
      )
    }
  }
  
  lineups
}

# ------------------------------------------------------------
# Parse one game into eligible rebound opportunities
# ------------------------------------------------------------

parse_game_r <- function(game, path, overrides = list()) {
  
  source <- jsonlite::fromJSON(path)
  
  if (!identical(source$game$gameId, as.character(game$game_id))) {
    stop("PBP game ID does not match schedule.")
  }
  
  events <- source$game$actions
  
  # Standardize missing player and team identifiers.
  numeric_fields <- c(
    "personId",
    "teamId",
    "assistPersonId",
    "blockPersonId",
    "stealPersonId",
    "foulDrawnPersonId",
    "shotActionNumber"
  )
  
  for (field in numeric_fields) {
    
    if (is.null(events[[field]])) {
      events[[field]] <- 0
    }
    
    events[[field]][is.na(events[[field]])] <- 0
  }
  
  # Standardize missing text fields.
  for (field in c("subType", "shotResult", "playerNameI")) {
    
    if (is.null(events[[field]])) {
      events[[field]] <- ""
    }
    
    events[[field]][is.na(events[[field]])] <- ""
  }
  
  # Require a completed game with all four regulation periods.
  if (
    !any(events$actionType == "game" & events$subType == "end") ||
    !all(1:4 %in% events$period)
  ) {
    stop("Game is incomplete.")
  }
  
  teams <- sort(
    unique(events$teamId[events$teamId > 0])
  )
  
  if (
    length(teams) != 2L ||
    !game$away_team_id %in% teams
  ) {
    stop("Invalid game teams.")
  }
  
  home <- game$home_team_id
  
  if (is.na(home)) {
    home <- setdiff(teams, game$away_team_id)
  }
  
  if (
    !home %in% teams ||
    home == game$away_team_id
  ) {
    stop("Invalid home team.")
  }
  
  # Build a player-to-team lookup.
  # Jump-ball team fields are excluded from this lookup.
  team_events <- events[
    events$personId > 0 &
      events$teamId > 0 &
      events$actionType != "jumpball",
    ,
    drop = FALSE
  ]
  
  team_pairs <- unique(
    team_events[c("personId", "teamId")]
  )
  
  if (anyDuplicated(team_pairs$personId)) {
    stop("Conflicting player-team assignments.")
  }
  
  team_map <- setNames(
    team_pairs$teamId,
    as.character(team_pairs$personId)
  )
  
  # Collect player-name labels available in the play-by-play.
  labels <- events[
    events$personId > 0 & nzchar(events$playerNameI),
    ,
    drop = FALSE
  ]
  
  labels <- labels[
    !duplicated(labels$personId, fromLast = TRUE),
    ,
    drop = FALSE
  ]
  
  player_names <- setNames(
    as.list(labels$playerNameI),
    as.character(labels$personId)
  )
  
  missed <- events$actionNumber[
    events$actionType %in% c("2pt", "3pt") &
      events$shotResult == "Missed"
  ]
  
  # Record retained opportunities and exclusion reasons.
  audit <- list(
    game_id = as.character(game$game_id),
    season = game$season,
    status = "ok",
    missed_field_goals = length(missed),
    opportunities = 0L,
    invalid_lineups = 0L,
    substitution_recoveries = 0L,
    membership_exclusions = 0L,
    placeholder_rebounds = 0L,
    invalid_shot_links = 0L,
    team_rebounds = 0L,
    excluded_periods = "",
    excluded_period_count = 0L,
    unresolved_misses = 0L
  )
  
  rows <- list()
  seen <- numeric()
  excluded <- character()
  
  game_override <- overrides[[as.character(game$game_id)]]
  
  # Process each quarter and overtime period.
  for (period in sort(unique(events$period))) {
    
    p <- events[
      events$period == period,
      ,
      drop = FALSE
    ]
    
    start <- which(
      p$actionType == "period" &
        p$subType == "start"
    )
    
    if (length(start) != 1L) {
      stop("Missing or duplicate period start.")
    }
    
    # Ignore records preceding the explicit period start.
    p <- p[seq.int(start, nrow(p)), , drop = FALSE]
    
    if (any(p$actionType == "foul" & !nzchar(p$subType))) {
      excluded <- c(
        excluded,
        paste0(period, ": missing foul subtype")
      )
      next
    }
    
    lineups <- period_starters(
      p,
      team_map,
      game_override[[as.character(period)]]
    )
    
    if (
      length(lineups) != 2L ||
      any(lengths(lineups) != 5L)
    ) {
      excluded <- c(
        excluded,
        paste0(period, ": unidentified starters")
      )
      next
    }
    
    shot_lineups <- list()
    
    # Walk through events in their recorded order.
    for (i in seq_len(nrow(p))) {
      
      event <- p[i, , drop = FALSE]
      team <- as.character(event$teamId)
      
      # Update the current on-court players.
      if (event$actionType == "substitution") {
        
        if (!team %in% names(lineups)) {
          stop("Substitution has unknown team.")
        }
        
        if (event$subType == "out") {
          lineups[[team]] <- setdiff(
            lineups[[team]],
            event$personId
          )
        }
        
        if (event$subType == "in") {
          lineups[[team]] <- union(
            lineups[[team]],
            event$personId
          )
        }
      }
      
      # Save the lineup at each field-goal attempt.
      if (event$actionType %in% c("2pt", "3pt")) {
        shot_lineups[[as.character(event$actionNumber)]] <-
          lapply(lineups, sort)
      }
      
      if (event$actionType != "rebound") {
        next
      }
      
      # Match this rebound to its preceding shot.
      shot_index <- match(
        event$shotActionNumber,
        p$actionNumber
      )
      
      if (is.na(shot_index) || shot_index >= i) {
        audit$invalid_shot_links <-
          audit$invalid_shot_links + 1L
        next
      }
      
      shot <- p[shot_index, , drop = FALSE]
      
      # Exclude rebounds linked to free throws or other events.
      if (!shot$actionType %in% c("2pt", "3pt")) {
        next
      }
      
      qualifiers <- unlist(
        event$qualifiers,
        use.names = FALSE
      )
      
      remaining <- clock_seconds(event$clock)
      shot_remaining <- clock_seconds(shot$clock)
      
      same_time <- p[
        p$clock == event$clock,
        ,
        drop = FALSE
      ]
      
      turnover_placeholder <- any(
        same_time$actionType == "turnover" &
          same_time$subType %in% c("shot clock", "kicked ball")
      )
      
      next_events <- p[
        seq.int(i, nrow(p)),
        ,
        drop = FALSE
      ]
      
      next_events <- next_events[
        !next_events$actionType %in% c("replay", "instantreplay"),
        ,
        drop = FALSE
      ]
      
      next_is_end <- (
        nrow(next_events) >= 2L &&
          next_events$actionType[2L] == "period" &&
          next_events$subType[2L] == "end"
      )
      
      # Exclude dead-ball and selected administrative
      # team-rebound records.
      placeholder <- (
        "deadball" %in% qualifiers ||
          (
            event$personId == 0 &&
              (
                (
                  remaining == 0 &&
                    (next_is_end || nrow(next_events) == 1L)
                ) ||
                  turnover_placeholder ||
                  (
                    shot_remaining <= 3 &&
                      shot$clock == event$clock &&
                      next_is_end
                  )
              )
          )
      )
      
      if (placeholder) {
        audit$placeholder_rebounds <-
          audit$placeholder_rebounds + 1L
        next
      }
      
      # Require a missed shot that has not already been used.
      if (
        shot$shotResult != "Missed" ||
        shot$actionNumber %in% seen
      ) {
        audit$invalid_shot_links <-
          audit$invalid_shot_links + 1L
        next
      }
      
      at_shot <- shot_lineups[[
        as.character(shot$actionNumber)
      ]]
      
      # Require five players per team and ten distinct players.
      if (
        any(lengths(at_shot) != 5L) ||
        length(unique(unlist(at_shot))) != 10L
      ) {
        audit$invalid_lineups <-
          audit$invalid_lineups + 1L
        next
      }
      
      # Exclude recoveries with a changed lineup between
      # the shot and rebound.
      if (!identical(at_shot, lapply(lineups, sort))) {
        audit$substitution_recoveries <-
          audit$substitution_recoveries + 1L
        next
      }
      
      offense <- shot$teamId
      defense <- setdiff(teams, offense)
      
      if (
        length(defense) != 1L ||
        !event$teamId %in% teams ||
        !event$subType %in% c("offensive", "defensive")
      ) {
        stop("Invalid rebound teams.")
      }
      
      oreb <- as.integer(event$teamId == offense)
      
      if (oreb != as.integer(event$subType == "offensive")) {
        stop("Rebound flags disagree.")
      }
      
      # Verify that the shooter and individual rebounder
      # belong to their recorded on-court lineups.
      if (
        !shot$personId %in% at_shot[[as.character(offense)]] ||
        (
          event$personId > 0 &&
          !event$personId %in% at_shot[[team]]
        )
      ) {
        audit$membership_exclusions <-
          audit$membership_exclusions + 1L
        next
      }
      
      # Create one eligible rebound-opportunity row.
      row <- data.frame(
        game_id = as.character(game$game_id),
        game_date = substr(
          as.character(game$game_date),
          1L,
          10L
        ),
        season = game$season,
        shot_event_id = shot$actionNumber,
        rebound_event_id = event$actionNumber,
        period = period,
        offense_team_id = offense,
        defense_team_id = defense,
        offense_home = as.integer(offense == home),
        three = as.integer(shot$actionType == "3pt"),
        blocked = as.integer(shot$blockPersonId > 0),
        oreb = oreb,
        rebounder_id = event$personId,
        team_rebound = as.integer(event$personId == 0)
      )
      
      row[paste0("off_", 1:5)] <- as.list(
        at_shot[[as.character(offense)]]
      )
      
      row[paste0("def_", 1:5)] <- as.list(
        at_shot[[as.character(defense)]]
      )
      
      rows[[length(rows) + 1L]] <- row
      
      seen <- c(seen, shot$actionNumber)
      
      audit$team_rebounds <-
        audit$team_rebounds + row$team_rebound
    }
  }
  
  if (!length(rows)) {
    stop("No eligible opportunities in game.")
  }
  
  audit$opportunities <- length(rows)
  
  audit$excluded_periods <- paste(
    excluded,
    collapse = " | "
  )
  
  audit$excluded_period_count <- length(excluded)
  
  audit$unresolved_misses <- length(
    setdiff(missed, seen)
  )
  
  list(
    opportunities = do.call(rbind, rows),
    audit = as.data.frame(audit),
    names = player_names
  )
}

# ------------------------------------------------------------
# Collect and process games across the configured seasons
# ------------------------------------------------------------

collect_r <- function(cfg, limit_per_season = NULL) {
  
  mode <- if (is.null(limit_per_season)) {
    "full"
  } else {
    "pilot"
  }
  
  dir.create(
    "data/processed/r/games",
    recursive = TRUE,
    showWarnings = FALSE
  )
  
  seasons <- c(
    cfg$training_seasons,
    cfg$validation_seasons,
    cfg$test_seasons
  )
  
  if (anyDuplicated(seasons)) {
    stop("Split seasons overlap.")
  }
  
  # Load the schedule from the configured archive version.
  schedule_path <- "data/raw/schedule/master.parquet"
  
  fetch_cached(
    paste0(
      "https://raw.githubusercontent.com/",
      "sportsdataverse/hoopR-nba-stats-raw/",
      cfg$schedule_commit,
      "/nba_stats/nba_stats_schedule_master.parquet"
    ),
    schedule_path
  )
  
  schedule <- as.data.frame(
    arrow::read_parquet(schedule_path)
  )
  
  # Keep regular-season games from the requested seasons.
  schedule <- schedule[
    schedule$season %in% seasons &
      schedule$season_type == "regular_season" &
      startsWith(schedule$game_id, "002"),
    ,
    drop = FALSE
  ]
  
  schedule <- schedule[
    order(schedule$game_date, schedule$game_id),
    ,
    drop = FALSE
  ]
  
  if (
    anyDuplicated(schedule$game_id) ||
    !setequal(schedule$season, seasons)
  ) {
    stop("Invalid schedule.")
  }
  
  # Optionally use a small number of games per season.
  if (!is.null(limit_per_season)) {
    
    schedule <- do.call(
      rbind,
      lapply(
        seasons,
        function(season) {
          head(
            schedule[
              schedule$season == season,
              ,
              drop = FALSE
            ],
            limit_per_season
          )
        }
      )
    )
  }
  
  overrides <- read_starter_overrides()
  
  override_hash <- digest::digest(
    overrides,
    algo = "sha256"
  )
  
  # Download and parse one game, or reuse its processed cache.
  process_game <- function(i) {
    
    game <- schedule[i, , drop = FALSE]
    game_id <- game$game_id
    
    path <- paste0(
      "data/raw/pbp/live_",
      game_id,
      ".json"
    )
    
    cache <- paste0(
      "data/processed/r/games/",
      game_id,
      ".rds"
    )
    
    tryCatch(
      {
        
        fetch_cached(
          paste0(
            "https://nba-prod-us-east-1-mediaops-stats",
            ".s3.amazonaws.com/NBA/liveData/playbyplay/",
            "playbyplay_",
            game_id,
            ".json"
          ),
          path
        )
        
        # Reprocess if parsing rules, references, source data,
        # or relevant schedule information have changed.
        signature <- digest::digest(
          list(
            parser_version,
            override_hash,
            
            digest::digest(
              file = path,
              algo = "sha256"
            ),
            
            game[
              c(
                "game_date",
                "season",
                "home_team_id",
                "away_team_id"
              )
            ]
          )
        )
        
        saved <- if (file.exists(cache)) {
          readRDS(cache)
        } else {
          NULL
        }
        
        if (
          is.null(saved) ||
          !identical(signature, saved$signature)
        ) {
          
          saved <- list(
            signature = signature,
            result = parse_game_r(
              game,
              path,
              overrides
            )
          )
          
          temporary <- paste0(cache, ".tmp")
          
          saveRDS(saved, temporary)
          
          if (!file.rename(temporary, cache)) {
            stop("Cannot save game cache.")
          }
        }
        
        list(
          result = saved$result,
          error = NULL
        )
      },
      
      error = function(error) {
        list(
          result = NULL,
          
          error = data.frame(
            game_id = game_id,
            error = conditionMessage(error)
          )
        )
      }
    )
  }
  
  # Process games in batches of 100.
  batches <- split(
    seq_len(nrow(schedule)),
    ceiling(seq_len(nrow(schedule)) / 100L)
  )
  
  results <- list()
  errors <- list()
  
  for (indices in batches) {
    
    if (
      .Platform$OS.type == "unix" &&
      cfg$collection_workers > 1L
    ) {
      
      batch <- parallel::mclapply(
        indices,
        process_game,
        mc.cores = cfg$collection_workers
      )
      
    } else {
      
      batch <- lapply(
        indices,
        process_game
      )
    }
    
    for (item in batch) {
      
      if (!is.null(item$error)) {
        errors[[length(errors) + 1L]] <- item$error
      }
      
      results <- c(
        results,
        list(item$result)
      )
    }
    
    message(
      max(indices),
      "/",
      nrow(schedule),
      " games processed, ",
      length(errors),
      " failures"
    )
  }
  
  # Stop instead of silently dropping failed games.
  if (length(errors)) {
    
    write.csv(
      do.call(rbind, errors),
      paste0(
        "data/processed/r/",
        mode,
        "_failures.csv"
      ),
      row.names = FALSE
    )
    
    stop(
      "R collection failed. Inspect the failures CSV. ",
      "Successful games are cached."
    )
  }
  
  # Combine each game's opportunities and audit records.
  opportunities <- do.call(
    rbind,
    lapply(results, `[[`, "opportunities")
  )
  
  audit <- do.call(
    rbind,
    lapply(results, `[[`, "audit")
  )
  
  player_names <- list()
  
  for (result in results) {
    player_names[names(result$names)] <- result$names
  }
  
  collected <- list(
    opportunities = opportunities,
    audit = audit,
    names = player_names,
    mode = mode,
    parser_version = parser_version,
    schedule_commit = cfg$schedule_commit,
    seasons = seasons,
    override_hash = override_hash
  )
  
  # Save the combined dataset.
  destination <- paste0(
    "data/processed/r/",
    mode,
    "_data.rds"
  )
  
  temporary <- paste0(destination, ".tmp")
  
  saveRDS(collected, temporary)
  
  if (!file.rename(temporary, destination)) {
    stop("Cannot save collected data.")
  }
  
  write.csv(
    audit,
    paste0(
      "data/processed/r/",
      mode,
      "_game_audit.csv"
    ),
    row.names = FALSE
  )
  
  collected
}
