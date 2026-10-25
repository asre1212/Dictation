export function formatCommands(text) {
  // Explicitly invoked on the desktop. Never rewrite diagnoses, doses or negation.
  return text.replace(/\bnew paragraph\b[.,]?\s*/gi, '\n\n').replace(/\bnew line\b[.,]?\s*/gi, '\n').replace(/ +\n/g, '\n');
}
