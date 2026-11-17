# Run from the repository root after fitting the R model.
if (!file.exists("dashboard/template.html")) stop("Run from the project root.")
if (dir.exists(".Rlib")) .libPaths(c(normalizePath(".Rlib"), .libPaths()))
if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite first.")
path <- "output/r/full/analysis.rds"
if (!file.exists(path)) stop('Fit the R model first with source("scripts/run.R").')
bundle <- readRDS(path)
payload <- list(
  players = bundle$ratings,
  seasons = bundle$player_seasons,
  metrics = bundle$metrics,
  splits = bundle$splits,
  coverage = bundle$coverage,
  comparison = bundle$comparison,
  metadata = list(
    title = "Rebound Lab",
    author = "Hunter Clark",
    default_player = "1628389",
    minimum_opportunities = bundle$config$minimum_display_opportunities,
    training_seasons = bundle$config$training_seasons,
    validation_seasons = bundle$config$validation_seasons,
    test_seasons = bundle$config$test_seasons,
    ridge_penalty = bundle$frozen_models$context_rapm$penalty,
    archive_commit = bundle$config$schedule_commit,
    fitted_utc = bundle$created_utc,
    built_utc = format(Sys.time(), tz = "UTC", usetz = TRUE)
  )
)
json <- jsonlite::toJSON(payload, auto_unbox = TRUE, dataframe = "rows", digits = 10,
                         na = "null", null = "null")
# Keep source strings inside the embedded application/json element.
json <- gsub("<", "\\u003c", json, fixed = TRUE)
template <- paste(readLines("dashboard/template.html", warn = FALSE, encoding = "UTF-8"), collapse = "\n")
parts <- strsplit(template, "__RAPM_DATA__", fixed = TRUE)[[1L]]
if (length(parts) != 2L) stop("Expected one dashboard data marker.")
html <- paste0(parts[1L], json, parts[2L])
dir.create("docs", showWarnings = FALSE)
writeLines(enc2utf8(html), "docs/index.html", useBytes = TRUE)
message("Built docs/index.html with ", nrow(bundle$ratings), " players.")
