#!/usr/bin/env bash
# Shared helper: emit a GitHub Actions error annotation with a multi-line
# message. Annotations show up on the PR and through the checks API, so a
# failure can be diagnosed without opening the job log.

# annotate <level> <title> <message>
annotate() {
  local level=$1 title=$2 text=$3
  text=${text//'%'/'%25'}
  text=${text//$'\r'/'%0D'}
  text=${text//$'\n'/'%0A'}
  echo "::${level} title=${title}::${text}"
}

# annotate_error <title> <message>
annotate_error() { annotate error "$1" "$2"; }

# annotate_warning <title> <message>
annotate_warning() { annotate warning "$1" "$2"; }
