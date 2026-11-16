include "lib";
if (.scripts | length) == 0 then "no handoff scripts"
elif (.scripts | length) == 1 and (.scripts[0] | has("content")) then
  (.scripts[0] | "\(.path)" | fit), "", (.scripts[0].content | rtrimstr("\n")),
  "", ("run it, after reading it:  sudo bash \(.scripts[0].path)" | fit)
else
  (.scripts[] | "\(.created | pad(21)) \(.title | trunc(46) | pad(46)) \(.name | trunc(30))" | fit)
end,
unavailable_lines
