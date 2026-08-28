import Foundation

// Stylesheet for the generated report. Lifted verbatim from the design of
// record, `../report/report-template.html`, so the exported file and the
// designed template can never drift apart.
//
// Palette note: chart marks use validated steps of the brand hues rather than
// the brand hexes themselves — brand amber #D7A84F sits above the OKLCH
// lightness band for data marks. Details in ../report/report-spec.md §4.

extension ReportBuilder {
    static let css = """
/* ───────────────────────────────────────────────────────────────
   Vaultline "Archive Console" palette.
   Brand hexes are canonical for surfaces, ink and rules.
   Chart marks use validated steps of the same two hues — brand
   amber #D7A84F sits above the OKLCH lightness band for marks,
   so charts use a darker step. Validated: light surface #F4F1EA
   → #2F6FE0 / #A8761F, all six checks PASS.
   ─────────────────────────────────────────────────────────────── */
:root{
  --charcoal:#0B0F14;
  --slate:#151B23;
  --steel:#7D8896;
  --white:#F4F1EA;
  --blue:#4C8DFF;        /* brand accent — dark surfaces only */
  --amber:#D7A84F;       /* brand accent — dark surfaces only */

  --mark-blue:#2F6FE0;   /* validated chart mark, light surface */
  --mark-amber:#A8761F;  /* validated status mark, light surface */

  --ink:#0B0F14;
  --ink-2:#3C444E;
  --ink-3:#6B7480;
  --rule:#DCD7CC;
  --track:#E4DFD4;
  --panel:#FBF9F5;
}
*{box-sizing:border-box}
html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{
  margin:0;background:#E8E4DA;color:var(--ink);
  font:14px/1.5 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Inter","Helvetica Neue",Arial,sans-serif;
  -webkit-font-smoothing:antialiased;
}
.page{max-width:860px;margin:0 auto;background:var(--white)}

/* ── Masthead ───────────────────────────────────────────────── */
.mast{background:var(--charcoal);color:var(--white);padding:30px 44px 26px}
.wordmark{display:flex;align-items:center;gap:14px}
.wordmark .logo{height:42px;width:auto;display:block;flex:0 0 auto}
.wordmark .line{flex:1;height:1px;background:rgba(244,241,234,.28)}
.wordmark .sub{font-size:10px;letter-spacing:1.6px;text-transform:uppercase;color:var(--steel)}
.mast h1{margin:26px 0 0;font-size:31px;font-weight:600;letter-spacing:-.5px}
.mast .cap{font-weight:400;color:var(--steel)}
.mast .meta{margin-top:9px;font-size:12.5px;color:var(--steel);font-variant-numeric:tabular-nums}

/* ── Hero stats ─────────────────────────────────────────────── */
.hero{display:grid;grid-template-columns:repeat(4,1fr);border-bottom:1px solid var(--rule)}
/* Each tile is a column so the notes sit on a common bottom line. Without it
   a value that wraps to two lines (a date range does, often) drops its own
   note below every other tile's and the row reads as misaligned. */
.hero div{padding:19px 20px;border-right:1px solid var(--rule);display:flex;flex-direction:column}
.hero div:last-child{border-right:0}
.hero .k{font-size:9.5px;letter-spacing:1.1px;text-transform:uppercase;color:var(--ink-3);font-weight:600}
.hero .v{margin-top:5px;font-size:22px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-.4px}
.hero .n{margin-top:auto;padding-top:6px;font-size:11.5px;color:var(--ink-3)}

.body{padding:34px 44px 12px}
section{margin-bottom:36px;break-inside:avoid}
h2{margin:0 0 3px;font-size:11px;font-weight:700;letter-spacing:1.3px;text-transform:uppercase;color:var(--ink-3)}
.lede{margin:0 0 16px;font-size:12.5px;color:var(--ink-3)}
/* Anything the report had to leave out says so here, with the count. A list
   that silently stops at ten reads as a complete answer. */
.more{margin-top:11px;font-size:11.5px;color:var(--ink-3);font-variant-numeric:tabular-nums}

/* ── Capacity ───────────────────────────────────────────────── */
.cap-bar{height:26px;border-radius:4px;background:var(--track);overflow:hidden;display:flex}
.cap-bar i{display:block;height:100%;background:var(--mark-blue)}
.cap-legend{display:flex;gap:22px;margin-top:9px;font-size:12px;color:var(--ink-2);font-variant-numeric:tabular-nums}
.sw{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:6px;vertical-align:baseline}

/* ── Bar rows ───────────────────────────────────────────────── */
.bars{display:flex;flex-direction:column;gap:11px}
.bar{display:grid;grid-template-columns:126px 1fr 78px;align-items:center;gap:14px}
.bar .lbl{font-size:12.5px;font-weight:500}
.bar .tr{height:9px;border-radius:4px;background:var(--track);overflow:hidden}
/* `display:block` is load-bearing. `.fl` is an <i>, so without it the fill is
   an inline box, width and height are ignored, and every bar in the report
   renders as an empty grey track with no mark on it at all. */
.bar .fl{display:block;height:100%;border-radius:4px;background:var(--mark-blue)}
.bar .val{font-size:12px;text-align:right;color:var(--ink-2);font-variant-numeric:tabular-nums}
.bar .sub{grid-column:2/4;font-size:11px;color:var(--ink-3);margin-top:-4px;font-variant-numeric:tabular-nums}

.cols2{display:grid;grid-template-columns:1fr 1fr;gap:34px}

/* ── Cameras ────────────────────────────────────────────────── */
.cams{display:flex;flex-wrap:wrap;gap:8px}
.cam{border:1px solid var(--rule);border-radius:5px;padding:7px 11px;background:var(--panel)}
.cam b{font-size:12.5px;font-weight:600;display:block}
.cam span{font-size:11px;color:var(--ink-3);font-variant-numeric:tabular-nums}

/* ── Timeline ───────────────────────────────────────────────── */
.years{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;align-items:end;height:112px}
.yr{display:flex;flex-direction:column;justify-content:flex-end;height:100%;gap:6px;text-align:center}
.yr .col{background:var(--mark-blue);border-radius:4px 4px 0 0;min-height:3px}
.yr .lb{font-size:11.5px;color:var(--ink-2);font-variant-numeric:tabular-nums}
.yr .lb b{display:block;font-size:12px;color:var(--ink);font-weight:600}

/* ── Tables ─────────────────────────────────────────────────── */
table{width:100%;border-collapse:collapse}
th{font-size:9.5px;letter-spacing:1px;text-transform:uppercase;color:var(--ink-3);
   text-align:left;font-weight:600;padding:0 0 7px;border-bottom:1px solid var(--rule)}
td{padding:7px 0;font-size:12.5px;border-bottom:1px solid var(--rule);vertical-align:middle}
/* Every numeric column is right-aligned, so without a gutter two adjacent
   headings butt straight into each other and "Copies Reclaimable" reads as
   one word. The gutter goes on the cell, not the table, so the first
   column keeps the full width it needs for long paths. */
th+th,td+td{padding-left:26px}
th.n{text-align:right}
td.n{text-align:right;font-variant-numeric:tabular-nums;color:var(--ink-2);white-space:nowrap}
/* Paths are long and unbreakable at spaces. Letting them wrap anywhere is
   what keeps the first column from crushing the numeric ones. */
td .path{color:var(--ink-3);font-size:11px;overflow-wrap:anywhere}
td .nm{overflow-wrap:anywhere}
.minibar{height:5px;border-radius:3px;background:var(--track);overflow:hidden;margin-top:4px}
.minibar i{display:block;height:100%;background:var(--mark-blue);border-radius:3px}

/* ── Attention ──────────────────────────────────────────────── */
.att{border:1px solid var(--rule);border-left:3px solid var(--mark-amber);
     border-radius:5px;background:var(--panel);padding:15px 18px;display:flex;
     flex-direction:column;gap:12px}
.att .it{display:flex;gap:11px;align-items:flex-start}
.att .ic{flex:0 0 15px;height:15px;margin-top:1px;color:var(--mark-amber)}
.att b{font-size:12.5px;font-weight:600;display:block}
.att span{font-size:11.5px;color:var(--ink-3)}

/* ── Data tables (a11y) ─────────────────────────────────────── */
details{margin-top:12px}
summary{font-size:11px;color:var(--ink-3);cursor:pointer;letter-spacing:.3px}
details table{margin-top:9px}
details td,details th{font-size:11.5px}

/* ── Footer ─────────────────────────────────────────────────── */
.foot{background:var(--charcoal);color:var(--white);padding:30px 44px 26px;margin-top:8px}
.foot .q{font-size:17px;font-weight:500;letter-spacing:-.2px;max-width:600px;line-height:1.42}
.foot .p{margin-top:11px;font-size:13px;color:var(--steel);max-width:600px}
.foot .cta{display:inline-block;margin-top:8px;color:var(--white);font-weight:600;text-decoration:none}
.foot .r{margin-top:22px;padding-top:15px;border-top:1px solid rgba(244,241,234,.14);
         display:flex;justify-content:space-between;align-items:baseline;gap:16px}
.foot .r .t{font-size:12.5px;color:var(--white);display:flex;align-items:center;gap:11px}
.foot .r .t img{height:23px;width:auto;opacity:.92}
.foot .r .s{font-size:10.5px;color:var(--steel)}

/* ── Tooltip ────────────────────────────────────────────────── */
#tip{position:fixed;pointer-events:none;opacity:0;transition:opacity .08s;
     background:var(--charcoal);color:var(--white);font-size:11.5px;padding:6px 9px;
     border-radius:4px;white-space:nowrap;z-index:99;font-variant-numeric:tabular-nums}

@media print{
  body{background:#fff}
  .page{max-width:none}
  section{page-break-inside:avoid}
  details{display:none}
}
@media (max-width:700px){
  .hero{grid-template-columns:repeat(2,1fr)}
  .cols2{grid-template-columns:1fr}
  .bar{grid-template-columns:100px 1fr 66px}
  .mast,.body,.foot{padding-left:22px;padding-right:22px}
}
"""
}
