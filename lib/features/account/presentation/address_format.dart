/// Truncates [address] for single-line display (`ethereum-account` spec's
/// "Address truncates to first 5 and last 5 characters on one line"
/// requirement, design.md D5): a pure top-level function, independently
/// unit-testable, with no widget/`BuildContext` dependency.
///
/// Returns `first [lead] chars + "…" (U+2026) + last [tail] chars`. Returns
/// [address] unchanged when truncating would not shorten it
/// (`address.length <= lead + tail + 1`).
String truncateAddress(String address, {int lead = 5, int tail = 5}) {
  if (address.length <= lead + tail + 1) return address;
  return '${address.substring(0, lead)}…${address.substring(address.length - tail)}';
}
