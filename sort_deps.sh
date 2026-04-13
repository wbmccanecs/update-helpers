#! /bin/sh

# This awk script extracts the org and name values using regular expressions
# and prepends them to the original line, separated by the chosen delimiter.
DELIMITER=$(echo -ne "\037")

/usr/bin/awk -v d="$DELIMITER" '
{
    org_val = "";
    name_val = "";

    if (match($0, /org => "([^"]+)"/, org_match_arr)) {
        org_val = org_match_arr[1];
    }

    if (match($0, /name => "([^"]+)"/, name_match_arr)) {
        name_val = name_match_arr[1];
    }

    print org_val d name_val d $0
}' |
    /usr/bin/sort -t "$DELIMITER" -k1,1 -k2,2 |
    cut -d "$DELIMITER" -f3-
