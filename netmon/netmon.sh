#!/bin/zsh
# Network Monitor - Shows internet traffic with per-second rates
# Excludes localhost and local network traffic
# Tracks by process name (aggregates across restarts), shows current PID
# Use < and > to change sort column (refreshes immediately)
# Use d to toggle showing dead processes

# Create a temporary directory for all files
TMP_DIR=$(mktemp -d /tmp/netmon.XXXXXX) || exit 1

PREV_FILE="$TMP_DIR/prev"
HISTORY_FILE="$TMP_DIR/history"
CURR_FILE="$TMP_DIR/curr"

INTERVAL=2
POLL_INTERVAL=0.1
MAX_ROWS=20

# Sort column: 1=PROCESS, 2=IN(MB), 3=OUT(MB), 4=IN/s, 5=OUT/s
SORT_COL=5
COL_NAMES=("PROCESS (PID)" "IN (MB)" "OUT (MB)" "IN/s" "OUT/s")

# Toggle for showing dead processes
SHOW_DEAD=1

# ANSI escape codes
CURSOR_HOME='\033[H'
CLEAR_LINE='\033[K'
CLEAR_SCREEN='\033[2J'
HIDE_CURSOR='\033[?25l'
SHOW_CURSOR='\033[?25h'

# Colors
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null
  echo -ne "${SHOW_CURSOR}"
  stty sane 2>/dev/null
  exit 0
}
trap cleanup INT TERM EXIT

get_header() {
  local header=""
  for i in {1..5}; do
    local name="${COL_NAMES[$i]}"
    if [[ $i -eq $SORT_COL ]]; then
      if [[ $i -eq 1 ]]; then
        header+="${CYAN}$(printf '%-30s' "$name")${NC} "
      else
        header+="${CYAN}$(printf '%12s' "$name")${NC} "
      fi
    else
      if [[ $i -eq 1 ]]; then
        header+="$(printf '%-30s' "$name") "
      else
        header+="$(printf '%12s' "$name") "
      fi
    fi
  done
  echo -e "$header${CLEAR_LINE}"
}

refresh_display() {
  echo -ne "${CURSOR_HOME}"

  local dead_status="showing"
  [[ $SHOW_DEAD -eq 0 ]] && dead_status="hidden"

  echo -e "=== Internet Traffic $(date +%H:%M:%S) === (< > sort, d toggle dead [$dead_status], Ctrl+C exit)${CLEAR_LINE}"
  get_header
  echo -e "--------------------------------------------------------------------------------------------${CLEAR_LINE}"

  # Get current active processes from nettop
  # We capture the output to a file first to avoid pipe buffering issues and for debugging if needed
  nettop -P -L 1 2>/dev/null | tail -n +2 | \
    grep -vE "127\.0\.0\.1|::1|localhost|192\.168\.|^10\.|172\.(1[6-9]|2[0-9]|3[0-1])\." | \
    awk -F',' '$5+$6 > 0 {print $2 "|" $5 "|" $6}' > "$CURR_FILE"

  # Process data and generate sorted output with totals - all in one awk call
  awk -F'|' -v prev_file="$PREV_FILE" -v history_file="$HISTORY_FILE" -v interval="$INTERVAL" \
      -v sort_col="$SORT_COL" -v show_dead="$SHOW_DEAD" -v max_rows="$MAX_ROWS" \
      -v dim="${DIM}" -v nc="${NC}" -v yellow="${YELLOW}" -v clear_line="${CLEAR_LINE}" '
    BEGIN {
      # Load previous readings (Key: Full Process.PID)
      while ((getline line < prev_file) > 0) {
        n = split(line, a, "|")
        prev_in[a[1]] = a[2]
        prev_out[a[1]] = a[3]
      }
      close(prev_file)

      # Load historical values (Key: Process Name)
      while ((getline line < history_file) > 0) {
        n = split(line, a, "|")
        # Skip empty or invalid entries
        if (a[1] == "" || a[1] ~ /^[[:space:]]*$/) continue
        hist_in[a[1]] = a[2]
        hist_out[a[1]] = a[3]
        hist_status[a[1]] = a[4]
        hist_pid[a[1]] = a[5]
      }
      close(history_file)

      # Mark all historical entries as potentially dead
      for (proc in hist_in) {
        if (proc == "" || proc ~ /^[[:space:]]*$/) continue
        hist_status[proc] = "DEAD"
        hist_pid[proc] = "-"
      }
    }
    {
      full_name = $1
      in_bytes = $2
      out_bytes = $3

      # Extract process name and PID
      if (match(full_name, /\.[0-9]+$/)) {
        pid = substr(full_name, RSTART + 1)
        proc_name = substr(full_name, 1, RSTART - 1)
      } else {
        pid = "?"
        proc_name = full_name
      }

      # Skip empty or invalid process names
      if (proc_name == "" || proc_name ~ /^[[:space:]]*$/) next

      # Initialize history if needed
      if (hist_in[proc_name] == "") hist_in[proc_name] = 0
      if (hist_out[proc_name] == "") hist_out[proc_name] = 0

      # Calculate delta for THIS specific PID instance
      delta_in = 0
      delta_out = 0

      # Calculate delta for IN bytes
      if ((full_name in prev_in) && in_bytes >= prev_in[full_name]) {
        delta_in = in_bytes - prev_in[full_name]
      } else {
        delta_in = 0
      }

      # Calculate delta for OUT bytes
      if ((full_name in prev_out) && out_bytes >= prev_out[full_name]) {
        delta_out = out_bytes - prev_out[full_name]
      } else {
        delta_out = 0
      }

      # Update history with delta
      hist_in[proc_name] += delta_in
      hist_out[proc_name] += delta_out

      hist_status[proc_name] = "ALIVE"
      hist_pid[proc_name] = pid

      # Calculate rate for this PID
      pid_in_rate = delta_in / interval / 1024
      pid_out_rate = delta_out / interval / 1024

      # Aggregate rates for the process name
      current_in_rate[proc_name] += pid_in_rate
      current_out_rate[proc_name] += pid_out_rate

      # Store current values for next run (Key: Full Process.PID)
      current_in_save[full_name] = in_bytes
      current_out_save[full_name] = out_bytes
    }
    END {
      # Write updated history
      for (proc in hist_in) {
        print proc "|" hist_in[proc] "|" hist_out[proc] "|" hist_status[proc] "|" hist_pid[proc] > history_file
      }
      close(history_file)

      # Write current values for next comparison (Key: Full Process.PID)
      for (full in current_in_save) {
        print full "|" current_in_save[full] "|" current_out_save[full] > prev_file
      }
      close(prev_file)

      # Build array for sorting
      n = 0
      for (proc in hist_in) {
        # Skip empty/invalid process names
        if (proc == "" || proc ~ /^[[:space:]]*$/) continue
        if (show_dead == 0 && hist_status[proc] == "DEAD") continue

        n++
        entries[n, "status"] = hist_status[proc]
        entries[n, "name"] = proc
        entries[n, "pid"] = hist_pid[proc]
        entries[n, "in_mb"] = hist_in[proc]/1048576
        entries[n, "out_mb"] = hist_out[proc]/1048576
        entries[n, "in_rate"] = (hist_status[proc] == "ALIVE") ? current_in_rate[proc] + 0 : 0
        entries[n, "out_rate"] = (hist_status[proc] == "ALIVE") ? current_out_rate[proc] + 0 : 0
      }
      total_entries = n

      # Simple bubble sort (sufficient for ~20-30 entries)
      for (i = 1; i <= total_entries; i++) {
        for (j = i + 1; j <= total_entries; j++) {
          swap = 0
          if (sort_col == 1) {
            if (entries[i, "name"] > entries[j, "name"]) swap = 1
          } else if (sort_col == 2) {
            if (entries[i, "in_mb"] < entries[j, "in_mb"]) swap = 1
          } else if (sort_col == 3) {
            if (entries[i, "out_mb"] < entries[j, "out_mb"]) swap = 1
          } else if (sort_col == 4) {
            if (entries[i, "in_rate"] < entries[j, "in_rate"]) swap = 1
          } else if (sort_col == 5) {
            if (entries[i, "out_rate"] < entries[j, "out_rate"]) swap = 1
          }

          if (swap) {
            # Swap entries
            for (field in entries) {
              split(field, idx, SUBSEP)
              if (idx[1] == i) {
                tmp[idx[2]] = entries[i, idx[2]]
              }
            }
            for (field in entries) {
              split(field, idx, SUBSEP)
              if (idx[1] == i) {
                entries[i, idx[2]] = entries[j, idx[2]]
              }
            }
            for (k in tmp) {
              entries[j, k] = tmp[k]
              delete tmp[k]
            }
          }
        }
      }

      # Display sorted entries and calculate totals
      total_in = 0
      total_out = 0
      total_in_rate = 0
      total_out_rate = 0
      alive_count = 0
      dead_count = 0

      for (i = 1; i <= total_entries; i++) {
        total_in += entries[i, "in_mb"]
        total_out += entries[i, "out_mb"]

        if (entries[i, "status"] == "ALIVE") {
          total_in_rate += entries[i, "in_rate"]
          total_out_rate += entries[i, "out_rate"]
          alive_count++
        } else {
          dead_count++
        }

        if (i <= max_rows) {
          display_name = entries[i, "name"] " (" entries[i, "pid"] ")"
          if (entries[i, "status"] == "DEAD") {
            printf "%s%-30s %10.2f MB %10.2f MB %8s %8s%s%s\n", dim, display_name, entries[i, "in_mb"], entries[i, "out_mb"], "-", "-", nc, clear_line
          } else {
            printf "%-30s %10.2f MB %10.2f MB %8.1f KB/s %8.1f KB/s%s\n", display_name, entries[i, "in_mb"], entries[i, "out_mb"], entries[i, "in_rate"], entries[i, "out_rate"], clear_line
          }
        }
      }

      # Pad remaining rows
      for (i = total_entries + 1; i <= max_rows; i++) {
        printf "%s\n", clear_line
      }

      # Print separator and totals
      printf "--------------------------------------------------------------------------------------------%s\n", clear_line

      status_str = alive_count " alive"
      if (dead_count > 0) status_str = status_str ", " dead_count " dead"

      printf "%s%-30s %10.2f MB %10.2f MB %8.1f KB/s %8.1f KB/s%s%s\n", yellow, "TOTAL (" status_str ")", total_in, total_out, total_in_rate, total_out_rate, nc, clear_line
    }
  ' "$CURR_FILE"
}

# Initialize files
echo "" > "$PREV_FILE"
echo "" > "$HISTORY_FILE"

# Set terminal to non-blocking input and hide cursor
stty -echo -icanon time 0 min 0 2>/dev/null
echo -ne "${HIDE_CURSOR}"
echo -ne "${CLEAR_SCREEN}"

# Initial display
refresh_display

LAST_REFRESH=$SECONDS

while true; do
  key=$(dd bs=1 count=1 2>/dev/null)

  NEEDS_REFRESH=0

  case "$key" in
    "<"|",")
      ((SORT_COL--))
      [[ $SORT_COL -lt 1 ]] && SORT_COL=5
      NEEDS_REFRESH=1
      ;;
    ">"|".")
      ((SORT_COL++))
      [[ $SORT_COL -gt 5 ]] && SORT_COL=1
      NEEDS_REFRESH=1
      ;;
    "d"|"D")
      SHOW_DEAD=$((1 - SHOW_DEAD))
      NEEDS_REFRESH=1
      ;;
  esac

  ELAPSED=$((SECONDS - LAST_REFRESH))
  if [[ $ELAPSED -ge $INTERVAL ]]; then
    NEEDS_REFRESH=1
  fi

  if [[ $NEEDS_REFRESH -eq 1 ]]; then
    refresh_display
    LAST_REFRESH=$SECONDS
  fi

  sleep $POLL_INTERVAL
done