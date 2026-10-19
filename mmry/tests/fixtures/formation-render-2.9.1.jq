# The message renderer of the RELEASED plugin 2.9.1, verbatim (#31410 requirement 5).
#
# Copied byte for byte from mmry/hooks-handlers/formation-check.sh at tag v2.9.1
# (041b9413eb940c1843ac328cbe695e3193107554), lines 330 to 337 (the shell quote and redirection that
# close line 337 removed), the jq program the delivery hook
# ran over the poll response. Held here because CI checks out without tags, so the test cannot
# read the tag itself. handlers/formation-member-names.bats runs it over the NEW response shape to
# prove a customer still on 2.9.1 keeps receiving messages after the service adds the sender's
# member id and name. Do not edit it: it is evidence of what is already installed, not code.
        if type == "array" then
            .[] | (if ((.senderSessionID // null) == null and (.senderUserID // null) == null)
                   then "  [MMRY] "
                   else "  [" + ((.senderRole // "member")) + " " + ((.senderSessionID // "?") | tostring) + "] "
                   end)
                  + (if (.recipientMemberID // null) != null then "DIRECTED TO YOU: " else "" end)
                  + ((.content // .topic // "") | tostring)
        else empty end
