if (!file.exists("config.R")) stop("Run from the project root.")
if (dir.exists(".Rlib")) .libPaths(c(normalizePath(".Rlib"), .libPaths()))
source("R/model.R")
source("R/report.R")
source("R/data.R")
set.seed(11)
n <- 3000L
offense <- t(replicate(n, sample(1:10, 5L)))
defense <- t(replicate(n, sample(11:20, 5L)))
fixture <- data.frame(game_id = as.character(rep(1:30, each = 100)),
  game_date = "2024-01-01", season = "2023-24", shot_event_id = seq_len(n),
  three = rbinom(n, 1L, .35), blocked = rbinom(n, 1L, .1), offense_home = rbinom(n, 1L, .5))
fixture[paste0("off_", 1:5)] <- as.data.frame(offense)
fixture[paste0("def_", 1:5)] <- as.data.frame(defense)
probability <- .3 + .12 * (rowSums(offense == 1L) > 0L) - .12 * (rowSums(defense == 11L) > 0L)
fixture$oreb <- rbinom(n, 1L, probability)
validate_opportunities_r(fixture)
model <- fit_rapm_r(fixture, 100)
x <- as.matrix(cbind(1, lineup_design(fixture, model$players, TRUE)))
penalty <- diag(c(rep(0, 4L), rep(100, 2L * length(model$players))))
reference <- solve(crossprod(x) + penalty, crossprod(x, fixture$oreb))
stopifnot(max(abs(as.numeric(x %*% reference) - predict_rapm_r(model, fixture))) < 1e-8)
ratings <- ratings_r(model, fixture, list("1" = "Test Player"), 100L)
stopifnot(ratings$off_rapm_per100[ratings$player_id == 1L] > 5,
          ratings$def_rapm_per100[ratings$player_id == 11L] > 5)
altered <- fixture
altered$oreb <- 1L - altered$oreb
stopifnot(identical(predict_rapm_r(model, fixture), predict_rapm_r(model, altered)))
unseen <- fixture
unseen$off_1 <- 999999L
stopifnot(all(is.finite(predict_rapm_r(model, unseen))))
duplicate <- rbind(fixture, fixture[1L, ])
stopifnot(inherits(try(validate_opportunities_r(duplicate), silent = TRUE), "try-error"))
shrunken <- fit_rapm_r(fixture, 10000)
stopifnot(sum(shrunken$coefficients[-(1:4)]^2) < sum(model$coefficients[-(1:4)]^2))
stopifnot(resolve_player_r("test player", ratings)$player_id == 1L,
          resolve_player_r("1", ratings)$player_id == 1L)
ambiguous <- ratings
ambiguous$player_name[2L] <- "Test Player Two"
stopifnot(inherits(try(resolve_player_r("Test", ambiguous), silent = TRUE), "try-error"))
events <- data.frame(actionType = rep("2pt", 10L), subType = "Jump Shot", personId = 1:10,
  assistPersonId = 0, blockPersonId = 0, stealPersonId = 0, foulDrawnPersonId = 0)
events$actionType[5L] <- "jumpball"
teams <- setNames(rep(c(100, 200), each = 5L), as.character(1:10))
starters <- period_starters(events, teams, NULL)
stopifnot(identical(as.integer(starters[["100"]]), 1:5), identical(as.integer(starters[["200"]]), 6:10))
accented <- ratings
accented$player_name[1L] <- "Nikola Joki\u0107"
stopifnot(resolve_player_r("Nikola Jokic", accented)$player_id == 1L)
message("R checks passed for exact ridge, role signs, shrinkage, input validation, unseen players, and player lookup.")
