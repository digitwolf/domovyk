# Shared helpers for the text Renderers (include "lib";).
# Every line a Renderer prints must fit in 100 columns (requirement 4.1).

def width: 100;

# trunc(n): cut a string to n characters, ending with "…" when cut.
def trunc(n): tostring | if length > n then .[0:(n - 1)] + "…" else . end;

# fit: cut a line to the 100-column limit.
def fit: trunc(width);

# human: bytes as B, K, M, G, T with one decimal, rounded to nearest.
def human:
  if . == null then "?"
  else (tonumber) as $b
    | if $b < 1024 then "\($b) B"
      else [["K", 1024], ["M", 1048576], ["G", 1073741824], ["T", 1099511627776]]
        | map(select($b >= .[1])) | last
        | "\(($b / .[1] * 10 | round) / 10)\(.[0])"
      end
  end;

# pad(n): left-justify in n columns.
def pad(n): tostring | if length >= n then .[0:n] else . + (" " * (n - length)) end;

# The footer every Renderer prints when Sources were unavailable.
def unavailable_lines:
  if (.unavailable | length) == 0 then empty
  else "", "unavailable:",
    (.unavailable[] | "  \(.source): \(.reason)"
      + (if .package then " (apt install \(.package))" else "" end)
      + (if .hint then ", \(.hint)" else "" end) | fit)
  end;
