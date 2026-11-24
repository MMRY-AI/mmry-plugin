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
#   - timeout, time, nice (with or without -n N), nohup, command, builtin, noglob, stdbuf and a bare
#     xargs in front are taken off before matching, and so is the do, then or else that opens the body
#     of a loop or an if;
#   - a deny or ask rule matches past a leading VAR=value; an allow rule does not.
#
# THE BUILT-IN READ-ONLY COMMANDS (round 3, Seat A's delta A3). The documentation: "Claude Code
# recognizes a built-in set of Bash commands as read-only and runs them without a permission prompt in
# every mode ... ls, cat, echo, pwd, head, tail, grep, find, wc, which, diff, stat, du, cd, and
# read-only forms of git", and a Read deny rule applies to the files such a command names. Until round 3
# this helper answered "none" for them, so a check that "nothing is allowed" passed on a read the rules
# did not deny. Now:
#   - a part that is one of those commands, and that no deny or ask rule matches, counts as ALLOWED;
#   - a part that reads files (cat, head, tail, grep, find, wc, diff, stat, du, ls) is DENIED when one
#     of its words matches a Read deny rule (the path patterns: ./ from the working folder, // from the
#     root, ** any folders, * any text inside one folder);
#   - "read-only forms of git" is not spelled out by the documentation, so it is read WIDE here, toward
#     reporting an allow: status, log, diff, show, rev-parse, ls-files, blame, describe, shortlog and the
#     listing forms of branch, behind any of git's own global options (-C <dir>, -c <k>=<v>, --git-dir,
#     --no-pager, -P and the rest). A rule file must therefore DENY "git ... -c core.fsmonitor=<cmd>
#     status" and "git log --output=<file>" to get anything but "allow" for them here. Whether a live
#     session treats each such form as read-only was not measured.
# Pass --arg readonly 0 to switch this off and see what the Bash rules alone decide (E-05's rows from
# the documentation's rule tables do).
#
# Where it is stricter or simpler than the documentation, always toward "not allowed":
#   - it splits at the operators even inside quotes, and at $( ) ` ( ) as well, so a quoted && makes a
#     command "none" here that Claude Code might allow;
#   - it takes off no "known safe" variable assignment for an allow rule (the documentation does not
#     list them);
#   - a command with a redirect (< or >) is never "allow" here: Claude Code checks the redirect's
#     target against the Read and Edit rules, and this helper matches Read rules only against the
#     words of a read-only command;
#   - it knows nothing of permission modes, hooks or the sandbox: "none" means "no rule decides and it
#     is not a built-in read-only command", which in the default mode is a prompt;
#   - Edit path rules are not matched here, and ~ in a Read rule is not expanded.
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

# A Read rule's path pattern as a regular expression over a path written with forward slashes and no
# leading "./". "//x" is the root; "./x" and "x" are the working folder; "**/" is any folders or none;
# "**" is anything; "*" is anything inside one folder.
def path_regex:
    (if startswith("//") then "/" + .[2:] elif startswith("./") then .[2:] else . end)
    | [ splits("[*][*]/") ]
    | map([ splits("[*][*]") ] | map(split("*") | map(literal) | join("[^/]*")) | join(".*"))
    | "^" + join("(.*/)?") + "$";

def read_denies:
    [ (.permissions.deny // [])[] | (rule_parts? // empty) | select(.tool == "Read") | .spec | path_regex ];

def strip_wrappers:
    def once: sub("^(?:(?:time|nohup|command|builtin|noglob|xargs|do|then|else) +|nice +-n +-?[0-9]+ +|nice +|stdbuf +(?:-[^ ]+ +)+|timeout +[0-9.]+[smhd]? +)"; "");
    . as $in | once | if . == $in then . else strip_wrappers end;

def strip_assignments:
    . as $in | sub("^[A-Za-z_][A-Za-z0-9_]*=[^ ]* +"; "") | if . == $in then . else strip_assignments end;

def parts:
    [ splits("&&|\\|\\||;|\\|&|\\||(?<![>0-9])&(?!>)|\\n|\\$\\(|`|\\(|\\)")
      | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) | strip_wrappers ];

def matches_any($regexes): . as $c | any($regexes[]; . as $r | $c | test($r));

# ---- the built-in read-only commands ----
def readonly_on: (($ARGS.named.readonly // "1") | tostring) != "0";

def reads_files: test("^(cat|head|tail|grep|find|wc|diff|stat|du|ls)( |$)");

def readonly_plain:
    test("^(ls|cat|echo|pwd|head|tail|grep|wc|which|diff|stat|du|cd)( |$)")
    or (test("^find( |$)") and (test(" -(exec|execdir|ok|okdir|delete|fprint|fprintf|fls)( |$)") | not));

def readonly_git:
    test("^git( +(-C +[^ ]+|-c +[^ ]+|--git-dir(=| +)[^ ]+|--work-tree(=| +)[^ ]+|--namespace(=| +)[^ ]+|--no-pager|-P|-p|--paginate|--bare|--no-replace-objects|--literal-pathspecs|--no-optional-locks|--config-env(=| +)[^ ]+|--exec-path(=| +)[^ ]+))*"
         + " +(status|log|diff|show|rev-parse|ls-files|blame|describe|shortlog)( |$)")
    or test("^git( +(-C +[^ ]+|--no-pager|-P))* +branch( +(-a|-r|-v|-vv|--all|--remotes|--list|--show-current))*$");

def readonly_part: readonly_plain or readonly_git;

# The words of a part as paths: quotes off, "./" off, a Windows drive as "/c/...".
def path_words:
    [ splits(" +") | select(length > 0) | gsub("[\"']"; "") | select(startswith("-") | not)
      | (if test("^[A-Za-z]:/") then "/" + (.[0:1] | ascii_downcase) + .[2:] else . end)
      | (if startswith("./") then .[2:] else . end) ];

# A relative word is also tried as if it stood under the root, so a "//**/x/**" rule sees it.
def read_denied($rd):
    reads_files and any(path_words[1:][]; . as $w | any($rd[]; . as $r | ($w | test($r)) or (("/" + ($w | ltrimstr("/"))) | test($r))));

def decide($deny; $ask; $allow; $rd):
    parts as $p
    | ($p | map(strip_assignments | strip_wrappers)) as $bare
    | if ($p | length) == 0 then "none"
      elif any($bare[]; matches_any($deny)) then "deny"
      elif readonly_on and any($bare[]; read_denied($rd)) then "deny"
      elif any($bare[]; matches_any($ask)) then "ask"
      elif any($p[]; test("[<>]")) then "none"
      elif all($p[]; matches_any($allow) or (readonly_on and readonly_part)) then "allow"
      else "none"
      end;

specs("deny"; $tool) as $deny | specs("ask"; $tool) as $ask | specs("allow"; $tool) as $allow
| read_denies as $rd
| $cmds | split("\n") | map(sub("\r$"; "")) | map(select(length > 0))[]
| "\(decide($deny; $ask; $allow; $rd))\t\(.)"
