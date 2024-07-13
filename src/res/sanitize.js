export function sanitize(s) {
  if (s === undefined) {
    return "UNKNOWN";
  }
  if (s.match(/^[0-9a-zA-Z _]*$/)) {
    return s;
  } else {
    return "REDACTED";
  }
}
