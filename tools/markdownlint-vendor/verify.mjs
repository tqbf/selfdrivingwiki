// Phase 0 verification: cosmetic config, mermaid-fence safety, wiki-link safety.
// Uses vm.runInThisContext to eval the IIFE in global scope (where `var
// __markdownlint` becomes global), matching how JavaScriptCore evaluates it.
import fs from "node:fs";
import vm from "node:vm";

const src = fs.readFileSync("../../Resources/markdownlint.bundle.js", "utf8");
vm.runInThisContext(src);
const ml = globalThis.__markdownlint;

const config = {
  default: false,
  MD009: true, MD010: true, MD012: true,
  "MD018": true, "MD019": true, "MD020": true, "MD021": true,
  MD022: true, MD023: true, MD027: true, MD030: true,
  MD031: true, MD032: true,
  "MD037": true, "MD038": true, "MD039": true,
  MD047: true, MD058: true,
};

function lint(md) { return ml.lint({ strings: { content: md }, config }).content; }

let pass = 0, fail = 0;
function check(name, cond) {
  console.log((cond ? "PASS" : "FAIL") + " — " + name);
  cond ? pass++ : fail++;
}

// 1. Wiki-link no false positive.
check("wiki-link no findings", lint("See [[some wiki link]] for details.\n").length === 0);

// 2. Mermaid fence composition — content must survive fixes untouched.
const fence = String.fromCharCode(96).repeat(3);
const withMermaid = "# Title   \n\n" + fence + "mermaid\nflowchart LR\nA-->B\n" + fence + "\nmore text";
const f2 = lint(withMermaid);
const fixed2 = ml.applyFixes(withMermaid, f2);
console.log("  mermaid input:  " + JSON.stringify(withMermaid));
console.log("  mermaid fixed:  " + JSON.stringify(fixed2));
check("mermaid block intact after fix",
      fixed2.includes("flowchart LR") && fixed2.includes("A-->B"));
check("trailing space stripped (# Title)", fixed2.startsWith("# Title\n"));
check("mermaid findings count", f2.length > 0);

// 3. Clean doc → no findings.
check("clean doc no findings", lint("# Title\n\nSome paragraph text here.\n").length === 0);

// 4. Cosmetic messy doc fix.
const messy = "##Heading\nText with trailing space   \n\n\n" + fence + "code" + fence + " here\n";
const f4 = lint(messy);
const fixed4 = ml.applyFixes(messy, f4);
console.log("  messy fixed: " + JSON.stringify(fixed4));
check("space after ## heading", fixed4.startsWith("## Heading\n"));
check("trailing space stripped (line 2)", !fixed4.includes("space   "));
check("blanks collapsed", !fixed4.includes("\n\n\n"));

// 5. Missing blank line around fence (MD031).
const noBlankFence = "# Title\n" + fence + "\ncode\n" + fence + "\n";
const f5 = lint(noBlankFence);
console.log("  fence fix rules: " + f5.map(x => x.ruleNames[0]).join(","));
check("MD031 flags missing blank around fence",
      f5.some(x => x.ruleNames[0] === "MD031"));

// 6. No trailing newline (MD047).
check("MD047 flags missing trailing newline",
      lint("# Title\n\nText").some(x => x.ruleNames[0] === "MD047"));

console.log("\n=== " + pass + " passed, " + fail + " failed ===");
process.exit(fail > 0 ? 1 : 0);
