# permission-rule-match.jq - what a Claude Code permissions block decides for a command (#34651).
#
# A TEST AID, written for this repository because Claude Code ships no offline rule checker. It follows
# the rules Claude Code documents for Bash permission rules (code.claude.com/docs/en/permissions, read
# 2026-11-24) and nothing else. It is not Claude Code's own matcher: a result here is evidence about the
# text of the rules, never proof of what a live session does.
#
# What it follows:
#   - deny is checked first, then ask, then allow; the first list with a match decides;
#   - a rule with no * matches one exact command;
#   - a * stands for any text, spaces included, anywhere in the rule;
#   - a rule ending " *" whose only * is that one also matches the bare command ("git log *" matches
#     "git log"), and ":*" at the end is the same as " *";
#   - a compound command is split at && || ; | |& & and line breaks; deny and ask apply when any part
#     matches, and allow needs every part to match;
#   - timeout, time, nice, nohup, command, builtin and noglob in front are taken off before matching;
#   - a deny or ask rule matches past a leading VAR=value; an allow rule does not.
#
# Where it is stricter or simpler than the documentation, always toward "not allowed":
#   - it splits at the operators even inside quotes, and at $( ) ` ( ) as well, so a quoted && makes a
#     command "none" here that Claude Code might allow;
#   - it takes off no "known safe" variable assignment for an allow rule (the documentation does not
#     list them);
#   - it knows nothing of Claude Code's built-in read-only commands, permission modes, hooks or the
#     sandbox: "none" means "no rule decides", which in the default mode is a prompt;
#   - Read and Edit path rules are not matched here.
#
# Use:  jq -r --arg tool Bash --rawfile cmds <file of commands, one a line> -f permission-rule-match.jq <settings.json>
# Prints one line per command: the decision (deny, ask, allow or none), a tab, the command.

def rule_parts: capture("^(?<tool>[A-Za-z]+)[(](?<spec>.*)[)]$");

# The literal text of a rule, safe inside a regular expression.
def literal: gsub("(?<c>[^A-Za-z0-9 ])"; "\\\(.c)");

def rule_regex:
    (if endswith(":*") then .[0:length - 2] + " *" else . end) as $spec
    | ($spec | split("*")) as $parts
    | if ($parts | length) == 2 and ($spec | endswith(" *"))
      then "^" + ($parts[0] | rtrimstr(" ") | literal) + "( .*)?$"
      else "^" + ($parts | map(literal) | join(".*")) + "$"
      end;

def specs($list; $tool):
    [ (.permissions[$list] // [])[] | (rule_parts? // empty)
      | select((.tool | ascii_downcase) == ($tool | ascii_downcase)) | .spec | rule_regex ];

def strip_wrappers:
    def once: sub("^(?:(?:time|nice|nohup|command|builtin|noglob) +|timeout +[0-9.]+[smhd]? +)"; "");
    . as $in | once | if . == $in then . else strip_wrappers end;

def strip_assignments:
    . as $in | sub("^[A-Za-z_][A-Za-z0-9_]*=[^ ]* +"; "") | if . == $in then . else strip_assignments end;

def parts:
    [ splits("&&|\\|\\||;|\\|&|\\||(?<![>0-9])&(?!>)|\\n|\\$\\(|`|\\(|\\)")
      | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) | strip_wrappers ];

def matches_any($regexes): . as $c | any($regexes[]; . as $r | $c | test($r));

def decide($deny; $ask; $allow):
    parts as $p
    | ($p | map(strip_assignments | strip_wrappers)) as $bare
    | if ($p | length) == 0 then "none"
      elif any($bare[]; matches_any($deny)) then "deny"
      elif any($bare[]; matches_any($ask)) then "ask"
      elif all($p[]; matches_any($allow)) then "allow"
      else "none"
      end;

specs("deny"; $tool) as $deny | specs("ask"; $tool) as $ask | specs("allow"; $tool) as $allow
| $cmds | split("\n") | map(sub("\r$"; "")) | map(select(length > 0))[]
| "\(decide($deny; $ask; $allow))\t\(.)"
