// Timestamped console logging (Phase 6 will also write these lines to a file).
function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export const log = {
  info: (msg) => console.log(`${stamp()}  INFO   ${msg}`),
  warn: (msg) => console.warn(`${stamp()}  WARN   ${msg}`),
  error: (msg) => console.error(`${stamp()}  ERROR  ${msg}`),
};