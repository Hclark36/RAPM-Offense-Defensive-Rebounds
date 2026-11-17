role_columns <- list(
  off = paste0("off_", 1:5),
  def = paste0("def_", 1:5)
)

context_columns <- c(
  "three",
  "blocked",
  "offense_home"
)

# ------------------------------------------------------------
# Validate the rebound-opportunity dataset
# ------------------------------------------------------------

validate_opportunities_r <- function(data) {
  
  required <- c(
    "game_id",
    "game_date",
    "season",
    "shot_event_id",
    "oreb",
    context_columns,
    unlist(role_columns)
  )
  
  if (!all(required %in% names(data))) {
    stop("The opportunity dataset is missing required columns.")
  }
  
  if (!nrow(data) || anyNA(data[required])) {
    stop("The opportunity dataset is empty or contains missing values.")
  }
  
  if (anyDuplicated(data[c("game_id", "shot_event_id")])) {
    stop("Duplicate rebound opportunities were found.")
  }
  
  for (field in c("oreb", context_columns)) {
    if (!all(data[[field]] %in% 0:1)) {
      stop("This field must contain only zero or one: ", field)
    }
  }
  
  players <- as.matrix(
    data[unlist(role_columns)]
  )
  
  if (
    any(!is.finite(players)) ||
    any(players <= 0) ||
    any(players != floor(players))
  ) {
    stop("Player IDs must be positive integers.")
  }
  
  duplicate_players <- apply(
    players,
    1L,
    anyDuplicated
  )
  
  if (any(duplicate_players > 0L)) {
    stop("Each opportunity must contain ten distinct players.")
  }
  
  assignments <- unique(
    data[c("game_id", "game_date", "season")]
  )
  
  if (anyDuplicated(assignments$game_id)) {
    stop("A game has been assigned multiple dates or seasons.")
  }
  
  invisible(TRUE)
}

# ------------------------------------------------------------
# Build the sparse lineup matrix
#
# Offensive player columns receive +1.
# Defensive player columns receive -1.
#
# Each player has separate offensive and defensive columns.
# ------------------------------------------------------------

lineup_design <- function(
    data,
    players,
    include_context = TRUE
) {
  
  n <- nrow(data)
  
  matrices <- lapply(
    seq_along(role_columns),
    function(role_index) {
      
      ids <- as.vector(
        t(
          as.matrix(
            data[role_columns[[role_index]]]
          )
        )
      )
      
      positions <- match(ids, players)
      known <- !is.na(positions)
      
      direction <- if (role_index == 1L) {
        1
      } else {
        -1
      }
      
      Matrix::sparseMatrix(
        i = rep(seq_len(n), each = 5L)[known],
        j = positions[known],
        x = rep(direction, sum(known)),
        dims = c(n, length(players))
      )
    }
  )
  
  x <- cbind(
    matrices[[1L]],
    matrices[[2L]]
  )
  
  colnames(x) <- c(
    paste0("off_", players),
    paste0("def_", players)
  )
  
  if (include_context) {
    
    controls <- Matrix::Matrix(
      as.matrix(data[context_columns]),
      sparse = TRUE
    )
    
    x <- cbind(controls, x)
  }
  
  x
}

# ------------------------------------------------------------
# Fit ridge RAPM
#
# Objective:
# summed squared error
# + penalty * sum(squared player coefficients)
#
# The intercept and context controls are unpenalized.
# ------------------------------------------------------------

fit_rapm_r <- function(
    data,
    penalty,
    include_context = TRUE
) {
  
  if (
    length(penalty) != 1L ||
    !is.finite(penalty) ||
    penalty <= 0
  ) {
    stop("The ridge penalty must be one positive number.")
  }
  
  players <- sort(
    unique(
      as.vector(
        as.matrix(
          data[unlist(role_columns)]
        )
      )
    )
  )
  
  features <- lineup_design(
    data,
    players,
    include_context
  )
  
  x <- cbind(
    intercept = 1,
    features
  )
  
  controls <- if (include_context) {
    length(context_columns)
  } else {
    0L
  }
  
  control_matrix <- as.matrix(
    x[
      ,
      seq_len(controls + 1L),
      drop = FALSE
    ]
  )
  
  if (qr(control_matrix)$rank != controls + 1L) {
    stop("The unpenalized controls are rank deficient.")
  }
  
  penalty_values <- c(
    rep(0, controls + 1L),
    rep(penalty, 2L * length(players))
  )
  
  penalty_matrix <- Matrix::Diagonal(
    ncol(x),
    penalty_values
  )
  
  system <- (
    Matrix::crossprod(x) +
      penalty_matrix
  )
  
  decomposition <- Matrix::Cholesky(
    Matrix::forceSymmetric(system),
    LDL = FALSE
  )
  
  coefficients <- as.numeric(
    Matrix::solve(
      decomposition,
      Matrix::crossprod(x, data$oreb)
    )
  )
  
  names(coefficients) <- colnames(x)
  
  if (any(!is.finite(coefficients))) {
    stop("The model produced nonfinite coefficients.")
  }
  
  list(
    coefficients = coefficients,
    players = players,
    include_context = include_context,
    penalty = penalty,
    features = colnames(features)
  )
}

# ------------------------------------------------------------
# Generate predictions using a fitted model
# ------------------------------------------------------------

predict_rapm_r <- function(model, data) {
  
  x <- lineup_design(
    data,
    model$players,
    model$include_context
  )
  
  if (!identical(colnames(x), model$features)) {
    stop("The prediction columns do not match the fitted model.")
  }
  
  as.numeric(
    cbind(intercept = 1, x) %*%
      model$coefficients
  )
}

# ------------------------------------------------------------
# Evaluate rebound predictions
# ------------------------------------------------------------

score_rebounds <- function(data, prediction) {
  
  if (
    length(prediction) != nrow(data) ||
    any(!is.finite(prediction))
  ) {
    stop("Invalid predictions.")
  }
  
  probabilities <- pmin(
    pmax(prediction, 1e-12),
    1 - 1e-12
  )
  
  data.frame(
    opportunities = nrow(data),
    games = length(unique(data$game_id)),
    
    brier = mean(
      (probabilities - data$oreb)^2
    ),
    
    log_loss = -mean(
      data$oreb * log(probabilities) +
        (1 - data$oreb) * log1p(-probabilities)
    ),
    
    predicted_oreb_rate = mean(probabilities),
    observed_oreb_rate = mean(data$oreb),
    
    outside_unit_interval = sum(
      prediction < 0 | prediction > 1
    )
  )
}

# ------------------------------------------------------------
# Convert model coefficients into player ratings
# ------------------------------------------------------------

ratings_r <- function(
    model,
    data,
    player_names,
    minimum
) {
  
  coefficients <- model$coefficients
  
  ratings <- data.frame(
    player_id = model$players,
    
    player_name = vapply(
      as.character(model$players),
      function(id) {
        
        value <- player_names[[id]]
        
        if (is.null(value)) {
          id
        } else {
          as.character(value)
        }
      },
      character(1)
    )
  )
  
  for (role in names(role_columns)) {
    
    ids <- as.vector(
      t(
        as.matrix(
          data[role_columns[[role]]]
        )
      )
    )
    
    positions <- match(
      ids,
      model$players
    )
    
    outcome <- if (role == "off") {
      data$oreb
    } else {
      1 - data$oreb
    }
    
    opportunities <- tabulate(
      positions,
      nbins = length(model$players)
    )
    
    recoveries <- tabulate(
      positions[
        rep(outcome == 1L, each = 5L)
      ],
      nbins = length(model$players)
    )
    
    effects <- 100 * coefficients[
      paste0(role, "_", model$players)
    ]
    
    # Center separately within each role.
    effects <- effects - weighted.mean(
      effects,
      opportunities
    )
    
    ratings[[paste0(role, "_opportunities")]] <-
      opportunities
    
    ratings[[paste0(role, "_on_floor_rebound_pct")]] <-
      ifelse(
        opportunities > 0L,
        100 * recoveries / opportunities,
        NA_real_
      )
    
    ratings[[paste0(role, "_rapm_per100")]] <-
      as.numeric(effects)
    
    ratings[[paste0(role, "_display_eligible")]] <-
      opportunities >= minimum
  }
  
  ratings
}

# ------------------------------------------------------------
# Bootstrap the held-out Brier-score difference
#
# Resample whole games to retain within-game dependence.
# Negative differences favor RAPM over the baseline.
# ------------------------------------------------------------

bootstrap_games_r <- function(
    data,
    candidate,
    baseline,
    repetitions,
    seed
) {
  
  clip <- function(value) {
    pmin(pmax(value, 0), 1)
  }
  
  difference <- (
    clip(candidate) - data$oreb
  )^2 - (
    clip(baseline) - data$oreb
  )^2
  
  grouped <- rowsum(
    cbind(
      difference = difference,
      count = 1
    ),
    data$game_id,
    reorder = TRUE
  )
  
  set.seed(seed)
  
  draws <- replicate(
    repetitions,
    {
      
      indices <- sample.int(
        nrow(grouped),
        nrow(grouped),
        replace = TRUE
      )
      
      sum(grouped[indices, 1L]) /
        sum(grouped[indices, 2L])
    }
  )
  
  interval <- quantile(
    draws,
    c(0.025, 0.975),
    names = FALSE
  )
  
  data.frame(
    brier_difference = mean(difference),
    lower_95 = interval[1L],
    upper_95 = interval[2L],
    games = nrow(grouped),
    repetitions = repetitions
  )
}

# ------------------------------------------------------------
# Run training, validation, final testing, and historical refit
# ------------------------------------------------------------

fit_analysis_r <- function(collected, cfg) {
  
  data <- collected$opportunities
  
  validate_opportunities_r(data)
  
  settings <- list(
    train = cfg$training_seasons,
    validation = cfg$validation_seasons,
    test = cfg$test_seasons
  )
  
  if (anyDuplicated(unlist(settings))) {
    stop("The split seasons overlap.")
  }
  
  splits <- lapply(
    settings,
    function(seasons) {
      data[
        data$season %in% seasons,
        ,
        drop = FALSE
      ]
    }
  )
  
  split_sizes <- vapply(
    splits,
    nrow,
    integer(1)
  )
  
  if (
    any(split_sizes == 0L) ||
    sum(split_sizes) != nrow(data)
  ) {
    stop("Missing or unassigned split data.")
  }
  
  train <- splits$train
  validation <- splits$validation
  test <- splits$test
  
  if (
    max(train$game_date) >= min(validation$game_date) ||
    max(validation$game_date) >= min(test$game_date)
  ) {
    stop("The splits are not chronological.")
  }
  
  coverage <- aggregate(
    cbind(
      missed_field_goals,
      opportunities,
      excluded_period_count
    ) ~ season,
    data = collected$audit,
    FUN = sum
  )
  
  coverage$games <- as.integer(
    table(collected$audit$season)[coverage$season]
  )
  
  coverage$retained_fraction <- (
    coverage$opportunities /
      coverage$missed_field_goals
  )
  
  if (
    collected$mode == "full" &&
    any(
      coverage$games < 1200L |
      coverage$retained_fraction < 0.90
    )
  ) {
    stop("Insufficient full-season coverage. Inspect the game audit.")
  }
  
  selected <- list()
  validation_rows <- list()
  
  for (
    model_name in c(
      "lineup_rapm",
      "context_rapm"
    )
  ) {
    
    candidates <- lapply(
      cfg$ridge_penalties,
      function(penalty) {
        
        model <- fit_rapm_r(
          train,
          penalty,
          include_context = model_name == "context_rapm"
        )
        
        score <- score_rebounds(
          validation,
          predict_rapm_r(model, validation)
        )
        
        list(
          model = model,
          score = score
        )
      }
    )
    
    scores <- do.call(
      rbind,
      lapply(
        seq_along(candidates),
        function(i) {
          cbind(
            model = model_name,
            penalty = cfg$ridge_penalties[i],
            candidates[[i]]$score
          )
        }
      )
    )
    
    validation_rows[[model_name]] <- scores
    
    # Select the lowest validation Brier score.
    # Exact ties favor stronger regularization.
    best <- order(
      scores$brier,
      -scores$penalty
    )[1L]
    
    selected[[model_name]] <-
      candidates[[best]]$model
  }
  
  # Fit the context-only baseline on training data.
  context_train <- cbind(
    intercept = 1,
    as.matrix(train[context_columns])
  )
  
  context_fit <- lm.fit(
    context_train,
    train$oreb
  )
  
  if (anyNA(context_fit$coefficients)) {
    stop("The context-only baseline is rank deficient.")
  }
  
  context_test <- cbind(
    intercept = 1,
    as.matrix(test[context_columns])
  )
  
  predictions <- list(
    training_mean = rep(
      mean(train$oreb),
      nrow(test)
    ),
    
    miss_context = as.numeric(
      context_test %*%
        context_fit$coefficients
    )
  )
  
  # Evaluate the selected models without refitting.
  for (model_name in names(selected)) {
    predictions[[model_name]] <- predict_rapm_r(
      selected[[model_name]],
      test
    )
  }
  
  metrics <- do.call(
    rbind,
    lapply(
      names(predictions),
      function(model_name) {
        cbind(
          model = model_name,
          score_rebounds(
            test,
            predictions[[model_name]]
          )
        )
      }
    )
  )
  
  comparison <- bootstrap_games_r(
    data = test,
    candidate = predictions$context_rapm,
    baseline = predictions$miss_context,
    repetitions = cfg$bootstrap_repetitions,
    seed = cfg$seed
  )
  
  # Fit a separate historical model for player reports.
  # Preserve penalty strength per observation.
  historical_penalty <- (
    selected$context_rapm$penalty *
      nrow(data) /
      nrow(train)
  )
  
  historical <- fit_rapm_r(
    data,
    historical_penalty,
    include_context = TRUE
  )
  
  ratings <- ratings_r(
    historical,
    data,
    collected$names,
    cfg$minimum_display_opportunities
  )
  
  training_ratings <- ratings_r(
    selected$context_rapm,
    train,
    collected$names,
    cfg$minimum_display_opportunities
  )
  
  split_summary <- do.call(
    rbind,
    lapply(
      names(splits),
      function(split_name) {
        
        frame <- splits[[split_name]]
        
        data.frame(
          split = split_name,
          
          seasons = paste(
            unique(frame$season),
            collapse = ", "
          ),
          
          first_date = min(frame$game_date),
          last_date = max(frame$game_date),
          
          games = length(
            unique(frame$game_id)
          ),
          
          opportunities = nrow(frame)
        )
      }
    )
  )
  
  list(
    config = cfg,
    mode = collected$mode,
    
    ratings = ratings,
    training_ratings = training_ratings,
    
    frozen_models = selected,
    historical_model = historical,
    
    metrics = metrics,
    
    validation_scores = do.call(
      rbind,
      validation_rows
    ),
    
    comparison = comparison,
    splits = split_summary,
    coverage = coverage,
    audit = collected$audit,
    
    test_predictions = cbind(
      test[c("game_id", "shot_event_id", "oreb")],
      as.data.frame(predictions)
    ),
    
    created_utc = format(
      Sys.time(),
      tz = "UTC",
      usetz = TRUE
    ),
    
    session_info = capture.output(
      sessionInfo()
    )
  )
}