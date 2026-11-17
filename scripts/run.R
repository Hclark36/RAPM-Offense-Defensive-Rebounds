
# ------------------------------------------------------------
# Run the complete rebounding RAPM pipeline
# Run from the repository's RStudio project.
# ------------------------------------------------------------

source("scripts/setup.R")
source("config.R")

source("R/data.R")
source("R/model.R")
source("R/report.R")


# ------------------------------------------------------------
# Collect data
# Existing verified game caches are reused.
# ------------------------------------------------------------

collected <- collect_r(
  cfg = config
)


# ------------------------------------------------------------
# Load full player names
# ------------------------------------------------------------

collected$names <- player_names_r(
  cfg = config,
  fallback = collected$names
)

saveRDS(
  collected,
  "data/processed/r/full_data.rds"
)


# ------------------------------------------------------------
# Fit, validate, and evaluate the models
# ------------------------------------------------------------

analysis <- fit_analysis_r(
  collected = collected,
  cfg = config
)


# ------------------------------------------------------------
# Add raw season-by-season team recovery rates
# ------------------------------------------------------------

analysis$player_seasons <- player_seasons_r(
  data = collected$opportunities,
  players = analysis$historical_model$players
)


# ------------------------------------------------------------
# Save analysis outputs
# ------------------------------------------------------------

save_analysis_r(
  bundle = analysis,
  output = "output/r/full"
)


# ------------------------------------------------------------
# Generate the configured player's report
# ------------------------------------------------------------

report_player_r(
  bundle = analysis,
  selection = config$selected_player,
  output = "output/r/full"
)


# ------------------------------------------------------------
# Display held-out results
# ------------------------------------------------------------

print(analysis$metrics)

print(analysis$comparison)

message("Rebounding RAPM analysis complete.")