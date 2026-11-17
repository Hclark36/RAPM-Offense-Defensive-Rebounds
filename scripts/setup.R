# Install missing dependencies into a project-local library.

if (!file.exists("config.R")) {
  stop("Set your working directory to the project root.")
}

dir.create(
  ".Rlib",
  showWarnings = FALSE
)

.libPaths(
  c(
    normalizePath(".Rlib"),
    .libPaths()
  )
)

required_packages <- c(
  "jsonlite",
  "arrow",
  "curl",
  "digest",
  "Matrix",
  "ggplot2"
)

installed <- vapply(
  required_packages,
  requireNamespace,
  logical(1),
  quietly = TRUE
)

missing_packages <- required_packages[!installed]

repositories <- getOption("repos")

if (is.null(repositories) || !length(repositories)) {
  repositories <- c(
    CRAN = "https://cloud.r-project.org"
  )
}

repositories[repositories == "@CRAN@"] <-
  "https://cloud.r-project.org"

if (length(missing_packages) > 0L) {
  install.packages(
    missing_packages,
    repos = repositories
  )
}

available <- vapply(
  required_packages,
  requireNamespace,
  logical(1),
  quietly = TRUE
)

if (any(!available)) {
  stop(
    "These packages still need installation: ",
    paste(
      required_packages[!available],
      collapse = ", "
    )
  )
}

message("R dependencies are ready.")