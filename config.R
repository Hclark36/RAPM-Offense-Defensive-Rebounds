# Settings for the NBA rebounding RAPM project.

config <- list(
  
  # Player used for the default report.
  # Accepts a full name or NBA player ID.
  selected_player = "Bam Adebayo",
  
  # Seasons used to fit the league model.
  training_seasons = "2023-24",
  
  # Season used to select the ridge penalty.
  validation_seasons = "2024-25",
  
  # Held-out season used for final evaluation.
  test_seasons = "2025-26",
  
  # Pinned SportsDataverse archive version.
  schedule_commit =
    "0bca6cf72d9f879140148882657affc1591efd13",
  
  # Candidate regularization strengths.
  ridge_penalties = c(
    10,
    30,
    100,
    300,
    1000,
    3000,
    10000
  ),
  
  # Minimum role-specific opportunities for a displayed rank.
  minimum_display_opportunities = 500L,
  
  # Whole-game bootstrap resamples for model comparison.
  bootstrap_repetitions = 2000L,
  
  # Parallel collection on macOS/Linux.
  # Windows uses sequential collection.
  collection_workers = 4L,
  
  # Reproducible bootstrap sampling.
  seed = 2026L
)