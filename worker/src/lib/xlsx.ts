// Minimal, dependency-free .xlsx writer for Workers.
// Produces a standard Office Open XML workbook (stored zip, inline strings).

export const STYLE = {
  normal: 0,
  header: 1,     // bold on light blue
  date: 2,       // dd-mmm-yyyy
  time: 3,       // hh:mm
  duration: 4,   // [h]:mm
  bold: 5,
  // ---- attendance grid (all with thin borders on every side)
  gridCorner: 6, // bold, centered both ways
  gridDate: 7,   // d-mmm, bold, centered both ways
  gridDay: 8,    // weekday name, bold, centered
  gridHead: 9,   // "Time In" / "Time Out", bold
  gridHeadC: 10, // "Hours Worked", bold, centered
  gridName: 11,  // employee name, bold
  gridTime: 12,  // h:mm AM/PM, centered
  gridHours: 13, // h:mm, centered
  gridCell: 14,  // plain bordered cell
} as const;

/**
 * A cell: a plain value, or { v, s } for a styled value (v may be empty for a styled blank cell),
 * or { f, v, s } for a formula with its cached result.
 */
export type CellValue =
  | string
  | number
  | null
  | undefined
  | { v?: string | number | null; s: number; f?: string };

export interface SheetSpec {
  name: string;
  widths: number[];
  rows: CellValue[][];
  /** First row is a header: bold, frozen, with filter buttons. */
  header?: boolean;
  /** Merged ranges, e.g. ["A1:A3", "B1:D1"]. */
  merges?: string[];
  /** Freeze panes: number of columns on the left and rows on top that stay visible. */
  freeze?: { cols: number; rows: number };
}

import { zipStore } from "./zip";

const enc = new TextEncoder();

function xmlEscape(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    // strip control characters Excel rejects
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
}

export function colName(index: number): string {
  let n = index + 1;
  let s = "";
  while (n > 0) {
    const m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

function safeSheetName(name: string): string {
  return name.replace(/[\[\]:*?/\\]/g, " ").slice(0, 31) || "Sheet";
}

function cellXml(ref: string, cell: CellValue, defaultStyle: number): string {
  if (cell === null || cell === undefined || cell === "") return "";
  let value: string | number | null | undefined;
  let style = defaultStyle;
  let formula: string | undefined;
  if (typeof cell === "object") {
    value = cell.v;
    style = cell.s;
    formula = cell.f;
  } else {
    value = cell;
  }
  const s = style ? ` s="${style}"` : "";
  if (formula) {
    const f = `<f>${xmlEscape(formula)}</f>`;
    if (typeof value === "number" && Number.isFinite(value)) return `<c r="${ref}"${s}>${f}<v>${value}</v></c>`;
    return `<c r="${ref}"${s} t="str">${f}<v>${xmlEscape(String(value ?? ""))}</v></c>`;
  }
  if (value === null || value === undefined || value === "") {
    return style ? `<c r="${ref}"${s}/>` : "";
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return `<c r="${ref}"${s}><v>${value}</v></c>`;
  }
  return `<c r="${ref}"${s} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(String(value))}</t></is></c>`;
}

function sheetXml(sheet: SheetSpec): string {
  const lastCol = colName(Math.max(sheet.widths.length, 1) - 1);
  const lastRow = Math.max(sheet.rows.length, 1);
  const parts: string[] = [];
  parts.push(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`);
  parts.push(`<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`);
  const freeze = sheet.freeze ?? (sheet.header ? { cols: 0, rows: 1 } : undefined);
  if (freeze && (freeze.cols > 0 || freeze.rows > 0)) {
    const topLeft = `${colName(freeze.cols)}${freeze.rows + 1}`;
    const pane = freeze.cols > 0 && freeze.rows > 0 ? "bottomRight" : freeze.rows > 0 ? "bottomLeft" : "topRight";
    const split = (freeze.cols > 0 ? ` xSplit="${freeze.cols}"` : "") + (freeze.rows > 0 ? ` ySplit="${freeze.rows}"` : "");
    parts.push(`<sheetViews><sheetView workbookViewId="0"><pane${split} topLeftCell="${topLeft}" activePane="${pane}" state="frozen"/><selection pane="${pane}" activeCell="${topLeft}" sqref="${topLeft}"/></sheetView></sheetViews>`);
  } else {
    parts.push(`<sheetViews><sheetView workbookViewId="0"/></sheetViews>`);
  }
  parts.push(`<sheetFormatPr defaultRowHeight="14.4"/>`);
  parts.push(`<cols>`);
  sheet.widths.forEach((w, i) => parts.push(`<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`));
  parts.push(`</cols><sheetData>`);
  sheet.rows.forEach((row, r) => {
    const defaultStyle = sheet.header && r === 0 ? STYLE.header : STYLE.normal;
    const cells = row.map((c, i) => cellXml(`${colName(i)}${r + 1}`, c, defaultStyle)).join("");
    parts.push(`<row r="${r + 1}">${cells}</row>`);
  });
  parts.push(`</sheetData>`);
  if (sheet.header && sheet.rows.length > 0) parts.push(`<autoFilter ref="A1:${lastCol}${lastRow}"/>`);
  if (sheet.merges && sheet.merges.length > 0) {
    parts.push(`<mergeCells count="${sheet.merges.length}">${sheet.merges.map((m) => `<mergeCell ref="${m}"/>`).join("")}</mergeCells>`);
  }
  parts.push(`<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>`);
  parts.push(`</worksheet>`);
  return parts.join("");
}

const FONT = `<sz val="11"/><name val="Aptos Narrow"/><family val="2"/>`;
const THIN = `<color auto="1"/>`;
const CENTER = `<alignment horizontal="center" vertical="center"/>`;
const H_CENTER = `<alignment horizontal="center"/>`;

const STYLES_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="5"><numFmt numFmtId="164" formatCode="dd\\-mmm\\-yyyy"/><numFmt numFmtId="165" formatCode="hh:mm"/><numFmt numFmtId="166" formatCode="[h]:mm"/><numFmt numFmtId="167" formatCode="h:mm\\ AM/PM"/><numFmt numFmtId="168" formatCode="h:mm;@"/></numFmts>
<fonts count="2"><font>${FONT}</font><font><b/>${FONT}</font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin">${THIN}</left><right style="thin">${THIN}</right><top style="thin">${THIN}</top><bottom style="thin">${THIN}</bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="15">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="16" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">${H_CENTER}</xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">${H_CENTER}</xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>
<xf numFmtId="167" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="168" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

export function buildXlsx(sheets: SheetSpec[]): Uint8Array {
  const names = sheets.map((s) => safeSheetName(s.name));
  const files: Array<[string, string]> = [];

  files.push(["[Content_Types].xml",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
    `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
    `<Default Extension="xml" ContentType="application/xml"/>` +
    `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
    `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
    sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("") +
    `</Types>`]);

  files.push(["_rels/.rels",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
    `</Relationships>`]);

  const definedNames = sheets
    .map((s, i) => (s.header && s.rows.length > 0
      ? `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${xmlEscape(names[i].replace(/'/g, "''"))}'!$A$1:$${colName(Math.max(s.widths.length, 1) - 1)}$${s.rows.length}</definedName>`
      : ""))
    .join("");

  files.push(["xl/workbook.xml",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
    `<bookViews><workbookView/></bookViews><sheets>` +
    names.map((n, i) => `<sheet name="${xmlEscape(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("") +
    `</sheets>` + (definedNames ? `<definedNames>${definedNames}</definedNames>` : "") +
    `<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>`]);

  files.push(["xl/_rels/workbook.xml.rels",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("") +
    `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
    `</Relationships>`]);

  files.push(["xl/styles.xml", STYLES_XML]);
  sheets.forEach((s, i) => files.push([`xl/worksheets/sheet${i + 1}.xml`, sheetXml({ ...s, name: names[i] })]));

  return zipStore(files.map(([name, text]) => ({ name, data: enc.encode(text) })));
}