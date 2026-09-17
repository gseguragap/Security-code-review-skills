# cost.awk - extract per-model token usage from a Claude Code session transcript (JSONL).
#
# Usage:  awk -v SKIP=<lines-to-skip> -f cost.awk transcript.jsonl
#
# Why this is not a naive sum:
#   A single assistant message is written to the transcript MULTIPLE times (streaming
#   partials plus a final record). Summing every line inflates the total by 2-3x.
#   We therefore key on the message id and keep the MAXIMUM value seen per field,
#   which converges on the final, complete usage record for that message.
#
# Output: one TSV row per model
#   model \t messages \t input \t cacheWrite5m \t cacheWrite1h \t cacheRead \t output
#
# Requires only POSIX awk (present in Git Bash on Windows, and natively on macOS/Linux).

NR <= SKIP { next }

/"type":"assistant"/ {
  if (!match($0, /"id":"msg_[^"]*"/)) next
  id = substr($0, RSTART + 6, RLENGTH - 7)
  seen[id] = 1

  if (match($0, /"model":"[^"]*"/)) model[id] = substr($0, RSTART + 9, RLENGTH - 10)

  # "input_tokens": -> 15 chars of prefix
  if (match($0, /"input_tokens":[0-9]+/)) {
    v = substr($0, RSTART + 15, RLENGTH - 15) + 0; if (v > I[id]) I[id] = v
  }
  # "output_tokens": -> 16
  if (match($0, /"output_tokens":[0-9]+/)) {
    v = substr($0, RSTART + 16, RLENGTH - 16) + 0; if (v > O[id]) O[id] = v
  }
  # "cache_read_input_tokens": -> 26
  if (match($0, /"cache_read_input_tokens":[0-9]+/)) {
    v = substr($0, RSTART + 26, RLENGTH - 26) + 0; if (v > R[id]) R[id] = v
  }
  # Per-TTL cache writes. Field order varies between records, so match each by name.
  # "ephemeral_5m_input_tokens": -> 28
  if (match($0, /"ephemeral_5m_input_tokens":[0-9]+/)) {
    v = substr($0, RSTART + 28, RLENGTH - 28) + 0; if (v > W5[id]) W5[id] = v
  }
  # "ephemeral_1h_input_tokens": -> 28
  if (match($0, /"ephemeral_1h_input_tokens":[0-9]+/)) {
    v = substr($0, RSTART + 28, RLENGTH - 28) + 0; if (v > W1[id]) W1[id] = v
  }
  # Fallback for older transcripts with no per-TTL breakdown.
  # "cache_creation_input_tokens": -> 30
  if (match($0, /"cache_creation_input_tokens":[0-9]+/)) {
    v = substr($0, RSTART + 30, RLENGTH - 30) + 0; if (v > CC[id]) CC[id] = v
  }
}

END {
  for (id in seen) {
    m = (model[id] != "" ? model[id] : "unknown")
    # If the per-TTL fields are absent, attribute the whole cache_creation figure to
    # the 5-minute rate: it is the cheaper of the two, so this UNDER-states cost rather
    # than over-stating it. An under-stated cost is the honest direction to err.
    w5 = W5[id]; w1 = W1[id]
    if (w5 == 0 && w1 == 0 && CC[id] > 0) w5 = CC[id]

    n[m]++
    ti[m] += I[id]; t5[m] += w5; t1[m] += w1; tr[m] += R[id]; to[m] += O[id]
  }
  for (m in n) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", m, n[m], ti[m], t5[m], t1[m], tr[m], to[m]
}
