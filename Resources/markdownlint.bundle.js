var __markdownlint = (() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
  }) : x)(function(x) {
    if (typeof require !== "undefined") return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });
  var __commonJS = (cb, mod) => function __require2() {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // node_modules/markdownlint/helpers/shared.cjs
  var require_shared = __commonJS({
    "node_modules/markdownlint/helpers/shared.cjs"(exports, module) {
      "use strict";
      module.exports.flatTokensSymbol = Symbol("flat-tokens");
      module.exports.htmlFlowSymbol = Symbol("html-flow");
      module.exports.newlineRe = /\r\n?|\n/g;
      module.exports.nextLinesRe = /[\r\n][\s\S]*$/;
    }
  });

  // node_modules/markdownlint/helpers/micromark-helpers.cjs
  var require_micromark_helpers = __commonJS({
    "node_modules/markdownlint/helpers/micromark-helpers.cjs"(exports, module) {
      "use strict";
      var { flatTokensSymbol: flatTokensSymbol2, htmlFlowSymbol: htmlFlowSymbol2, newlineRe: newlineRe2 } = require_shared();
      function inHtmlFlow3(token) {
        return Boolean(token[htmlFlowSymbol2]);
      }
      function isHtmlFlowComment4(token) {
        const { text: text4, type } = token;
        if (type === "htmlFlow" && text4.startsWith("<!--") && text4.endsWith("-->")) {
          const comment = text4.slice(4, -3);
          return !comment.startsWith(">") && !comment.startsWith("->") && !comment.endsWith("-");
        }
        return false;
      }
      function addRangeToSet7(set, start, end) {
        for (let i = start; i <= end; i++) {
          set.add(i);
        }
      }
      function filterByPredicate7(tokens, allowed, transformChildren) {
        const result = [];
        const queue = [
          {
            "array": tokens,
            "index": 0
          }
        ];
        while (queue.length > 0) {
          const current = queue[queue.length - 1];
          const { array, index } = current;
          if (index < array.length) {
            const token = array[current.index++];
            if (allowed(token)) {
              result.push(token);
            }
            const { children } = token;
            if (children.length > 0) {
              const transformed = transformChildren ? transformChildren(token) : children;
              queue.push(
                {
                  "array": transformed,
                  "index": 0
                }
              );
            }
          } else {
            queue.pop();
          }
        }
        return result;
      }
      function filterByTypes6(tokens, types, htmlFlow2) {
        const predicate = (token) => types.includes(token.type) && (htmlFlow2 || !inHtmlFlow3(token));
        const flatTokens = (
          // @ts-ignore
          tokens[flatTokensSymbol2]
        );
        if (flatTokens) {
          return flatTokens.filter(predicate);
        }
        return filterByPredicate7(tokens, predicate);
      }
      function getBlockQuotePrefixText4(tokens, lineNumber, count = 1) {
        return filterByTypes6(tokens, ["blockQuotePrefix", "linePrefix"]).filter((prefix) => prefix.startLine === lineNumber).map((prefix) => prefix.text).join("").trimEnd().concat("\n").repeat(count);
      }
      function getDescendantsByType14(parent, typePath) {
        let tokens = Array.isArray(parent) ? parent : [parent];
        for (const type of typePath) {
          const predicate = (token) => Array.isArray(type) ? type.includes(token.type) : type === token.type;
          tokens = tokens.flatMap((t) => t.children.filter(predicate));
        }
        return tokens;
      }
      function getHeadingLevel8(heading) {
        let level = 1;
        const headingSequence = heading.children.find(
          (child) => ["atxHeadingSequence", "setextHeadingLine"].includes(child.type)
        );
        const { text: text4 } = headingSequence;
        if (text4[0] === "#") {
          level = Math.min(text4.length, 6);
        } else if (text4[0] === "-") {
          level = 2;
        }
        return level;
      }
      function getHeadingStyle3(heading) {
        if (heading.type === "setextHeading") {
          return "setext";
        }
        const atxHeadingSequenceLength = heading.children.filter(
          (child) => child.type === "atxHeadingSequence"
        ).length;
        if (atxHeadingSequenceLength === 1) {
          return "atx";
        }
        return "atx_closed";
      }
      function getHeadingText4(heading) {
        return getDescendantsByType14(heading, [["atxHeadingText", "setextHeadingText"]]).flatMap((descendant) => descendant.children.filter((child) => child.type !== "htmlText")).map((data) => data.text).join("").replace(newlineRe2, " ");
      }
      function getHtmlTagInfo6(token) {
        const htmlTagNameRe = /^<([^!>][^/\s>]*)/;
        if (token.type === "htmlText") {
          const match = htmlTagNameRe.exec(token.text);
          if (match) {
            const name = match[1];
            const close = name.startsWith("/");
            return {
              close,
              "name": close ? name.slice(1) : name
            };
          }
        }
        return null;
      }
      function getParentOfType7(token, types) {
        let current = token;
        while ((current = current.parent) && !types.includes(current.type)) {
        }
        return current;
      }
      var docfxTabSyntaxRe = /^#tab\//;
      function isDocfxTab3(heading) {
        if (heading?.type === "atxHeading") {
          const headingTexts = getDescendantsByType14(heading, ["atxHeadingText"]);
          if (headingTexts.length === 1 && headingTexts[0].children.length === 1 && headingTexts[0].children[0].type === "link") {
            const resourceDestinationStrings = filterByTypes6(headingTexts[0].children[0].children, ["resourceDestinationString"]);
            return resourceDestinationStrings.length === 1 && docfxTabSyntaxRe.test(resourceDestinationStrings[0].text);
          }
        }
        return false;
      }
      var nonContentTokens4 = /* @__PURE__ */ new Set([
        "blockQuoteMarker",
        "blockQuotePrefix",
        "blockQuotePrefixWhitespace",
        "gfmFootnoteDefinitionIndent",
        "lineEnding",
        "lineEndingBlank",
        "linePrefix",
        "listItemIndent",
        "undefinedReference",
        "undefinedReferenceCollapsed",
        "undefinedReferenceFull",
        "undefinedReferenceShortcut"
      ]);
      module.exports = {
        addRangeToSet: addRangeToSet7,
        filterByPredicate: filterByPredicate7,
        filterByTypes: filterByTypes6,
        getBlockQuotePrefixText: getBlockQuotePrefixText4,
        getDescendantsByType: getDescendantsByType14,
        getHeadingLevel: getHeadingLevel8,
        getHeadingStyle: getHeadingStyle3,
        getHeadingText: getHeadingText4,
        getHtmlTagInfo: getHtmlTagInfo6,
        getParentOfType: getParentOfType7,
        inHtmlFlow: inHtmlFlow3,
        isDocfxTab: isDocfxTab3,
        isHtmlFlowComment: isHtmlFlowComment4,
        nonContentTokens: nonContentTokens4
      };
    }
  });

  // node_modules/markdownlint/helpers/helpers.cjs
  var require_helpers = __commonJS({
    "node_modules/markdownlint/helpers/helpers.cjs"(exports, module) {
      "use strict";
      var micromark = require_micromark_helpers();
      var { newlineRe: newlineRe2, nextLinesRe: nextLinesRe4 } = require_shared();
      module.exports.newLineRe = newlineRe2;
      module.exports.nextLinesRe = nextLinesRe4;
      module.exports.frontMatterRe = /((^---[^\S\r\n\u2028\u2029]*$[\s\S]+?^---\s*)|(^\+\+\+[^\S\r\n\u2028\u2029]*$[\s\S]+?^(\+\+\+|\.\.\.)\s*)|(^\{[^\S\r\n\u2028\u2029]*$[\s\S]+?^\}\s*))(\r\n|\r|\n|$)/m;
      var inlineCommentStartRe2 = /(<!--\s*markdownlint-(disable|enable|capture|restore|disable-file|enable-file|disable-line|disable-next-line|configure-file))(?:\s|-->)/gi;
      module.exports.inlineCommentStartRe = inlineCommentStartRe2;
      module.exports.endOfLineHtmlEntityRe = /&(?:#\d+|#[xX][\da-fA-F]+|[a-zA-Z]{2,31}|blk\d{2}|emsp1[34]|frac\d{2}|sup\d|there4);$/;
      module.exports.endOfLineGemojiCodeRe = /:(?:[abmovx]|[-+]1|100|1234|(?:1st|2nd|3rd)_place_medal|8ball|clock\d{1,4}|e-mail|non-potable_water|o2|t-rex|u5272|u5408|u55b6|u6307|u6708|u6709|u6e80|u7121|u7533|u7981|u7a7a|[a-z]{2,15}2?|[a-z]{1,14}(?:_[a-z\d]{1,16})+):$/;
      var allPunctuation2 = ".,;:!?\u3002\uFF0C\uFF1B\uFF1A\uFF01\uFF1F";
      module.exports.allPunctuation = allPunctuation2;
      module.exports.allPunctuationNoQuestion = allPunctuation2.replace(/[?？]/gu, "");
      function isNumber2(obj) {
        return typeof obj === "number";
      }
      module.exports.isNumber = isNumber2;
      function isString2(obj) {
        return typeof obj === "string";
      }
      module.exports.isString = isString2;
      function isEmptyString2(str) {
        return str.length === 0;
      }
      module.exports.isEmptyString = isEmptyString2;
      function isObject2(obj) {
        return !!obj && typeof obj === "object" && !Array.isArray(obj);
      }
      module.exports.isObject = isObject2;
      function isUrl2(obj) {
        return !!obj && Object.getPrototypeOf(obj) === URL.prototype;
      }
      module.exports.isUrl = isUrl2;
      function cloneIfArray2(arr) {
        return Array.isArray(arr) ? [...arr] : arr;
      }
      module.exports.cloneIfArray = cloneIfArray2;
      function cloneIfUrl2(url) {
        return isUrl2(url) ? new URL(url) : url;
      }
      module.exports.cloneIfUrl = cloneIfUrl2;
      module.exports.getHtmlAttributeRe = function getHtmlAttributeRe3(name) {
        return new RegExp(`\\s${name}\\s*=\\s*['"]?([^'"\\s>]*)`, "iu");
      };
      function isBlankLine6(line) {
        const startComment = "<!--";
        const endComment = "-->";
        const removeComments = (s) => {
          while (true) {
            const start = s.indexOf(startComment);
            const end = s.indexOf(endComment);
            if (end !== -1 && (start === -1 || end < start)) {
              s = s.slice(end + endComment.length);
            } else if (start !== -1 && end !== -1) {
              s = s.slice(0, start) + s.slice(end + endComment.length);
            } else if (start !== -1 && end === -1) {
              s = s.slice(0, start);
            } else {
              return s;
            }
          }
        };
        return !line || !line.trim() || !removeComments(line).replace(/>/g, "").trim();
      }
      module.exports.isBlankLine = isBlankLine6;
      var htmlCommentBegin = "<!--";
      var htmlCommentEnd = "-->";
      var safeCommentCharacter = ".";
      var startsWithPipeRe = /^ *\|/;
      var notCrLfRe = /[^\r\n]/g;
      var notSpaceCrLfRe = /[^ \r\n]/g;
      var trailingSpaceRe = / +[\r\n]/g;
      var replaceTrailingSpace = (s) => s.replace(notCrLfRe, safeCommentCharacter);
      module.exports.clearHtmlCommentText = function clearHtmlCommentText2(text4) {
        let i = 0;
        while ((i = text4.indexOf(htmlCommentBegin, i)) !== -1) {
          const j = text4.indexOf(htmlCommentEnd, i + 2);
          if (j === -1) {
            break;
          }
          if (j > i + htmlCommentBegin.length) {
            const content3 = text4.slice(i + htmlCommentBegin.length, j);
            const lastLf = text4.lastIndexOf("\n", i) + 1;
            const preText = text4.slice(lastLf, i);
            const isBlock = preText.trim().length === 0;
            const couldBeTable = startsWithPipeRe.test(preText);
            const spansTableCells = couldBeTable && content3.includes("\n");
            const isValid = isBlock || !(spansTableCells || content3.startsWith(">") || content3.startsWith("->") || content3.endsWith("-") || content3.includes("--"));
            if (isValid) {
              const clearedContent = content3.replace(notSpaceCrLfRe, safeCommentCharacter).replace(trailingSpaceRe, replaceTrailingSpace);
              text4 = text4.slice(0, i + htmlCommentBegin.length) + clearedContent + text4.slice(j);
            }
          }
          i = j + htmlCommentEnd.length;
        }
        return text4;
      };
      module.exports.escapeForRegExp = function escapeForRegExp3(str) {
        return str.replace(/[-/\\^$*+?.()|[\]{}]/g, "\\$&");
      };
      function ellipsify2(text4, start, end) {
        if (text4.length <= 30) {
        } else if (start && end) {
          text4 = text4.slice(0, 15) + "..." + text4.slice(-15);
        } else if (end) {
          text4 = "..." + text4.slice(-30);
        } else {
          text4 = text4.slice(0, 30) + "...";
        }
        return text4;
      }
      module.exports.ellipsify = ellipsify2;
      function addError18(onError, lineNumber, detail, context, range, fixInfo) {
        onError({
          lineNumber,
          detail,
          context,
          range,
          fixInfo
        });
      }
      module.exports.addError = addError18;
      function addErrorDetailIf18(onError, lineNumber, expected, actual, detail, context, range, fixInfo) {
        if (expected !== actual) {
          addError18(
            onError,
            lineNumber,
            "Expected: " + expected + "; Actual: " + actual + (detail ? "; " + detail : ""),
            context,
            range,
            fixInfo
          );
        }
      }
      module.exports.addErrorDetailIf = addErrorDetailIf18;
      function addErrorContext22(onError, lineNumber, context, start, end, range, fixInfo) {
        context = ellipsify2(context.replace(newlineRe2, "\n"), start, end);
        addError18(onError, lineNumber, void 0, context, range, fixInfo);
      }
      module.exports.addErrorContext = addErrorContext22;
      var positionLessThanOrEqual = (lineA, columnA, lineB, columnB) => lineA < lineB || lineA === lineB && columnA <= columnB;
      module.exports.hasOverlap = function hasOverlap4(rangeA, rangeB) {
        const lte = positionLessThanOrEqual(rangeA.startLine, rangeA.startColumn, rangeB.startLine, rangeB.startColumn);
        const first = lte ? rangeA : rangeB;
        const second = lte ? rangeB : rangeA;
        return positionLessThanOrEqual(second.startLine, second.startColumn, first.endLine, first.endColumn);
      };
      module.exports.frontMatterHasTitle = function frontMatterHasTitle4(frontMatterLines, frontMatterTitlePattern) {
        const ignoreFrontMatter = frontMatterTitlePattern !== void 0 && !frontMatterTitlePattern;
        const frontMatterTitleRe = new RegExp(
          String(frontMatterTitlePattern || '^\\s*"?title"?\\s*[:=]'),
          "i"
        );
        return !ignoreFrontMatter && frontMatterLines.some((line) => frontMatterTitleRe.test(line));
      };
      function getReferenceLinkImageData2(tokens) {
        const normalizeReference = (s) => s.toLowerCase().trim().replace(/\s+/g, " ");
        const getText2 = (t) => t?.children.filter((c) => c.type !== "blockQuotePrefix").map((c) => c.text).join("");
        const references = /* @__PURE__ */ new Map();
        const shortcuts = /* @__PURE__ */ new Map();
        const addReferenceToDictionary = (token, label4, isShortcut) => {
          const referenceDatum = [
            token.startLine - 1,
            token.startColumn - 1,
            token.text.length
          ];
          const reference = normalizeReference(label4);
          const dictionary = isShortcut ? shortcuts : references;
          const referenceData = dictionary.get(reference) || [];
          referenceData.push(referenceDatum);
          dictionary.set(reference, referenceData);
        };
        const definitions = /* @__PURE__ */ new Map();
        const definitionLineIndices = [];
        const duplicateDefinitions = [];
        const filteredTokens = micromark.filterByTypes(
          tokens,
          [
            // definitionLineIndices
            "definition",
            "gfmFootnoteDefinition",
            // definitions and definitionLineIndices
            "definitionLabelString",
            "gfmFootnoteDefinitionLabelString",
            // references and shortcuts
            "gfmFootnoteCall",
            "image",
            "link",
            // undefined link labels
            "undefinedReferenceCollapsed",
            "undefinedReferenceFull",
            "undefinedReferenceShortcut"
          ]
        );
        for (const token of filteredTokens) {
          let labelPrefix = "";
          switch (token.type) {
            case "definition":
            case "gfmFootnoteDefinition":
              for (let i = token.startLine; i <= token.endLine; i++) {
                definitionLineIndices.push(i - 1);
              }
              break;
            case "gfmFootnoteDefinitionLabelString":
              labelPrefix = "^";
            case "definitionLabelString": {
              const reference = normalizeReference(`${labelPrefix}${token.text}`);
              if (definitions.has(reference)) {
                duplicateDefinitions.push([reference, token.startLine - 1]);
              } else {
                const parent = micromark.getParentOfType(token, ["definition"]);
                const destinationString = parent && micromark.getDescendantsByType(parent, ["definitionDestination", "definitionDestinationRaw", "definitionDestinationString"])[0]?.text;
                definitions.set(
                  reference,
                  [token.startLine - 1, destinationString || ""]
                );
              }
              break;
            }
            case "gfmFootnoteCall":
            case "image":
            case "link": {
              let isShortcut = token.children.length === 1;
              const isFullOrCollapsed = token.children.length === 2 && !token.children.some((t) => t.type === "resource");
              const [labelText] = micromark.getDescendantsByType(token, ["label", "labelText"]);
              const [referenceString] = micromark.getDescendantsByType(token, ["reference", "referenceString"]);
              let label4 = getText2(labelText);
              if (!isShortcut && !isFullOrCollapsed) {
                const [footnoteCallMarker, footnoteCallString] = token.children.filter(
                  (t) => ["gfmFootnoteCallMarker", "gfmFootnoteCallString"].includes(t.type)
                );
                if (footnoteCallMarker && footnoteCallString) {
                  label4 = `${footnoteCallMarker.text}${footnoteCallString.text}`;
                  isShortcut = true;
                }
              }
              if (isShortcut || isFullOrCollapsed) {
                addReferenceToDictionary(token, getText2(referenceString) || label4, isShortcut);
              }
              break;
            }
            case "undefinedReferenceCollapsed":
            case "undefinedReferenceFull":
            case "undefinedReferenceShortcut": {
              const undefinedReference = micromark.getDescendantsByType(token, ["undefinedReference"])[0];
              const label4 = undefinedReference.children.map((t) => t.text).join("");
              const isShortcut = token.type === "undefinedReferenceShortcut";
              addReferenceToDictionary(token, label4, isShortcut);
              break;
            }
          }
        }
        return {
          references,
          shortcuts,
          definitions,
          duplicateDefinitions,
          definitionLineIndices
        };
      }
      module.exports.getReferenceLinkImageData = getReferenceLinkImageData2;
      function getPreferredLineEnding2(input, os2) {
        let cr = 0;
        let lf = 0;
        let crlf = 0;
        const endings = input.match(newlineRe2) || [];
        for (const ending of endings) {
          switch (ending) {
            case "\r":
              cr++;
              break;
            case "\n":
              lf++;
              break;
            case "\r\n":
              crlf++;
              break;
          }
        }
        let preferredLineEnding = null;
        if (!cr && !lf && !crlf) {
          preferredLineEnding = os2 && os2.EOL || "\n";
        } else if (lf >= crlf && lf >= cr) {
          preferredLineEnding = "\n";
        } else if (crlf >= cr) {
          preferredLineEnding = "\r\n";
        } else {
          preferredLineEnding = "\r";
        }
        return preferredLineEnding;
      }
      module.exports.getPreferredLineEnding = getPreferredLineEnding2;
      function expandTildePath2(file, os2) {
        const homedir = os2 && os2.homedir && os2.homedir();
        return homedir ? file.replace(/^~($|\/|\\)/, `${homedir}$1`) : file;
      }
      module.exports.expandTildePath = expandTildePath2;
      function convertLintErrorsVersion3To2(errors) {
        const noPrevious = {
          "ruleNames": [],
          "lineNumber": -1
        };
        return errors.filter((error, index, array) => {
          delete error.fixInfo;
          delete error.severity;
          const previous4 = array[index - 1] || noPrevious;
          return error.ruleNames[0] !== previous4.ruleNames[0] || error.lineNumber !== previous4.lineNumber;
        });
      }
      function convertLintErrorsVersion2To1(errors) {
        for (const error of errors) {
          error.ruleName = error.ruleNames[0];
          error.ruleAlias = error.ruleNames[1] || error.ruleName;
          delete error.ruleNames;
        }
        return errors;
      }
      function convertLintErrorsVersion2To0(errors) {
        const dictionary = {};
        for (const error of errors) {
          const ruleName = error.ruleNames[0];
          const ruleLines = dictionary[ruleName] || [];
          ruleLines.push(error.lineNumber);
          dictionary[ruleName] = ruleLines;
        }
        return dictionary;
      }
      function copyAndTransformResults(results, transform) {
        const newResults = {};
        for (const key of Object.keys(results)) {
          const arr = results[key].map((r) => ({ ...r }));
          newResults[key] = transform(arr);
        }
        return newResults;
      }
      module.exports.convertToResultVersion0 = function convertToResultVersion0(results) {
        return copyAndTransformResults(results, (r) => convertLintErrorsVersion2To0(convertLintErrorsVersion3To2(r)));
      };
      module.exports.convertToResultVersion1 = function convertToResultVersion1(results) {
        return copyAndTransformResults(results, (r) => convertLintErrorsVersion2To1(convertLintErrorsVersion3To2(r)));
      };
      module.exports.convertToResultVersion2 = function convertToResultVersion2(results) {
        return copyAndTransformResults(results, convertLintErrorsVersion3To2);
      };
      module.exports.formatLintResults = function formatLintResults(lintResults) {
        const results = [];
        const entries = Object.entries(lintResults || {});
        entries.sort((a, b) => a[0].localeCompare(b[0]));
        for (const [source, lintErrors] of entries) {
          for (const lintError of lintErrors) {
            const { lineNumber, ruleNames, ruleDescription, errorDetail, errorContext, errorRange, severity } = lintError;
            const rule = ruleNames.join("/");
            const line = `:${lineNumber}`;
            const rangeStart = errorRange && errorRange[0] || 0;
            const column = rangeStart ? `:${rangeStart}` : "";
            const description = ruleDescription;
            const detail = errorDetail ? ` [${errorDetail}]` : "";
            const context = errorContext ? ` [Context: "${errorContext}"]` : "";
            results.push(`${source}${line}${column} ${severity} ${rule} ${description}${detail}${context}`);
          }
        }
        return results;
      };
    }
  });

  // node_modules/markdownlint/lib/markdownit.cjs
  var require_markdownit = __commonJS({
    "node_modules/markdownlint/lib/markdownit.cjs"(exports, module) {
      "use strict";
      var { newlineRe: newlineRe2 } = require_shared();
      function forEachInlineCodeSpan(input, handler) {
        const backtickRe = /`+/g;
        let match = null;
        const backticksLengthAndIndex = [];
        while ((match = backtickRe.exec(input)) !== null) {
          backticksLengthAndIndex.push([match[0].length, match.index]);
        }
        const newLinesIndex = [];
        while ((match = newlineRe2.exec(input)) !== null) {
          newLinesIndex.push(match.index);
        }
        let lineIndex = 0;
        let lineStartIndex = 0;
        let k = 0;
        for (let i = 0; i < backticksLengthAndIndex.length - 1; i++) {
          const [startLength, startIndex] = backticksLengthAndIndex[i];
          if (startIndex === 0 || input[startIndex - 1] !== "\\") {
            for (let j = i + 1; j < backticksLengthAndIndex.length; j++) {
              const [endLength, endIndex] = backticksLengthAndIndex[j];
              if (startLength === endLength) {
                for (; k < newLinesIndex.length; k++) {
                  const newlineIndex = newLinesIndex[k];
                  if (startIndex < newlineIndex) {
                    break;
                  }
                  lineIndex++;
                  lineStartIndex = newlineIndex + 1;
                }
                const columnIndex = startIndex - lineStartIndex + startLength;
                handler(
                  input.slice(startIndex + startLength, endIndex),
                  lineIndex,
                  columnIndex,
                  startLength
                );
                i = j;
                break;
              }
            }
          }
        }
      }
      function freezeToken(token) {
        if (token.attrs) {
          for (const attr of token.attrs) {
            Object.freeze(attr);
          }
          Object.freeze(token.attrs);
        }
        if (token.children) {
          for (const child of token.children) {
            freezeToken(child);
          }
          Object.freeze(token.children);
        }
        if (token.map) {
          Object.freeze(token.map);
        }
        Object.freeze(token);
      }
      function annotateAndFreezeTokens(tokens, lines) {
        let trMap = null;
        const markdownItTokens = tokens;
        for (const token of markdownItTokens) {
          if (token.type === "tr_open") {
            trMap = token.map;
          } else if (token.type === "tr_close") {
            trMap = null;
          }
          if (!token.map && trMap) {
            token.map = [...trMap];
          }
          if (token.map) {
            token.line = lines[token.map[0]];
            token.lineNumber = token.map[0] + 1;
            while (token.map[1] && !(lines[token.map[1] - 1] || "").trim()) {
              token.map[1]--;
            }
          }
          if (token.children) {
            const codeSpanExtraLines = [];
            if (token.children.some((child) => child.type === "code_inline")) {
              forEachInlineCodeSpan(token.content, (code2) => {
                codeSpanExtraLines.push(code2.split(newlineRe2).length - 1);
              });
            }
            let lineNumber = token.lineNumber;
            for (const child of token.children) {
              child.lineNumber = lineNumber;
              child.line = lines[lineNumber - 1];
              if (child.type === "softbreak" || child.type === "hardbreak") {
                lineNumber++;
              } else if (child.type === "code_inline") {
                lineNumber += codeSpanExtraLines.shift() || 0;
              }
            }
          }
          freezeToken(token);
        }
        Object.freeze(tokens);
      }
      function getMarkdownItTokens(markdownIt, content3, lines) {
        const tokens = markdownIt.parse(content3, {});
        annotateAndFreezeTokens(tokens, lines);
        return tokens;
      }
      module.exports = {
        forEachInlineCodeSpan,
        getMarkdownItTokens
      };
    }
  });

  // node_modules/markdownlint/lib/defer-require.cjs
  var require_defer_require = __commonJS({
    "node_modules/markdownlint/lib/defer-require.cjs"(exports, module) {
      "use strict";
      function requireMarkdownItCjs2() {
        return require_markdownit();
      }
      module.exports = {
        requireMarkdownItCjs: requireMarkdownItCjs2
      };
    }
  });

  // node_modules/markdownlint/lib/resolve-module.cjs
  var require_resolve_module = __commonJS({
    "node_modules/markdownlint/lib/resolve-module.cjs"(exports, module) {
      "use strict";
      var nativeRequire = globalThis.__non_webpack_require__ ?? __require;
      var resolveModuleCustomResolve = (resolve, id, paths = []) => {
        const resolvePaths = resolve.paths?.("") || [];
        const allPaths = [...paths, ...resolvePaths];
        return resolve(id, { "paths": allPaths });
      };
      var resolveModule3 = (id, paths) => resolveModuleCustomResolve(nativeRequire.resolve, id, paths);
      module.exports = {
        resolveModule: resolveModule3,
        resolveModuleCustomResolve
      };
    }
  });

  // entry.mjs
  var entry_exports = {};
  __export(entry_exports, {
    applyFixes: () => applyFixes,
    lint: () => lintSync
  });

  // node_modules/markdownlint/lib/node-imports-browser.mjs
  var getError = () => new Error("Node APIs are not available in browser context.");
  var throwForSync = () => {
    throw getError();
  };
  var fs = {
    // @ts-ignore
    "access": (path3, callback) => callback(getError()),
    "accessSync": throwForSync,
    // @ts-ignore
    "readFile": (path3, options, callback) => callback(getError()),
    "readFileSync": throwForSync
  };
  var os = {};

  // node_modules/markdownlint/lib/cache.mjs
  var import_helpers = __toESM(require_helpers(), 1);
  var import_micromark_helpers = __toESM(require_micromark_helpers(), 1);
  var map = /* @__PURE__ */ new Map();
  var params = void 0;
  function initialize(p) {
    map.clear();
    params = p;
  }
  function micromarkTokens() {
    return params?.parsers.micromark.tokens || [];
  }
  function getCached(name, getValue) {
    if (map.has(name)) {
      return map.get(name);
    }
    const value = getValue();
    map.set(name, value);
    return value;
  }
  function filterByTypesCached(types, htmlFlow2) {
    return getCached(
      // eslint-disable-next-line prefer-rest-params
      JSON.stringify(arguments),
      () => (0, import_micromark_helpers.filterByTypes)(micromarkTokens(), types, htmlFlow2)
    );
  }
  function getReferenceLinkImageData() {
    return getCached(
      getReferenceLinkImageData.name,
      () => (0, import_helpers.getReferenceLinkImageData)(micromarkTokens())
    );
  }

  // node_modules/markdownlint/lib/constants.mjs
  var homepage = "https://github.com/DavidAnson/markdownlint";
  var version = "0.41.0";

  // node_modules/markdownlint/lib/markdownlint.mjs
  var import_defer_require = __toESM(require_defer_require(), 1);
  var import_resolve_module = __toESM(require_resolve_module(), 1);

  // node_modules/markdownlint/lib/md001.mjs
  var import_helpers2 = __toESM(require_helpers(), 1);
  var import_micromark_helpers2 = __toESM(require_micromark_helpers(), 1);
  var md001_default = {
    "names": ["MD001", "heading-increment"],
    "description": "Heading levels should only increment by one level at a time",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD001(params2, onError) {
      const hasTitle = (0, import_helpers2.frontMatterHasTitle)(
        params2.frontMatterLines,
        params2.config.front_matter_title
      );
      let prevLevel = hasTitle ? 1 : Number.MAX_SAFE_INTEGER;
      for (const heading of filterByTypesCached(["atxHeading", "setextHeading"])) {
        const level = (0, import_micromark_helpers2.getHeadingLevel)(heading);
        if (level > prevLevel) {
          (0, import_helpers2.addErrorDetailIf)(
            onError,
            heading.startLine,
            `h${prevLevel + 1}`,
            `h${level}`
          );
        }
        prevLevel = level;
      }
    }
  };

  // node_modules/markdownlint/lib/md003.mjs
  var import_helpers3 = __toESM(require_helpers(), 1);
  var import_micromark_helpers3 = __toESM(require_micromark_helpers(), 1);
  var md003_default = {
    "names": ["MD003", "heading-style"],
    "description": "Heading style",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD003(params2, onError) {
      let style = String(params2.config.style || "consistent");
      for (const heading of filterByTypesCached(["atxHeading", "setextHeading"])) {
        const styleForToken = (0, import_micromark_helpers3.getHeadingStyle)(heading);
        if (style === "consistent") {
          style = styleForToken;
        }
        if (styleForToken !== style) {
          const h12 = (0, import_micromark_helpers3.getHeadingLevel)(heading) <= 2;
          const setextWithAtx = style === "setext_with_atx" && (h12 && styleForToken === "setext" || !h12 && styleForToken === "atx");
          const setextWithAtxClosed = style === "setext_with_atx_closed" && (h12 && styleForToken === "setext" || !h12 && styleForToken === "atx_closed");
          if (!setextWithAtx && !setextWithAtxClosed) {
            let expected = style;
            if (style === "setext_with_atx") {
              expected = h12 ? "setext" : "atx";
            } else if (style === "setext_with_atx_closed") {
              expected = h12 ? "setext" : "atx_closed";
            }
            (0, import_helpers3.addErrorDetailIf)(
              onError,
              heading.startLine,
              expected,
              styleForToken
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md004.mjs
  var import_helpers4 = __toESM(require_helpers(), 1);
  var import_micromark_helpers4 = __toESM(require_micromark_helpers(), 1);
  var markerToStyle = (marker) => marker === "-" ? "dash" : marker === "+" ? "plus" : "asterisk";
  var styleToMarker = (style) => style === "dash" ? "-" : style === "plus" ? "+" : "*";
  var differentItemStyle = (style) => style === "dash" ? "plus" : style === "plus" ? "asterisk" : "dash";
  var validStyles = /* @__PURE__ */ new Set([
    "asterisk",
    "consistent",
    "dash",
    "plus",
    "sublist"
  ]);
  var md004_default = {
    "names": ["MD004", "ul-style"],
    "description": "Unordered list style",
    "tags": ["bullet", "ul"],
    "parser": "micromark",
    "function": function MD004(params2, onError) {
      const style = String(params2.config.style || "consistent");
      let expectedStyle = validStyles.has(style) ? style : "dash";
      const nestingStyles = [];
      for (const listUnordered of filterByTypesCached(["listUnordered"])) {
        let nesting = 0;
        if (style === "sublist") {
          let parent = listUnordered;
          while (parent = (0, import_micromark_helpers4.getParentOfType)(parent, ["listOrdered", "listUnordered"])) {
            nesting++;
          }
        }
        const listItemMarkers = (0, import_micromark_helpers4.getDescendantsByType)(listUnordered, ["listItemPrefix", "listItemMarker"]);
        for (const listItemMarker of listItemMarkers) {
          const itemStyle = markerToStyle(listItemMarker.text);
          if (style === "sublist") {
            if (!nestingStyles[nesting]) {
              nestingStyles[nesting] = itemStyle === nestingStyles[nesting - 1] ? differentItemStyle(itemStyle) : itemStyle;
            }
            expectedStyle = nestingStyles[nesting];
          } else if (expectedStyle === "consistent") {
            expectedStyle = itemStyle;
          }
          const column = listItemMarker.startColumn;
          const length = listItemMarker.endColumn - listItemMarker.startColumn;
          (0, import_helpers4.addErrorDetailIf)(
            onError,
            listItemMarker.startLine,
            expectedStyle,
            itemStyle,
            void 0,
            void 0,
            [column, length],
            {
              "editColumn": column,
              "deleteCount": length,
              "insertText": styleToMarker(expectedStyle)
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md005.mjs
  var import_helpers5 = __toESM(require_helpers(), 1);
  var md005_default = {
    "names": ["MD005", "list-indent"],
    "description": "Inconsistent indentation for list items at the same level",
    "tags": ["bullet", "ul", "indentation"],
    "parser": "micromark",
    "function": function MD005(params2, onError) {
      for (const list2 of filterByTypesCached(["listOrdered", "listUnordered"])) {
        const expectedIndent = list2.startColumn - 1;
        let expectedEnd = 0;
        let endMatching = false;
        const listItemPrefixes = list2.children.filter((token) => token.type === "listItemPrefix");
        for (const listItemPrefix of listItemPrefixes) {
          const lineNumber = listItemPrefix.startLine;
          const actualIndent = listItemPrefix.startColumn - 1;
          const range = [1, listItemPrefix.endColumn - 1];
          if (list2.type === "listUnordered") {
            (0, import_helpers5.addErrorDetailIf)(
              onError,
              lineNumber,
              expectedIndent,
              actualIndent,
              void 0,
              void 0,
              range
              // No fixInfo; MD007 handles this scenario better
            );
          } else {
            const markerLength = listItemPrefix.text.trim().length;
            const actualEnd = listItemPrefix.startColumn + markerLength - 1;
            expectedEnd = expectedEnd || actualEnd;
            if (expectedIndent !== actualIndent || endMatching) {
              if (expectedEnd === actualEnd) {
                endMatching = true;
              } else {
                const detail = endMatching ? `Expected: (${expectedEnd}); Actual: (${actualEnd})` : `Expected: ${expectedIndent}; Actual: ${actualIndent}`;
                const expected = endMatching ? expectedEnd - markerLength : expectedIndent;
                const actual = endMatching ? actualEnd - markerLength : actualIndent;
                (0, import_helpers5.addError)(
                  onError,
                  lineNumber,
                  detail,
                  void 0,
                  range,
                  {
                    "editColumn": Math.min(actual, expected) + 1,
                    "deleteCount": Math.max(actual - expected, 0),
                    "insertText": "".padEnd(Math.max(expected - actual, 0))
                  }
                );
              }
            }
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md007.mjs
  var import_helpers6 = __toESM(require_helpers(), 1);
  var import_micromark_helpers5 = __toESM(require_micromark_helpers(), 1);
  var unorderedListTypes = ["blockQuotePrefix", "listItemPrefix", "listUnordered"];
  var unorderedParentTypes = ["blockQuote", "listOrdered", "listUnordered"];
  var md007_default = {
    "names": ["MD007", "ul-indent"],
    "description": "Unordered list indentation",
    "tags": ["bullet", "ul", "indentation"],
    "parser": "micromark",
    "function": function MD007(params2, onError) {
      const indent2 = Number(params2.config.indent || 2);
      const startIndented = !!params2.config.start_indented;
      const startIndent = Number(params2.config.start_indent || indent2);
      const unorderedListNesting = /* @__PURE__ */ new Map();
      let lastBlockQuotePrefix = null;
      const tokens = filterByTypesCached(unorderedListTypes);
      for (const token of tokens) {
        const { endColumn, parent, startColumn, startLine, type } = token;
        if (type === "blockQuotePrefix") {
          lastBlockQuotePrefix = token;
        } else if (type === "listUnordered") {
          let nesting = 0;
          let current = token;
          while (
            // @ts-ignore
            current = (0, import_micromark_helpers5.getParentOfType)(current, unorderedParentTypes)
          ) {
            if (current.type === "listUnordered") {
              nesting++;
              continue;
            } else if (current.type === "listOrdered") {
              nesting = -1;
            }
            break;
          }
          if (nesting >= 0) {
            unorderedListNesting.set(token, nesting);
          }
        } else {
          const nesting = unorderedListNesting.get(parent);
          if (nesting !== void 0) {
            const baseIndent = (0, import_micromark_helpers5.getParentOfType)(token, ["gfmFootnoteDefinition"]) ? 4 : 0;
            const expectedIndent = baseIndent + (startIndented ? startIndent : 0) + nesting * indent2;
            const blockQuoteAdjustment = lastBlockQuotePrefix?.endLine === startLine ? lastBlockQuotePrefix.endColumn - 1 : 0;
            const actualIndent = startColumn - 1 - blockQuoteAdjustment;
            const range = [1, endColumn - 1];
            const fixInfo = {
              "editColumn": startColumn - actualIndent,
              "deleteCount": Math.max(actualIndent - expectedIndent, 0),
              "insertText": "".padEnd(Math.max(expectedIndent - actualIndent, 0))
            };
            (0, import_helpers6.addErrorDetailIf)(
              onError,
              startLine,
              expectedIndent,
              actualIndent,
              void 0,
              void 0,
              range,
              fixInfo
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md009.mjs
  var import_helpers7 = __toESM(require_helpers(), 1);
  var import_micromark_helpers6 = __toESM(require_micromark_helpers(), 1);
  var md009_default = {
    "names": ["MD009", "no-trailing-spaces"],
    "description": "Trailing spaces",
    "tags": ["whitespace"],
    "parser": "micromark",
    "function": function MD009(params2, onError) {
      let brSpaces = params2.config.br_spaces;
      brSpaces = Number(brSpaces === void 0 ? 2 : brSpaces);
      const codeBlocks = params2.config.code_blocks;
      const includeCode = codeBlocks === void 0 ? false : !!codeBlocks;
      const listItemEmptyLines = !!params2.config.list_item_empty_lines;
      const strict = !!params2.config.strict;
      const codeBlockLineNumbers = /* @__PURE__ */ new Set();
      if (!includeCode) {
        for (const codeBlock of filterByTypesCached(["codeFenced"])) {
          (0, import_micromark_helpers6.addRangeToSet)(codeBlockLineNumbers, codeBlock.startLine + 1, codeBlock.endLine - 1);
        }
        for (const codeBlock of filterByTypesCached(["codeIndented"])) {
          (0, import_micromark_helpers6.addRangeToSet)(codeBlockLineNumbers, codeBlock.startLine, codeBlock.endLine);
        }
      }
      const listItemLineNumbers = /* @__PURE__ */ new Set();
      if (listItemEmptyLines) {
        for (const listBlock of filterByTypesCached(["listOrdered", "listUnordered"])) {
          (0, import_micromark_helpers6.addRangeToSet)(listItemLineNumbers, listBlock.startLine, listBlock.endLine);
          let trailingIndent = true;
          for (let i = listBlock.children.length - 1; i >= 0; i--) {
            const child = listBlock.children[i];
            switch (child.type) {
              case "content":
                trailingIndent = false;
                break;
              case "listItemIndent":
                if (trailingIndent) {
                  listItemLineNumbers.delete(child.startLine);
                }
                break;
              case "listItemPrefix":
                trailingIndent = true;
                break;
              default:
                break;
            }
          }
        }
      }
      const paragraphLineNumbers = /* @__PURE__ */ new Set();
      const codeInlineLineNumbers = /* @__PURE__ */ new Set();
      if (strict) {
        for (const paragraph of filterByTypesCached(["paragraph"])) {
          (0, import_micromark_helpers6.addRangeToSet)(paragraphLineNumbers, paragraph.startLine, paragraph.endLine - 1);
        }
        for (const codeText2 of filterByTypesCached(["codeText"])) {
          (0, import_micromark_helpers6.addRangeToSet)(codeInlineLineNumbers, codeText2.startLine, codeText2.endLine - 1);
        }
      }
      const expected = brSpaces < 2 ? 0 : brSpaces;
      for (let lineIndex = 0; lineIndex < params2.lines.length; lineIndex++) {
        const line = params2.lines[lineIndex];
        const lineNumber = lineIndex + 1;
        const trailingSpaces = line.length - line.trimEnd().length;
        if (trailingSpaces && !codeBlockLineNumbers.has(lineNumber) && !listItemLineNumbers.has(lineNumber) && (expected !== trailingSpaces || strict && (!paragraphLineNumbers.has(lineNumber) || codeInlineLineNumbers.has(lineNumber)))) {
          const column = line.length - trailingSpaces + 1;
          (0, import_helpers7.addError)(
            onError,
            lineNumber,
            "Expected: " + (expected === 0 ? "" : "0 or ") + expected + "; Actual: " + trailingSpaces,
            void 0,
            [column, trailingSpaces],
            {
              "editColumn": column,
              "deleteCount": trailingSpaces
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md010.mjs
  var import_helpers8 = __toESM(require_helpers(), 1);
  var import_micromark_helpers7 = __toESM(require_micromark_helpers(), 1);
  var tabRe = /\t+/g;
  var md010_default = {
    "names": ["MD010", "no-hard-tabs"],
    "description": "Hard tabs",
    "tags": ["whitespace", "hard_tab"],
    "parser": "micromark",
    "function": function MD010(params2, onError) {
      const codeBlocks = params2.config.code_blocks;
      const includeCode = codeBlocks === void 0 ? true : !!codeBlocks;
      const ignoreCodeLanguages = new Set(
        (params2.config.ignore_code_languages || []).map((language) => String(language).toLowerCase())
      );
      const spacesPerTab = params2.config.spaces_per_tab;
      const spaceMultiplier = spacesPerTab === void 0 ? 1 : Math.max(0, Number(spacesPerTab));
      const exclusionTypes = [];
      if (includeCode) {
        if (ignoreCodeLanguages.size > 0) {
          exclusionTypes.push("codeFenced");
        }
      } else {
        exclusionTypes.push("codeFenced", "codeIndented", "codeText");
      }
      const codeTokens = filterByTypesCached(exclusionTypes).filter((token) => {
        if (token.type === "codeFenced" && ignoreCodeLanguages.size > 0) {
          const fenceInfos = (0, import_micromark_helpers7.getDescendantsByType)(token, ["codeFencedFence", "codeFencedFenceInfo"]);
          return fenceInfos.every((fenceInfo) => ignoreCodeLanguages.has(fenceInfo.text.toLowerCase()));
        }
        return true;
      });
      const codeRanges = codeTokens.map((token) => {
        const { type, startLine, startColumn, endLine, endColumn } = token;
        const codeFenced2 = type === "codeFenced";
        return {
          "startLine": startLine + (codeFenced2 ? 1 : 0),
          "startColumn": codeFenced2 ? 0 : startColumn,
          "endLine": endLine - (codeFenced2 ? 1 : 0),
          "endColumn": codeFenced2 ? Number.MAX_SAFE_INTEGER : endColumn
        };
      });
      for (let lineIndex = 0; lineIndex < params2.lines.length; lineIndex++) {
        const line = params2.lines[lineIndex];
        let match = null;
        while ((match = tabRe.exec(line)) !== null) {
          const lineNumber = lineIndex + 1;
          const column = match.index + 1;
          const length = match[0].length;
          const range = { "startLine": lineNumber, "startColumn": column, "endLine": lineNumber, "endColumn": column + length - 1 };
          if (!codeRanges.some((codeRange) => (0, import_helpers8.hasOverlap)(codeRange, range))) {
            (0, import_helpers8.addError)(
              onError,
              lineNumber,
              "Column: " + column,
              void 0,
              [column, length],
              {
                "editColumn": column,
                "deleteCount": length,
                "insertText": "".padEnd(length * spaceMultiplier)
              }
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md011.mjs
  var import_helpers9 = __toESM(require_helpers(), 1);
  var import_micromark_helpers8 = __toESM(require_micromark_helpers(), 1);
  var reversedLinkRe = /(^|[^\\])\(([^()]+)\)\[([^\]^][^\]]*)\](?!\()/g;
  var md011_default = {
    "names": ["MD011", "no-reversed-links"],
    "description": "Reversed link syntax",
    "tags": ["links"],
    "parser": "micromark",
    "function": function MD011(params2, onError) {
      const ignoreBlockLineNumbers = /* @__PURE__ */ new Set();
      for (const ignoreBlock of filterByTypesCached(["codeFenced", "codeIndented", "mathFlow"])) {
        (0, import_micromark_helpers8.addRangeToSet)(ignoreBlockLineNumbers, ignoreBlock.startLine, ignoreBlock.endLine);
      }
      const ignoreTexts = filterByTypesCached(["codeText", "mathText"]);
      for (const [lineIndex, line] of params2.lines.entries()) {
        const lineNumber = lineIndex + 1;
        if (!ignoreBlockLineNumbers.has(lineNumber)) {
          let match = null;
          while ((match = reversedLinkRe.exec(line)) !== null) {
            const [reversedLink, preChar, linkText, linkDestination] = match;
            if (!linkText.endsWith("\\") && !linkDestination.endsWith("\\")) {
              const column = match.index + preChar.length + 1;
              const length = match[0].length - preChar.length;
              const range = { "startLine": lineNumber, "startColumn": column, "endLine": lineNumber, "endColumn": column + length - 1 };
              if (!ignoreTexts.some((ignoreText) => (0, import_helpers9.hasOverlap)(ignoreText, range))) {
                (0, import_helpers9.addError)(
                  onError,
                  lineNumber,
                  reversedLink.slice(preChar.length),
                  void 0,
                  [column, length],
                  {
                    "editColumn": column,
                    "deleteCount": length,
                    "insertText": `[${linkText}](${linkDestination})`
                  }
                );
              }
            }
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md012.mjs
  var import_helpers10 = __toESM(require_helpers(), 1);
  var import_micromark_helpers9 = __toESM(require_micromark_helpers(), 1);
  var md012_default = {
    "names": ["MD012", "no-multiple-blanks"],
    "description": "Multiple consecutive blank lines",
    "tags": ["whitespace", "blank_lines"],
    "parser": "micromark",
    "function": function MD012(params2, onError) {
      const maximum = Number(params2.config.maximum || 1);
      const { lines } = params2;
      const codeBlockLineNumbers = /* @__PURE__ */ new Set();
      for (const codeBlock of filterByTypesCached(["codeFenced", "codeIndented"])) {
        (0, import_micromark_helpers9.addRangeToSet)(codeBlockLineNumbers, codeBlock.startLine, codeBlock.endLine);
      }
      let count = 0;
      for (const [lineIndex, line] of lines.entries()) {
        const inCode = codeBlockLineNumbers.has(lineIndex + 1);
        count = inCode || line.trim().length > 0 ? 0 : count + 1;
        if (maximum < count) {
          (0, import_helpers10.addErrorDetailIf)(
            onError,
            lineIndex + 1,
            maximum,
            count,
            void 0,
            void 0,
            void 0,
            {
              "deleteCount": -1
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md013.mjs
  var import_helpers11 = __toESM(require_helpers(), 1);
  var import_micromark_helpers10 = __toESM(require_micromark_helpers(), 1);
  var notWrappableRe = /^(?:[#>\s]*\s)?\S*$/;
  var md013_default = {
    "names": ["MD013", "line-length"],
    "description": "Line length",
    "tags": ["line_length"],
    "parser": "micromark",
    "function": function MD013(params2, onError) {
      const lineLength = Number(params2.config.line_length || 80);
      const headingLineLength = Number(params2.config.heading_line_length || lineLength);
      const codeLineLength = Number(params2.config.code_block_line_length || lineLength);
      const strict = !!params2.config.strict;
      const stern = !!params2.config.stern;
      const codeBlocks = params2.config.code_blocks;
      const includeCodeBlocks = codeBlocks === void 0 ? true : !!codeBlocks;
      const tables = params2.config.tables;
      const includeTables = tables === void 0 ? true : !!tables;
      const headings = params2.config.headings;
      const includeHeadings = headings === void 0 ? true : !!headings;
      const headingLineNumbers = /* @__PURE__ */ new Set();
      for (const heading of filterByTypesCached(["atxHeading", "setextHeading"])) {
        (0, import_micromark_helpers10.addRangeToSet)(headingLineNumbers, heading.startLine, heading.endLine);
      }
      const codeBlockLineNumbers = /* @__PURE__ */ new Set();
      for (const codeBlock of filterByTypesCached(["codeFenced", "codeIndented"])) {
        (0, import_micromark_helpers10.addRangeToSet)(codeBlockLineNumbers, codeBlock.startLine, codeBlock.endLine);
      }
      const tableLineNumbers = /* @__PURE__ */ new Set();
      for (const table of filterByTypesCached(["table"])) {
        (0, import_micromark_helpers10.addRangeToSet)(tableLineNumbers, table.startLine, table.endLine);
      }
      const linkLineNumbers = /* @__PURE__ */ new Set();
      for (const link of filterByTypesCached(["autolink", "image", "link", "literalAutolink"])) {
        (0, import_micromark_helpers10.addRangeToSet)(linkLineNumbers, link.startLine, link.endLine);
      }
      const paragraphDataLineNumbers = /* @__PURE__ */ new Set();
      for (const paragraph of filterByTypesCached(["paragraph"])) {
        for (const data of (0, import_micromark_helpers10.getDescendantsByType)(paragraph, ["data"])) {
          (0, import_micromark_helpers10.addRangeToSet)(paragraphDataLineNumbers, data.startLine, data.endLine);
        }
      }
      const linkOnlyLineNumbers = /* @__PURE__ */ new Set();
      for (const lineNumber of linkLineNumbers) {
        if (!paragraphDataLineNumbers.has(lineNumber)) {
          linkOnlyLineNumbers.add(lineNumber);
        }
      }
      const definitionLineIndices = new Set(getReferenceLinkImageData().definitionLineIndices);
      for (let lineIndex = 0; lineIndex < params2.lines.length; lineIndex++) {
        const line = params2.lines[lineIndex];
        const lineNumber = lineIndex + 1;
        const isHeading = headingLineNumbers.has(lineNumber);
        const inCode = codeBlockLineNumbers.has(lineNumber);
        const inTable = tableLineNumbers.has(lineNumber);
        const maxLength = inCode ? codeLineLength : isHeading ? headingLineLength : lineLength;
        const text4 = strict || stern ? line : line.replace(/\S*$/u, "#");
        if (maxLength > 0 && (includeCodeBlocks || !inCode) && (includeTables || !inTable) && (includeHeadings || !isHeading) && !definitionLineIndices.has(lineIndex) && (strict || !(stern && notWrappableRe.test(line)) && !linkOnlyLineNumbers.has(lineNumber)) && text4.length > maxLength) {
          (0, import_helpers11.addErrorDetailIf)(
            onError,
            lineNumber,
            maxLength,
            line.length,
            void 0,
            void 0,
            [maxLength + 1, line.length - maxLength]
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md014.mjs
  var import_helpers12 = __toESM(require_helpers(), 1);
  var dollarCommandRe = /^(\s*)(\$\s+)/;
  var md014_default = {
    "names": ["MD014", "commands-show-output"],
    "description": "Dollar signs used before commands without showing output",
    "tags": ["code"],
    "parser": "micromark",
    "function": function MD014(params2, onError) {
      for (const codeBlock of filterByTypesCached(["codeFenced", "codeIndented"])) {
        const codeFlowValues = codeBlock.children.filter((child) => child.type === "codeFlowValue");
        const dollarMatches = codeFlowValues.map((codeFlowValue) => ({
          "result": codeFlowValue.text.match(dollarCommandRe),
          "startColumn": codeFlowValue.startColumn,
          "startLine": codeFlowValue.startLine,
          "text": codeFlowValue.text
        })).filter((dollarMatch) => dollarMatch.result);
        if (dollarMatches.length === codeFlowValues.length) {
          for (const dollarMatch of dollarMatches) {
            const column = dollarMatch.startColumn + dollarMatch.result[1].length;
            const length = dollarMatch.result[2].length;
            (0, import_helpers12.addErrorContext)(
              onError,
              dollarMatch.startLine,
              dollarMatch.text,
              void 0,
              void 0,
              [column, length],
              {
                "editColumn": column,
                "deleteCount": length
              }
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md018.mjs
  var import_helpers13 = __toESM(require_helpers(), 1);
  var import_micromark_helpers11 = __toESM(require_micromark_helpers(), 1);
  var md018_default = {
    "names": ["MD018", "no-missing-space-atx"],
    "description": "No space after hash on atx style heading",
    "tags": ["headings", "atx", "spaces"],
    "parser": "micromark",
    "function": function MD018(params2, onError) {
      const { lines } = params2;
      const ignoreBlockLineNumbers = /* @__PURE__ */ new Set();
      for (const ignoreBlock of filterByTypesCached(["codeFenced", "codeIndented", "htmlFlow"])) {
        (0, import_micromark_helpers11.addRangeToSet)(ignoreBlockLineNumbers, ignoreBlock.startLine, ignoreBlock.endLine);
      }
      for (const [lineIndex, line] of lines.entries()) {
        if (!ignoreBlockLineNumbers.has(lineIndex + 1) && /^#+[^# \t]/.test(line) && !/#\s*$/.test(line) && !line.startsWith("#\uFE0F\u20E3")) {
          const hashCount = /^#+/.exec(line)[0].length;
          (0, import_helpers13.addErrorContext)(
            onError,
            lineIndex + 1,
            line.trim(),
            void 0,
            void 0,
            [1, hashCount + 1],
            {
              "editColumn": hashCount + 1,
              "insertText": " "
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md019-md021.mjs
  var import_helpers14 = __toESM(require_helpers(), 1);
  var import_micromark_helpers12 = __toESM(require_micromark_helpers(), 1);
  function validateHeadingSpaces(onError, heading, delta) {
    const { children, startLine, text: text4 } = heading;
    let index = delta > 0 ? 0 : children.length - 1;
    while (children[index] && children[index].type !== "atxHeadingSequence") {
      index += delta;
    }
    const headingSequence = children[index];
    const whitespace = children[index + delta];
    if (headingSequence?.type === "atxHeadingSequence" && whitespace?.type === "whitespace" && whitespace.text.length > 1) {
      const column = whitespace.startColumn + 1;
      const length = whitespace.endColumn - column;
      (0, import_helpers14.addErrorContext)(
        onError,
        startLine,
        text4.trim(),
        delta > 0,
        delta < 0,
        [column, length],
        {
          "editColumn": column,
          "deleteCount": length
        }
      );
    }
  }
  var md019_md021_default = [
    {
      "names": ["MD019", "no-multiple-space-atx"],
      "description": "Multiple spaces after hash on atx style heading",
      "tags": ["headings", "atx", "spaces"],
      "parser": "micromark",
      "function": function MD019(params2, onError) {
        const atxHeadings = filterByTypesCached(["atxHeading"]).filter((heading) => (0, import_micromark_helpers12.getHeadingStyle)(heading) === "atx");
        for (const atxHeading of atxHeadings) {
          validateHeadingSpaces(onError, atxHeading, 1);
        }
      }
    },
    {
      "names": ["MD021", "no-multiple-space-closed-atx"],
      "description": "Multiple spaces inside hashes on closed atx style heading",
      "tags": ["headings", "atx_closed", "spaces"],
      "parser": "micromark",
      "function": function MD021(params2, onError) {
        const atxClosedHeadings = filterByTypesCached(["atxHeading"]).filter((heading) => (0, import_micromark_helpers12.getHeadingStyle)(heading) === "atx_closed");
        for (const atxClosedHeading of atxClosedHeadings) {
          validateHeadingSpaces(onError, atxClosedHeading, 1);
          validateHeadingSpaces(onError, atxClosedHeading, -1);
        }
      }
    }
  ];

  // node_modules/markdownlint/lib/md020.mjs
  var import_helpers15 = __toESM(require_helpers(), 1);
  var import_micromark_helpers13 = __toESM(require_micromark_helpers(), 1);
  var md020_default = {
    "names": ["MD020", "no-missing-space-closed-atx"],
    "description": "No space inside hashes on closed atx style heading",
    "tags": ["headings", "atx_closed", "spaces"],
    "parser": "micromark",
    "function": function MD020(params2, onError) {
      const { lines } = params2;
      const ignoreBlockLineNumbers = /* @__PURE__ */ new Set();
      for (const ignoreBlock of filterByTypesCached(["codeFenced", "codeIndented", "htmlFlow"])) {
        (0, import_micromark_helpers13.addRangeToSet)(ignoreBlockLineNumbers, ignoreBlock.startLine, ignoreBlock.endLine);
      }
      for (const [lineIndex, line] of lines.entries()) {
        if (!ignoreBlockLineNumbers.has(lineIndex + 1)) {
          const match = /^(#+)([ \t]*)([^# \t\\]|[^# \t][^#]*?[^# \t\\])([ \t]*)((?:\\#)?)(#+)(\s*)$/.exec(line);
          if (match) {
            const [
              ,
              leftHash,
              { "length": leftSpaceLength },
              content3,
              { "length": rightSpaceLength },
              rightEscape,
              rightHash,
              { "length": trailSpaceLength }
            ] = match;
            const leftHashLength = leftHash.length;
            const rightHashLength = rightHash.length;
            const left = !leftSpaceLength;
            const right = !rightSpaceLength || !!rightEscape;
            const rightEscapeReplacement = rightEscape ? `${rightEscape} ` : "";
            if (left || right) {
              const range = left ? [
                1,
                leftHashLength + 1
              ] : [
                line.length - trailSpaceLength - rightHashLength,
                rightHashLength + 1
              ];
              (0, import_helpers15.addErrorContext)(
                onError,
                lineIndex + 1,
                line.trim(),
                left,
                right,
                range,
                {
                  "editColumn": 1,
                  "deleteCount": line.length,
                  "insertText": `${leftHash} ${content3} ${rightEscapeReplacement}${rightHash}`
                }
              );
            }
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md022.mjs
  var import_helpers16 = __toESM(require_helpers(), 1);
  var import_micromark_helpers14 = __toESM(require_micromark_helpers(), 1);
  var defaultLines = 1;
  var getLinesFunction = (linesParam) => {
    if (Array.isArray(linesParam)) {
      const linesArray = new Array(6).fill(defaultLines);
      for (const [index, value] of [...linesParam.entries()].slice(0, 6)) {
        linesArray[index] = value;
      }
      return (heading) => linesArray[(0, import_micromark_helpers14.getHeadingLevel)(heading) - 1];
    }
    const lines = linesParam === void 0 ? defaultLines : Number(linesParam);
    return () => lines;
  };
  var getLine = (lines, index, frontMatterLines, includeFrontMatter) => {
    if (index >= 0 && index < lines.length) {
      return lines[index];
    }
    if (includeFrontMatter && frontMatterLines.length > 0 && index < 0 && index >= -frontMatterLines.length) {
      return frontMatterLines[frontMatterLines.length + index];
    }
    return "";
  };
  var md022_default = {
    "names": ["MD022", "blanks-around-headings"],
    "description": "Headings should be surrounded by blank lines",
    "tags": ["headings", "blank_lines"],
    "parser": "micromark",
    "function": function MD022(params2, onError) {
      const getLinesAbove = getLinesFunction(params2.config.lines_above);
      const getLinesBelow = getLinesFunction(params2.config.lines_below);
      const includeFrontMatter = !!params2.config.include_front_matter;
      const { lines, frontMatterLines } = params2;
      const blockQuotePrefixes = filterByTypesCached(["blockQuotePrefix", "linePrefix"]);
      for (const heading of filterByTypesCached(["atxHeading", "setextHeading"])) {
        const { startLine, endLine } = heading;
        const line = lines[startLine - 1].trim();
        const linesAbove = getLinesAbove(heading);
        if (linesAbove >= 0) {
          let actualAbove = 0;
          for (let i = 0; i < linesAbove && (0, import_helpers16.isBlankLine)(getLine(lines, startLine - 2 - i, frontMatterLines, includeFrontMatter)); i++) {
            actualAbove++;
          }
          (0, import_helpers16.addErrorDetailIf)(
            onError,
            startLine,
            linesAbove,
            actualAbove,
            "Above",
            line,
            void 0,
            {
              "insertText": (0, import_micromark_helpers14.getBlockQuotePrefixText)(
                blockQuotePrefixes,
                startLine - 1,
                linesAbove - actualAbove
              )
            }
          );
        }
        const linesBelow = getLinesBelow(heading);
        if (linesBelow >= 0) {
          let actualBelow = 0;
          for (let i = 0; i < linesBelow && (0, import_helpers16.isBlankLine)(getLine(lines, endLine + i, frontMatterLines, false)); i++) {
            actualBelow++;
          }
          (0, import_helpers16.addErrorDetailIf)(
            onError,
            startLine,
            linesBelow,
            actualBelow,
            "Below",
            line,
            void 0,
            {
              "lineNumber": endLine + 1,
              "insertText": (0, import_micromark_helpers14.getBlockQuotePrefixText)(
                blockQuotePrefixes,
                endLine + 1,
                linesBelow - actualBelow
              )
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md023.mjs
  var import_helpers17 = __toESM(require_helpers(), 1);
  var md023_default = {
    "names": ["MD023", "heading-start-left"],
    "description": "Headings must start at the beginning of the line",
    "tags": ["headings", "spaces"],
    "parser": "micromark",
    "function": function MD023(params2, onError) {
      const headings = filterByTypesCached(["atxHeading", "linePrefix", "setextHeading"]);
      for (let i = 0; i < headings.length - 1; i++) {
        if (headings[i].type === "linePrefix" && headings[i + 1].type !== "linePrefix" && headings[i].startLine === headings[i + 1].startLine) {
          const { endColumn, startColumn, startLine } = headings[i];
          const length = endColumn - startColumn;
          (0, import_helpers17.addErrorContext)(
            onError,
            startLine,
            params2.lines[startLine - 1],
            true,
            false,
            [startColumn, length],
            {
              "editColumn": startColumn,
              "deleteCount": length
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md024.mjs
  var import_helpers18 = __toESM(require_helpers(), 1);
  var import_micromark_helpers15 = __toESM(require_micromark_helpers(), 1);
  var md024_default = {
    "names": ["MD024", "no-duplicate-heading"],
    "description": "Multiple headings with the same content",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD024(params2, onError) {
      const siblingsOnly = !!params2.config.siblings_only || false;
      const knownContents = [null, []];
      let lastLevel = 1;
      let knownContent = knownContents[lastLevel];
      for (const heading of filterByTypesCached(["atxHeading", "setextHeading"])) {
        const headingText = (0, import_micromark_helpers15.getHeadingText)(heading);
        if (siblingsOnly) {
          const newLevel = (0, import_micromark_helpers15.getHeadingLevel)(heading);
          while (lastLevel < newLevel) {
            lastLevel++;
            knownContents[lastLevel] = [];
          }
          while (lastLevel > newLevel) {
            knownContents[lastLevel] = [];
            lastLevel--;
          }
          knownContent = knownContents[newLevel];
        }
        if (knownContent.includes(headingText)) {
          (0, import_helpers18.addErrorContext)(
            onError,
            heading.startLine,
            headingText.trim()
          );
        } else {
          knownContent.push(headingText);
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md025.mjs
  var import_helpers19 = __toESM(require_helpers(), 1);
  var import_micromark_helpers16 = __toESM(require_micromark_helpers(), 1);
  var md025_default = {
    "names": ["MD025", "single-title", "single-h1"],
    "description": "Multiple top-level headings in the same document",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD025(params2, onError) {
      const level = Number(params2.config.level || 1);
      const { tokens } = params2.parsers.micromark;
      const matchingHeadings = filterByTypesCached(["atxHeading", "setextHeading"]).filter((heading) => level === (0, import_micromark_helpers16.getHeadingLevel)(heading) && !(0, import_micromark_helpers16.isDocfxTab)(heading));
      if (matchingHeadings.length > 0) {
        const foundFrontMatterTitle = (0, import_helpers19.frontMatterHasTitle)(
          params2.frontMatterLines,
          params2.config.front_matter_title
        );
        let hasTopLevelHeading = foundFrontMatterTitle;
        if (!hasTopLevelHeading) {
          const previousTokens = tokens.slice(0, tokens.indexOf(matchingHeadings[0]));
          hasTopLevelHeading = previousTokens.every(
            (token) => import_micromark_helpers16.nonContentTokens.has(token.type) || (0, import_micromark_helpers16.isHtmlFlowComment)(token)
          );
        }
        if (hasTopLevelHeading) {
          for (const heading of matchingHeadings.slice(foundFrontMatterTitle ? 0 : 1)) {
            (0, import_helpers19.addErrorContext)(
              onError,
              heading.startLine,
              (0, import_micromark_helpers16.getHeadingText)(heading)
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md026.mjs
  var import_helpers20 = __toESM(require_helpers(), 1);
  var md026_default = {
    "names": ["MD026", "no-trailing-punctuation"],
    "description": "Trailing punctuation in heading",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD026(params2, onError) {
      let punctuation = params2.config.punctuation;
      punctuation = String(
        punctuation === void 0 ? import_helpers20.allPunctuationNoQuestion : punctuation
      );
      const trailingPunctuationRe = new RegExp("\\s*[" + (0, import_helpers20.escapeForRegExp)(punctuation) + "]+$");
      const headings = filterByTypesCached(["atxHeadingText", "setextHeadingText"]);
      for (const heading of headings) {
        const { endColumn, endLine, text: text4 } = heading;
        const match = trailingPunctuationRe.exec(text4);
        if (match && !import_helpers20.endOfLineHtmlEntityRe.test(text4) && !import_helpers20.endOfLineGemojiCodeRe.test(text4)) {
          const fullMatch = match[0];
          const length = fullMatch.length;
          const column = endColumn - length;
          (0, import_helpers20.addError)(
            onError,
            endLine,
            `Punctuation: '${fullMatch}'`,
            void 0,
            [column, length],
            {
              "editColumn": column,
              "deleteCount": length
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md027.mjs
  var import_helpers21 = __toESM(require_helpers(), 1);
  var import_micromark_helpers17 = __toESM(require_micromark_helpers(), 1);
  var listTypes = ["listOrdered", "listUnordered"];
  var md027_default = {
    "names": ["MD027", "no-multiple-space-blockquote"],
    "description": "Multiple spaces after blockquote symbol",
    "tags": ["blockquote", "whitespace", "indentation"],
    "parser": "micromark",
    "function": function MD027(params2, onError) {
      const listItems = params2.config.list_items;
      const includeListItems = listItems === void 0 ? true : !!listItems;
      const { tokens } = params2.parsers.micromark;
      for (const token of filterByTypesCached(["linePrefix"])) {
        const parent = token.parent;
        const codeIndented2 = parent?.type === "codeIndented";
        const siblings = parent?.children || tokens;
        if (!codeIndented2 && siblings[siblings.indexOf(token) - 1]?.type === "blockQuotePrefix" && (includeListItems || !listTypes.includes(siblings[siblings.indexOf(token) + 1]?.type) && !(0, import_micromark_helpers17.getParentOfType)(token, listTypes))) {
          const { startColumn, startLine, text: text4 } = token;
          const { length } = text4;
          const line = params2.lines[startLine - 1];
          (0, import_helpers21.addErrorContext)(
            onError,
            startLine,
            line,
            void 0,
            void 0,
            [startColumn, length],
            {
              "editColumn": startColumn,
              "deleteCount": length
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md028.mjs
  var import_helpers22 = __toESM(require_helpers(), 1);
  var ignoreTypes = /* @__PURE__ */ new Set(["lineEnding", "listItemIndent", "linePrefix"]);
  var md028_default = {
    "names": ["MD028", "no-blanks-blockquote"],
    "description": "Blank line inside blockquote",
    "tags": ["blockquote", "whitespace"],
    "parser": "micromark",
    "function": function MD028(params2, onError) {
      for (const token of filterByTypesCached(["blockQuote"])) {
        const errorLineNumbers = [];
        const siblings = token.parent?.children || params2.parsers.micromark.tokens;
        for (let i = siblings.indexOf(token) + 1; i < siblings.length; i++) {
          const sibling = siblings[i];
          const { startLine, type } = sibling;
          if (type === "lineEndingBlank") {
            errorLineNumbers.push(startLine);
          } else if (ignoreTypes.has(type)) {
          } else if (type === "blockQuote") {
            for (const lineNumber of errorLineNumbers) {
              (0, import_helpers22.addError)(onError, lineNumber);
            }
            break;
          } else {
            break;
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md029.mjs
  var import_helpers23 = __toESM(require_helpers(), 1);
  var import_micromark_helpers18 = __toESM(require_micromark_helpers(), 1);
  var listStyleExamples = {
    "one": "1/1/1",
    "ordered": "1/2/3",
    "zero": "0/0/0"
  };
  var listStyles = Object.keys(listStyleExamples);
  function getOrderedListItemValue(listItemPrefix) {
    const listItemValue = (0, import_micromark_helpers18.getDescendantsByType)(listItemPrefix, ["listItemValue"])[0];
    return {
      "column": listItemValue.startColumn,
      "value": Number(listItemValue.text)
    };
  }
  var md029_default = {
    "names": ["MD029", "ol-prefix"],
    "description": "Ordered list item prefix",
    "tags": ["ol"],
    "parser": "micromark",
    "function": function MD029(params2, onError) {
      const style = String(params2.config.style);
      for (const listOrdered of filterByTypesCached(["listOrdered"])) {
        const listItemPrefixes = (0, import_micromark_helpers18.getDescendantsByType)(listOrdered, ["listItemPrefix"]);
        let expected = 1;
        let incrementing = false;
        if (listItemPrefixes.length >= 2) {
          const first = getOrderedListItemValue(listItemPrefixes[0]);
          const second = getOrderedListItemValue(listItemPrefixes[1]);
          if (second.value !== 1 || first.value === 0) {
            incrementing = true;
            if (first.value === 0) {
              expected = 0;
            }
          }
        }
        const listStyle = listStyles.includes(style) ? style : incrementing ? "ordered" : "one";
        if (listStyle === "zero") {
          expected = 0;
        } else if (listStyle === "one") {
          expected = 1;
        }
        for (const listItemPrefix of listItemPrefixes) {
          const orderedListItemValue = getOrderedListItemValue(listItemPrefix);
          const actual = orderedListItemValue.value;
          const fixInfo = {
            "editColumn": orderedListItemValue.column,
            "deleteCount": orderedListItemValue.value.toString().length,
            "insertText": expected.toString()
          };
          (0, import_helpers23.addErrorDetailIf)(
            onError,
            listItemPrefix.startLine,
            expected,
            actual,
            // @ts-ignore
            "Style: " + listStyleExamples[listStyle],
            void 0,
            [listItemPrefix.startColumn, listItemPrefix.endColumn - listItemPrefix.startColumn],
            fixInfo
          );
          if (listStyle === "ordered") {
            expected++;
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md030.mjs
  var import_helpers24 = __toESM(require_helpers(), 1);
  var md030_default = {
    "names": ["MD030", "list-marker-space"],
    "description": "Spaces after list markers",
    "tags": ["ol", "ul", "whitespace"],
    "parser": "micromark",
    "function": function MD030(params2, onError) {
      const ulSingle = Number(params2.config.ul_single || 1);
      const olSingle = Number(params2.config.ol_single || 1);
      const ulMulti = Number(params2.config.ul_multi || 1);
      const olMulti = Number(params2.config.ol_multi || 1);
      for (const list2 of filterByTypesCached(["listOrdered", "listUnordered"])) {
        const ordered = list2.type === "listOrdered";
        const listItemPrefixes = list2.children.filter((token) => token.type === "listItemPrefix");
        const allSingleLine = list2.endLine - list2.startLine + 1 === listItemPrefixes.length;
        const expectedSpaces = ordered ? allSingleLine ? olSingle : olMulti : allSingleLine ? ulSingle : ulMulti;
        for (const listItemPrefix of listItemPrefixes) {
          const range = [
            listItemPrefix.startColumn,
            listItemPrefix.endColumn - listItemPrefix.startColumn
          ];
          const listItemPrefixWhitespaces = listItemPrefix.children.filter(
            (token) => token.type === "listItemPrefixWhitespace"
          );
          for (const listItemPrefixWhitespace of listItemPrefixWhitespaces) {
            const { endColumn, startColumn, startLine } = listItemPrefixWhitespace;
            const actualSpaces = endColumn - startColumn;
            const fixInfo = {
              "editColumn": startColumn,
              "deleteCount": actualSpaces,
              "insertText": "".padEnd(expectedSpaces)
            };
            (0, import_helpers24.addErrorDetailIf)(
              onError,
              startLine,
              expectedSpaces,
              actualSpaces,
              void 0,
              void 0,
              range,
              fixInfo
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md031.mjs
  var import_helpers25 = __toESM(require_helpers(), 1);
  var import_micromark_helpers19 = __toESM(require_micromark_helpers(), 1);
  var codeFencePrefixRe = /^(.*?)[`~]/;
  function addError7(onError, lines, lineNumber, top) {
    const line = lines[lineNumber - 1];
    const [, prefix] = line.match(codeFencePrefixRe) || [];
    const fixInfo = prefix === void 0 ? void 0 : {
      "lineNumber": lineNumber + (top ? 0 : 1),
      "insertText": `${prefix.replace(/[^>]/g, " ").trim()}
`
    };
    (0, import_helpers25.addErrorContext)(
      onError,
      lineNumber,
      line.trim(),
      void 0,
      void 0,
      void 0,
      fixInfo
    );
  }
  var md031_default = {
    "names": ["MD031", "blanks-around-fences"],
    "description": "Fenced code blocks should be surrounded by blank lines",
    "tags": ["code", "blank_lines"],
    "parser": "micromark",
    "function": function MD031(params2, onError) {
      const listItems = params2.config.list_items;
      const includeListItems = listItems === void 0 ? true : !!listItems;
      const { lines } = params2;
      for (const codeBlock of filterByTypesCached(["codeFenced"])) {
        if (includeListItems || !(0, import_micromark_helpers19.getParentOfType)(codeBlock, ["listOrdered", "listUnordered"])) {
          if (!(0, import_helpers25.isBlankLine)(lines[codeBlock.startLine - 2])) {
            addError7(onError, lines, codeBlock.startLine, true);
          }
          if (!(0, import_helpers25.isBlankLine)(lines[codeBlock.endLine]) && !(0, import_helpers25.isBlankLine)(lines[codeBlock.endLine - 1])) {
            addError7(onError, lines, codeBlock.endLine, false);
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md032.mjs
  var import_helpers26 = __toESM(require_helpers(), 1);
  var import_micromark_helpers20 = __toESM(require_micromark_helpers(), 1);
  var isList = (token) => token.type === "listOrdered" || token.type === "listUnordered";
  var md032_default = {
    "names": ["MD032", "blanks-around-lists"],
    "description": "Lists should be surrounded by blank lines",
    "tags": ["bullet", "ul", "ol", "blank_lines"],
    "parser": "micromark",
    "function": function MD032(params2, onError) {
      const { lines, parsers } = params2;
      const blockQuotePrefixes = filterByTypesCached(["blockQuotePrefix", "linePrefix"]);
      const topLevelLists = (0, import_micromark_helpers20.filterByPredicate)(
        parsers.micromark.tokens,
        isList,
        (token) => isList(token) || token.type === "htmlFlow" ? [] : token.children
      );
      for (const list2 of topLevelLists) {
        const firstLineNumber = list2.startLine;
        if (!(0, import_helpers26.isBlankLine)(lines[firstLineNumber - 2])) {
          (0, import_helpers26.addErrorContext)(
            onError,
            firstLineNumber,
            lines[firstLineNumber - 1].trim(),
            void 0,
            void 0,
            void 0,
            {
              "insertText": (0, import_micromark_helpers20.getBlockQuotePrefixText)(blockQuotePrefixes, firstLineNumber)
            }
          );
        }
        const flattenedChildren = (0, import_micromark_helpers20.filterByPredicate)(
          list2.children,
          (token) => !import_micromark_helpers20.nonContentTokens.has(token.type),
          (token) => import_micromark_helpers20.nonContentTokens.has(token.type) ? [] : token.children
        );
        let endLine = list2.endLine;
        if (flattenedChildren.length > 0) {
          endLine = flattenedChildren[flattenedChildren.length - 1].endLine;
        }
        const lastLineNumber = endLine;
        if (!(0, import_helpers26.isBlankLine)(lines[lastLineNumber])) {
          (0, import_helpers26.addErrorContext)(
            onError,
            lastLineNumber,
            lines[lastLineNumber - 1].trim(),
            void 0,
            void 0,
            void 0,
            {
              "lineNumber": lastLineNumber + 1,
              "insertText": (0, import_micromark_helpers20.getBlockQuotePrefixText)(blockQuotePrefixes, lastLineNumber)
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md033.mjs
  var import_helpers27 = __toESM(require_helpers(), 1);
  var import_micromark_helpers21 = __toESM(require_micromark_helpers(), 1);
  var toLowerCaseStringArray = (arr) => Array.isArray(arr) ? arr.map((elm) => String(elm).toLowerCase()) : [];
  var md033_default = {
    "names": ["MD033", "no-inline-html"],
    "description": "Inline HTML",
    "tags": ["html"],
    "parser": "micromark",
    "function": function MD033(params2, onError) {
      const allowedElements = toLowerCaseStringArray(params2.config.allowed_elements);
      const tableAllowedElements = toLowerCaseStringArray(params2.config.table_allowed_elements || params2.config.allowed_elements);
      for (const token of filterByTypesCached(["htmlText"], true)) {
        const htmlTagInfo = (0, import_micromark_helpers21.getHtmlTagInfo)(token);
        if (htmlTagInfo && !htmlTagInfo.close) {
          const elementName = htmlTagInfo?.name.toLowerCase();
          const inTable = !!(0, import_micromark_helpers21.getParentOfType)(token, ["table"]);
          if ((inTable || !allowedElements.includes(elementName)) && (!inTable || !tableAllowedElements.includes(elementName))) {
            const range = [
              token.startColumn,
              token.text.replace(import_helpers27.nextLinesRe, "").length
            ];
            (0, import_helpers27.addError)(
              onError,
              token.startLine,
              "Element: " + htmlTagInfo.name,
              void 0,
              range
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md034.mjs
  var import_helpers28 = __toESM(require_helpers(), 1);
  var import_micromark_helpers22 = __toESM(require_micromark_helpers(), 1);
  var md034_default = {
    "names": ["MD034", "no-bare-urls"],
    "description": "Bare URL used",
    "tags": ["links", "url"],
    "parser": "micromark",
    "function": function MD034(params2, onError) {
      const literalAutolinks = (tokens) => (0, import_micromark_helpers22.filterByPredicate)(
        tokens,
        (token) => {
          if (token.type === "literalAutolink" && !(0, import_micromark_helpers22.inHtmlFlow)(token)) {
            const siblings = token.parent?.children;
            const index = siblings?.indexOf(token);
            const prev = siblings?.at(index - 1);
            const next = siblings?.at(index + 1);
            return !(prev && next && prev.type === "data" && next.type === "data" && prev.text.endsWith("<") && next.text.startsWith(">"));
          }
          return false;
        },
        (token) => {
          const { children } = token;
          const result = [];
          for (let i = 0; i < children.length; i++) {
            const current = children[i];
            const openTagInfo = (0, import_micromark_helpers22.getHtmlTagInfo)(current);
            if (openTagInfo && !openTagInfo.close) {
              let count = 1;
              for (let j = i + 1; j < children.length; j++) {
                const candidate = children[j];
                const closeTagInfo = (0, import_micromark_helpers22.getHtmlTagInfo)(candidate);
                if (closeTagInfo && openTagInfo.name === closeTagInfo.name) {
                  if (closeTagInfo.close) {
                    count--;
                    if (count === 0) {
                      i = j;
                      break;
                    }
                  } else {
                    count++;
                  }
                }
              }
            } else {
              result.push(current);
            }
          }
          return result;
        }
      );
      for (const token of literalAutolinks(params2.parsers.micromark.tokens)) {
        const range = [
          token.startColumn,
          token.endColumn - token.startColumn
        ];
        const fixInfo = {
          "editColumn": range[0],
          "deleteCount": range[1],
          "insertText": `<${token.text}>`
        };
        (0, import_helpers28.addErrorContext)(
          onError,
          token.startLine,
          token.text,
          void 0,
          void 0,
          range,
          fixInfo
        );
      }
    }
  };

  // node_modules/markdownlint/lib/md035.mjs
  var import_helpers29 = __toESM(require_helpers(), 1);
  var md035_default = {
    "names": ["MD035", "hr-style"],
    "description": "Horizontal rule style",
    "tags": ["hr"],
    "parser": "micromark",
    "function": function MD035(params2, onError) {
      let style = String(params2.config.style || "consistent").trim();
      const thematicBreaks = filterByTypesCached(["thematicBreak"]);
      for (const token of thematicBreaks) {
        const { startLine, text: text4 } = token;
        if (style === "consistent") {
          style = text4;
        }
        (0, import_helpers29.addErrorDetailIf)(onError, startLine, style, text4);
      }
    }
  };

  // node_modules/markdownlint/lib/md036.mjs
  var import_helpers30 = __toESM(require_helpers(), 1);
  var import_micromark_helpers23 = __toESM(require_micromark_helpers(), 1);
  var emphasisTypes = [
    ["emphasis", "emphasisText"],
    ["strong", "strongText"]
  ];
  var isParagraphChildMeaningful = (token) => !(token.type === "htmlText" || token.type === "data" && token.text.trim().length === 0);
  var md036_default = {
    "names": ["MD036", "no-emphasis-as-heading"],
    "description": "Emphasis used instead of a heading",
    "tags": ["headings", "emphasis"],
    "parser": "micromark",
    "function": function MD036(params2, onError) {
      let punctuation = params2.config.punctuation;
      punctuation = String(punctuation === void 0 ? import_helpers30.allPunctuation : punctuation);
      const punctuationRe = new RegExp("[" + punctuation + "]$");
      const paragraphTokens = filterByTypesCached(["paragraph"], true).filter(
        (token) => token.parent?.type === "content" && (!token.parent?.parent || token.parent?.parent?.type === "htmlFlow" && !token.parent?.parent?.parent) && token.children.filter(isParagraphChildMeaningful).length === 1
      );
      for (const emphasisType of emphasisTypes) {
        const textTokens = (0, import_micromark_helpers23.getDescendantsByType)(paragraphTokens, emphasisType);
        for (const textToken of textTokens) {
          if (textToken.children.length === 1 && // eslint-disable-next-line unicorn/better-dom-traversing
          textToken.children[0].type === "data" && !punctuationRe.test(textToken.text)) {
            (0, import_helpers30.addErrorContext)(onError, textToken.startLine, textToken.text);
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md037.mjs
  var import_helpers31 = __toESM(require_helpers(), 1);
  var import_micromark_helpers24 = __toESM(require_micromark_helpers(), 1);
  var md037_default = {
    "names": ["MD037", "no-space-in-emphasis"],
    "description": "Spaces inside emphasis markers",
    "tags": ["whitespace", "emphasis"],
    "parser": "micromark",
    "function": function MD037(params2, onError) {
      const { lines, parsers } = params2;
      const emphasisTokensByMarker = /* @__PURE__ */ new Map();
      for (const marker of ["_", "__", "___", "*", "**", "***"]) {
        emphasisTokensByMarker.set(marker, []);
      }
      const tokens = (0, import_micromark_helpers24.filterByPredicate)(
        parsers.micromark.tokens,
        (token) => token.children.some((child) => child.type === "data")
      );
      for (const token of tokens) {
        for (const emphasisTokens of emphasisTokensByMarker.values()) {
          emphasisTokens.length = 0;
        }
        for (const child of token.children) {
          const { text: text4, type } = child;
          if (type === "data" && text4.length <= 3) {
            const emphasisTokens = emphasisTokensByMarker.get(text4);
            if (emphasisTokens && !(0, import_micromark_helpers24.inHtmlFlow)(child)) {
              emphasisTokens.push(child);
            }
          }
        }
        for (const entry of emphasisTokensByMarker.entries()) {
          const [marker, emphasisTokens] = entry;
          for (let i = 0; i + 1 < emphasisTokens.length; i += 2) {
            const startToken = emphasisTokens[i];
            const startLine = lines[startToken.startLine - 1];
            const startSlice = startLine.slice(startToken.endColumn - 1);
            const startMatch = startSlice.match(/^\s+\S/);
            if (startMatch) {
              const [startSpaceCharacter] = startMatch;
              const startContext = `${marker}${startSpaceCharacter}`;
              const column = startToken.endColumn;
              const count = startSpaceCharacter.length - 1;
              (0, import_helpers31.addError)(
                onError,
                startToken.startLine,
                void 0,
                startContext,
                [column, count],
                {
                  "editColumn": column,
                  "deleteCount": count
                }
              );
            }
            const endToken = emphasisTokens[i + 1];
            const endLine = lines[endToken.startLine - 1];
            const endSlice = endLine.slice(0, endToken.startColumn - 1);
            const endMatch = endSlice.match(/\S\s+$/);
            if (endMatch) {
              const [endSpaceCharacter] = endMatch;
              const endContext = `${endSpaceCharacter}${marker}`;
              const column = endToken.startColumn - (endSpaceCharacter.length - 1);
              const count = endSpaceCharacter.length - 1;
              (0, import_helpers31.addError)(
                onError,
                endToken.startLine,
                void 0,
                endContext,
                [column, count],
                {
                  "editColumn": column,
                  "deleteCount": count
                }
              );
            }
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md038.mjs
  var import_helpers32 = __toESM(require_helpers(), 1);
  var import_micromark_helpers25 = __toESM(require_micromark_helpers(), 1);
  var md038_default = {
    "names": ["MD038", "no-space-in-code"],
    "description": "Spaces inside code span elements",
    "tags": ["whitespace", "code"],
    "parser": "micromark",
    "function": function MD038(params2, onError) {
      const codeTexts = filterByTypesCached(["codeText"]);
      for (const codeText2 of codeTexts) {
        const datas = (0, import_micromark_helpers25.getDescendantsByType)(codeText2, ["codeTextData"]);
        if (datas.length > 0) {
          const paddings = (0, import_micromark_helpers25.getDescendantsByType)(codeText2, ["codeTextPadding"]);
          const startPadding = paddings[0];
          const startData = datas[0];
          const startMatch = /^(\s+)(\S)/.exec(startData.text) || [null, "", ""];
          const startBacktick = startMatch[2] === "`";
          const startCount = startMatch[1].length - (startBacktick && !startPadding ? 1 : 0);
          const startSpaces = startCount > 0;
          const endPadding = paddings[paddings.length - 1];
          const endData = datas[datas.length - 1];
          const endMatch = /(\S)(\s+)$/.exec(endData.text) || [null, "", ""];
          const endBacktick = endMatch[1] === "`";
          const endCount = endMatch[2].length - (endBacktick && !endPadding ? 1 : 0);
          const endSpaces = endCount > 0;
          const removePadding = startSpaces && endSpaces && startPadding && endPadding && !startBacktick && !endBacktick;
          const context = codeText2.text;
          if (startSpaces) {
            const startColumn = (removePadding ? startPadding : startData).startColumn;
            const length = startCount + (removePadding ? startPadding.text.length : 0);
            (0, import_helpers32.addErrorContext)(
              onError,
              startData.startLine,
              context,
              true,
              false,
              [startColumn, length],
              {
                "editColumn": startColumn,
                "deleteCount": length
              }
            );
          }
          if (endSpaces) {
            const endColumn = (removePadding ? endPadding : endData).endColumn;
            const length = endCount + (removePadding ? endPadding.text.length : 0);
            (0, import_helpers32.addErrorContext)(
              onError,
              endData.endLine,
              context,
              false,
              true,
              [endColumn - length, length],
              {
                "editColumn": endColumn - length,
                "deleteCount": length
              }
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md039.mjs
  var import_helpers33 = __toESM(require_helpers(), 1);
  function addLabelSpaceError(onError, label4, labelText, isStart) {
    const match = labelText.text.match(isStart ? /^[^\S\r\n]+/ : /[^\S\r\n]+$/);
    const range = match ? [
      isStart ? labelText.startColumn : labelText.endColumn - match[0].length,
      match[0].length
    ] : void 0;
    (0, import_helpers33.addErrorContext)(
      onError,
      isStart ? labelText.startLine + (match ? 0 : 1) : labelText.endLine - (match ? 0 : 1),
      label4.text.replace(/\s+/g, " "),
      isStart,
      !isStart,
      range,
      range ? {
        "editColumn": range[0],
        "deleteCount": range[1]
      } : void 0
    );
  }
  var md039_default = {
    "names": ["MD039", "no-space-in-links"],
    "description": "Spaces inside link text",
    "tags": ["whitespace", "links"],
    "parser": "micromark",
    "function": function MD039(params2, onError) {
      const labels = filterByTypesCached(["label"]).filter((label4) => label4.parent?.type === "link");
      for (const label4 of labels) {
        const labelTexts = label4.children.filter((child) => child.type === "labelText");
        for (const labelText of labelTexts) {
          if (labelText.text.trimStart().length !== labelText.text.length) {
            addLabelSpaceError(onError, label4, labelText, true);
          }
          if (labelText.text.trimEnd().length !== labelText.text.length) {
            addLabelSpaceError(onError, label4, labelText, false);
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md040.mjs
  var import_helpers34 = __toESM(require_helpers(), 1);
  var import_micromark_helpers26 = __toESM(require_micromark_helpers(), 1);
  var md040_default = {
    "names": ["MD040", "fenced-code-language"],
    "description": "Fenced code blocks should have a language specified",
    "tags": ["code", "language"],
    "parser": "micromark",
    "function": function MD040(params2, onError) {
      let allowed = params2.config.allowed_languages;
      allowed = Array.isArray(allowed) ? allowed : [];
      const languageOnly = !!params2.config.language_only;
      const fencedCodes = filterByTypesCached(["codeFenced"]);
      for (const fencedCode of fencedCodes) {
        const openingFence = (0, import_micromark_helpers26.getDescendantsByType)(fencedCode, ["codeFencedFence"])[0];
        const { startLine, text: text4 } = openingFence;
        const info = (0, import_micromark_helpers26.getDescendantsByType)(openingFence, ["codeFencedFenceInfo"])[0]?.text;
        if (!info) {
          (0, import_helpers34.addErrorContext)(onError, startLine, text4);
        } else if (allowed.length > 0 && !allowed.includes(info)) {
          (0, import_helpers34.addError)(onError, startLine, `"${info}" is not allowed`);
        }
        if (languageOnly && (0, import_micromark_helpers26.getDescendantsByType)(openingFence, ["codeFencedFenceMeta"]).length > 0) {
          (0, import_helpers34.addError)(onError, startLine, `Info string contains more than language: "${text4}"`);
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md041.mjs
  var import_helpers35 = __toESM(require_helpers(), 1);
  var import_micromark_helpers27 = __toESM(require_micromark_helpers(), 1);
  var headingTagNameRe = /^h[1-6]$/;
  function getHtmlFlowTagName(token) {
    const { children, type } = token;
    if (type === "htmlFlow") {
      const htmlTexts = (0, import_micromark_helpers27.filterByTypes)(children, ["htmlText"], true);
      const tagInfo = htmlTexts.length > 0 && (0, import_micromark_helpers27.getHtmlTagInfo)(htmlTexts[0]);
      if (tagInfo) {
        return tagInfo.name.toLowerCase();
      }
    }
    return null;
  }
  var md041_default = {
    "names": ["MD041", "first-line-heading", "first-line-h1"],
    "description": "First line in a file should be a top-level heading",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD041(params2, onError) {
      const allowPreamble = !!params2.config.allow_preamble;
      const level = Number(params2.config.level || 1);
      const { tokens } = params2.parsers.micromark;
      if (!(0, import_helpers35.frontMatterHasTitle)(
        params2.frontMatterLines,
        params2.config.front_matter_title
      )) {
        let errorLineNumber = 0;
        for (const token of tokens) {
          const { startLine, type } = token;
          if (!import_micromark_helpers27.nonContentTokens.has(type) && !(0, import_micromark_helpers27.isHtmlFlowComment)(token)) {
            let tagName = null;
            if (type === "atxHeading" || type === "setextHeading") {
              if ((0, import_micromark_helpers27.getHeadingLevel)(token) !== level) {
                errorLineNumber = startLine;
              }
              break;
            } else if ((tagName = getHtmlFlowTagName(token)) && headingTagNameRe.test(tagName)) {
              if (tagName !== `h${level}`) {
                errorLineNumber = startLine;
              }
              break;
            } else if (!allowPreamble) {
              errorLineNumber = startLine;
              break;
            }
          }
        }
        if (errorLineNumber > 0) {
          (0, import_helpers35.addErrorContext)(onError, errorLineNumber, params2.lines[errorLineNumber - 1]);
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md042.mjs
  var import_helpers36 = __toESM(require_helpers(), 1);
  var import_micromark_helpers28 = __toESM(require_micromark_helpers(), 1);
  var md042_default = {
    "names": ["MD042", "no-empty-links"],
    "description": "No empty links",
    "tags": ["links"],
    "parser": "micromark",
    "function": function MD042(params2, onError) {
      const { definitions } = getReferenceLinkImageData();
      const isReferenceDefinitionHash = (token) => {
        const definition2 = definitions.get(token.text.trim());
        return Boolean(definition2 && definition2[1] === "#");
      };
      const links = filterByTypesCached(["link"]);
      for (const link of links) {
        const labelText = (0, import_micromark_helpers28.getDescendantsByType)(link, ["label", "labelText"]);
        const reference = (0, import_micromark_helpers28.getDescendantsByType)(link, ["reference"]);
        const resource = (0, import_micromark_helpers28.getDescendantsByType)(link, ["resource"]);
        const referenceString = (0, import_micromark_helpers28.getDescendantsByType)(reference, ["referenceString"]);
        const resourceDestinationString = (0, import_micromark_helpers28.getDescendantsByType)(resource, ["resourceDestination", ["resourceDestinationLiteral", "resourceDestinationRaw"], "resourceDestinationString"]);
        const hasLabelText = labelText.length > 0;
        const hasReference = reference.length > 0;
        const hasResource = resource.length > 0;
        const hasReferenceString = referenceString.length > 0;
        const hasResourceDestinationString = resourceDestinationString.length > 0;
        let error = false;
        if (hasLabelText && (!hasReference && !hasResource || hasReference && !hasReferenceString)) {
          error = isReferenceDefinitionHash(labelText[0]);
        } else if (hasReferenceString && !hasResourceDestinationString) {
          error = isReferenceDefinitionHash(referenceString[0]);
        } else if (!hasReferenceString && hasResourceDestinationString) {
          error = resourceDestinationString[0].text.trim() === "#";
        } else if (!hasReferenceString && !hasResourceDestinationString) {
          error = true;
        }
        if (error) {
          (0, import_helpers36.addErrorContext)(
            onError,
            link.startLine,
            link.text,
            void 0,
            void 0,
            [link.startColumn, link.endColumn - link.startColumn]
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md043.mjs
  var import_helpers37 = __toESM(require_helpers(), 1);
  var import_micromark_helpers29 = __toESM(require_micromark_helpers(), 1);
  var md043_default = {
    "names": ["MD043", "required-headings"],
    "description": "Required heading structure",
    "tags": ["headings"],
    "parser": "micromark",
    "function": function MD043(params2, onError) {
      const requiredHeadings = params2.config.headings;
      if (!Array.isArray(requiredHeadings)) {
        return;
      }
      const matchCase = params2.config.match_case || false;
      let i = 0;
      let matchAny = false;
      let hasError = false;
      let anyHeadings = false;
      const getExpected = () => String(requiredHeadings[i++] || "[None]");
      const handleCase = (str) => matchCase ? str : str.toLowerCase();
      for (const heading of filterByTypesCached(["atxHeading", "setextHeading"])) {
        if (!hasError) {
          const headingText = (0, import_micromark_helpers29.getHeadingText)(heading);
          const headingLevel = (0, import_micromark_helpers29.getHeadingLevel)(heading);
          anyHeadings = true;
          const actual = `${"".padEnd(headingLevel, "#")} ${headingText}`;
          const expected = getExpected();
          if (expected === "*") {
            const nextExpected = getExpected();
            if (handleCase(nextExpected) !== handleCase(actual)) {
              matchAny = true;
              i--;
            }
          } else if (expected === "+") {
            matchAny = true;
          } else if (expected === "?") {
          } else if (handleCase(expected) === handleCase(actual)) {
            matchAny = false;
          } else if (matchAny) {
            i--;
          } else {
            (0, import_helpers37.addErrorDetailIf)(
              onError,
              heading.startLine,
              expected,
              actual
            );
            hasError = true;
          }
        }
      }
      const extraHeadings = requiredHeadings.length - i;
      if (!hasError && (extraHeadings > 1 || extraHeadings === 1 && requiredHeadings[i] !== "*") && (anyHeadings || !requiredHeadings.every((heading) => heading === "*"))) {
        (0, import_helpers37.addErrorContext)(
          onError,
          params2.lines.length,
          requiredHeadings[i]
        );
      }
    }
  };

  // node_modules/markdownlint/lib/md044.mjs
  var import_helpers38 = __toESM(require_helpers(), 1);
  var import_micromark_helpers31 = __toESM(require_micromark_helpers(), 1);

  // node_modules/micromark-util-character/index.js
  var asciiAlpha = regexCheck(/[A-Za-z]/);
  var asciiAlphanumeric = regexCheck(/[\dA-Za-z]/);
  var asciiAtext = regexCheck(/[#-'*+\--9=?A-Z^-~]/);
  function asciiControl(code2) {
    return (
      // Special whitespace codes (which have negative values), C0 and Control
      // character DEL
      code2 !== null && (code2 < 32 || code2 === 127)
    );
  }
  var asciiDigit = regexCheck(/\d/);
  var asciiHexDigit = regexCheck(/[\dA-Fa-f]/);
  var asciiPunctuation = regexCheck(/[!-/:-@[-`{-~]/);
  function markdownLineEnding(code2) {
    return code2 !== null && code2 < -2;
  }
  function markdownLineEndingOrSpace(code2) {
    return code2 !== null && (code2 < 0 || code2 === 32);
  }
  function markdownSpace(code2) {
    return code2 === -2 || code2 === -1 || code2 === 32;
  }
  var unicodePunctuation = regexCheck(/\p{P}|\p{S}/u);
  var unicodeWhitespace = regexCheck(/\s/);
  function regexCheck(regex2) {
    return check;
    function check(code2) {
      return code2 !== null && code2 > -1 && regex2.test(String.fromCharCode(code2));
    }
  }

  // node_modules/micromark-factory-space/index.js
  function factorySpace(effects, ok, type, max) {
    const limit = max ? max - 1 : Number.POSITIVE_INFINITY;
    let size = 0;
    return start;
    function start(code2) {
      if (markdownSpace(code2)) {
        effects.enter(type);
        return prefix(code2);
      }
      return ok(code2);
    }
    function prefix(code2) {
      if (markdownSpace(code2) && size++ < limit) {
        effects.consume(code2);
        return prefix;
      }
      effects.exit(type);
      return ok(code2);
    }
  }

  // node_modules/micromark-factory-whitespace/index.js
  function factoryWhitespace(effects, ok) {
    let seen;
    return start;
    function start(code2) {
      if (markdownLineEnding(code2)) {
        effects.enter("lineEnding");
        effects.consume(code2);
        effects.exit("lineEnding");
        seen = true;
        return start;
      }
      if (markdownSpace(code2)) {
        return factorySpace(effects, start, seen ? "linePrefix" : "lineSuffix")(code2);
      }
      return ok(code2);
    }
  }

  // node_modules/micromark-extension-directive/lib/factory-attributes.js
  function factoryAttributes(effects, ok, nok, attributesType, attributesMarkerType, attributeType, attributeIdType, attributeClassType, attributeNameType, attributeInitializerType, attributeValueLiteralType, attributeValueType, attributeValueMarker, attributeValueData, disallowEol) {
    let type;
    let marker;
    return start;
    function start(code2) {
      effects.enter(attributesType);
      effects.enter(attributesMarkerType);
      effects.consume(code2);
      effects.exit(attributesMarkerType);
      return between;
    }
    function between(code2) {
      if (code2 === 35) {
        type = attributeIdType;
        return shortcutStart(code2);
      }
      if (code2 === 46) {
        type = attributeClassType;
        return shortcutStart(code2);
      }
      if (disallowEol && markdownSpace(code2)) {
        return factorySpace(effects, between, "whitespace")(code2);
      }
      if (!disallowEol && markdownLineEndingOrSpace(code2)) {
        return factoryWhitespace(effects, between)(code2);
      }
      if (code2 === null || markdownLineEnding(code2) || unicodeWhitespace(code2) || unicodePunctuation(code2) && code2 !== 45 && code2 !== 95) {
        return end(code2);
      }
      effects.enter(attributeType);
      effects.enter(attributeNameType);
      effects.consume(code2);
      return name;
    }
    function shortcutStart(code2) {
      const markerType = (
        /** @type {TokenType} */
        type + "Marker"
      );
      effects.enter(attributeType);
      effects.enter(type);
      effects.enter(markerType);
      effects.consume(code2);
      effects.exit(markerType);
      return shortcutStartAfter;
    }
    function shortcutStartAfter(code2) {
      if (code2 === null || code2 === 34 || code2 === 35 || code2 === 39 || code2 === 46 || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96 || code2 === 125 || markdownLineEndingOrSpace(code2)) {
        return nok(code2);
      }
      const valueType = (
        /** @type {TokenType} */
        type + "Value"
      );
      effects.enter(valueType);
      effects.consume(code2);
      return shortcut;
    }
    function shortcut(code2) {
      if (code2 === null || code2 === 34 || code2 === 39 || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96) {
        return nok(code2);
      }
      if (code2 === 35 || code2 === 46 || code2 === 125 || markdownLineEndingOrSpace(code2)) {
        const valueType = (
          /** @type {TokenType} */
          type + "Value"
        );
        effects.exit(valueType);
        effects.exit(type);
        effects.exit(attributeType);
        return between(code2);
      }
      effects.consume(code2);
      return shortcut;
    }
    function name(code2) {
      if (code2 === null || markdownLineEnding(code2) || unicodeWhitespace(code2) || unicodePunctuation(code2) && code2 !== 45 && code2 !== 46 && code2 !== 58 && code2 !== 95) {
        effects.exit(attributeNameType);
        if (disallowEol && markdownSpace(code2)) {
          return factorySpace(effects, nameAfter, "whitespace")(code2);
        }
        if (!disallowEol && markdownLineEndingOrSpace(code2)) {
          return factoryWhitespace(effects, nameAfter)(code2);
        }
        return nameAfter(code2);
      }
      effects.consume(code2);
      return name;
    }
    function nameAfter(code2) {
      if (code2 === 61) {
        effects.enter(attributeInitializerType);
        effects.consume(code2);
        effects.exit(attributeInitializerType);
        return valueBefore;
      }
      effects.exit(attributeType);
      return between(code2);
    }
    function valueBefore(code2) {
      if (code2 === null || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96 || code2 === 125 || disallowEol && markdownLineEnding(code2)) {
        return nok(code2);
      }
      if (code2 === 34 || code2 === 39) {
        effects.enter(attributeValueLiteralType);
        effects.enter(attributeValueMarker);
        effects.consume(code2);
        effects.exit(attributeValueMarker);
        marker = code2;
        return valueQuotedStart;
      }
      if (disallowEol && markdownSpace(code2)) {
        return factorySpace(effects, valueBefore, "whitespace")(code2);
      }
      if (!disallowEol && markdownLineEndingOrSpace(code2)) {
        return factoryWhitespace(effects, valueBefore)(code2);
      }
      effects.enter(attributeValueType);
      effects.enter(attributeValueData);
      effects.consume(code2);
      marker = void 0;
      return valueUnquoted;
    }
    function valueUnquoted(code2) {
      if (code2 === null || code2 === 34 || code2 === 39 || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96) {
        return nok(code2);
      }
      if (code2 === 125 || markdownLineEndingOrSpace(code2)) {
        effects.exit(attributeValueData);
        effects.exit(attributeValueType);
        effects.exit(attributeType);
        return between(code2);
      }
      effects.consume(code2);
      return valueUnquoted;
    }
    function valueQuotedStart(code2) {
      if (code2 === marker) {
        effects.enter(attributeValueMarker);
        effects.consume(code2);
        effects.exit(attributeValueMarker);
        effects.exit(attributeValueLiteralType);
        effects.exit(attributeType);
        return valueQuotedAfter;
      }
      effects.enter(attributeValueType);
      return valueQuotedBetween(code2);
    }
    function valueQuotedBetween(code2) {
      if (code2 === marker) {
        effects.exit(attributeValueType);
        return valueQuotedStart(code2);
      }
      if (code2 === null) {
        return nok(code2);
      }
      if (markdownLineEnding(code2)) {
        return disallowEol ? nok(code2) : factoryWhitespace(effects, valueQuotedBetween)(code2);
      }
      effects.enter(attributeValueData);
      effects.consume(code2);
      return valueQuoted;
    }
    function valueQuoted(code2) {
      if (code2 === marker || code2 === null || markdownLineEnding(code2)) {
        effects.exit(attributeValueData);
        return valueQuotedBetween(code2);
      }
      effects.consume(code2);
      return valueQuoted;
    }
    function valueQuotedAfter(code2) {
      return code2 === 125 || markdownLineEndingOrSpace(code2) ? between(code2) : end(code2);
    }
    function end(code2) {
      if (code2 === 125) {
        effects.enter(attributesMarkerType);
        effects.consume(code2);
        effects.exit(attributesMarkerType);
        effects.exit(attributesType);
        return ok;
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-extension-directive/lib/factory-label.js
  function factoryLabel(effects, ok, nok, type, markerType, stringType, disallowEol) {
    let size = 0;
    let balance = 0;
    let previous4;
    return start;
    function start(code2) {
      effects.enter(type);
      effects.enter(markerType);
      effects.consume(code2);
      effects.exit(markerType);
      return afterStart;
    }
    function afterStart(code2) {
      if (code2 === 93) {
        effects.enter(markerType);
        effects.consume(code2);
        effects.exit(markerType);
        effects.exit(type);
        return ok;
      }
      effects.enter(stringType);
      return lineStart(code2);
    }
    function lineStart(code2) {
      if (code2 === 93 && !balance) {
        return atClosingBrace(code2);
      }
      const token = effects.enter("chunkText", {
        _contentTypeTextTrailing: true,
        contentType: "text",
        previous: previous4
      });
      if (previous4) previous4.next = token;
      previous4 = token;
      return data(code2);
    }
    function data(code2) {
      if (code2 === null || size > 999) {
        return nok(code2);
      }
      if (code2 === 91 && ++balance > 32) {
        return nok(code2);
      }
      if (code2 === 93 && !balance--) {
        effects.exit("chunkText");
        return atClosingBrace(code2);
      }
      if (markdownLineEnding(code2)) {
        if (disallowEol) {
          return nok(code2);
        }
        effects.consume(code2);
        effects.exit("chunkText");
        return lineStart;
      }
      effects.consume(code2);
      return code2 === 92 ? dataEscape : data;
    }
    function dataEscape(code2) {
      if (code2 === 91 || code2 === 92 || code2 === 93) {
        effects.consume(code2);
        size++;
        return data;
      }
      return data(code2);
    }
    function atClosingBrace(code2) {
      effects.exit(stringType);
      effects.enter(markerType);
      effects.consume(code2);
      effects.exit(markerType);
      effects.exit(type);
      return ok;
    }
  }

  // node_modules/micromark-extension-directive/lib/factory-name.js
  function factoryName(effects, ok, nok, type) {
    const self = this;
    return start;
    function start(code2) {
      if (code2 === null || markdownLineEnding(code2) || unicodePunctuation(code2) || unicodeWhitespace(code2)) {
        return nok(code2);
      }
      effects.enter(type);
      effects.consume(code2);
      return name;
    }
    function name(code2) {
      if (code2 === null || markdownLineEnding(code2) || unicodeWhitespace(code2) || unicodePunctuation(code2) && code2 !== 45 && code2 !== 95) {
        effects.exit(type);
        return self.previous === 45 || self.previous === 95 ? nok(code2) : ok(code2);
      }
      effects.consume(code2);
      return name;
    }
  }

  // node_modules/micromark-extension-directive/lib/directive-container.js
  var directiveContainer = {
    tokenize: tokenizeDirectiveContainer,
    concrete: true
  };
  var label = {
    tokenize: tokenizeLabel,
    partial: true
  };
  var attributes = {
    tokenize: tokenizeAttributes,
    partial: true
  };
  var nonLazyLine = {
    tokenize: tokenizeNonLazyLine,
    partial: true
  };
  function tokenizeDirectiveContainer(effects, ok, nok) {
    const self = this;
    const tail = self.events[self.events.length - 1];
    const initialSize = tail && tail[1].type === "linePrefix" ? tail[2].sliceSerialize(tail[1], true).length : 0;
    let sizeOpen = 0;
    let previous4;
    return start;
    function start(code2) {
      effects.enter("directiveContainer");
      effects.enter("directiveContainerFence");
      effects.enter("directiveContainerSequence");
      return sequenceOpen(code2);
    }
    function sequenceOpen(code2) {
      if (code2 === 58) {
        effects.consume(code2);
        sizeOpen++;
        return sequenceOpen;
      }
      if (sizeOpen < 3) {
        return nok(code2);
      }
      effects.exit("directiveContainerSequence");
      return factoryName.call(self, effects, afterName, nok, "directiveContainerName")(code2);
    }
    function afterName(code2) {
      return code2 === 91 ? effects.attempt(label, afterLabel, afterLabel)(code2) : afterLabel(code2);
    }
    function afterLabel(code2) {
      return code2 === 123 ? effects.attempt(attributes, afterAttributes, afterAttributes)(code2) : afterAttributes(code2);
    }
    function afterAttributes(code2) {
      return factorySpace(effects, openAfter, "whitespace")(code2);
    }
    function openAfter(code2) {
      effects.exit("directiveContainerFence");
      if (code2 === null) {
        return after(code2);
      }
      if (markdownLineEnding(code2)) {
        if (self.interrupt) {
          return ok(code2);
        }
        return effects.attempt(nonLazyLine, contentStart, after)(code2);
      }
      return nok(code2);
    }
    function contentStart(code2) {
      if (code2 === null) {
        return after(code2);
      }
      if (markdownLineEnding(code2)) {
        return effects.check(nonLazyLine, emptyContentNonLazyLineAfter, after)(code2);
      }
      effects.enter("directiveContainerContent");
      return lineStart(code2);
    }
    function lineStart(code2) {
      return effects.attempt({
        tokenize: tokenizeClosingFence,
        partial: true
      }, afterContent, initialSize ? factorySpace(effects, chunkStart, "linePrefix", initialSize + 1) : chunkStart)(code2);
    }
    function chunkStart(code2) {
      if (code2 === null) {
        return afterContent(code2);
      }
      if (markdownLineEnding(code2)) {
        return effects.check(nonLazyLine, chunkNonLazyStart, afterContent)(code2);
      }
      return chunkNonLazyStart(code2);
    }
    function contentContinue(code2) {
      if (code2 === null) {
        const t = effects.exit("chunkDocument");
        self.parser.lazy[t.start.line] = false;
        return afterContent(code2);
      }
      if (markdownLineEnding(code2)) {
        return effects.check(nonLazyLine, nonLazyLineAfter, lineAfter)(code2);
      }
      effects.consume(code2);
      return contentContinue;
    }
    function chunkNonLazyStart(code2) {
      const token = effects.enter("chunkDocument", {
        contentType: "document",
        previous: previous4
      });
      if (previous4) previous4.next = token;
      previous4 = token;
      return contentContinue(code2);
    }
    function emptyContentNonLazyLineAfter(code2) {
      effects.enter("directiveContainerContent");
      return lineStart(code2);
    }
    function nonLazyLineAfter(code2) {
      effects.consume(code2);
      const t = effects.exit("chunkDocument");
      self.parser.lazy[t.start.line] = false;
      return lineStart;
    }
    function lineAfter(code2) {
      const t = effects.exit("chunkDocument");
      self.parser.lazy[t.start.line] = false;
      return afterContent(code2);
    }
    function afterContent(code2) {
      effects.exit("directiveContainerContent");
      return after(code2);
    }
    function after(code2) {
      effects.exit("directiveContainer");
      return ok(code2);
    }
    function tokenizeClosingFence(effects2, ok2, nok2) {
      let size = 0;
      return factorySpace(effects2, closingPrefixAfter, "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4);
      function closingPrefixAfter(code2) {
        effects2.enter("directiveContainerFence");
        effects2.enter("directiveContainerSequence");
        return closingSequence(code2);
      }
      function closingSequence(code2) {
        if (code2 === 58) {
          effects2.consume(code2);
          size++;
          return closingSequence;
        }
        if (size < sizeOpen) return nok2(code2);
        effects2.exit("directiveContainerSequence");
        return factorySpace(effects2, closingSequenceEnd, "whitespace")(code2);
      }
      function closingSequenceEnd(code2) {
        if (code2 === null || markdownLineEnding(code2)) {
          effects2.exit("directiveContainerFence");
          return ok2(code2);
        }
        return nok2(code2);
      }
    }
  }
  function tokenizeLabel(effects, ok, nok) {
    return factoryLabel(effects, ok, nok, "directiveContainerLabel", "directiveContainerLabelMarker", "directiveContainerLabelString", true);
  }
  function tokenizeAttributes(effects, ok, nok) {
    return factoryAttributes(effects, ok, nok, "directiveContainerAttributes", "directiveContainerAttributesMarker", "directiveContainerAttribute", "directiveContainerAttributeId", "directiveContainerAttributeClass", "directiveContainerAttributeName", "directiveContainerAttributeInitializerMarker", "directiveContainerAttributeValueLiteral", "directiveContainerAttributeValue", "directiveContainerAttributeValueMarker", "directiveContainerAttributeValueData", true);
  }
  function tokenizeNonLazyLine(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return lineStart;
    }
    function lineStart(code2) {
      return self.parser.lazy[self.now().line] ? nok(code2) : ok(code2);
    }
  }

  // node_modules/micromark-extension-directive/lib/directive-leaf.js
  var directiveLeaf = {
    tokenize: tokenizeDirectiveLeaf
  };
  var label2 = {
    tokenize: tokenizeLabel2,
    partial: true
  };
  var attributes2 = {
    tokenize: tokenizeAttributes2,
    partial: true
  };
  function tokenizeDirectiveLeaf(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      effects.enter("directiveLeaf");
      effects.enter("directiveLeafSequence");
      effects.consume(code2);
      return inStart;
    }
    function inStart(code2) {
      if (code2 === 58) {
        effects.consume(code2);
        effects.exit("directiveLeafSequence");
        return factoryName.call(self, effects, afterName, nok, "directiveLeafName");
      }
      return nok(code2);
    }
    function afterName(code2) {
      return code2 === 91 ? effects.attempt(label2, afterLabel, afterLabel)(code2) : afterLabel(code2);
    }
    function afterLabel(code2) {
      return code2 === 123 ? effects.attempt(attributes2, afterAttributes, afterAttributes)(code2) : afterAttributes(code2);
    }
    function afterAttributes(code2) {
      return factorySpace(effects, end, "whitespace")(code2);
    }
    function end(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("directiveLeaf");
        return ok(code2);
      }
      return nok(code2);
    }
  }
  function tokenizeLabel2(effects, ok, nok) {
    return factoryLabel(effects, ok, nok, "directiveLeafLabel", "directiveLeafLabelMarker", "directiveLeafLabelString", true);
  }
  function tokenizeAttributes2(effects, ok, nok) {
    return factoryAttributes(effects, ok, nok, "directiveLeafAttributes", "directiveLeafAttributesMarker", "directiveLeafAttribute", "directiveLeafAttributeId", "directiveLeafAttributeClass", "directiveLeafAttributeName", "directiveLeafAttributeInitializerMarker", "directiveLeafAttributeValueLiteral", "directiveLeafAttributeValue", "directiveLeafAttributeValueMarker", "directiveLeafAttributeValueData", true);
  }

  // node_modules/micromark-extension-directive/lib/directive-text.js
  var directiveText = {
    tokenize: tokenizeDirectiveText,
    previous
  };
  var label3 = {
    tokenize: tokenizeLabel3,
    partial: true
  };
  var attributes3 = {
    tokenize: tokenizeAttributes3,
    partial: true
  };
  function previous(code2) {
    return code2 !== 58 || this.events[this.events.length - 1][1].type === "characterEscape";
  }
  function tokenizeDirectiveText(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      effects.enter("directiveText");
      effects.enter("directiveTextMarker");
      effects.consume(code2);
      effects.exit("directiveTextMarker");
      return factoryName.call(self, effects, afterName, nok, "directiveTextName");
    }
    function afterName(code2) {
      return code2 === 58 ? nok(code2) : code2 === 91 ? effects.attempt(label3, afterLabel, afterLabel)(code2) : afterLabel(code2);
    }
    function afterLabel(code2) {
      return code2 === 123 ? effects.attempt(attributes3, afterAttributes, afterAttributes)(code2) : afterAttributes(code2);
    }
    function afterAttributes(code2) {
      effects.exit("directiveText");
      return ok(code2);
    }
  }
  function tokenizeLabel3(effects, ok, nok) {
    return factoryLabel(effects, ok, nok, "directiveTextLabel", "directiveTextLabelMarker", "directiveTextLabelString");
  }
  function tokenizeAttributes3(effects, ok, nok) {
    return factoryAttributes(effects, ok, nok, "directiveTextAttributes", "directiveTextAttributesMarker", "directiveTextAttribute", "directiveTextAttributeId", "directiveTextAttributeClass", "directiveTextAttributeName", "directiveTextAttributeInitializerMarker", "directiveTextAttributeValueLiteral", "directiveTextAttributeValue", "directiveTextAttributeValueMarker", "directiveTextAttributeValueData");
  }

  // node_modules/micromark-extension-directive/lib/syntax.js
  function directive() {
    return {
      text: {
        [58]: directiveText
      },
      flow: {
        [58]: [directiveContainer, directiveLeaf]
      }
    };
  }

  // node_modules/character-entities/index.js
  var characterEntities = {
    AElig: "\xC6",
    AMP: "&",
    Aacute: "\xC1",
    Abreve: "\u0102",
    Acirc: "\xC2",
    Acy: "\u0410",
    Afr: "\u{1D504}",
    Agrave: "\xC0",
    Alpha: "\u0391",
    Amacr: "\u0100",
    And: "\u2A53",
    Aogon: "\u0104",
    Aopf: "\u{1D538}",
    ApplyFunction: "\u2061",
    Aring: "\xC5",
    Ascr: "\u{1D49C}",
    Assign: "\u2254",
    Atilde: "\xC3",
    Auml: "\xC4",
    Backslash: "\u2216",
    Barv: "\u2AE7",
    Barwed: "\u2306",
    Bcy: "\u0411",
    Because: "\u2235",
    Bernoullis: "\u212C",
    Beta: "\u0392",
    Bfr: "\u{1D505}",
    Bopf: "\u{1D539}",
    Breve: "\u02D8",
    Bscr: "\u212C",
    Bumpeq: "\u224E",
    CHcy: "\u0427",
    COPY: "\xA9",
    Cacute: "\u0106",
    Cap: "\u22D2",
    CapitalDifferentialD: "\u2145",
    Cayleys: "\u212D",
    Ccaron: "\u010C",
    Ccedil: "\xC7",
    Ccirc: "\u0108",
    Cconint: "\u2230",
    Cdot: "\u010A",
    Cedilla: "\xB8",
    CenterDot: "\xB7",
    Cfr: "\u212D",
    Chi: "\u03A7",
    CircleDot: "\u2299",
    CircleMinus: "\u2296",
    CirclePlus: "\u2295",
    CircleTimes: "\u2297",
    ClockwiseContourIntegral: "\u2232",
    CloseCurlyDoubleQuote: "\u201D",
    CloseCurlyQuote: "\u2019",
    Colon: "\u2237",
    Colone: "\u2A74",
    Congruent: "\u2261",
    Conint: "\u222F",
    ContourIntegral: "\u222E",
    Copf: "\u2102",
    Coproduct: "\u2210",
    CounterClockwiseContourIntegral: "\u2233",
    Cross: "\u2A2F",
    Cscr: "\u{1D49E}",
    Cup: "\u22D3",
    CupCap: "\u224D",
    DD: "\u2145",
    DDotrahd: "\u2911",
    DJcy: "\u0402",
    DScy: "\u0405",
    DZcy: "\u040F",
    Dagger: "\u2021",
    Darr: "\u21A1",
    Dashv: "\u2AE4",
    Dcaron: "\u010E",
    Dcy: "\u0414",
    Del: "\u2207",
    Delta: "\u0394",
    Dfr: "\u{1D507}",
    DiacriticalAcute: "\xB4",
    DiacriticalDot: "\u02D9",
    DiacriticalDoubleAcute: "\u02DD",
    DiacriticalGrave: "`",
    DiacriticalTilde: "\u02DC",
    Diamond: "\u22C4",
    DifferentialD: "\u2146",
    Dopf: "\u{1D53B}",
    Dot: "\xA8",
    DotDot: "\u20DC",
    DotEqual: "\u2250",
    DoubleContourIntegral: "\u222F",
    DoubleDot: "\xA8",
    DoubleDownArrow: "\u21D3",
    DoubleLeftArrow: "\u21D0",
    DoubleLeftRightArrow: "\u21D4",
    DoubleLeftTee: "\u2AE4",
    DoubleLongLeftArrow: "\u27F8",
    DoubleLongLeftRightArrow: "\u27FA",
    DoubleLongRightArrow: "\u27F9",
    DoubleRightArrow: "\u21D2",
    DoubleRightTee: "\u22A8",
    DoubleUpArrow: "\u21D1",
    DoubleUpDownArrow: "\u21D5",
    DoubleVerticalBar: "\u2225",
    DownArrow: "\u2193",
    DownArrowBar: "\u2913",
    DownArrowUpArrow: "\u21F5",
    DownBreve: "\u0311",
    DownLeftRightVector: "\u2950",
    DownLeftTeeVector: "\u295E",
    DownLeftVector: "\u21BD",
    DownLeftVectorBar: "\u2956",
    DownRightTeeVector: "\u295F",
    DownRightVector: "\u21C1",
    DownRightVectorBar: "\u2957",
    DownTee: "\u22A4",
    DownTeeArrow: "\u21A7",
    Downarrow: "\u21D3",
    Dscr: "\u{1D49F}",
    Dstrok: "\u0110",
    ENG: "\u014A",
    ETH: "\xD0",
    Eacute: "\xC9",
    Ecaron: "\u011A",
    Ecirc: "\xCA",
    Ecy: "\u042D",
    Edot: "\u0116",
    Efr: "\u{1D508}",
    Egrave: "\xC8",
    Element: "\u2208",
    Emacr: "\u0112",
    EmptySmallSquare: "\u25FB",
    EmptyVerySmallSquare: "\u25AB",
    Eogon: "\u0118",
    Eopf: "\u{1D53C}",
    Epsilon: "\u0395",
    Equal: "\u2A75",
    EqualTilde: "\u2242",
    Equilibrium: "\u21CC",
    Escr: "\u2130",
    Esim: "\u2A73",
    Eta: "\u0397",
    Euml: "\xCB",
    Exists: "\u2203",
    ExponentialE: "\u2147",
    Fcy: "\u0424",
    Ffr: "\u{1D509}",
    FilledSmallSquare: "\u25FC",
    FilledVerySmallSquare: "\u25AA",
    Fopf: "\u{1D53D}",
    ForAll: "\u2200",
    Fouriertrf: "\u2131",
    Fscr: "\u2131",
    GJcy: "\u0403",
    GT: ">",
    Gamma: "\u0393",
    Gammad: "\u03DC",
    Gbreve: "\u011E",
    Gcedil: "\u0122",
    Gcirc: "\u011C",
    Gcy: "\u0413",
    Gdot: "\u0120",
    Gfr: "\u{1D50A}",
    Gg: "\u22D9",
    Gopf: "\u{1D53E}",
    GreaterEqual: "\u2265",
    GreaterEqualLess: "\u22DB",
    GreaterFullEqual: "\u2267",
    GreaterGreater: "\u2AA2",
    GreaterLess: "\u2277",
    GreaterSlantEqual: "\u2A7E",
    GreaterTilde: "\u2273",
    Gscr: "\u{1D4A2}",
    Gt: "\u226B",
    HARDcy: "\u042A",
    Hacek: "\u02C7",
    Hat: "^",
    Hcirc: "\u0124",
    Hfr: "\u210C",
    HilbertSpace: "\u210B",
    Hopf: "\u210D",
    HorizontalLine: "\u2500",
    Hscr: "\u210B",
    Hstrok: "\u0126",
    HumpDownHump: "\u224E",
    HumpEqual: "\u224F",
    IEcy: "\u0415",
    IJlig: "\u0132",
    IOcy: "\u0401",
    Iacute: "\xCD",
    Icirc: "\xCE",
    Icy: "\u0418",
    Idot: "\u0130",
    Ifr: "\u2111",
    Igrave: "\xCC",
    Im: "\u2111",
    Imacr: "\u012A",
    ImaginaryI: "\u2148",
    Implies: "\u21D2",
    Int: "\u222C",
    Integral: "\u222B",
    Intersection: "\u22C2",
    InvisibleComma: "\u2063",
    InvisibleTimes: "\u2062",
    Iogon: "\u012E",
    Iopf: "\u{1D540}",
    Iota: "\u0399",
    Iscr: "\u2110",
    Itilde: "\u0128",
    Iukcy: "\u0406",
    Iuml: "\xCF",
    Jcirc: "\u0134",
    Jcy: "\u0419",
    Jfr: "\u{1D50D}",
    Jopf: "\u{1D541}",
    Jscr: "\u{1D4A5}",
    Jsercy: "\u0408",
    Jukcy: "\u0404",
    KHcy: "\u0425",
    KJcy: "\u040C",
    Kappa: "\u039A",
    Kcedil: "\u0136",
    Kcy: "\u041A",
    Kfr: "\u{1D50E}",
    Kopf: "\u{1D542}",
    Kscr: "\u{1D4A6}",
    LJcy: "\u0409",
    LT: "<",
    Lacute: "\u0139",
    Lambda: "\u039B",
    Lang: "\u27EA",
    Laplacetrf: "\u2112",
    Larr: "\u219E",
    Lcaron: "\u013D",
    Lcedil: "\u013B",
    Lcy: "\u041B",
    LeftAngleBracket: "\u27E8",
    LeftArrow: "\u2190",
    LeftArrowBar: "\u21E4",
    LeftArrowRightArrow: "\u21C6",
    LeftCeiling: "\u2308",
    LeftDoubleBracket: "\u27E6",
    LeftDownTeeVector: "\u2961",
    LeftDownVector: "\u21C3",
    LeftDownVectorBar: "\u2959",
    LeftFloor: "\u230A",
    LeftRightArrow: "\u2194",
    LeftRightVector: "\u294E",
    LeftTee: "\u22A3",
    LeftTeeArrow: "\u21A4",
    LeftTeeVector: "\u295A",
    LeftTriangle: "\u22B2",
    LeftTriangleBar: "\u29CF",
    LeftTriangleEqual: "\u22B4",
    LeftUpDownVector: "\u2951",
    LeftUpTeeVector: "\u2960",
    LeftUpVector: "\u21BF",
    LeftUpVectorBar: "\u2958",
    LeftVector: "\u21BC",
    LeftVectorBar: "\u2952",
    Leftarrow: "\u21D0",
    Leftrightarrow: "\u21D4",
    LessEqualGreater: "\u22DA",
    LessFullEqual: "\u2266",
    LessGreater: "\u2276",
    LessLess: "\u2AA1",
    LessSlantEqual: "\u2A7D",
    LessTilde: "\u2272",
    Lfr: "\u{1D50F}",
    Ll: "\u22D8",
    Lleftarrow: "\u21DA",
    Lmidot: "\u013F",
    LongLeftArrow: "\u27F5",
    LongLeftRightArrow: "\u27F7",
    LongRightArrow: "\u27F6",
    Longleftarrow: "\u27F8",
    Longleftrightarrow: "\u27FA",
    Longrightarrow: "\u27F9",
    Lopf: "\u{1D543}",
    LowerLeftArrow: "\u2199",
    LowerRightArrow: "\u2198",
    Lscr: "\u2112",
    Lsh: "\u21B0",
    Lstrok: "\u0141",
    Lt: "\u226A",
    Map: "\u2905",
    Mcy: "\u041C",
    MediumSpace: "\u205F",
    Mellintrf: "\u2133",
    Mfr: "\u{1D510}",
    MinusPlus: "\u2213",
    Mopf: "\u{1D544}",
    Mscr: "\u2133",
    Mu: "\u039C",
    NJcy: "\u040A",
    Nacute: "\u0143",
    Ncaron: "\u0147",
    Ncedil: "\u0145",
    Ncy: "\u041D",
    NegativeMediumSpace: "\u200B",
    NegativeThickSpace: "\u200B",
    NegativeThinSpace: "\u200B",
    NegativeVeryThinSpace: "\u200B",
    NestedGreaterGreater: "\u226B",
    NestedLessLess: "\u226A",
    NewLine: "\n",
    Nfr: "\u{1D511}",
    NoBreak: "\u2060",
    NonBreakingSpace: "\xA0",
    Nopf: "\u2115",
    Not: "\u2AEC",
    NotCongruent: "\u2262",
    NotCupCap: "\u226D",
    NotDoubleVerticalBar: "\u2226",
    NotElement: "\u2209",
    NotEqual: "\u2260",
    NotEqualTilde: "\u2242\u0338",
    NotExists: "\u2204",
    NotGreater: "\u226F",
    NotGreaterEqual: "\u2271",
    NotGreaterFullEqual: "\u2267\u0338",
    NotGreaterGreater: "\u226B\u0338",
    NotGreaterLess: "\u2279",
    NotGreaterSlantEqual: "\u2A7E\u0338",
    NotGreaterTilde: "\u2275",
    NotHumpDownHump: "\u224E\u0338",
    NotHumpEqual: "\u224F\u0338",
    NotLeftTriangle: "\u22EA",
    NotLeftTriangleBar: "\u29CF\u0338",
    NotLeftTriangleEqual: "\u22EC",
    NotLess: "\u226E",
    NotLessEqual: "\u2270",
    NotLessGreater: "\u2278",
    NotLessLess: "\u226A\u0338",
    NotLessSlantEqual: "\u2A7D\u0338",
    NotLessTilde: "\u2274",
    NotNestedGreaterGreater: "\u2AA2\u0338",
    NotNestedLessLess: "\u2AA1\u0338",
    NotPrecedes: "\u2280",
    NotPrecedesEqual: "\u2AAF\u0338",
    NotPrecedesSlantEqual: "\u22E0",
    NotReverseElement: "\u220C",
    NotRightTriangle: "\u22EB",
    NotRightTriangleBar: "\u29D0\u0338",
    NotRightTriangleEqual: "\u22ED",
    NotSquareSubset: "\u228F\u0338",
    NotSquareSubsetEqual: "\u22E2",
    NotSquareSuperset: "\u2290\u0338",
    NotSquareSupersetEqual: "\u22E3",
    NotSubset: "\u2282\u20D2",
    NotSubsetEqual: "\u2288",
    NotSucceeds: "\u2281",
    NotSucceedsEqual: "\u2AB0\u0338",
    NotSucceedsSlantEqual: "\u22E1",
    NotSucceedsTilde: "\u227F\u0338",
    NotSuperset: "\u2283\u20D2",
    NotSupersetEqual: "\u2289",
    NotTilde: "\u2241",
    NotTildeEqual: "\u2244",
    NotTildeFullEqual: "\u2247",
    NotTildeTilde: "\u2249",
    NotVerticalBar: "\u2224",
    Nscr: "\u{1D4A9}",
    Ntilde: "\xD1",
    Nu: "\u039D",
    OElig: "\u0152",
    Oacute: "\xD3",
    Ocirc: "\xD4",
    Ocy: "\u041E",
    Odblac: "\u0150",
    Ofr: "\u{1D512}",
    Ograve: "\xD2",
    Omacr: "\u014C",
    Omega: "\u03A9",
    Omicron: "\u039F",
    Oopf: "\u{1D546}",
    OpenCurlyDoubleQuote: "\u201C",
    OpenCurlyQuote: "\u2018",
    Or: "\u2A54",
    Oscr: "\u{1D4AA}",
    Oslash: "\xD8",
    Otilde: "\xD5",
    Otimes: "\u2A37",
    Ouml: "\xD6",
    OverBar: "\u203E",
    OverBrace: "\u23DE",
    OverBracket: "\u23B4",
    OverParenthesis: "\u23DC",
    PartialD: "\u2202",
    Pcy: "\u041F",
    Pfr: "\u{1D513}",
    Phi: "\u03A6",
    Pi: "\u03A0",
    PlusMinus: "\xB1",
    Poincareplane: "\u210C",
    Popf: "\u2119",
    Pr: "\u2ABB",
    Precedes: "\u227A",
    PrecedesEqual: "\u2AAF",
    PrecedesSlantEqual: "\u227C",
    PrecedesTilde: "\u227E",
    Prime: "\u2033",
    Product: "\u220F",
    Proportion: "\u2237",
    Proportional: "\u221D",
    Pscr: "\u{1D4AB}",
    Psi: "\u03A8",
    QUOT: '"',
    Qfr: "\u{1D514}",
    Qopf: "\u211A",
    Qscr: "\u{1D4AC}",
    RBarr: "\u2910",
    REG: "\xAE",
    Racute: "\u0154",
    Rang: "\u27EB",
    Rarr: "\u21A0",
    Rarrtl: "\u2916",
    Rcaron: "\u0158",
    Rcedil: "\u0156",
    Rcy: "\u0420",
    Re: "\u211C",
    ReverseElement: "\u220B",
    ReverseEquilibrium: "\u21CB",
    ReverseUpEquilibrium: "\u296F",
    Rfr: "\u211C",
    Rho: "\u03A1",
    RightAngleBracket: "\u27E9",
    RightArrow: "\u2192",
    RightArrowBar: "\u21E5",
    RightArrowLeftArrow: "\u21C4",
    RightCeiling: "\u2309",
    RightDoubleBracket: "\u27E7",
    RightDownTeeVector: "\u295D",
    RightDownVector: "\u21C2",
    RightDownVectorBar: "\u2955",
    RightFloor: "\u230B",
    RightTee: "\u22A2",
    RightTeeArrow: "\u21A6",
    RightTeeVector: "\u295B",
    RightTriangle: "\u22B3",
    RightTriangleBar: "\u29D0",
    RightTriangleEqual: "\u22B5",
    RightUpDownVector: "\u294F",
    RightUpTeeVector: "\u295C",
    RightUpVector: "\u21BE",
    RightUpVectorBar: "\u2954",
    RightVector: "\u21C0",
    RightVectorBar: "\u2953",
    Rightarrow: "\u21D2",
    Ropf: "\u211D",
    RoundImplies: "\u2970",
    Rrightarrow: "\u21DB",
    Rscr: "\u211B",
    Rsh: "\u21B1",
    RuleDelayed: "\u29F4",
    SHCHcy: "\u0429",
    SHcy: "\u0428",
    SOFTcy: "\u042C",
    Sacute: "\u015A",
    Sc: "\u2ABC",
    Scaron: "\u0160",
    Scedil: "\u015E",
    Scirc: "\u015C",
    Scy: "\u0421",
    Sfr: "\u{1D516}",
    ShortDownArrow: "\u2193",
    ShortLeftArrow: "\u2190",
    ShortRightArrow: "\u2192",
    ShortUpArrow: "\u2191",
    Sigma: "\u03A3",
    SmallCircle: "\u2218",
    Sopf: "\u{1D54A}",
    Sqrt: "\u221A",
    Square: "\u25A1",
    SquareIntersection: "\u2293",
    SquareSubset: "\u228F",
    SquareSubsetEqual: "\u2291",
    SquareSuperset: "\u2290",
    SquareSupersetEqual: "\u2292",
    SquareUnion: "\u2294",
    Sscr: "\u{1D4AE}",
    Star: "\u22C6",
    Sub: "\u22D0",
    Subset: "\u22D0",
    SubsetEqual: "\u2286",
    Succeeds: "\u227B",
    SucceedsEqual: "\u2AB0",
    SucceedsSlantEqual: "\u227D",
    SucceedsTilde: "\u227F",
    SuchThat: "\u220B",
    Sum: "\u2211",
    Sup: "\u22D1",
    Superset: "\u2283",
    SupersetEqual: "\u2287",
    Supset: "\u22D1",
    THORN: "\xDE",
    TRADE: "\u2122",
    TSHcy: "\u040B",
    TScy: "\u0426",
    Tab: "	",
    Tau: "\u03A4",
    Tcaron: "\u0164",
    Tcedil: "\u0162",
    Tcy: "\u0422",
    Tfr: "\u{1D517}",
    Therefore: "\u2234",
    Theta: "\u0398",
    ThickSpace: "\u205F\u200A",
    ThinSpace: "\u2009",
    Tilde: "\u223C",
    TildeEqual: "\u2243",
    TildeFullEqual: "\u2245",
    TildeTilde: "\u2248",
    Topf: "\u{1D54B}",
    TripleDot: "\u20DB",
    Tscr: "\u{1D4AF}",
    Tstrok: "\u0166",
    Uacute: "\xDA",
    Uarr: "\u219F",
    Uarrocir: "\u2949",
    Ubrcy: "\u040E",
    Ubreve: "\u016C",
    Ucirc: "\xDB",
    Ucy: "\u0423",
    Udblac: "\u0170",
    Ufr: "\u{1D518}",
    Ugrave: "\xD9",
    Umacr: "\u016A",
    UnderBar: "_",
    UnderBrace: "\u23DF",
    UnderBracket: "\u23B5",
    UnderParenthesis: "\u23DD",
    Union: "\u22C3",
    UnionPlus: "\u228E",
    Uogon: "\u0172",
    Uopf: "\u{1D54C}",
    UpArrow: "\u2191",
    UpArrowBar: "\u2912",
    UpArrowDownArrow: "\u21C5",
    UpDownArrow: "\u2195",
    UpEquilibrium: "\u296E",
    UpTee: "\u22A5",
    UpTeeArrow: "\u21A5",
    Uparrow: "\u21D1",
    Updownarrow: "\u21D5",
    UpperLeftArrow: "\u2196",
    UpperRightArrow: "\u2197",
    Upsi: "\u03D2",
    Upsilon: "\u03A5",
    Uring: "\u016E",
    Uscr: "\u{1D4B0}",
    Utilde: "\u0168",
    Uuml: "\xDC",
    VDash: "\u22AB",
    Vbar: "\u2AEB",
    Vcy: "\u0412",
    Vdash: "\u22A9",
    Vdashl: "\u2AE6",
    Vee: "\u22C1",
    Verbar: "\u2016",
    Vert: "\u2016",
    VerticalBar: "\u2223",
    VerticalLine: "|",
    VerticalSeparator: "\u2758",
    VerticalTilde: "\u2240",
    VeryThinSpace: "\u200A",
    Vfr: "\u{1D519}",
    Vopf: "\u{1D54D}",
    Vscr: "\u{1D4B1}",
    Vvdash: "\u22AA",
    Wcirc: "\u0174",
    Wedge: "\u22C0",
    Wfr: "\u{1D51A}",
    Wopf: "\u{1D54E}",
    Wscr: "\u{1D4B2}",
    Xfr: "\u{1D51B}",
    Xi: "\u039E",
    Xopf: "\u{1D54F}",
    Xscr: "\u{1D4B3}",
    YAcy: "\u042F",
    YIcy: "\u0407",
    YUcy: "\u042E",
    Yacute: "\xDD",
    Ycirc: "\u0176",
    Ycy: "\u042B",
    Yfr: "\u{1D51C}",
    Yopf: "\u{1D550}",
    Yscr: "\u{1D4B4}",
    Yuml: "\u0178",
    ZHcy: "\u0416",
    Zacute: "\u0179",
    Zcaron: "\u017D",
    Zcy: "\u0417",
    Zdot: "\u017B",
    ZeroWidthSpace: "\u200B",
    Zeta: "\u0396",
    Zfr: "\u2128",
    Zopf: "\u2124",
    Zscr: "\u{1D4B5}",
    aacute: "\xE1",
    abreve: "\u0103",
    ac: "\u223E",
    acE: "\u223E\u0333",
    acd: "\u223F",
    acirc: "\xE2",
    acute: "\xB4",
    acy: "\u0430",
    aelig: "\xE6",
    af: "\u2061",
    afr: "\u{1D51E}",
    agrave: "\xE0",
    alefsym: "\u2135",
    aleph: "\u2135",
    alpha: "\u03B1",
    amacr: "\u0101",
    amalg: "\u2A3F",
    amp: "&",
    and: "\u2227",
    andand: "\u2A55",
    andd: "\u2A5C",
    andslope: "\u2A58",
    andv: "\u2A5A",
    ang: "\u2220",
    ange: "\u29A4",
    angle: "\u2220",
    angmsd: "\u2221",
    angmsdaa: "\u29A8",
    angmsdab: "\u29A9",
    angmsdac: "\u29AA",
    angmsdad: "\u29AB",
    angmsdae: "\u29AC",
    angmsdaf: "\u29AD",
    angmsdag: "\u29AE",
    angmsdah: "\u29AF",
    angrt: "\u221F",
    angrtvb: "\u22BE",
    angrtvbd: "\u299D",
    angsph: "\u2222",
    angst: "\xC5",
    angzarr: "\u237C",
    aogon: "\u0105",
    aopf: "\u{1D552}",
    ap: "\u2248",
    apE: "\u2A70",
    apacir: "\u2A6F",
    ape: "\u224A",
    apid: "\u224B",
    apos: "'",
    approx: "\u2248",
    approxeq: "\u224A",
    aring: "\xE5",
    ascr: "\u{1D4B6}",
    ast: "*",
    asymp: "\u2248",
    asympeq: "\u224D",
    atilde: "\xE3",
    auml: "\xE4",
    awconint: "\u2233",
    awint: "\u2A11",
    bNot: "\u2AED",
    backcong: "\u224C",
    backepsilon: "\u03F6",
    backprime: "\u2035",
    backsim: "\u223D",
    backsimeq: "\u22CD",
    barvee: "\u22BD",
    barwed: "\u2305",
    barwedge: "\u2305",
    bbrk: "\u23B5",
    bbrktbrk: "\u23B6",
    bcong: "\u224C",
    bcy: "\u0431",
    bdquo: "\u201E",
    becaus: "\u2235",
    because: "\u2235",
    bemptyv: "\u29B0",
    bepsi: "\u03F6",
    bernou: "\u212C",
    beta: "\u03B2",
    beth: "\u2136",
    between: "\u226C",
    bfr: "\u{1D51F}",
    bigcap: "\u22C2",
    bigcirc: "\u25EF",
    bigcup: "\u22C3",
    bigodot: "\u2A00",
    bigoplus: "\u2A01",
    bigotimes: "\u2A02",
    bigsqcup: "\u2A06",
    bigstar: "\u2605",
    bigtriangledown: "\u25BD",
    bigtriangleup: "\u25B3",
    biguplus: "\u2A04",
    bigvee: "\u22C1",
    bigwedge: "\u22C0",
    bkarow: "\u290D",
    blacklozenge: "\u29EB",
    blacksquare: "\u25AA",
    blacktriangle: "\u25B4",
    blacktriangledown: "\u25BE",
    blacktriangleleft: "\u25C2",
    blacktriangleright: "\u25B8",
    blank: "\u2423",
    blk12: "\u2592",
    blk14: "\u2591",
    blk34: "\u2593",
    block: "\u2588",
    bne: "=\u20E5",
    bnequiv: "\u2261\u20E5",
    bnot: "\u2310",
    bopf: "\u{1D553}",
    bot: "\u22A5",
    bottom: "\u22A5",
    bowtie: "\u22C8",
    boxDL: "\u2557",
    boxDR: "\u2554",
    boxDl: "\u2556",
    boxDr: "\u2553",
    boxH: "\u2550",
    boxHD: "\u2566",
    boxHU: "\u2569",
    boxHd: "\u2564",
    boxHu: "\u2567",
    boxUL: "\u255D",
    boxUR: "\u255A",
    boxUl: "\u255C",
    boxUr: "\u2559",
    boxV: "\u2551",
    boxVH: "\u256C",
    boxVL: "\u2563",
    boxVR: "\u2560",
    boxVh: "\u256B",
    boxVl: "\u2562",
    boxVr: "\u255F",
    boxbox: "\u29C9",
    boxdL: "\u2555",
    boxdR: "\u2552",
    boxdl: "\u2510",
    boxdr: "\u250C",
    boxh: "\u2500",
    boxhD: "\u2565",
    boxhU: "\u2568",
    boxhd: "\u252C",
    boxhu: "\u2534",
    boxminus: "\u229F",
    boxplus: "\u229E",
    boxtimes: "\u22A0",
    boxuL: "\u255B",
    boxuR: "\u2558",
    boxul: "\u2518",
    boxur: "\u2514",
    boxv: "\u2502",
    boxvH: "\u256A",
    boxvL: "\u2561",
    boxvR: "\u255E",
    boxvh: "\u253C",
    boxvl: "\u2524",
    boxvr: "\u251C",
    bprime: "\u2035",
    breve: "\u02D8",
    brvbar: "\xA6",
    bscr: "\u{1D4B7}",
    bsemi: "\u204F",
    bsim: "\u223D",
    bsime: "\u22CD",
    bsol: "\\",
    bsolb: "\u29C5",
    bsolhsub: "\u27C8",
    bull: "\u2022",
    bullet: "\u2022",
    bump: "\u224E",
    bumpE: "\u2AAE",
    bumpe: "\u224F",
    bumpeq: "\u224F",
    cacute: "\u0107",
    cap: "\u2229",
    capand: "\u2A44",
    capbrcup: "\u2A49",
    capcap: "\u2A4B",
    capcup: "\u2A47",
    capdot: "\u2A40",
    caps: "\u2229\uFE00",
    caret: "\u2041",
    caron: "\u02C7",
    ccaps: "\u2A4D",
    ccaron: "\u010D",
    ccedil: "\xE7",
    ccirc: "\u0109",
    ccups: "\u2A4C",
    ccupssm: "\u2A50",
    cdot: "\u010B",
    cedil: "\xB8",
    cemptyv: "\u29B2",
    cent: "\xA2",
    centerdot: "\xB7",
    cfr: "\u{1D520}",
    chcy: "\u0447",
    check: "\u2713",
    checkmark: "\u2713",
    chi: "\u03C7",
    cir: "\u25CB",
    cirE: "\u29C3",
    circ: "\u02C6",
    circeq: "\u2257",
    circlearrowleft: "\u21BA",
    circlearrowright: "\u21BB",
    circledR: "\xAE",
    circledS: "\u24C8",
    circledast: "\u229B",
    circledcirc: "\u229A",
    circleddash: "\u229D",
    cire: "\u2257",
    cirfnint: "\u2A10",
    cirmid: "\u2AEF",
    cirscir: "\u29C2",
    clubs: "\u2663",
    clubsuit: "\u2663",
    colon: ":",
    colone: "\u2254",
    coloneq: "\u2254",
    comma: ",",
    commat: "@",
    comp: "\u2201",
    compfn: "\u2218",
    complement: "\u2201",
    complexes: "\u2102",
    cong: "\u2245",
    congdot: "\u2A6D",
    conint: "\u222E",
    copf: "\u{1D554}",
    coprod: "\u2210",
    copy: "\xA9",
    copysr: "\u2117",
    crarr: "\u21B5",
    cross: "\u2717",
    cscr: "\u{1D4B8}",
    csub: "\u2ACF",
    csube: "\u2AD1",
    csup: "\u2AD0",
    csupe: "\u2AD2",
    ctdot: "\u22EF",
    cudarrl: "\u2938",
    cudarrr: "\u2935",
    cuepr: "\u22DE",
    cuesc: "\u22DF",
    cularr: "\u21B6",
    cularrp: "\u293D",
    cup: "\u222A",
    cupbrcap: "\u2A48",
    cupcap: "\u2A46",
    cupcup: "\u2A4A",
    cupdot: "\u228D",
    cupor: "\u2A45",
    cups: "\u222A\uFE00",
    curarr: "\u21B7",
    curarrm: "\u293C",
    curlyeqprec: "\u22DE",
    curlyeqsucc: "\u22DF",
    curlyvee: "\u22CE",
    curlywedge: "\u22CF",
    curren: "\xA4",
    curvearrowleft: "\u21B6",
    curvearrowright: "\u21B7",
    cuvee: "\u22CE",
    cuwed: "\u22CF",
    cwconint: "\u2232",
    cwint: "\u2231",
    cylcty: "\u232D",
    dArr: "\u21D3",
    dHar: "\u2965",
    dagger: "\u2020",
    daleth: "\u2138",
    darr: "\u2193",
    dash: "\u2010",
    dashv: "\u22A3",
    dbkarow: "\u290F",
    dblac: "\u02DD",
    dcaron: "\u010F",
    dcy: "\u0434",
    dd: "\u2146",
    ddagger: "\u2021",
    ddarr: "\u21CA",
    ddotseq: "\u2A77",
    deg: "\xB0",
    delta: "\u03B4",
    demptyv: "\u29B1",
    dfisht: "\u297F",
    dfr: "\u{1D521}",
    dharl: "\u21C3",
    dharr: "\u21C2",
    diam: "\u22C4",
    diamond: "\u22C4",
    diamondsuit: "\u2666",
    diams: "\u2666",
    die: "\xA8",
    digamma: "\u03DD",
    disin: "\u22F2",
    div: "\xF7",
    divide: "\xF7",
    divideontimes: "\u22C7",
    divonx: "\u22C7",
    djcy: "\u0452",
    dlcorn: "\u231E",
    dlcrop: "\u230D",
    dollar: "$",
    dopf: "\u{1D555}",
    dot: "\u02D9",
    doteq: "\u2250",
    doteqdot: "\u2251",
    dotminus: "\u2238",
    dotplus: "\u2214",
    dotsquare: "\u22A1",
    doublebarwedge: "\u2306",
    downarrow: "\u2193",
    downdownarrows: "\u21CA",
    downharpoonleft: "\u21C3",
    downharpoonright: "\u21C2",
    drbkarow: "\u2910",
    drcorn: "\u231F",
    drcrop: "\u230C",
    dscr: "\u{1D4B9}",
    dscy: "\u0455",
    dsol: "\u29F6",
    dstrok: "\u0111",
    dtdot: "\u22F1",
    dtri: "\u25BF",
    dtrif: "\u25BE",
    duarr: "\u21F5",
    duhar: "\u296F",
    dwangle: "\u29A6",
    dzcy: "\u045F",
    dzigrarr: "\u27FF",
    eDDot: "\u2A77",
    eDot: "\u2251",
    eacute: "\xE9",
    easter: "\u2A6E",
    ecaron: "\u011B",
    ecir: "\u2256",
    ecirc: "\xEA",
    ecolon: "\u2255",
    ecy: "\u044D",
    edot: "\u0117",
    ee: "\u2147",
    efDot: "\u2252",
    efr: "\u{1D522}",
    eg: "\u2A9A",
    egrave: "\xE8",
    egs: "\u2A96",
    egsdot: "\u2A98",
    el: "\u2A99",
    elinters: "\u23E7",
    ell: "\u2113",
    els: "\u2A95",
    elsdot: "\u2A97",
    emacr: "\u0113",
    empty: "\u2205",
    emptyset: "\u2205",
    emptyv: "\u2205",
    emsp13: "\u2004",
    emsp14: "\u2005",
    emsp: "\u2003",
    eng: "\u014B",
    ensp: "\u2002",
    eogon: "\u0119",
    eopf: "\u{1D556}",
    epar: "\u22D5",
    eparsl: "\u29E3",
    eplus: "\u2A71",
    epsi: "\u03B5",
    epsilon: "\u03B5",
    epsiv: "\u03F5",
    eqcirc: "\u2256",
    eqcolon: "\u2255",
    eqsim: "\u2242",
    eqslantgtr: "\u2A96",
    eqslantless: "\u2A95",
    equals: "=",
    equest: "\u225F",
    equiv: "\u2261",
    equivDD: "\u2A78",
    eqvparsl: "\u29E5",
    erDot: "\u2253",
    erarr: "\u2971",
    escr: "\u212F",
    esdot: "\u2250",
    esim: "\u2242",
    eta: "\u03B7",
    eth: "\xF0",
    euml: "\xEB",
    euro: "\u20AC",
    excl: "!",
    exist: "\u2203",
    expectation: "\u2130",
    exponentiale: "\u2147",
    fallingdotseq: "\u2252",
    fcy: "\u0444",
    female: "\u2640",
    ffilig: "\uFB03",
    fflig: "\uFB00",
    ffllig: "\uFB04",
    ffr: "\u{1D523}",
    filig: "\uFB01",
    fjlig: "fj",
    flat: "\u266D",
    fllig: "\uFB02",
    fltns: "\u25B1",
    fnof: "\u0192",
    fopf: "\u{1D557}",
    forall: "\u2200",
    fork: "\u22D4",
    forkv: "\u2AD9",
    fpartint: "\u2A0D",
    frac12: "\xBD",
    frac13: "\u2153",
    frac14: "\xBC",
    frac15: "\u2155",
    frac16: "\u2159",
    frac18: "\u215B",
    frac23: "\u2154",
    frac25: "\u2156",
    frac34: "\xBE",
    frac35: "\u2157",
    frac38: "\u215C",
    frac45: "\u2158",
    frac56: "\u215A",
    frac58: "\u215D",
    frac78: "\u215E",
    frasl: "\u2044",
    frown: "\u2322",
    fscr: "\u{1D4BB}",
    gE: "\u2267",
    gEl: "\u2A8C",
    gacute: "\u01F5",
    gamma: "\u03B3",
    gammad: "\u03DD",
    gap: "\u2A86",
    gbreve: "\u011F",
    gcirc: "\u011D",
    gcy: "\u0433",
    gdot: "\u0121",
    ge: "\u2265",
    gel: "\u22DB",
    geq: "\u2265",
    geqq: "\u2267",
    geqslant: "\u2A7E",
    ges: "\u2A7E",
    gescc: "\u2AA9",
    gesdot: "\u2A80",
    gesdoto: "\u2A82",
    gesdotol: "\u2A84",
    gesl: "\u22DB\uFE00",
    gesles: "\u2A94",
    gfr: "\u{1D524}",
    gg: "\u226B",
    ggg: "\u22D9",
    gimel: "\u2137",
    gjcy: "\u0453",
    gl: "\u2277",
    glE: "\u2A92",
    gla: "\u2AA5",
    glj: "\u2AA4",
    gnE: "\u2269",
    gnap: "\u2A8A",
    gnapprox: "\u2A8A",
    gne: "\u2A88",
    gneq: "\u2A88",
    gneqq: "\u2269",
    gnsim: "\u22E7",
    gopf: "\u{1D558}",
    grave: "`",
    gscr: "\u210A",
    gsim: "\u2273",
    gsime: "\u2A8E",
    gsiml: "\u2A90",
    gt: ">",
    gtcc: "\u2AA7",
    gtcir: "\u2A7A",
    gtdot: "\u22D7",
    gtlPar: "\u2995",
    gtquest: "\u2A7C",
    gtrapprox: "\u2A86",
    gtrarr: "\u2978",
    gtrdot: "\u22D7",
    gtreqless: "\u22DB",
    gtreqqless: "\u2A8C",
    gtrless: "\u2277",
    gtrsim: "\u2273",
    gvertneqq: "\u2269\uFE00",
    gvnE: "\u2269\uFE00",
    hArr: "\u21D4",
    hairsp: "\u200A",
    half: "\xBD",
    hamilt: "\u210B",
    hardcy: "\u044A",
    harr: "\u2194",
    harrcir: "\u2948",
    harrw: "\u21AD",
    hbar: "\u210F",
    hcirc: "\u0125",
    hearts: "\u2665",
    heartsuit: "\u2665",
    hellip: "\u2026",
    hercon: "\u22B9",
    hfr: "\u{1D525}",
    hksearow: "\u2925",
    hkswarow: "\u2926",
    hoarr: "\u21FF",
    homtht: "\u223B",
    hookleftarrow: "\u21A9",
    hookrightarrow: "\u21AA",
    hopf: "\u{1D559}",
    horbar: "\u2015",
    hscr: "\u{1D4BD}",
    hslash: "\u210F",
    hstrok: "\u0127",
    hybull: "\u2043",
    hyphen: "\u2010",
    iacute: "\xED",
    ic: "\u2063",
    icirc: "\xEE",
    icy: "\u0438",
    iecy: "\u0435",
    iexcl: "\xA1",
    iff: "\u21D4",
    ifr: "\u{1D526}",
    igrave: "\xEC",
    ii: "\u2148",
    iiiint: "\u2A0C",
    iiint: "\u222D",
    iinfin: "\u29DC",
    iiota: "\u2129",
    ijlig: "\u0133",
    imacr: "\u012B",
    image: "\u2111",
    imagline: "\u2110",
    imagpart: "\u2111",
    imath: "\u0131",
    imof: "\u22B7",
    imped: "\u01B5",
    in: "\u2208",
    incare: "\u2105",
    infin: "\u221E",
    infintie: "\u29DD",
    inodot: "\u0131",
    int: "\u222B",
    intcal: "\u22BA",
    integers: "\u2124",
    intercal: "\u22BA",
    intlarhk: "\u2A17",
    intprod: "\u2A3C",
    iocy: "\u0451",
    iogon: "\u012F",
    iopf: "\u{1D55A}",
    iota: "\u03B9",
    iprod: "\u2A3C",
    iquest: "\xBF",
    iscr: "\u{1D4BE}",
    isin: "\u2208",
    isinE: "\u22F9",
    isindot: "\u22F5",
    isins: "\u22F4",
    isinsv: "\u22F3",
    isinv: "\u2208",
    it: "\u2062",
    itilde: "\u0129",
    iukcy: "\u0456",
    iuml: "\xEF",
    jcirc: "\u0135",
    jcy: "\u0439",
    jfr: "\u{1D527}",
    jmath: "\u0237",
    jopf: "\u{1D55B}",
    jscr: "\u{1D4BF}",
    jsercy: "\u0458",
    jukcy: "\u0454",
    kappa: "\u03BA",
    kappav: "\u03F0",
    kcedil: "\u0137",
    kcy: "\u043A",
    kfr: "\u{1D528}",
    kgreen: "\u0138",
    khcy: "\u0445",
    kjcy: "\u045C",
    kopf: "\u{1D55C}",
    kscr: "\u{1D4C0}",
    lAarr: "\u21DA",
    lArr: "\u21D0",
    lAtail: "\u291B",
    lBarr: "\u290E",
    lE: "\u2266",
    lEg: "\u2A8B",
    lHar: "\u2962",
    lacute: "\u013A",
    laemptyv: "\u29B4",
    lagran: "\u2112",
    lambda: "\u03BB",
    lang: "\u27E8",
    langd: "\u2991",
    langle: "\u27E8",
    lap: "\u2A85",
    laquo: "\xAB",
    larr: "\u2190",
    larrb: "\u21E4",
    larrbfs: "\u291F",
    larrfs: "\u291D",
    larrhk: "\u21A9",
    larrlp: "\u21AB",
    larrpl: "\u2939",
    larrsim: "\u2973",
    larrtl: "\u21A2",
    lat: "\u2AAB",
    latail: "\u2919",
    late: "\u2AAD",
    lates: "\u2AAD\uFE00",
    lbarr: "\u290C",
    lbbrk: "\u2772",
    lbrace: "{",
    lbrack: "[",
    lbrke: "\u298B",
    lbrksld: "\u298F",
    lbrkslu: "\u298D",
    lcaron: "\u013E",
    lcedil: "\u013C",
    lceil: "\u2308",
    lcub: "{",
    lcy: "\u043B",
    ldca: "\u2936",
    ldquo: "\u201C",
    ldquor: "\u201E",
    ldrdhar: "\u2967",
    ldrushar: "\u294B",
    ldsh: "\u21B2",
    le: "\u2264",
    leftarrow: "\u2190",
    leftarrowtail: "\u21A2",
    leftharpoondown: "\u21BD",
    leftharpoonup: "\u21BC",
    leftleftarrows: "\u21C7",
    leftrightarrow: "\u2194",
    leftrightarrows: "\u21C6",
    leftrightharpoons: "\u21CB",
    leftrightsquigarrow: "\u21AD",
    leftthreetimes: "\u22CB",
    leg: "\u22DA",
    leq: "\u2264",
    leqq: "\u2266",
    leqslant: "\u2A7D",
    les: "\u2A7D",
    lescc: "\u2AA8",
    lesdot: "\u2A7F",
    lesdoto: "\u2A81",
    lesdotor: "\u2A83",
    lesg: "\u22DA\uFE00",
    lesges: "\u2A93",
    lessapprox: "\u2A85",
    lessdot: "\u22D6",
    lesseqgtr: "\u22DA",
    lesseqqgtr: "\u2A8B",
    lessgtr: "\u2276",
    lesssim: "\u2272",
    lfisht: "\u297C",
    lfloor: "\u230A",
    lfr: "\u{1D529}",
    lg: "\u2276",
    lgE: "\u2A91",
    lhard: "\u21BD",
    lharu: "\u21BC",
    lharul: "\u296A",
    lhblk: "\u2584",
    ljcy: "\u0459",
    ll: "\u226A",
    llarr: "\u21C7",
    llcorner: "\u231E",
    llhard: "\u296B",
    lltri: "\u25FA",
    lmidot: "\u0140",
    lmoust: "\u23B0",
    lmoustache: "\u23B0",
    lnE: "\u2268",
    lnap: "\u2A89",
    lnapprox: "\u2A89",
    lne: "\u2A87",
    lneq: "\u2A87",
    lneqq: "\u2268",
    lnsim: "\u22E6",
    loang: "\u27EC",
    loarr: "\u21FD",
    lobrk: "\u27E6",
    longleftarrow: "\u27F5",
    longleftrightarrow: "\u27F7",
    longmapsto: "\u27FC",
    longrightarrow: "\u27F6",
    looparrowleft: "\u21AB",
    looparrowright: "\u21AC",
    lopar: "\u2985",
    lopf: "\u{1D55D}",
    loplus: "\u2A2D",
    lotimes: "\u2A34",
    lowast: "\u2217",
    lowbar: "_",
    loz: "\u25CA",
    lozenge: "\u25CA",
    lozf: "\u29EB",
    lpar: "(",
    lparlt: "\u2993",
    lrarr: "\u21C6",
    lrcorner: "\u231F",
    lrhar: "\u21CB",
    lrhard: "\u296D",
    lrm: "\u200E",
    lrtri: "\u22BF",
    lsaquo: "\u2039",
    lscr: "\u{1D4C1}",
    lsh: "\u21B0",
    lsim: "\u2272",
    lsime: "\u2A8D",
    lsimg: "\u2A8F",
    lsqb: "[",
    lsquo: "\u2018",
    lsquor: "\u201A",
    lstrok: "\u0142",
    lt: "<",
    ltcc: "\u2AA6",
    ltcir: "\u2A79",
    ltdot: "\u22D6",
    lthree: "\u22CB",
    ltimes: "\u22C9",
    ltlarr: "\u2976",
    ltquest: "\u2A7B",
    ltrPar: "\u2996",
    ltri: "\u25C3",
    ltrie: "\u22B4",
    ltrif: "\u25C2",
    lurdshar: "\u294A",
    luruhar: "\u2966",
    lvertneqq: "\u2268\uFE00",
    lvnE: "\u2268\uFE00",
    mDDot: "\u223A",
    macr: "\xAF",
    male: "\u2642",
    malt: "\u2720",
    maltese: "\u2720",
    map: "\u21A6",
    mapsto: "\u21A6",
    mapstodown: "\u21A7",
    mapstoleft: "\u21A4",
    mapstoup: "\u21A5",
    marker: "\u25AE",
    mcomma: "\u2A29",
    mcy: "\u043C",
    mdash: "\u2014",
    measuredangle: "\u2221",
    mfr: "\u{1D52A}",
    mho: "\u2127",
    micro: "\xB5",
    mid: "\u2223",
    midast: "*",
    midcir: "\u2AF0",
    middot: "\xB7",
    minus: "\u2212",
    minusb: "\u229F",
    minusd: "\u2238",
    minusdu: "\u2A2A",
    mlcp: "\u2ADB",
    mldr: "\u2026",
    mnplus: "\u2213",
    models: "\u22A7",
    mopf: "\u{1D55E}",
    mp: "\u2213",
    mscr: "\u{1D4C2}",
    mstpos: "\u223E",
    mu: "\u03BC",
    multimap: "\u22B8",
    mumap: "\u22B8",
    nGg: "\u22D9\u0338",
    nGt: "\u226B\u20D2",
    nGtv: "\u226B\u0338",
    nLeftarrow: "\u21CD",
    nLeftrightarrow: "\u21CE",
    nLl: "\u22D8\u0338",
    nLt: "\u226A\u20D2",
    nLtv: "\u226A\u0338",
    nRightarrow: "\u21CF",
    nVDash: "\u22AF",
    nVdash: "\u22AE",
    nabla: "\u2207",
    nacute: "\u0144",
    nang: "\u2220\u20D2",
    nap: "\u2249",
    napE: "\u2A70\u0338",
    napid: "\u224B\u0338",
    napos: "\u0149",
    napprox: "\u2249",
    natur: "\u266E",
    natural: "\u266E",
    naturals: "\u2115",
    nbsp: "\xA0",
    nbump: "\u224E\u0338",
    nbumpe: "\u224F\u0338",
    ncap: "\u2A43",
    ncaron: "\u0148",
    ncedil: "\u0146",
    ncong: "\u2247",
    ncongdot: "\u2A6D\u0338",
    ncup: "\u2A42",
    ncy: "\u043D",
    ndash: "\u2013",
    ne: "\u2260",
    neArr: "\u21D7",
    nearhk: "\u2924",
    nearr: "\u2197",
    nearrow: "\u2197",
    nedot: "\u2250\u0338",
    nequiv: "\u2262",
    nesear: "\u2928",
    nesim: "\u2242\u0338",
    nexist: "\u2204",
    nexists: "\u2204",
    nfr: "\u{1D52B}",
    ngE: "\u2267\u0338",
    nge: "\u2271",
    ngeq: "\u2271",
    ngeqq: "\u2267\u0338",
    ngeqslant: "\u2A7E\u0338",
    nges: "\u2A7E\u0338",
    ngsim: "\u2275",
    ngt: "\u226F",
    ngtr: "\u226F",
    nhArr: "\u21CE",
    nharr: "\u21AE",
    nhpar: "\u2AF2",
    ni: "\u220B",
    nis: "\u22FC",
    nisd: "\u22FA",
    niv: "\u220B",
    njcy: "\u045A",
    nlArr: "\u21CD",
    nlE: "\u2266\u0338",
    nlarr: "\u219A",
    nldr: "\u2025",
    nle: "\u2270",
    nleftarrow: "\u219A",
    nleftrightarrow: "\u21AE",
    nleq: "\u2270",
    nleqq: "\u2266\u0338",
    nleqslant: "\u2A7D\u0338",
    nles: "\u2A7D\u0338",
    nless: "\u226E",
    nlsim: "\u2274",
    nlt: "\u226E",
    nltri: "\u22EA",
    nltrie: "\u22EC",
    nmid: "\u2224",
    nopf: "\u{1D55F}",
    not: "\xAC",
    notin: "\u2209",
    notinE: "\u22F9\u0338",
    notindot: "\u22F5\u0338",
    notinva: "\u2209",
    notinvb: "\u22F7",
    notinvc: "\u22F6",
    notni: "\u220C",
    notniva: "\u220C",
    notnivb: "\u22FE",
    notnivc: "\u22FD",
    npar: "\u2226",
    nparallel: "\u2226",
    nparsl: "\u2AFD\u20E5",
    npart: "\u2202\u0338",
    npolint: "\u2A14",
    npr: "\u2280",
    nprcue: "\u22E0",
    npre: "\u2AAF\u0338",
    nprec: "\u2280",
    npreceq: "\u2AAF\u0338",
    nrArr: "\u21CF",
    nrarr: "\u219B",
    nrarrc: "\u2933\u0338",
    nrarrw: "\u219D\u0338",
    nrightarrow: "\u219B",
    nrtri: "\u22EB",
    nrtrie: "\u22ED",
    nsc: "\u2281",
    nsccue: "\u22E1",
    nsce: "\u2AB0\u0338",
    nscr: "\u{1D4C3}",
    nshortmid: "\u2224",
    nshortparallel: "\u2226",
    nsim: "\u2241",
    nsime: "\u2244",
    nsimeq: "\u2244",
    nsmid: "\u2224",
    nspar: "\u2226",
    nsqsube: "\u22E2",
    nsqsupe: "\u22E3",
    nsub: "\u2284",
    nsubE: "\u2AC5\u0338",
    nsube: "\u2288",
    nsubset: "\u2282\u20D2",
    nsubseteq: "\u2288",
    nsubseteqq: "\u2AC5\u0338",
    nsucc: "\u2281",
    nsucceq: "\u2AB0\u0338",
    nsup: "\u2285",
    nsupE: "\u2AC6\u0338",
    nsupe: "\u2289",
    nsupset: "\u2283\u20D2",
    nsupseteq: "\u2289",
    nsupseteqq: "\u2AC6\u0338",
    ntgl: "\u2279",
    ntilde: "\xF1",
    ntlg: "\u2278",
    ntriangleleft: "\u22EA",
    ntrianglelefteq: "\u22EC",
    ntriangleright: "\u22EB",
    ntrianglerighteq: "\u22ED",
    nu: "\u03BD",
    num: "#",
    numero: "\u2116",
    numsp: "\u2007",
    nvDash: "\u22AD",
    nvHarr: "\u2904",
    nvap: "\u224D\u20D2",
    nvdash: "\u22AC",
    nvge: "\u2265\u20D2",
    nvgt: ">\u20D2",
    nvinfin: "\u29DE",
    nvlArr: "\u2902",
    nvle: "\u2264\u20D2",
    nvlt: "<\u20D2",
    nvltrie: "\u22B4\u20D2",
    nvrArr: "\u2903",
    nvrtrie: "\u22B5\u20D2",
    nvsim: "\u223C\u20D2",
    nwArr: "\u21D6",
    nwarhk: "\u2923",
    nwarr: "\u2196",
    nwarrow: "\u2196",
    nwnear: "\u2927",
    oS: "\u24C8",
    oacute: "\xF3",
    oast: "\u229B",
    ocir: "\u229A",
    ocirc: "\xF4",
    ocy: "\u043E",
    odash: "\u229D",
    odblac: "\u0151",
    odiv: "\u2A38",
    odot: "\u2299",
    odsold: "\u29BC",
    oelig: "\u0153",
    ofcir: "\u29BF",
    ofr: "\u{1D52C}",
    ogon: "\u02DB",
    ograve: "\xF2",
    ogt: "\u29C1",
    ohbar: "\u29B5",
    ohm: "\u03A9",
    oint: "\u222E",
    olarr: "\u21BA",
    olcir: "\u29BE",
    olcross: "\u29BB",
    oline: "\u203E",
    olt: "\u29C0",
    omacr: "\u014D",
    omega: "\u03C9",
    omicron: "\u03BF",
    omid: "\u29B6",
    ominus: "\u2296",
    oopf: "\u{1D560}",
    opar: "\u29B7",
    operp: "\u29B9",
    oplus: "\u2295",
    or: "\u2228",
    orarr: "\u21BB",
    ord: "\u2A5D",
    order: "\u2134",
    orderof: "\u2134",
    ordf: "\xAA",
    ordm: "\xBA",
    origof: "\u22B6",
    oror: "\u2A56",
    orslope: "\u2A57",
    orv: "\u2A5B",
    oscr: "\u2134",
    oslash: "\xF8",
    osol: "\u2298",
    otilde: "\xF5",
    otimes: "\u2297",
    otimesas: "\u2A36",
    ouml: "\xF6",
    ovbar: "\u233D",
    par: "\u2225",
    para: "\xB6",
    parallel: "\u2225",
    parsim: "\u2AF3",
    parsl: "\u2AFD",
    part: "\u2202",
    pcy: "\u043F",
    percnt: "%",
    period: ".",
    permil: "\u2030",
    perp: "\u22A5",
    pertenk: "\u2031",
    pfr: "\u{1D52D}",
    phi: "\u03C6",
    phiv: "\u03D5",
    phmmat: "\u2133",
    phone: "\u260E",
    pi: "\u03C0",
    pitchfork: "\u22D4",
    piv: "\u03D6",
    planck: "\u210F",
    planckh: "\u210E",
    plankv: "\u210F",
    plus: "+",
    plusacir: "\u2A23",
    plusb: "\u229E",
    pluscir: "\u2A22",
    plusdo: "\u2214",
    plusdu: "\u2A25",
    pluse: "\u2A72",
    plusmn: "\xB1",
    plussim: "\u2A26",
    plustwo: "\u2A27",
    pm: "\xB1",
    pointint: "\u2A15",
    popf: "\u{1D561}",
    pound: "\xA3",
    pr: "\u227A",
    prE: "\u2AB3",
    prap: "\u2AB7",
    prcue: "\u227C",
    pre: "\u2AAF",
    prec: "\u227A",
    precapprox: "\u2AB7",
    preccurlyeq: "\u227C",
    preceq: "\u2AAF",
    precnapprox: "\u2AB9",
    precneqq: "\u2AB5",
    precnsim: "\u22E8",
    precsim: "\u227E",
    prime: "\u2032",
    primes: "\u2119",
    prnE: "\u2AB5",
    prnap: "\u2AB9",
    prnsim: "\u22E8",
    prod: "\u220F",
    profalar: "\u232E",
    profline: "\u2312",
    profsurf: "\u2313",
    prop: "\u221D",
    propto: "\u221D",
    prsim: "\u227E",
    prurel: "\u22B0",
    pscr: "\u{1D4C5}",
    psi: "\u03C8",
    puncsp: "\u2008",
    qfr: "\u{1D52E}",
    qint: "\u2A0C",
    qopf: "\u{1D562}",
    qprime: "\u2057",
    qscr: "\u{1D4C6}",
    quaternions: "\u210D",
    quatint: "\u2A16",
    quest: "?",
    questeq: "\u225F",
    quot: '"',
    rAarr: "\u21DB",
    rArr: "\u21D2",
    rAtail: "\u291C",
    rBarr: "\u290F",
    rHar: "\u2964",
    race: "\u223D\u0331",
    racute: "\u0155",
    radic: "\u221A",
    raemptyv: "\u29B3",
    rang: "\u27E9",
    rangd: "\u2992",
    range: "\u29A5",
    rangle: "\u27E9",
    raquo: "\xBB",
    rarr: "\u2192",
    rarrap: "\u2975",
    rarrb: "\u21E5",
    rarrbfs: "\u2920",
    rarrc: "\u2933",
    rarrfs: "\u291E",
    rarrhk: "\u21AA",
    rarrlp: "\u21AC",
    rarrpl: "\u2945",
    rarrsim: "\u2974",
    rarrtl: "\u21A3",
    rarrw: "\u219D",
    ratail: "\u291A",
    ratio: "\u2236",
    rationals: "\u211A",
    rbarr: "\u290D",
    rbbrk: "\u2773",
    rbrace: "}",
    rbrack: "]",
    rbrke: "\u298C",
    rbrksld: "\u298E",
    rbrkslu: "\u2990",
    rcaron: "\u0159",
    rcedil: "\u0157",
    rceil: "\u2309",
    rcub: "}",
    rcy: "\u0440",
    rdca: "\u2937",
    rdldhar: "\u2969",
    rdquo: "\u201D",
    rdquor: "\u201D",
    rdsh: "\u21B3",
    real: "\u211C",
    realine: "\u211B",
    realpart: "\u211C",
    reals: "\u211D",
    rect: "\u25AD",
    reg: "\xAE",
    rfisht: "\u297D",
    rfloor: "\u230B",
    rfr: "\u{1D52F}",
    rhard: "\u21C1",
    rharu: "\u21C0",
    rharul: "\u296C",
    rho: "\u03C1",
    rhov: "\u03F1",
    rightarrow: "\u2192",
    rightarrowtail: "\u21A3",
    rightharpoondown: "\u21C1",
    rightharpoonup: "\u21C0",
    rightleftarrows: "\u21C4",
    rightleftharpoons: "\u21CC",
    rightrightarrows: "\u21C9",
    rightsquigarrow: "\u219D",
    rightthreetimes: "\u22CC",
    ring: "\u02DA",
    risingdotseq: "\u2253",
    rlarr: "\u21C4",
    rlhar: "\u21CC",
    rlm: "\u200F",
    rmoust: "\u23B1",
    rmoustache: "\u23B1",
    rnmid: "\u2AEE",
    roang: "\u27ED",
    roarr: "\u21FE",
    robrk: "\u27E7",
    ropar: "\u2986",
    ropf: "\u{1D563}",
    roplus: "\u2A2E",
    rotimes: "\u2A35",
    rpar: ")",
    rpargt: "\u2994",
    rppolint: "\u2A12",
    rrarr: "\u21C9",
    rsaquo: "\u203A",
    rscr: "\u{1D4C7}",
    rsh: "\u21B1",
    rsqb: "]",
    rsquo: "\u2019",
    rsquor: "\u2019",
    rthree: "\u22CC",
    rtimes: "\u22CA",
    rtri: "\u25B9",
    rtrie: "\u22B5",
    rtrif: "\u25B8",
    rtriltri: "\u29CE",
    ruluhar: "\u2968",
    rx: "\u211E",
    sacute: "\u015B",
    sbquo: "\u201A",
    sc: "\u227B",
    scE: "\u2AB4",
    scap: "\u2AB8",
    scaron: "\u0161",
    sccue: "\u227D",
    sce: "\u2AB0",
    scedil: "\u015F",
    scirc: "\u015D",
    scnE: "\u2AB6",
    scnap: "\u2ABA",
    scnsim: "\u22E9",
    scpolint: "\u2A13",
    scsim: "\u227F",
    scy: "\u0441",
    sdot: "\u22C5",
    sdotb: "\u22A1",
    sdote: "\u2A66",
    seArr: "\u21D8",
    searhk: "\u2925",
    searr: "\u2198",
    searrow: "\u2198",
    sect: "\xA7",
    semi: ";",
    seswar: "\u2929",
    setminus: "\u2216",
    setmn: "\u2216",
    sext: "\u2736",
    sfr: "\u{1D530}",
    sfrown: "\u2322",
    sharp: "\u266F",
    shchcy: "\u0449",
    shcy: "\u0448",
    shortmid: "\u2223",
    shortparallel: "\u2225",
    shy: "\xAD",
    sigma: "\u03C3",
    sigmaf: "\u03C2",
    sigmav: "\u03C2",
    sim: "\u223C",
    simdot: "\u2A6A",
    sime: "\u2243",
    simeq: "\u2243",
    simg: "\u2A9E",
    simgE: "\u2AA0",
    siml: "\u2A9D",
    simlE: "\u2A9F",
    simne: "\u2246",
    simplus: "\u2A24",
    simrarr: "\u2972",
    slarr: "\u2190",
    smallsetminus: "\u2216",
    smashp: "\u2A33",
    smeparsl: "\u29E4",
    smid: "\u2223",
    smile: "\u2323",
    smt: "\u2AAA",
    smte: "\u2AAC",
    smtes: "\u2AAC\uFE00",
    softcy: "\u044C",
    sol: "/",
    solb: "\u29C4",
    solbar: "\u233F",
    sopf: "\u{1D564}",
    spades: "\u2660",
    spadesuit: "\u2660",
    spar: "\u2225",
    sqcap: "\u2293",
    sqcaps: "\u2293\uFE00",
    sqcup: "\u2294",
    sqcups: "\u2294\uFE00",
    sqsub: "\u228F",
    sqsube: "\u2291",
    sqsubset: "\u228F",
    sqsubseteq: "\u2291",
    sqsup: "\u2290",
    sqsupe: "\u2292",
    sqsupset: "\u2290",
    sqsupseteq: "\u2292",
    squ: "\u25A1",
    square: "\u25A1",
    squarf: "\u25AA",
    squf: "\u25AA",
    srarr: "\u2192",
    sscr: "\u{1D4C8}",
    ssetmn: "\u2216",
    ssmile: "\u2323",
    sstarf: "\u22C6",
    star: "\u2606",
    starf: "\u2605",
    straightepsilon: "\u03F5",
    straightphi: "\u03D5",
    strns: "\xAF",
    sub: "\u2282",
    subE: "\u2AC5",
    subdot: "\u2ABD",
    sube: "\u2286",
    subedot: "\u2AC3",
    submult: "\u2AC1",
    subnE: "\u2ACB",
    subne: "\u228A",
    subplus: "\u2ABF",
    subrarr: "\u2979",
    subset: "\u2282",
    subseteq: "\u2286",
    subseteqq: "\u2AC5",
    subsetneq: "\u228A",
    subsetneqq: "\u2ACB",
    subsim: "\u2AC7",
    subsub: "\u2AD5",
    subsup: "\u2AD3",
    succ: "\u227B",
    succapprox: "\u2AB8",
    succcurlyeq: "\u227D",
    succeq: "\u2AB0",
    succnapprox: "\u2ABA",
    succneqq: "\u2AB6",
    succnsim: "\u22E9",
    succsim: "\u227F",
    sum: "\u2211",
    sung: "\u266A",
    sup1: "\xB9",
    sup2: "\xB2",
    sup3: "\xB3",
    sup: "\u2283",
    supE: "\u2AC6",
    supdot: "\u2ABE",
    supdsub: "\u2AD8",
    supe: "\u2287",
    supedot: "\u2AC4",
    suphsol: "\u27C9",
    suphsub: "\u2AD7",
    suplarr: "\u297B",
    supmult: "\u2AC2",
    supnE: "\u2ACC",
    supne: "\u228B",
    supplus: "\u2AC0",
    supset: "\u2283",
    supseteq: "\u2287",
    supseteqq: "\u2AC6",
    supsetneq: "\u228B",
    supsetneqq: "\u2ACC",
    supsim: "\u2AC8",
    supsub: "\u2AD4",
    supsup: "\u2AD6",
    swArr: "\u21D9",
    swarhk: "\u2926",
    swarr: "\u2199",
    swarrow: "\u2199",
    swnwar: "\u292A",
    szlig: "\xDF",
    target: "\u2316",
    tau: "\u03C4",
    tbrk: "\u23B4",
    tcaron: "\u0165",
    tcedil: "\u0163",
    tcy: "\u0442",
    tdot: "\u20DB",
    telrec: "\u2315",
    tfr: "\u{1D531}",
    there4: "\u2234",
    therefore: "\u2234",
    theta: "\u03B8",
    thetasym: "\u03D1",
    thetav: "\u03D1",
    thickapprox: "\u2248",
    thicksim: "\u223C",
    thinsp: "\u2009",
    thkap: "\u2248",
    thksim: "\u223C",
    thorn: "\xFE",
    tilde: "\u02DC",
    times: "\xD7",
    timesb: "\u22A0",
    timesbar: "\u2A31",
    timesd: "\u2A30",
    tint: "\u222D",
    toea: "\u2928",
    top: "\u22A4",
    topbot: "\u2336",
    topcir: "\u2AF1",
    topf: "\u{1D565}",
    topfork: "\u2ADA",
    tosa: "\u2929",
    tprime: "\u2034",
    trade: "\u2122",
    triangle: "\u25B5",
    triangledown: "\u25BF",
    triangleleft: "\u25C3",
    trianglelefteq: "\u22B4",
    triangleq: "\u225C",
    triangleright: "\u25B9",
    trianglerighteq: "\u22B5",
    tridot: "\u25EC",
    trie: "\u225C",
    triminus: "\u2A3A",
    triplus: "\u2A39",
    trisb: "\u29CD",
    tritime: "\u2A3B",
    trpezium: "\u23E2",
    tscr: "\u{1D4C9}",
    tscy: "\u0446",
    tshcy: "\u045B",
    tstrok: "\u0167",
    twixt: "\u226C",
    twoheadleftarrow: "\u219E",
    twoheadrightarrow: "\u21A0",
    uArr: "\u21D1",
    uHar: "\u2963",
    uacute: "\xFA",
    uarr: "\u2191",
    ubrcy: "\u045E",
    ubreve: "\u016D",
    ucirc: "\xFB",
    ucy: "\u0443",
    udarr: "\u21C5",
    udblac: "\u0171",
    udhar: "\u296E",
    ufisht: "\u297E",
    ufr: "\u{1D532}",
    ugrave: "\xF9",
    uharl: "\u21BF",
    uharr: "\u21BE",
    uhblk: "\u2580",
    ulcorn: "\u231C",
    ulcorner: "\u231C",
    ulcrop: "\u230F",
    ultri: "\u25F8",
    umacr: "\u016B",
    uml: "\xA8",
    uogon: "\u0173",
    uopf: "\u{1D566}",
    uparrow: "\u2191",
    updownarrow: "\u2195",
    upharpoonleft: "\u21BF",
    upharpoonright: "\u21BE",
    uplus: "\u228E",
    upsi: "\u03C5",
    upsih: "\u03D2",
    upsilon: "\u03C5",
    upuparrows: "\u21C8",
    urcorn: "\u231D",
    urcorner: "\u231D",
    urcrop: "\u230E",
    uring: "\u016F",
    urtri: "\u25F9",
    uscr: "\u{1D4CA}",
    utdot: "\u22F0",
    utilde: "\u0169",
    utri: "\u25B5",
    utrif: "\u25B4",
    uuarr: "\u21C8",
    uuml: "\xFC",
    uwangle: "\u29A7",
    vArr: "\u21D5",
    vBar: "\u2AE8",
    vBarv: "\u2AE9",
    vDash: "\u22A8",
    vangrt: "\u299C",
    varepsilon: "\u03F5",
    varkappa: "\u03F0",
    varnothing: "\u2205",
    varphi: "\u03D5",
    varpi: "\u03D6",
    varpropto: "\u221D",
    varr: "\u2195",
    varrho: "\u03F1",
    varsigma: "\u03C2",
    varsubsetneq: "\u228A\uFE00",
    varsubsetneqq: "\u2ACB\uFE00",
    varsupsetneq: "\u228B\uFE00",
    varsupsetneqq: "\u2ACC\uFE00",
    vartheta: "\u03D1",
    vartriangleleft: "\u22B2",
    vartriangleright: "\u22B3",
    vcy: "\u0432",
    vdash: "\u22A2",
    vee: "\u2228",
    veebar: "\u22BB",
    veeeq: "\u225A",
    vellip: "\u22EE",
    verbar: "|",
    vert: "|",
    vfr: "\u{1D533}",
    vltri: "\u22B2",
    vnsub: "\u2282\u20D2",
    vnsup: "\u2283\u20D2",
    vopf: "\u{1D567}",
    vprop: "\u221D",
    vrtri: "\u22B3",
    vscr: "\u{1D4CB}",
    vsubnE: "\u2ACB\uFE00",
    vsubne: "\u228A\uFE00",
    vsupnE: "\u2ACC\uFE00",
    vsupne: "\u228B\uFE00",
    vzigzag: "\u299A",
    wcirc: "\u0175",
    wedbar: "\u2A5F",
    wedge: "\u2227",
    wedgeq: "\u2259",
    weierp: "\u2118",
    wfr: "\u{1D534}",
    wopf: "\u{1D568}",
    wp: "\u2118",
    wr: "\u2240",
    wreath: "\u2240",
    wscr: "\u{1D4CC}",
    xcap: "\u22C2",
    xcirc: "\u25EF",
    xcup: "\u22C3",
    xdtri: "\u25BD",
    xfr: "\u{1D535}",
    xhArr: "\u27FA",
    xharr: "\u27F7",
    xi: "\u03BE",
    xlArr: "\u27F8",
    xlarr: "\u27F5",
    xmap: "\u27FC",
    xnis: "\u22FB",
    xodot: "\u2A00",
    xopf: "\u{1D569}",
    xoplus: "\u2A01",
    xotime: "\u2A02",
    xrArr: "\u27F9",
    xrarr: "\u27F6",
    xscr: "\u{1D4CD}",
    xsqcup: "\u2A06",
    xuplus: "\u2A04",
    xutri: "\u25B3",
    xvee: "\u22C1",
    xwedge: "\u22C0",
    yacute: "\xFD",
    yacy: "\u044F",
    ycirc: "\u0177",
    ycy: "\u044B",
    yen: "\xA5",
    yfr: "\u{1D536}",
    yicy: "\u0457",
    yopf: "\u{1D56A}",
    yscr: "\u{1D4CE}",
    yucy: "\u044E",
    yuml: "\xFF",
    zacute: "\u017A",
    zcaron: "\u017E",
    zcy: "\u0437",
    zdot: "\u017C",
    zeetrf: "\u2128",
    zeta: "\u03B6",
    zfr: "\u{1D537}",
    zhcy: "\u0436",
    zigrarr: "\u21DD",
    zopf: "\u{1D56B}",
    zscr: "\u{1D4CF}",
    zwj: "\u200D",
    zwnj: "\u200C"
  };

  // node_modules/decode-named-character-reference/index.js
  var own = {}.hasOwnProperty;
  function decodeNamedCharacterReference(value) {
    return own.call(characterEntities, value) ? characterEntities[value] : false;
  }

  // node_modules/micromark-extension-gfm-autolink-literal/lib/syntax.js
  var wwwPrefix = {
    tokenize: tokenizeWwwPrefix,
    partial: true
  };
  var domain = {
    tokenize: tokenizeDomain,
    partial: true
  };
  var path = {
    tokenize: tokenizePath,
    partial: true
  };
  var trail = {
    tokenize: tokenizeTrail,
    partial: true
  };
  var emailDomainDotTrail = {
    tokenize: tokenizeEmailDomainDotTrail,
    partial: true
  };
  var wwwAutolink = {
    name: "wwwAutolink",
    tokenize: tokenizeWwwAutolink,
    previous: previousWww
  };
  var protocolAutolink = {
    name: "protocolAutolink",
    tokenize: tokenizeProtocolAutolink,
    previous: previousProtocol
  };
  var emailAutolink = {
    name: "emailAutolink",
    tokenize: tokenizeEmailAutolink,
    previous: previousEmail
  };
  var text = {};
  function gfmAutolinkLiteral() {
    return {
      text
    };
  }
  var code = 48;
  while (code < 123) {
    text[code] = emailAutolink;
    code++;
    if (code === 58) code = 65;
    else if (code === 91) code = 97;
  }
  text[43] = emailAutolink;
  text[45] = emailAutolink;
  text[46] = emailAutolink;
  text[95] = emailAutolink;
  text[72] = [emailAutolink, protocolAutolink];
  text[104] = [emailAutolink, protocolAutolink];
  text[87] = [emailAutolink, wwwAutolink];
  text[119] = [emailAutolink, wwwAutolink];
  function tokenizeEmailAutolink(effects, ok, nok) {
    const self = this;
    let dot;
    let data;
    return start;
    function start(code2) {
      if (!gfmAtext(code2) || !previousEmail.call(self, self.previous) || previousUnbalanced(self.events)) {
        return nok(code2);
      }
      effects.enter("literalAutolink");
      effects.enter("literalAutolinkEmail");
      return atext(code2);
    }
    function atext(code2) {
      if (gfmAtext(code2)) {
        effects.consume(code2);
        return atext;
      }
      if (code2 === 64) {
        effects.consume(code2);
        return emailDomain;
      }
      return nok(code2);
    }
    function emailDomain(code2) {
      if (code2 === 46) {
        return effects.check(emailDomainDotTrail, emailDomainAfter, emailDomainDot)(code2);
      }
      if (code2 === 45 || code2 === 95 || asciiAlphanumeric(code2)) {
        data = true;
        effects.consume(code2);
        return emailDomain;
      }
      return emailDomainAfter(code2);
    }
    function emailDomainDot(code2) {
      effects.consume(code2);
      dot = true;
      return emailDomain;
    }
    function emailDomainAfter(code2) {
      if (data && dot && asciiAlpha(self.previous)) {
        effects.exit("literalAutolinkEmail");
        effects.exit("literalAutolink");
        return ok(code2);
      }
      return nok(code2);
    }
  }
  function tokenizeWwwAutolink(effects, ok, nok) {
    const self = this;
    return wwwStart;
    function wwwStart(code2) {
      if (code2 !== 87 && code2 !== 119 || !previousWww.call(self, self.previous) || previousUnbalanced(self.events)) {
        return nok(code2);
      }
      effects.enter("literalAutolink");
      effects.enter("literalAutolinkWww");
      return effects.check(wwwPrefix, effects.attempt(domain, effects.attempt(path, wwwAfter), nok), nok)(code2);
    }
    function wwwAfter(code2) {
      effects.exit("literalAutolinkWww");
      effects.exit("literalAutolink");
      return ok(code2);
    }
  }
  function tokenizeProtocolAutolink(effects, ok, nok) {
    const self = this;
    let buffer = "";
    let seen = false;
    return protocolStart;
    function protocolStart(code2) {
      if ((code2 === 72 || code2 === 104) && previousProtocol.call(self, self.previous) && !previousUnbalanced(self.events)) {
        effects.enter("literalAutolink");
        effects.enter("literalAutolinkHttp");
        buffer += String.fromCodePoint(code2);
        effects.consume(code2);
        return protocolPrefixInside;
      }
      return nok(code2);
    }
    function protocolPrefixInside(code2) {
      if (asciiAlpha(code2) && buffer.length < 5) {
        buffer += String.fromCodePoint(code2);
        effects.consume(code2);
        return protocolPrefixInside;
      }
      if (code2 === 58) {
        const protocol = buffer.toLowerCase();
        if (protocol === "http" || protocol === "https") {
          effects.consume(code2);
          return protocolSlashesInside;
        }
      }
      return nok(code2);
    }
    function protocolSlashesInside(code2) {
      if (code2 === 47) {
        effects.consume(code2);
        if (seen) {
          return afterProtocol;
        }
        seen = true;
        return protocolSlashesInside;
      }
      return nok(code2);
    }
    function afterProtocol(code2) {
      return code2 === null || asciiControl(code2) || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2) || unicodePunctuation(code2) ? nok(code2) : effects.attempt(domain, effects.attempt(path, protocolAfter), nok)(code2);
    }
    function protocolAfter(code2) {
      effects.exit("literalAutolinkHttp");
      effects.exit("literalAutolink");
      return ok(code2);
    }
  }
  function tokenizeWwwPrefix(effects, ok, nok) {
    let size = 0;
    return wwwPrefixInside;
    function wwwPrefixInside(code2) {
      if ((code2 === 87 || code2 === 119) && size < 3) {
        size++;
        effects.consume(code2);
        return wwwPrefixInside;
      }
      if (code2 === 46 && size === 3) {
        effects.consume(code2);
        return wwwPrefixAfter;
      }
      return nok(code2);
    }
    function wwwPrefixAfter(code2) {
      return code2 === null ? nok(code2) : ok(code2);
    }
  }
  function tokenizeDomain(effects, ok, nok) {
    let underscoreInLastSegment;
    let underscoreInLastLastSegment;
    let seen;
    return domainInside;
    function domainInside(code2) {
      if (code2 === 46 || code2 === 95) {
        return effects.check(trail, domainAfter, domainAtPunctuation)(code2);
      }
      if (code2 === null || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2) || code2 !== 45 && unicodePunctuation(code2)) {
        return domainAfter(code2);
      }
      seen = true;
      effects.consume(code2);
      return domainInside;
    }
    function domainAtPunctuation(code2) {
      if (code2 === 95) {
        underscoreInLastSegment = true;
      } else {
        underscoreInLastLastSegment = underscoreInLastSegment;
        underscoreInLastSegment = void 0;
      }
      effects.consume(code2);
      return domainInside;
    }
    function domainAfter(code2) {
      if (underscoreInLastLastSegment || underscoreInLastSegment || !seen) {
        return nok(code2);
      }
      return ok(code2);
    }
  }
  function tokenizePath(effects, ok) {
    let sizeOpen = 0;
    let sizeClose = 0;
    return pathInside;
    function pathInside(code2) {
      if (code2 === 40) {
        sizeOpen++;
        effects.consume(code2);
        return pathInside;
      }
      if (code2 === 41 && sizeClose < sizeOpen) {
        return pathAtPunctuation(code2);
      }
      if (code2 === 33 || code2 === 34 || code2 === 38 || code2 === 39 || code2 === 41 || code2 === 42 || code2 === 44 || code2 === 46 || code2 === 58 || code2 === 59 || code2 === 60 || code2 === 63 || code2 === 93 || code2 === 95 || code2 === 126) {
        return effects.check(trail, ok, pathAtPunctuation)(code2);
      }
      if (code2 === null || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2)) {
        return ok(code2);
      }
      effects.consume(code2);
      return pathInside;
    }
    function pathAtPunctuation(code2) {
      if (code2 === 41) {
        sizeClose++;
      }
      effects.consume(code2);
      return pathInside;
    }
  }
  function tokenizeTrail(effects, ok, nok) {
    return trail2;
    function trail2(code2) {
      if (code2 === 33 || code2 === 34 || code2 === 39 || code2 === 41 || code2 === 42 || code2 === 44 || code2 === 46 || code2 === 58 || code2 === 59 || code2 === 63 || code2 === 95 || code2 === 126) {
        effects.consume(code2);
        return trail2;
      }
      if (code2 === 38) {
        effects.consume(code2);
        return trailCharacterReferenceStart;
      }
      if (code2 === 93) {
        effects.consume(code2);
        return trailBracketAfter;
      }
      if (
        // `<` is an end.
        code2 === 60 || // So is whitespace.
        code2 === null || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2)
      ) {
        return ok(code2);
      }
      return nok(code2);
    }
    function trailBracketAfter(code2) {
      if (code2 === null || code2 === 40 || code2 === 91 || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2)) {
        return ok(code2);
      }
      return trail2(code2);
    }
    function trailCharacterReferenceStart(code2) {
      return asciiAlpha(code2) ? trailCharacterReferenceInside(code2) : nok(code2);
    }
    function trailCharacterReferenceInside(code2) {
      if (code2 === 59) {
        effects.consume(code2);
        return trail2;
      }
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        return trailCharacterReferenceInside;
      }
      return nok(code2);
    }
  }
  function tokenizeEmailDomainDotTrail(effects, ok, nok) {
    return start;
    function start(code2) {
      effects.consume(code2);
      return after;
    }
    function after(code2) {
      return asciiAlphanumeric(code2) ? nok(code2) : ok(code2);
    }
  }
  function previousWww(code2) {
    return code2 === null || code2 === 40 || code2 === 42 || code2 === 95 || code2 === 91 || code2 === 93 || code2 === 126 || markdownLineEndingOrSpace(code2);
  }
  function previousProtocol(code2) {
    return !asciiAlpha(code2);
  }
  function previousEmail(code2) {
    return !(code2 === 47 || gfmAtext(code2));
  }
  function gfmAtext(code2) {
    return code2 === 43 || code2 === 45 || code2 === 46 || code2 === 95 || asciiAlphanumeric(code2);
  }
  function previousUnbalanced(events) {
    let index = events.length;
    let result = false;
    while (index--) {
      const token = events[index][1];
      if ((token.type === "labelLink" || token.type === "labelImage") && !token._balanced) {
        result = true;
        break;
      }
      if (token._gfmAutolinkLiteralWalkedInto) {
        result = false;
        break;
      }
    }
    if (events.length > 0 && !result) {
      events[events.length - 1][1]._gfmAutolinkLiteralWalkedInto = true;
    }
    return result;
  }

  // node_modules/micromark-util-chunked/index.js
  function splice(list2, start, remove, items) {
    const end = list2.length;
    let chunkStart = 0;
    let parameters;
    if (start < 0) {
      start = -start > end ? 0 : end + start;
    } else {
      start = start > end ? end : start;
    }
    remove = remove > 0 ? remove : 0;
    if (items.length < 1e4) {
      parameters = Array.from(items);
      parameters.unshift(start, remove);
      list2.splice(...parameters);
    } else {
      if (remove) list2.splice(start, remove);
      while (chunkStart < items.length) {
        parameters = items.slice(chunkStart, chunkStart + 1e4);
        parameters.unshift(start, 0);
        list2.splice(...parameters);
        chunkStart += 1e4;
        start += 1e4;
      }
    }
  }
  function push(list2, items) {
    if (list2.length > 0) {
      splice(list2, list2.length, 0, items);
      return list2;
    }
    return items;
  }

  // node_modules/micromark-util-classify-character/index.js
  function classifyCharacter(code2) {
    if (code2 === null || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2)) {
      return 1;
    }
    if (unicodePunctuation(code2)) {
      return 2;
    }
  }

  // node_modules/micromark-util-resolve-all/index.js
  function resolveAll(constructs2, events, context) {
    const called = [];
    let index = -1;
    while (++index < constructs2.length) {
      const resolve = constructs2[index].resolveAll;
      if (resolve && !called.includes(resolve)) {
        events = resolve(events, context);
        called.push(resolve);
      }
    }
    return events;
  }

  // node_modules/micromark-core-commonmark/lib/attention.js
  var attention = {
    name: "attention",
    resolveAll: resolveAllAttention,
    tokenize: tokenizeAttention
  };
  function resolveAllAttention(events, context) {
    let index = -1;
    let open;
    let group;
    let text4;
    let openingSequence;
    let closingSequence;
    let use;
    let nextEvents;
    let offset;
    while (++index < events.length) {
      if (events[index][0] === "enter" && events[index][1].type === "attentionSequence" && events[index][1]._close) {
        open = index;
        while (open--) {
          if (events[open][0] === "exit" && events[open][1].type === "attentionSequence" && events[open][1]._open && // If the markers are the same:
          context.sliceSerialize(events[open][1]).charCodeAt(0) === context.sliceSerialize(events[index][1]).charCodeAt(0)) {
            if ((events[open][1]._close || events[index][1]._open) && (events[index][1].end.offset - events[index][1].start.offset) % 3 && !((events[open][1].end.offset - events[open][1].start.offset + events[index][1].end.offset - events[index][1].start.offset) % 3)) {
              continue;
            }
            use = events[open][1].end.offset - events[open][1].start.offset > 1 && events[index][1].end.offset - events[index][1].start.offset > 1 ? 2 : 1;
            const start = {
              ...events[open][1].end
            };
            const end = {
              ...events[index][1].start
            };
            movePoint(start, -use);
            movePoint(end, use);
            openingSequence = {
              type: use > 1 ? "strongSequence" : "emphasisSequence",
              start,
              end: {
                ...events[open][1].end
              }
            };
            closingSequence = {
              type: use > 1 ? "strongSequence" : "emphasisSequence",
              start: {
                ...events[index][1].start
              },
              end
            };
            text4 = {
              type: use > 1 ? "strongText" : "emphasisText",
              start: {
                ...events[open][1].end
              },
              end: {
                ...events[index][1].start
              }
            };
            group = {
              type: use > 1 ? "strong" : "emphasis",
              start: {
                ...openingSequence.start
              },
              end: {
                ...closingSequence.end
              }
            };
            events[open][1].end = {
              ...openingSequence.start
            };
            events[index][1].start = {
              ...closingSequence.end
            };
            nextEvents = [];
            if (events[open][1].end.offset - events[open][1].start.offset) {
              nextEvents = push(nextEvents, [["enter", events[open][1], context], ["exit", events[open][1], context]]);
            }
            nextEvents = push(nextEvents, [["enter", group, context], ["enter", openingSequence, context], ["exit", openingSequence, context], ["enter", text4, context]]);
            nextEvents = push(nextEvents, resolveAll(context.parser.constructs.insideSpan.null, events.slice(open + 1, index), context));
            nextEvents = push(nextEvents, [["exit", text4, context], ["enter", closingSequence, context], ["exit", closingSequence, context], ["exit", group, context]]);
            if (events[index][1].end.offset - events[index][1].start.offset) {
              offset = 2;
              nextEvents = push(nextEvents, [["enter", events[index][1], context], ["exit", events[index][1], context]]);
            } else {
              offset = 0;
            }
            splice(events, open - 1, index - open + 3, nextEvents);
            index = open + nextEvents.length - offset - 2;
            break;
          }
        }
      }
    }
    index = -1;
    while (++index < events.length) {
      if (events[index][1].type === "attentionSequence") {
        events[index][1].type = "data";
      }
    }
    return events;
  }
  function tokenizeAttention(effects, ok) {
    const attentionMarkers2 = this.parser.constructs.attentionMarkers.null;
    const previous4 = this.previous;
    const before = classifyCharacter(previous4);
    let marker;
    return start;
    function start(code2) {
      marker = code2;
      effects.enter("attentionSequence");
      return inside(code2);
    }
    function inside(code2) {
      if (code2 === marker) {
        effects.consume(code2);
        return inside;
      }
      const token = effects.exit("attentionSequence");
      const after = classifyCharacter(code2);
      const open = !after || after === 2 && before || attentionMarkers2.includes(code2);
      const close = !before || before === 2 && after || attentionMarkers2.includes(previous4);
      token._open = Boolean(marker === 42 ? open : open && (before || !close));
      token._close = Boolean(marker === 42 ? close : close && (after || !open));
      return ok(code2);
    }
  }
  function movePoint(point, offset) {
    point.column += offset;
    point.offset += offset;
    point._bufferIndex += offset;
  }

  // node_modules/micromark-core-commonmark/lib/autolink.js
  var autolink = {
    name: "autolink",
    tokenize: tokenizeAutolink
  };
  function tokenizeAutolink(effects, ok, nok) {
    let size = 0;
    return start;
    function start(code2) {
      effects.enter("autolink");
      effects.enter("autolinkMarker");
      effects.consume(code2);
      effects.exit("autolinkMarker");
      effects.enter("autolinkProtocol");
      return open;
    }
    function open(code2) {
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        return schemeOrEmailAtext;
      }
      if (code2 === 64) {
        return nok(code2);
      }
      return emailAtext(code2);
    }
    function schemeOrEmailAtext(code2) {
      if (code2 === 43 || code2 === 45 || code2 === 46 || asciiAlphanumeric(code2)) {
        size = 1;
        return schemeInsideOrEmailAtext(code2);
      }
      return emailAtext(code2);
    }
    function schemeInsideOrEmailAtext(code2) {
      if (code2 === 58) {
        effects.consume(code2);
        size = 0;
        return urlInside;
      }
      if ((code2 === 43 || code2 === 45 || code2 === 46 || asciiAlphanumeric(code2)) && size++ < 32) {
        effects.consume(code2);
        return schemeInsideOrEmailAtext;
      }
      size = 0;
      return emailAtext(code2);
    }
    function urlInside(code2) {
      if (code2 === 62) {
        effects.exit("autolinkProtocol");
        effects.enter("autolinkMarker");
        effects.consume(code2);
        effects.exit("autolinkMarker");
        effects.exit("autolink");
        return ok;
      }
      if (code2 === null || code2 === 32 || code2 === 60 || asciiControl(code2)) {
        return nok(code2);
      }
      effects.consume(code2);
      return urlInside;
    }
    function emailAtext(code2) {
      if (code2 === 64) {
        effects.consume(code2);
        return emailAtSignOrDot;
      }
      if (asciiAtext(code2)) {
        effects.consume(code2);
        return emailAtext;
      }
      return nok(code2);
    }
    function emailAtSignOrDot(code2) {
      return asciiAlphanumeric(code2) ? emailLabel(code2) : nok(code2);
    }
    function emailLabel(code2) {
      if (code2 === 46) {
        effects.consume(code2);
        size = 0;
        return emailAtSignOrDot;
      }
      if (code2 === 62) {
        effects.exit("autolinkProtocol").type = "autolinkEmail";
        effects.enter("autolinkMarker");
        effects.consume(code2);
        effects.exit("autolinkMarker");
        effects.exit("autolink");
        return ok;
      }
      return emailValue(code2);
    }
    function emailValue(code2) {
      if ((code2 === 45 || asciiAlphanumeric(code2)) && size++ < 63) {
        const next = code2 === 45 ? emailValue : emailLabel;
        effects.consume(code2);
        return next;
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/blank-line.js
  var blankLine = {
    partial: true,
    tokenize: tokenizeBlankLine
  };
  function tokenizeBlankLine(effects, ok, nok) {
    return start;
    function start(code2) {
      return markdownSpace(code2) ? factorySpace(effects, after, "linePrefix")(code2) : after(code2);
    }
    function after(code2) {
      return code2 === null || markdownLineEnding(code2) ? ok(code2) : nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/block-quote.js
  var blockQuote = {
    continuation: {
      tokenize: tokenizeBlockQuoteContinuation
    },
    exit,
    name: "blockQuote",
    tokenize: tokenizeBlockQuoteStart
  };
  function tokenizeBlockQuoteStart(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      if (code2 === 62) {
        const state = self.containerState;
        if (!state.open) {
          effects.enter("blockQuote", {
            _container: true
          });
          state.open = true;
        }
        effects.enter("blockQuotePrefix");
        effects.enter("blockQuoteMarker");
        effects.consume(code2);
        effects.exit("blockQuoteMarker");
        return after;
      }
      return nok(code2);
    }
    function after(code2) {
      if (markdownSpace(code2)) {
        effects.enter("blockQuotePrefixWhitespace");
        effects.consume(code2);
        effects.exit("blockQuotePrefixWhitespace");
        effects.exit("blockQuotePrefix");
        return ok;
      }
      effects.exit("blockQuotePrefix");
      return ok(code2);
    }
  }
  function tokenizeBlockQuoteContinuation(effects, ok, nok) {
    const self = this;
    return contStart;
    function contStart(code2) {
      if (markdownSpace(code2)) {
        return factorySpace(effects, contBefore, "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4)(code2);
      }
      return contBefore(code2);
    }
    function contBefore(code2) {
      return effects.attempt(blockQuote, ok, nok)(code2);
    }
  }
  function exit(effects) {
    effects.exit("blockQuote");
  }

  // node_modules/micromark-core-commonmark/lib/character-escape.js
  var characterEscape = {
    name: "characterEscape",
    tokenize: tokenizeCharacterEscape
  };
  function tokenizeCharacterEscape(effects, ok, nok) {
    return start;
    function start(code2) {
      effects.enter("characterEscape");
      effects.enter("escapeMarker");
      effects.consume(code2);
      effects.exit("escapeMarker");
      return inside;
    }
    function inside(code2) {
      if (asciiPunctuation(code2)) {
        effects.enter("characterEscapeValue");
        effects.consume(code2);
        effects.exit("characterEscapeValue");
        effects.exit("characterEscape");
        return ok;
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/character-reference.js
  var characterReference = {
    name: "characterReference",
    tokenize: tokenizeCharacterReference
  };
  function tokenizeCharacterReference(effects, ok, nok) {
    const self = this;
    let size = 0;
    let max;
    let test;
    return start;
    function start(code2) {
      effects.enter("characterReference");
      effects.enter("characterReferenceMarker");
      effects.consume(code2);
      effects.exit("characterReferenceMarker");
      return open;
    }
    function open(code2) {
      if (code2 === 35) {
        effects.enter("characterReferenceMarkerNumeric");
        effects.consume(code2);
        effects.exit("characterReferenceMarkerNumeric");
        return numeric;
      }
      effects.enter("characterReferenceValue");
      max = 31;
      test = asciiAlphanumeric;
      return value(code2);
    }
    function numeric(code2) {
      if (code2 === 88 || code2 === 120) {
        effects.enter("characterReferenceMarkerHexadecimal");
        effects.consume(code2);
        effects.exit("characterReferenceMarkerHexadecimal");
        effects.enter("characterReferenceValue");
        max = 6;
        test = asciiHexDigit;
        return value;
      }
      effects.enter("characterReferenceValue");
      max = 7;
      test = asciiDigit;
      return value(code2);
    }
    function value(code2) {
      if (code2 === 59 && size) {
        const token = effects.exit("characterReferenceValue");
        if (test === asciiAlphanumeric && !decodeNamedCharacterReference(self.sliceSerialize(token))) {
          return nok(code2);
        }
        effects.enter("characterReferenceMarker");
        effects.consume(code2);
        effects.exit("characterReferenceMarker");
        effects.exit("characterReference");
        return ok;
      }
      if (test(code2) && size++ < max) {
        effects.consume(code2);
        return value;
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/code-fenced.js
  var nonLazyContinuation = {
    partial: true,
    tokenize: tokenizeNonLazyContinuation
  };
  var codeFenced = {
    concrete: true,
    name: "codeFenced",
    tokenize: tokenizeCodeFenced
  };
  function tokenizeCodeFenced(effects, ok, nok) {
    const self = this;
    const closeStart = {
      partial: true,
      tokenize: tokenizeCloseStart
    };
    let initialPrefix = 0;
    let sizeOpen = 0;
    let marker;
    return start;
    function start(code2) {
      return beforeSequenceOpen(code2);
    }
    function beforeSequenceOpen(code2) {
      const tail = self.events[self.events.length - 1];
      initialPrefix = tail && tail[1].type === "linePrefix" ? tail[2].sliceSerialize(tail[1], true).length : 0;
      marker = code2;
      effects.enter("codeFenced");
      effects.enter("codeFencedFence");
      effects.enter("codeFencedFenceSequence");
      return sequenceOpen(code2);
    }
    function sequenceOpen(code2) {
      if (code2 === marker) {
        sizeOpen++;
        effects.consume(code2);
        return sequenceOpen;
      }
      if (sizeOpen < 3) {
        return nok(code2);
      }
      effects.exit("codeFencedFenceSequence");
      return markdownSpace(code2) ? factorySpace(effects, infoBefore, "whitespace")(code2) : infoBefore(code2);
    }
    function infoBefore(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("codeFencedFence");
        return self.interrupt ? ok(code2) : effects.check(nonLazyContinuation, atNonLazyBreak, after)(code2);
      }
      effects.enter("codeFencedFenceInfo");
      effects.enter("chunkString", {
        contentType: "string"
      });
      return info(code2);
    }
    function info(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("chunkString");
        effects.exit("codeFencedFenceInfo");
        return infoBefore(code2);
      }
      if (markdownSpace(code2)) {
        effects.exit("chunkString");
        effects.exit("codeFencedFenceInfo");
        return factorySpace(effects, metaBefore, "whitespace")(code2);
      }
      if (code2 === 96 && code2 === marker) {
        return nok(code2);
      }
      effects.consume(code2);
      return info;
    }
    function metaBefore(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        return infoBefore(code2);
      }
      effects.enter("codeFencedFenceMeta");
      effects.enter("chunkString", {
        contentType: "string"
      });
      return meta(code2);
    }
    function meta(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("chunkString");
        effects.exit("codeFencedFenceMeta");
        return infoBefore(code2);
      }
      if (code2 === 96 && code2 === marker) {
        return nok(code2);
      }
      effects.consume(code2);
      return meta;
    }
    function atNonLazyBreak(code2) {
      return effects.attempt(closeStart, after, contentBefore)(code2);
    }
    function contentBefore(code2) {
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return contentStart;
    }
    function contentStart(code2) {
      return initialPrefix > 0 && markdownSpace(code2) ? factorySpace(effects, beforeContentChunk, "linePrefix", initialPrefix + 1)(code2) : beforeContentChunk(code2);
    }
    function beforeContentChunk(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        return effects.check(nonLazyContinuation, atNonLazyBreak, after)(code2);
      }
      effects.enter("codeFlowValue");
      return contentChunk(code2);
    }
    function contentChunk(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("codeFlowValue");
        return beforeContentChunk(code2);
      }
      effects.consume(code2);
      return contentChunk;
    }
    function after(code2) {
      effects.exit("codeFenced");
      return ok(code2);
    }
    function tokenizeCloseStart(effects2, ok2, nok2) {
      let size = 0;
      return startBefore;
      function startBefore(code2) {
        effects2.enter("lineEnding");
        effects2.consume(code2);
        effects2.exit("lineEnding");
        return start2;
      }
      function start2(code2) {
        effects2.enter("codeFencedFence");
        return markdownSpace(code2) ? factorySpace(effects2, beforeSequenceClose, "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4)(code2) : beforeSequenceClose(code2);
      }
      function beforeSequenceClose(code2) {
        if (code2 === marker) {
          effects2.enter("codeFencedFenceSequence");
          return sequenceClose(code2);
        }
        return nok2(code2);
      }
      function sequenceClose(code2) {
        if (code2 === marker) {
          size++;
          effects2.consume(code2);
          return sequenceClose;
        }
        if (size >= sizeOpen) {
          effects2.exit("codeFencedFenceSequence");
          return markdownSpace(code2) ? factorySpace(effects2, sequenceCloseAfter, "whitespace")(code2) : sequenceCloseAfter(code2);
        }
        return nok2(code2);
      }
      function sequenceCloseAfter(code2) {
        if (code2 === null || markdownLineEnding(code2)) {
          effects2.exit("codeFencedFence");
          return ok2(code2);
        }
        return nok2(code2);
      }
    }
  }
  function tokenizeNonLazyContinuation(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      if (code2 === null) {
        return nok(code2);
      }
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return lineStart;
    }
    function lineStart(code2) {
      return self.parser.lazy[self.now().line] ? nok(code2) : ok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/code-indented.js
  var codeIndented = {
    name: "codeIndented",
    tokenize: tokenizeCodeIndented
  };
  var furtherStart = {
    partial: true,
    tokenize: tokenizeFurtherStart
  };
  function tokenizeCodeIndented(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      effects.enter("codeIndented");
      return factorySpace(effects, afterPrefix, "linePrefix", 4 + 1)(code2);
    }
    function afterPrefix(code2) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === "linePrefix" && tail[2].sliceSerialize(tail[1], true).length >= 4 ? atBreak(code2) : nok(code2);
    }
    function atBreak(code2) {
      if (code2 === null) {
        return after(code2);
      }
      if (markdownLineEnding(code2)) {
        return effects.attempt(furtherStart, atBreak, after)(code2);
      }
      effects.enter("codeFlowValue");
      return inside(code2);
    }
    function inside(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("codeFlowValue");
        return atBreak(code2);
      }
      effects.consume(code2);
      return inside;
    }
    function after(code2) {
      effects.exit("codeIndented");
      return ok(code2);
    }
  }
  function tokenizeFurtherStart(effects, ok, nok) {
    const self = this;
    return furtherStart2;
    function furtherStart2(code2) {
      if (self.parser.lazy[self.now().line]) {
        return nok(code2);
      }
      if (markdownLineEnding(code2)) {
        effects.enter("lineEnding");
        effects.consume(code2);
        effects.exit("lineEnding");
        return furtherStart2;
      }
      return factorySpace(effects, afterPrefix, "linePrefix", 4 + 1)(code2);
    }
    function afterPrefix(code2) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === "linePrefix" && tail[2].sliceSerialize(tail[1], true).length >= 4 ? ok(code2) : markdownLineEnding(code2) ? furtherStart2(code2) : nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/code-text.js
  var codeText = {
    name: "codeText",
    previous: previous2,
    resolve: resolveCodeText,
    tokenize: tokenizeCodeText
  };
  function resolveCodeText(events) {
    let tailExitIndex = events.length - 4;
    let headEnterIndex = 3;
    let index;
    let enter;
    if ((events[headEnterIndex][1].type === "lineEnding" || events[headEnterIndex][1].type === "space") && (events[tailExitIndex][1].type === "lineEnding" || events[tailExitIndex][1].type === "space")) {
      index = headEnterIndex;
      while (++index < tailExitIndex) {
        if (events[index][1].type === "codeTextData") {
          events[headEnterIndex][1].type = "codeTextPadding";
          events[tailExitIndex][1].type = "codeTextPadding";
          headEnterIndex += 2;
          tailExitIndex -= 2;
          break;
        }
      }
    }
    index = headEnterIndex - 1;
    tailExitIndex++;
    while (++index <= tailExitIndex) {
      if (enter === void 0) {
        if (index !== tailExitIndex && events[index][1].type !== "lineEnding") {
          enter = index;
        }
      } else if (index === tailExitIndex || events[index][1].type === "lineEnding") {
        events[enter][1].type = "codeTextData";
        if (index !== enter + 2) {
          events[enter][1].end = events[index - 1][1].end;
          events.splice(enter + 2, index - enter - 2);
          tailExitIndex -= index - enter - 2;
          index = enter + 2;
        }
        enter = void 0;
      }
    }
    return events;
  }
  function previous2(code2) {
    return code2 !== 96 || this.events[this.events.length - 1][1].type === "characterEscape";
  }
  function tokenizeCodeText(effects, ok, nok) {
    const self = this;
    let sizeOpen = 0;
    let size;
    let token;
    return start;
    function start(code2) {
      effects.enter("codeText");
      effects.enter("codeTextSequence");
      return sequenceOpen(code2);
    }
    function sequenceOpen(code2) {
      if (code2 === 96) {
        effects.consume(code2);
        sizeOpen++;
        return sequenceOpen;
      }
      effects.exit("codeTextSequence");
      return between(code2);
    }
    function between(code2) {
      if (code2 === null) {
        return nok(code2);
      }
      if (code2 === 32) {
        effects.enter("space");
        effects.consume(code2);
        effects.exit("space");
        return between;
      }
      if (code2 === 96) {
        token = effects.enter("codeTextSequence");
        size = 0;
        return sequenceClose(code2);
      }
      if (markdownLineEnding(code2)) {
        effects.enter("lineEnding");
        effects.consume(code2);
        effects.exit("lineEnding");
        return between;
      }
      effects.enter("codeTextData");
      return data(code2);
    }
    function data(code2) {
      if (code2 === null || code2 === 32 || code2 === 96 || markdownLineEnding(code2)) {
        effects.exit("codeTextData");
        return between(code2);
      }
      effects.consume(code2);
      return data;
    }
    function sequenceClose(code2) {
      if (code2 === 96) {
        effects.consume(code2);
        size++;
        return sequenceClose;
      }
      if (size === sizeOpen) {
        effects.exit("codeTextSequence");
        effects.exit("codeText");
        return ok(code2);
      }
      token.type = "codeTextData";
      return data(code2);
    }
  }

  // node_modules/micromark-util-subtokenize/lib/splice-buffer.js
  var SpliceBuffer = class {
    /**
     * @param {ReadonlyArray<T> | null | undefined} [initial]
     *   Initial items (optional).
     * @returns
     *   Splice buffer.
     */
    constructor(initial) {
      this.left = initial ? [...initial] : [];
      this.right = [];
    }
    /**
     * Array access;
     * does not move the cursor.
     *
     * @param {number} index
     *   Index.
     * @return {T}
     *   Item.
     */
    get(index) {
      if (index < 0 || index >= this.left.length + this.right.length) {
        throw new RangeError("Cannot access index `" + index + "` in a splice buffer of size `" + (this.left.length + this.right.length) + "`");
      }
      if (index < this.left.length) return this.left[index];
      return this.right[this.right.length - index + this.left.length - 1];
    }
    /**
     * The length of the splice buffer, one greater than the largest index in the
     * array.
     */
    get length() {
      return this.left.length + this.right.length;
    }
    /**
     * Remove and return `list[0]`;
     * moves the cursor to `0`.
     *
     * @returns {T | undefined}
     *   Item, optional.
     */
    shift() {
      this.setCursor(0);
      return this.right.pop();
    }
    /**
     * Slice the buffer to get an array;
     * does not move the cursor.
     *
     * @param {number} start
     *   Start.
     * @param {number | null | undefined} [end]
     *   End (optional).
     * @returns {Array<T>}
     *   Array of items.
     */
    slice(start, end) {
      const stop = end === null || end === void 0 ? Number.POSITIVE_INFINITY : end;
      if (stop < this.left.length) {
        return this.left.slice(start, stop);
      }
      if (start > this.left.length) {
        return this.right.slice(this.right.length - stop + this.left.length, this.right.length - start + this.left.length).reverse();
      }
      return this.left.slice(start).concat(this.right.slice(this.right.length - stop + this.left.length).reverse());
    }
    /**
     * Mimics the behavior of Array.prototype.splice() except for the change of
     * interface necessary to avoid segfaults when patching in very large arrays.
     *
     * This operation moves cursor is moved to `start` and results in the cursor
     * placed after any inserted items.
     *
     * @param {number} start
     *   Start;
     *   zero-based index at which to start changing the array;
     *   negative numbers count backwards from the end of the array and values
     *   that are out-of bounds are clamped to the appropriate end of the array.
     * @param {number | null | undefined} [deleteCount=0]
     *   Delete count (default: `0`);
     *   maximum number of elements to delete, starting from start.
     * @param {Array<T> | null | undefined} [items=[]]
     *   Items to include in place of the deleted items (default: `[]`).
     * @return {Array<T>}
     *   Any removed items.
     */
    splice(start, deleteCount, items) {
      const count = deleteCount || 0;
      this.setCursor(Math.trunc(start));
      const removed = this.right.splice(this.right.length - count, Number.POSITIVE_INFINITY);
      if (items) chunkedPush(this.left, items);
      return removed.reverse();
    }
    /**
     * Remove and return the highest-numbered item in the array, so
     * `list[list.length - 1]`;
     * Moves the cursor to `length`.
     *
     * @returns {T | undefined}
     *   Item, optional.
     */
    pop() {
      this.setCursor(Number.POSITIVE_INFINITY);
      return this.left.pop();
    }
    /**
     * Inserts a single item to the high-numbered side of the array;
     * moves the cursor to `length`.
     *
     * @param {T} item
     *   Item.
     * @returns {undefined}
     *   Nothing.
     */
    push(item) {
      this.setCursor(Number.POSITIVE_INFINITY);
      this.left.push(item);
    }
    /**
     * Inserts many items to the high-numbered side of the array.
     * Moves the cursor to `length`.
     *
     * @param {Array<T>} items
     *   Items.
     * @returns {undefined}
     *   Nothing.
     */
    pushMany(items) {
      this.setCursor(Number.POSITIVE_INFINITY);
      chunkedPush(this.left, items);
    }
    /**
     * Inserts a single item to the low-numbered side of the array;
     * Moves the cursor to `0`.
     *
     * @param {T} item
     *   Item.
     * @returns {undefined}
     *   Nothing.
     */
    unshift(item) {
      this.setCursor(0);
      this.right.push(item);
    }
    /**
     * Inserts many items to the low-numbered side of the array;
     * moves the cursor to `0`.
     *
     * @param {Array<T>} items
     *   Items.
     * @returns {undefined}
     *   Nothing.
     */
    unshiftMany(items) {
      this.setCursor(0);
      chunkedPush(this.right, items.reverse());
    }
    /**
     * Move the cursor to a specific position in the array. Requires
     * time proportional to the distance moved.
     *
     * If `n < 0`, the cursor will end up at the beginning.
     * If `n > length`, the cursor will end up at the end.
     *
     * @param {number} n
     *   Position.
     * @return {undefined}
     *   Nothing.
     */
    setCursor(n) {
      if (n === this.left.length || n > this.left.length && this.right.length === 0 || n < 0 && this.left.length === 0) return;
      if (n < this.left.length) {
        const removed = this.left.splice(n, Number.POSITIVE_INFINITY);
        chunkedPush(this.right, removed.reverse());
      } else {
        const removed = this.right.splice(this.left.length + this.right.length - n, Number.POSITIVE_INFINITY);
        chunkedPush(this.left, removed.reverse());
      }
    }
  };
  function chunkedPush(list2, right) {
    let chunkStart = 0;
    if (right.length < 1e4) {
      list2.push(...right);
    } else {
      while (chunkStart < right.length) {
        list2.push(...right.slice(chunkStart, chunkStart + 1e4));
        chunkStart += 1e4;
      }
    }
  }

  // node_modules/micromark-util-subtokenize/index.js
  function subtokenize(eventsArray) {
    const jumps = {};
    let index = -1;
    let event;
    let lineIndex;
    let otherIndex;
    let otherEvent;
    let parameters;
    let subevents;
    let more;
    const events = new SpliceBuffer(eventsArray);
    while (++index < events.length) {
      while (index in jumps) {
        index = jumps[index];
      }
      event = events.get(index);
      if (index && event[1].type === "chunkFlow" && events.get(index - 1)[1].type === "listItemPrefix") {
        subevents = event[1]._tokenizer.events;
        otherIndex = 0;
        if (otherIndex < subevents.length && subevents[otherIndex][1].type === "lineEndingBlank") {
          otherIndex += 2;
        }
        if (otherIndex < subevents.length && subevents[otherIndex][1].type === "content") {
          while (++otherIndex < subevents.length) {
            if (subevents[otherIndex][1].type === "content") {
              break;
            }
            if (subevents[otherIndex][1].type === "chunkText") {
              subevents[otherIndex][1]._isInFirstContentOfListItem = true;
              otherIndex++;
            }
          }
        }
      }
      if (event[0] === "enter") {
        if (event[1].contentType) {
          Object.assign(jumps, subcontent(events, index));
          index = jumps[index];
          more = true;
        }
      } else if (event[1]._container) {
        otherIndex = index;
        lineIndex = void 0;
        while (otherIndex--) {
          otherEvent = events.get(otherIndex);
          if (otherEvent[1].type === "lineEnding" || otherEvent[1].type === "lineEndingBlank") {
            if (otherEvent[0] === "enter") {
              if (lineIndex) {
                events.get(lineIndex)[1].type = "lineEndingBlank";
              }
              otherEvent[1].type = "lineEnding";
              lineIndex = otherIndex;
            }
          } else if (otherEvent[1].type === "linePrefix" || otherEvent[1].type === "listItemIndent") {
          } else {
            break;
          }
        }
        if (lineIndex) {
          event[1].end = {
            ...events.get(lineIndex)[1].start
          };
          parameters = events.slice(lineIndex, index);
          parameters.unshift(event);
          events.splice(lineIndex, index - lineIndex + 1, parameters);
        }
      }
    }
    splice(eventsArray, 0, Number.POSITIVE_INFINITY, events.slice(0));
    return !more;
  }
  function subcontent(events, eventIndex) {
    const token = events.get(eventIndex)[1];
    const context = events.get(eventIndex)[2];
    let startPosition = eventIndex - 1;
    const startPositions = [];
    let tokenizer = token._tokenizer;
    if (!tokenizer) {
      tokenizer = context.parser[token.contentType](token.start);
      if (token._contentTypeTextTrailing) {
        tokenizer._contentTypeTextTrailing = true;
      }
    }
    const childEvents = tokenizer.events;
    const jumps = [];
    const gaps = {};
    let stream;
    let previous4;
    let index = -1;
    let current = token;
    let adjust = 0;
    let start = 0;
    const breaks = [start];
    while (current) {
      while (events.get(++startPosition)[1] !== current) {
      }
      startPositions.push(startPosition);
      if (!current._tokenizer) {
        stream = context.sliceStream(current);
        if (!current.next) {
          stream.push(null);
        }
        if (previous4) {
          tokenizer.defineSkip(current.start);
        }
        if (current._isInFirstContentOfListItem) {
          tokenizer._gfmTasklistFirstContentOfListItem = true;
        }
        tokenizer.write(stream);
        if (current._isInFirstContentOfListItem) {
          tokenizer._gfmTasklistFirstContentOfListItem = void 0;
        }
      }
      previous4 = current;
      current = current.next;
    }
    current = token;
    while (++index < childEvents.length) {
      if (
        // Find a void token that includes a break.
        childEvents[index][0] === "exit" && childEvents[index - 1][0] === "enter" && childEvents[index][1].type === childEvents[index - 1][1].type && childEvents[index][1].start.line !== childEvents[index][1].end.line
      ) {
        start = index + 1;
        breaks.push(start);
        current._tokenizer = void 0;
        current.previous = void 0;
        current = current.next;
      }
    }
    tokenizer.events = [];
    if (current) {
      current._tokenizer = void 0;
      current.previous = void 0;
    } else {
      breaks.pop();
    }
    index = breaks.length;
    while (index--) {
      const slice = childEvents.slice(breaks[index], breaks[index + 1]);
      const start2 = startPositions.pop();
      jumps.push([start2, start2 + slice.length - 1]);
      events.splice(start2, 2, slice);
    }
    jumps.reverse();
    index = -1;
    while (++index < jumps.length) {
      gaps[adjust + jumps[index][0]] = adjust + jumps[index][1];
      adjust += jumps[index][1] - jumps[index][0] - 1;
    }
    return gaps;
  }

  // node_modules/micromark-core-commonmark/lib/content.js
  var content = {
    resolve: resolveContent,
    tokenize: tokenizeContent
  };
  var continuationConstruct = {
    partial: true,
    tokenize: tokenizeContinuation
  };
  function resolveContent(events) {
    subtokenize(events);
    return events;
  }
  function tokenizeContent(effects, ok) {
    let previous4;
    return chunkStart;
    function chunkStart(code2) {
      effects.enter("content");
      previous4 = effects.enter("chunkContent", {
        contentType: "content"
      });
      return chunkInside(code2);
    }
    function chunkInside(code2) {
      if (code2 === null) {
        return contentEnd(code2);
      }
      if (markdownLineEnding(code2)) {
        return effects.check(continuationConstruct, contentContinue, contentEnd)(code2);
      }
      effects.consume(code2);
      return chunkInside;
    }
    function contentEnd(code2) {
      effects.exit("chunkContent");
      effects.exit("content");
      return ok(code2);
    }
    function contentContinue(code2) {
      effects.consume(code2);
      effects.exit("chunkContent");
      previous4.next = effects.enter("chunkContent", {
        contentType: "content",
        previous: previous4
      });
      previous4 = previous4.next;
      return chunkInside;
    }
  }
  function tokenizeContinuation(effects, ok, nok) {
    const self = this;
    return startLookahead;
    function startLookahead(code2) {
      effects.exit("chunkContent");
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return factorySpace(effects, prefixed, "linePrefix");
    }
    function prefixed(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        return nok(code2);
      }
      const tail = self.events[self.events.length - 1];
      if (!self.parser.constructs.disable.null.includes("codeIndented") && tail && tail[1].type === "linePrefix" && tail[2].sliceSerialize(tail[1], true).length >= 4) {
        return ok(code2);
      }
      return effects.interrupt(self.parser.constructs.flow, nok, ok)(code2);
    }
  }

  // node_modules/micromark-factory-destination/index.js
  function factoryDestination(effects, ok, nok, type, literalType, literalMarkerType, rawType, stringType, max) {
    const limit = max || Number.POSITIVE_INFINITY;
    let balance = 0;
    return start;
    function start(code2) {
      if (code2 === 60) {
        effects.enter(type);
        effects.enter(literalType);
        effects.enter(literalMarkerType);
        effects.consume(code2);
        effects.exit(literalMarkerType);
        return enclosedBefore;
      }
      if (code2 === null || code2 === 32 || code2 === 41 || asciiControl(code2)) {
        return nok(code2);
      }
      effects.enter(type);
      effects.enter(rawType);
      effects.enter(stringType);
      effects.enter("chunkString", {
        contentType: "string"
      });
      return raw(code2);
    }
    function enclosedBefore(code2) {
      if (code2 === 62) {
        effects.enter(literalMarkerType);
        effects.consume(code2);
        effects.exit(literalMarkerType);
        effects.exit(literalType);
        effects.exit(type);
        return ok;
      }
      effects.enter(stringType);
      effects.enter("chunkString", {
        contentType: "string"
      });
      return enclosed(code2);
    }
    function enclosed(code2) {
      if (code2 === 62) {
        effects.exit("chunkString");
        effects.exit(stringType);
        return enclosedBefore(code2);
      }
      if (code2 === null || code2 === 60 || markdownLineEnding(code2)) {
        return nok(code2);
      }
      effects.consume(code2);
      return code2 === 92 ? enclosedEscape : enclosed;
    }
    function enclosedEscape(code2) {
      if (code2 === 60 || code2 === 62 || code2 === 92) {
        effects.consume(code2);
        return enclosed;
      }
      return enclosed(code2);
    }
    function raw(code2) {
      if (!balance && (code2 === null || code2 === 41 || markdownLineEndingOrSpace(code2))) {
        effects.exit("chunkString");
        effects.exit(stringType);
        effects.exit(rawType);
        effects.exit(type);
        return ok(code2);
      }
      if (balance < limit && code2 === 40) {
        effects.consume(code2);
        balance++;
        return raw;
      }
      if (code2 === 41) {
        effects.consume(code2);
        balance--;
        return raw;
      }
      if (code2 === null || code2 === 32 || code2 === 40 || asciiControl(code2)) {
        return nok(code2);
      }
      effects.consume(code2);
      return code2 === 92 ? rawEscape : raw;
    }
    function rawEscape(code2) {
      if (code2 === 40 || code2 === 41 || code2 === 92) {
        effects.consume(code2);
        return raw;
      }
      return raw(code2);
    }
  }

  // node_modules/micromark-factory-label/index.js
  function factoryLabel2(effects, ok, nok, type, markerType, stringType) {
    const self = this;
    let size = 0;
    let seen;
    return start;
    function start(code2) {
      effects.enter(type);
      effects.enter(markerType);
      effects.consume(code2);
      effects.exit(markerType);
      effects.enter(stringType);
      return atBreak;
    }
    function atBreak(code2) {
      if (size > 999 || code2 === null || code2 === 91 || code2 === 93 && !seen || // To do: remove in the future once we’ve switched from
      // `micromark-extension-footnote` to `micromark-extension-gfm-footnote`,
      // which doesn’t need this.
      // Hidden footnotes hook.
      /* c8 ignore next 3 */
      code2 === 94 && !size && "_hiddenFootnoteSupport" in self.parser.constructs) {
        return nok(code2);
      }
      if (code2 === 93) {
        effects.exit(stringType);
        effects.enter(markerType);
        effects.consume(code2);
        effects.exit(markerType);
        effects.exit(type);
        return ok;
      }
      if (markdownLineEnding(code2)) {
        effects.enter("lineEnding");
        effects.consume(code2);
        effects.exit("lineEnding");
        return atBreak;
      }
      effects.enter("chunkString", {
        contentType: "string"
      });
      return labelInside(code2);
    }
    function labelInside(code2) {
      if (code2 === null || code2 === 91 || code2 === 93 || markdownLineEnding(code2) || size++ > 999) {
        effects.exit("chunkString");
        return atBreak(code2);
      }
      effects.consume(code2);
      if (!seen) seen = !markdownSpace(code2);
      return code2 === 92 ? labelEscape : labelInside;
    }
    function labelEscape(code2) {
      if (code2 === 91 || code2 === 92 || code2 === 93) {
        effects.consume(code2);
        size++;
        return labelInside;
      }
      return labelInside(code2);
    }
  }

  // node_modules/micromark-factory-title/index.js
  function factoryTitle(effects, ok, nok, type, markerType, stringType) {
    let marker;
    return start;
    function start(code2) {
      if (code2 === 34 || code2 === 39 || code2 === 40) {
        effects.enter(type);
        effects.enter(markerType);
        effects.consume(code2);
        effects.exit(markerType);
        marker = code2 === 40 ? 41 : code2;
        return begin;
      }
      return nok(code2);
    }
    function begin(code2) {
      if (code2 === marker) {
        effects.enter(markerType);
        effects.consume(code2);
        effects.exit(markerType);
        effects.exit(type);
        return ok;
      }
      effects.enter(stringType);
      return atBreak(code2);
    }
    function atBreak(code2) {
      if (code2 === marker) {
        effects.exit(stringType);
        return begin(marker);
      }
      if (code2 === null) {
        return nok(code2);
      }
      if (markdownLineEnding(code2)) {
        effects.enter("lineEnding");
        effects.consume(code2);
        effects.exit("lineEnding");
        return factorySpace(effects, atBreak, "linePrefix");
      }
      effects.enter("chunkString", {
        contentType: "string"
      });
      return inside(code2);
    }
    function inside(code2) {
      if (code2 === marker || code2 === null || markdownLineEnding(code2)) {
        effects.exit("chunkString");
        return atBreak(code2);
      }
      effects.consume(code2);
      return code2 === 92 ? escape : inside;
    }
    function escape(code2) {
      if (code2 === marker || code2 === 92) {
        effects.consume(code2);
        return inside;
      }
      return inside(code2);
    }
  }

  // node_modules/micromark-util-normalize-identifier/index.js
  function normalizeIdentifier(value) {
    return value.replace(/[\t\n\r ]+/g, " ").replace(/^ | $/g, "").toLowerCase().toUpperCase();
  }

  // node_modules/micromark-core-commonmark/lib/definition.js
  var definition = {
    name: "definition",
    tokenize: tokenizeDefinition
  };
  var titleBefore = {
    partial: true,
    tokenize: tokenizeTitleBefore
  };
  function tokenizeDefinition(effects, ok, nok) {
    const self = this;
    let identifier;
    return start;
    function start(code2) {
      effects.enter("definition");
      return before(code2);
    }
    function before(code2) {
      return factoryLabel2.call(
        self,
        effects,
        labelAfter,
        // Note: we don’t need to reset the way `markdown-rs` does.
        nok,
        "definitionLabel",
        "definitionLabelMarker",
        "definitionLabelString"
      )(code2);
    }
    function labelAfter(code2) {
      identifier = normalizeIdentifier(self.sliceSerialize(self.events[self.events.length - 1][1]).slice(1, -1));
      if (code2 === 58) {
        effects.enter("definitionMarker");
        effects.consume(code2);
        effects.exit("definitionMarker");
        return markerAfter;
      }
      return nok(code2);
    }
    function markerAfter(code2) {
      return markdownLineEndingOrSpace(code2) ? factoryWhitespace(effects, destinationBefore)(code2) : destinationBefore(code2);
    }
    function destinationBefore(code2) {
      return factoryDestination(
        effects,
        destinationAfter,
        // Note: we don’t need to reset the way `markdown-rs` does.
        nok,
        "definitionDestination",
        "definitionDestinationLiteral",
        "definitionDestinationLiteralMarker",
        "definitionDestinationRaw",
        "definitionDestinationString"
      )(code2);
    }
    function destinationAfter(code2) {
      return effects.attempt(titleBefore, after, after)(code2);
    }
    function after(code2) {
      return markdownSpace(code2) ? factorySpace(effects, afterWhitespace, "whitespace")(code2) : afterWhitespace(code2);
    }
    function afterWhitespace(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("definition");
        self.parser.defined.push(identifier);
        return ok(code2);
      }
      return nok(code2);
    }
  }
  function tokenizeTitleBefore(effects, ok, nok) {
    return titleBefore2;
    function titleBefore2(code2) {
      return markdownLineEndingOrSpace(code2) ? factoryWhitespace(effects, beforeMarker)(code2) : nok(code2);
    }
    function beforeMarker(code2) {
      return factoryTitle(effects, titleAfter, nok, "definitionTitle", "definitionTitleMarker", "definitionTitleString")(code2);
    }
    function titleAfter(code2) {
      return markdownSpace(code2) ? factorySpace(effects, titleAfterOptionalWhitespace, "whitespace")(code2) : titleAfterOptionalWhitespace(code2);
    }
    function titleAfterOptionalWhitespace(code2) {
      return code2 === null || markdownLineEnding(code2) ? ok(code2) : nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/hard-break-escape.js
  var hardBreakEscape = {
    name: "hardBreakEscape",
    tokenize: tokenizeHardBreakEscape
  };
  function tokenizeHardBreakEscape(effects, ok, nok) {
    return start;
    function start(code2) {
      effects.enter("hardBreakEscape");
      effects.consume(code2);
      return after;
    }
    function after(code2) {
      if (markdownLineEnding(code2)) {
        effects.exit("hardBreakEscape");
        return ok(code2);
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/heading-atx.js
  var headingAtx = {
    name: "headingAtx",
    resolve: resolveHeadingAtx,
    tokenize: tokenizeHeadingAtx
  };
  function resolveHeadingAtx(events, context) {
    let contentEnd = events.length - 2;
    let contentStart = 3;
    let content3;
    let text4;
    if (events[contentStart][1].type === "whitespace") {
      contentStart += 2;
    }
    if (contentEnd - 2 > contentStart && events[contentEnd][1].type === "whitespace") {
      contentEnd -= 2;
    }
    if (events[contentEnd][1].type === "atxHeadingSequence" && (contentStart === contentEnd - 1 || contentEnd - 4 > contentStart && events[contentEnd - 2][1].type === "whitespace")) {
      contentEnd -= contentStart + 1 === contentEnd ? 2 : 4;
    }
    if (contentEnd > contentStart) {
      content3 = {
        type: "atxHeadingText",
        start: events[contentStart][1].start,
        end: events[contentEnd][1].end
      };
      text4 = {
        type: "chunkText",
        start: events[contentStart][1].start,
        end: events[contentEnd][1].end,
        contentType: "text"
      };
      splice(events, contentStart, contentEnd - contentStart + 1, [["enter", content3, context], ["enter", text4, context], ["exit", text4, context], ["exit", content3, context]]);
    }
    return events;
  }
  function tokenizeHeadingAtx(effects, ok, nok) {
    let size = 0;
    return start;
    function start(code2) {
      effects.enter("atxHeading");
      return before(code2);
    }
    function before(code2) {
      effects.enter("atxHeadingSequence");
      return sequenceOpen(code2);
    }
    function sequenceOpen(code2) {
      if (code2 === 35 && size++ < 6) {
        effects.consume(code2);
        return sequenceOpen;
      }
      if (code2 === null || markdownLineEndingOrSpace(code2)) {
        effects.exit("atxHeadingSequence");
        return atBreak(code2);
      }
      return nok(code2);
    }
    function atBreak(code2) {
      if (code2 === 35) {
        effects.enter("atxHeadingSequence");
        return sequenceFurther(code2);
      }
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("atxHeading");
        return ok(code2);
      }
      if (markdownSpace(code2)) {
        return factorySpace(effects, atBreak, "whitespace")(code2);
      }
      effects.enter("atxHeadingText");
      return data(code2);
    }
    function sequenceFurther(code2) {
      if (code2 === 35) {
        effects.consume(code2);
        return sequenceFurther;
      }
      effects.exit("atxHeadingSequence");
      return atBreak(code2);
    }
    function data(code2) {
      if (code2 === null || code2 === 35 || markdownLineEndingOrSpace(code2)) {
        effects.exit("atxHeadingText");
        return atBreak(code2);
      }
      effects.consume(code2);
      return data;
    }
  }

  // node_modules/micromark-util-html-tag-name/index.js
  var htmlBlockNames = [
    "address",
    "article",
    "aside",
    "base",
    "basefont",
    "blockquote",
    "body",
    "caption",
    "center",
    "col",
    "colgroup",
    "dd",
    "details",
    "dialog",
    "dir",
    "div",
    "dl",
    "dt",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "frame",
    "frameset",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "head",
    "header",
    "hr",
    "html",
    "iframe",
    "legend",
    "li",
    "link",
    "main",
    "menu",
    "menuitem",
    "nav",
    "noframes",
    "ol",
    "optgroup",
    "option",
    "p",
    "param",
    "search",
    "section",
    "summary",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "title",
    "tr",
    "track",
    "ul"
  ];
  var htmlRawNames = ["pre", "script", "style", "textarea"];

  // node_modules/micromark-core-commonmark/lib/html-flow.js
  var htmlFlow = {
    concrete: true,
    name: "htmlFlow",
    resolveTo: resolveToHtmlFlow,
    tokenize: tokenizeHtmlFlow
  };
  var blankLineBefore = {
    partial: true,
    tokenize: tokenizeBlankLineBefore
  };
  var nonLazyContinuationStart = {
    partial: true,
    tokenize: tokenizeNonLazyContinuationStart
  };
  function resolveToHtmlFlow(events) {
    let index = events.length;
    while (index--) {
      if (events[index][0] === "enter" && events[index][1].type === "htmlFlow") {
        break;
      }
    }
    if (index > 1 && events[index - 2][1].type === "linePrefix") {
      events[index][1].start = events[index - 2][1].start;
      events[index + 1][1].start = events[index - 2][1].start;
      events.splice(index - 2, 2);
    }
    return events;
  }
  function tokenizeHtmlFlow(effects, ok, nok) {
    const self = this;
    let marker;
    let closingTag;
    let buffer;
    let index;
    let markerB;
    return start;
    function start(code2) {
      return before(code2);
    }
    function before(code2) {
      effects.enter("htmlFlow");
      effects.enter("htmlFlowData");
      effects.consume(code2);
      return open;
    }
    function open(code2) {
      if (code2 === 33) {
        effects.consume(code2);
        return declarationOpen;
      }
      if (code2 === 47) {
        effects.consume(code2);
        closingTag = true;
        return tagCloseStart;
      }
      if (code2 === 63) {
        effects.consume(code2);
        marker = 3;
        return self.interrupt ? ok : continuationDeclarationInside;
      }
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        buffer = String.fromCharCode(code2);
        return tagName;
      }
      return nok(code2);
    }
    function declarationOpen(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        marker = 2;
        return commentOpenInside;
      }
      if (code2 === 91) {
        effects.consume(code2);
        marker = 5;
        index = 0;
        return cdataOpenInside;
      }
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        marker = 4;
        return self.interrupt ? ok : continuationDeclarationInside;
      }
      return nok(code2);
    }
    function commentOpenInside(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        return self.interrupt ? ok : continuationDeclarationInside;
      }
      return nok(code2);
    }
    function cdataOpenInside(code2) {
      const value = "CDATA[";
      if (code2 === value.charCodeAt(index++)) {
        effects.consume(code2);
        if (index === value.length) {
          return self.interrupt ? ok : continuation;
        }
        return cdataOpenInside;
      }
      return nok(code2);
    }
    function tagCloseStart(code2) {
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        buffer = String.fromCharCode(code2);
        return tagName;
      }
      return nok(code2);
    }
    function tagName(code2) {
      if (code2 === null || code2 === 47 || code2 === 62 || markdownLineEndingOrSpace(code2)) {
        const slash = code2 === 47;
        const name = buffer.toLowerCase();
        if (!slash && !closingTag && htmlRawNames.includes(name)) {
          marker = 1;
          return self.interrupt ? ok(code2) : continuation(code2);
        }
        if (htmlBlockNames.includes(buffer.toLowerCase())) {
          marker = 6;
          if (slash) {
            effects.consume(code2);
            return basicSelfClosing;
          }
          return self.interrupt ? ok(code2) : continuation(code2);
        }
        marker = 7;
        return self.interrupt && !self.parser.lazy[self.now().line] ? nok(code2) : closingTag ? completeClosingTagAfter(code2) : completeAttributeNameBefore(code2);
      }
      if (code2 === 45 || asciiAlphanumeric(code2)) {
        effects.consume(code2);
        buffer += String.fromCharCode(code2);
        return tagName;
      }
      return nok(code2);
    }
    function basicSelfClosing(code2) {
      if (code2 === 62) {
        effects.consume(code2);
        return self.interrupt ? ok : continuation;
      }
      return nok(code2);
    }
    function completeClosingTagAfter(code2) {
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return completeClosingTagAfter;
      }
      return completeEnd(code2);
    }
    function completeAttributeNameBefore(code2) {
      if (code2 === 47) {
        effects.consume(code2);
        return completeEnd;
      }
      if (code2 === 58 || code2 === 95 || asciiAlpha(code2)) {
        effects.consume(code2);
        return completeAttributeName;
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return completeAttributeNameBefore;
      }
      return completeEnd(code2);
    }
    function completeAttributeName(code2) {
      if (code2 === 45 || code2 === 46 || code2 === 58 || code2 === 95 || asciiAlphanumeric(code2)) {
        effects.consume(code2);
        return completeAttributeName;
      }
      return completeAttributeNameAfter(code2);
    }
    function completeAttributeNameAfter(code2) {
      if (code2 === 61) {
        effects.consume(code2);
        return completeAttributeValueBefore;
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return completeAttributeNameAfter;
      }
      return completeAttributeNameBefore(code2);
    }
    function completeAttributeValueBefore(code2) {
      if (code2 === null || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96) {
        return nok(code2);
      }
      if (code2 === 34 || code2 === 39) {
        effects.consume(code2);
        markerB = code2;
        return completeAttributeValueQuoted;
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return completeAttributeValueBefore;
      }
      return completeAttributeValueUnquoted(code2);
    }
    function completeAttributeValueQuoted(code2) {
      if (code2 === markerB) {
        effects.consume(code2);
        markerB = null;
        return completeAttributeValueQuotedAfter;
      }
      if (code2 === null || markdownLineEnding(code2)) {
        return nok(code2);
      }
      effects.consume(code2);
      return completeAttributeValueQuoted;
    }
    function completeAttributeValueUnquoted(code2) {
      if (code2 === null || code2 === 34 || code2 === 39 || code2 === 47 || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96 || markdownLineEndingOrSpace(code2)) {
        return completeAttributeNameAfter(code2);
      }
      effects.consume(code2);
      return completeAttributeValueUnquoted;
    }
    function completeAttributeValueQuotedAfter(code2) {
      if (code2 === 47 || code2 === 62 || markdownSpace(code2)) {
        return completeAttributeNameBefore(code2);
      }
      return nok(code2);
    }
    function completeEnd(code2) {
      if (code2 === 62) {
        effects.consume(code2);
        return completeAfter;
      }
      return nok(code2);
    }
    function completeAfter(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        return continuation(code2);
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return completeAfter;
      }
      return nok(code2);
    }
    function continuation(code2) {
      if (code2 === 45 && marker === 2) {
        effects.consume(code2);
        return continuationCommentInside;
      }
      if (code2 === 60 && marker === 1) {
        effects.consume(code2);
        return continuationRawTagOpen;
      }
      if (code2 === 62 && marker === 4) {
        effects.consume(code2);
        return continuationClose;
      }
      if (code2 === 63 && marker === 3) {
        effects.consume(code2);
        return continuationDeclarationInside;
      }
      if (code2 === 93 && marker === 5) {
        effects.consume(code2);
        return continuationCdataInside;
      }
      if (markdownLineEnding(code2) && (marker === 6 || marker === 7)) {
        effects.exit("htmlFlowData");
        return effects.check(blankLineBefore, continuationAfter, continuationStart)(code2);
      }
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("htmlFlowData");
        return continuationStart(code2);
      }
      effects.consume(code2);
      return continuation;
    }
    function continuationStart(code2) {
      return effects.check(nonLazyContinuationStart, continuationStartNonLazy, continuationAfter)(code2);
    }
    function continuationStartNonLazy(code2) {
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return continuationBefore;
    }
    function continuationBefore(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        return continuationStart(code2);
      }
      effects.enter("htmlFlowData");
      return continuation(code2);
    }
    function continuationCommentInside(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        return continuationDeclarationInside;
      }
      return continuation(code2);
    }
    function continuationRawTagOpen(code2) {
      if (code2 === 47) {
        effects.consume(code2);
        buffer = "";
        return continuationRawEndTag;
      }
      return continuation(code2);
    }
    function continuationRawEndTag(code2) {
      if (code2 === 62) {
        const name = buffer.toLowerCase();
        if (htmlRawNames.includes(name)) {
          effects.consume(code2);
          return continuationClose;
        }
        return continuation(code2);
      }
      if (asciiAlpha(code2) && buffer.length < 8) {
        effects.consume(code2);
        buffer += String.fromCharCode(code2);
        return continuationRawEndTag;
      }
      return continuation(code2);
    }
    function continuationCdataInside(code2) {
      if (code2 === 93) {
        effects.consume(code2);
        return continuationDeclarationInside;
      }
      return continuation(code2);
    }
    function continuationDeclarationInside(code2) {
      if (code2 === 62) {
        effects.consume(code2);
        return continuationClose;
      }
      if (code2 === 45 && marker === 2) {
        effects.consume(code2);
        return continuationDeclarationInside;
      }
      return continuation(code2);
    }
    function continuationClose(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("htmlFlowData");
        return continuationAfter(code2);
      }
      effects.consume(code2);
      return continuationClose;
    }
    function continuationAfter(code2) {
      effects.exit("htmlFlow");
      return ok(code2);
    }
  }
  function tokenizeNonLazyContinuationStart(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      if (markdownLineEnding(code2)) {
        effects.enter("lineEnding");
        effects.consume(code2);
        effects.exit("lineEnding");
        return after;
      }
      return nok(code2);
    }
    function after(code2) {
      return self.parser.lazy[self.now().line] ? nok(code2) : ok(code2);
    }
  }
  function tokenizeBlankLineBefore(effects, ok, nok) {
    return start;
    function start(code2) {
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return effects.attempt(blankLine, ok, nok);
    }
  }

  // node_modules/micromark-core-commonmark/lib/html-text.js
  var htmlText = {
    name: "htmlText",
    tokenize: tokenizeHtmlText
  };
  function tokenizeHtmlText(effects, ok, nok) {
    const self = this;
    let marker;
    let index;
    let returnState;
    return start;
    function start(code2) {
      effects.enter("htmlText");
      effects.enter("htmlTextData");
      effects.consume(code2);
      return open;
    }
    function open(code2) {
      if (code2 === 33) {
        effects.consume(code2);
        return declarationOpen;
      }
      if (code2 === 47) {
        effects.consume(code2);
        return tagCloseStart;
      }
      if (code2 === 63) {
        effects.consume(code2);
        return instruction;
      }
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        return tagOpen;
      }
      return nok(code2);
    }
    function declarationOpen(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        return commentOpenInside;
      }
      if (code2 === 91) {
        effects.consume(code2);
        index = 0;
        return cdataOpenInside;
      }
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        return declaration;
      }
      return nok(code2);
    }
    function commentOpenInside(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        return commentEnd;
      }
      return nok(code2);
    }
    function comment(code2) {
      if (code2 === null) {
        return nok(code2);
      }
      if (code2 === 45) {
        effects.consume(code2);
        return commentClose;
      }
      if (markdownLineEnding(code2)) {
        returnState = comment;
        return lineEndingBefore(code2);
      }
      effects.consume(code2);
      return comment;
    }
    function commentClose(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        return commentEnd;
      }
      return comment(code2);
    }
    function commentEnd(code2) {
      return code2 === 62 ? end(code2) : code2 === 45 ? commentClose(code2) : comment(code2);
    }
    function cdataOpenInside(code2) {
      const value = "CDATA[";
      if (code2 === value.charCodeAt(index++)) {
        effects.consume(code2);
        return index === value.length ? cdata : cdataOpenInside;
      }
      return nok(code2);
    }
    function cdata(code2) {
      if (code2 === null) {
        return nok(code2);
      }
      if (code2 === 93) {
        effects.consume(code2);
        return cdataClose;
      }
      if (markdownLineEnding(code2)) {
        returnState = cdata;
        return lineEndingBefore(code2);
      }
      effects.consume(code2);
      return cdata;
    }
    function cdataClose(code2) {
      if (code2 === 93) {
        effects.consume(code2);
        return cdataEnd;
      }
      return cdata(code2);
    }
    function cdataEnd(code2) {
      if (code2 === 62) {
        return end(code2);
      }
      if (code2 === 93) {
        effects.consume(code2);
        return cdataEnd;
      }
      return cdata(code2);
    }
    function declaration(code2) {
      if (code2 === null || code2 === 62) {
        return end(code2);
      }
      if (markdownLineEnding(code2)) {
        returnState = declaration;
        return lineEndingBefore(code2);
      }
      effects.consume(code2);
      return declaration;
    }
    function instruction(code2) {
      if (code2 === null) {
        return nok(code2);
      }
      if (code2 === 63) {
        effects.consume(code2);
        return instructionClose;
      }
      if (markdownLineEnding(code2)) {
        returnState = instruction;
        return lineEndingBefore(code2);
      }
      effects.consume(code2);
      return instruction;
    }
    function instructionClose(code2) {
      return code2 === 62 ? end(code2) : instruction(code2);
    }
    function tagCloseStart(code2) {
      if (asciiAlpha(code2)) {
        effects.consume(code2);
        return tagClose;
      }
      return nok(code2);
    }
    function tagClose(code2) {
      if (code2 === 45 || asciiAlphanumeric(code2)) {
        effects.consume(code2);
        return tagClose;
      }
      return tagCloseBetween(code2);
    }
    function tagCloseBetween(code2) {
      if (markdownLineEnding(code2)) {
        returnState = tagCloseBetween;
        return lineEndingBefore(code2);
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return tagCloseBetween;
      }
      return end(code2);
    }
    function tagOpen(code2) {
      if (code2 === 45 || asciiAlphanumeric(code2)) {
        effects.consume(code2);
        return tagOpen;
      }
      if (code2 === 47 || code2 === 62 || markdownLineEndingOrSpace(code2)) {
        return tagOpenBetween(code2);
      }
      return nok(code2);
    }
    function tagOpenBetween(code2) {
      if (code2 === 47) {
        effects.consume(code2);
        return end;
      }
      if (code2 === 58 || code2 === 95 || asciiAlpha(code2)) {
        effects.consume(code2);
        return tagOpenAttributeName;
      }
      if (markdownLineEnding(code2)) {
        returnState = tagOpenBetween;
        return lineEndingBefore(code2);
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return tagOpenBetween;
      }
      return end(code2);
    }
    function tagOpenAttributeName(code2) {
      if (code2 === 45 || code2 === 46 || code2 === 58 || code2 === 95 || asciiAlphanumeric(code2)) {
        effects.consume(code2);
        return tagOpenAttributeName;
      }
      return tagOpenAttributeNameAfter(code2);
    }
    function tagOpenAttributeNameAfter(code2) {
      if (code2 === 61) {
        effects.consume(code2);
        return tagOpenAttributeValueBefore;
      }
      if (markdownLineEnding(code2)) {
        returnState = tagOpenAttributeNameAfter;
        return lineEndingBefore(code2);
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return tagOpenAttributeNameAfter;
      }
      return tagOpenBetween(code2);
    }
    function tagOpenAttributeValueBefore(code2) {
      if (code2 === null || code2 === 60 || code2 === 61 || code2 === 62 || code2 === 96) {
        return nok(code2);
      }
      if (code2 === 34 || code2 === 39) {
        effects.consume(code2);
        marker = code2;
        return tagOpenAttributeValueQuoted;
      }
      if (markdownLineEnding(code2)) {
        returnState = tagOpenAttributeValueBefore;
        return lineEndingBefore(code2);
      }
      if (markdownSpace(code2)) {
        effects.consume(code2);
        return tagOpenAttributeValueBefore;
      }
      effects.consume(code2);
      return tagOpenAttributeValueUnquoted;
    }
    function tagOpenAttributeValueQuoted(code2) {
      if (code2 === marker) {
        effects.consume(code2);
        marker = void 0;
        return tagOpenAttributeValueQuotedAfter;
      }
      if (code2 === null) {
        return nok(code2);
      }
      if (markdownLineEnding(code2)) {
        returnState = tagOpenAttributeValueQuoted;
        return lineEndingBefore(code2);
      }
      effects.consume(code2);
      return tagOpenAttributeValueQuoted;
    }
    function tagOpenAttributeValueUnquoted(code2) {
      if (code2 === null || code2 === 34 || code2 === 39 || code2 === 60 || code2 === 61 || code2 === 96) {
        return nok(code2);
      }
      if (code2 === 47 || code2 === 62 || markdownLineEndingOrSpace(code2)) {
        return tagOpenBetween(code2);
      }
      effects.consume(code2);
      return tagOpenAttributeValueUnquoted;
    }
    function tagOpenAttributeValueQuotedAfter(code2) {
      if (code2 === 47 || code2 === 62 || markdownLineEndingOrSpace(code2)) {
        return tagOpenBetween(code2);
      }
      return nok(code2);
    }
    function end(code2) {
      if (code2 === 62) {
        effects.consume(code2);
        effects.exit("htmlTextData");
        effects.exit("htmlText");
        return ok;
      }
      return nok(code2);
    }
    function lineEndingBefore(code2) {
      effects.exit("htmlTextData");
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return lineEndingAfter;
    }
    function lineEndingAfter(code2) {
      return markdownSpace(code2) ? factorySpace(effects, lineEndingAfterPrefix, "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4)(code2) : lineEndingAfterPrefix(code2);
    }
    function lineEndingAfterPrefix(code2) {
      effects.enter("htmlTextData");
      return returnState(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/label-end.js
  var labelEnd = {
    name: "labelEnd",
    resolveAll: resolveAllLabelEnd,
    resolveTo: resolveToLabelEnd,
    tokenize: tokenizeLabelEnd
  };
  var resourceConstruct = {
    tokenize: tokenizeResource
  };
  var referenceFullConstruct = {
    tokenize: tokenizeReferenceFull
  };
  var referenceCollapsedConstruct = {
    tokenize: tokenizeReferenceCollapsed
  };
  function resolveAllLabelEnd(events) {
    let index = -1;
    const newEvents = [];
    while (++index < events.length) {
      const token = events[index][1];
      newEvents.push(events[index]);
      if (token.type === "labelImage" || token.type === "labelLink" || token.type === "labelEnd") {
        const offset = token.type === "labelImage" ? 4 : 2;
        token.type = "data";
        index += offset;
      }
    }
    if (events.length !== newEvents.length) {
      splice(events, 0, events.length, newEvents);
    }
    return events;
  }
  function resolveToLabelEnd(events, context) {
    let index = events.length;
    let offset = 0;
    let token;
    let open;
    let close;
    let media;
    while (index--) {
      token = events[index][1];
      if (open) {
        if (token.type === "link" || token.type === "labelLink" && token._inactive) {
          break;
        }
        if (events[index][0] === "enter" && token.type === "labelLink") {
          token._inactive = true;
        }
      } else if (close) {
        if (events[index][0] === "enter" && (token.type === "labelImage" || token.type === "labelLink") && !token._balanced) {
          open = index;
          if (token.type !== "labelLink") {
            offset = 2;
            break;
          }
        }
      } else if (token.type === "labelEnd") {
        close = index;
      }
    }
    const group = {
      type: events[open][1].type === "labelLink" ? "link" : "image",
      start: {
        ...events[open][1].start
      },
      end: {
        ...events[events.length - 1][1].end
      }
    };
    const label4 = {
      type: "label",
      start: {
        ...events[open][1].start
      },
      end: {
        ...events[close][1].end
      }
    };
    const text4 = {
      type: "labelText",
      start: {
        ...events[open + offset + 2][1].end
      },
      end: {
        ...events[close - 2][1].start
      }
    };
    media = [["enter", group, context], ["enter", label4, context]];
    media = push(media, events.slice(open + 1, open + offset + 3));
    media = push(media, [["enter", text4, context]]);
    media = push(media, resolveAll(context.parser.constructs.insideSpan.null, events.slice(open + offset + 4, close - 3), context));
    media = push(media, [["exit", text4, context], events[close - 2], events[close - 1], ["exit", label4, context]]);
    media = push(media, events.slice(close + 1));
    media = push(media, [["exit", group, context]]);
    splice(events, open, events.length, media);
    return events;
  }
  function tokenizeLabelEnd(effects, ok, nok) {
    const self = this;
    let index = self.events.length;
    let labelStart;
    let defined;
    while (index--) {
      if ((self.events[index][1].type === "labelImage" || self.events[index][1].type === "labelLink") && !self.events[index][1]._balanced) {
        labelStart = self.events[index][1];
        break;
      }
    }
    return start;
    function start(code2) {
      if (!labelStart) {
        return nok(code2);
      }
      if (labelStart._inactive) {
        return labelEndNok(code2);
      }
      defined = self.parser.defined.includes(normalizeIdentifier(self.sliceSerialize({
        start: labelStart.end,
        end: self.now()
      })));
      effects.enter("labelEnd");
      effects.enter("labelMarker");
      effects.consume(code2);
      effects.exit("labelMarker");
      effects.exit("labelEnd");
      return after;
    }
    function after(code2) {
      if (code2 === 40) {
        return effects.attempt(resourceConstruct, labelEndOk, defined ? labelEndOk : labelEndNok)(code2);
      }
      if (code2 === 91) {
        return effects.attempt(referenceFullConstruct, labelEndOk, defined ? referenceNotFull : labelEndNok)(code2);
      }
      return defined ? labelEndOk(code2) : labelEndNok(code2);
    }
    function referenceNotFull(code2) {
      return effects.attempt(referenceCollapsedConstruct, labelEndOk, labelEndNok)(code2);
    }
    function labelEndOk(code2) {
      return ok(code2);
    }
    function labelEndNok(code2) {
      labelStart._balanced = true;
      return nok(code2);
    }
  }
  function tokenizeResource(effects, ok, nok) {
    return resourceStart;
    function resourceStart(code2) {
      effects.enter("resource");
      effects.enter("resourceMarker");
      effects.consume(code2);
      effects.exit("resourceMarker");
      return resourceBefore;
    }
    function resourceBefore(code2) {
      return markdownLineEndingOrSpace(code2) ? factoryWhitespace(effects, resourceOpen)(code2) : resourceOpen(code2);
    }
    function resourceOpen(code2) {
      if (code2 === 41) {
        return resourceEnd(code2);
      }
      return factoryDestination(effects, resourceDestinationAfter, resourceDestinationMissing, "resourceDestination", "resourceDestinationLiteral", "resourceDestinationLiteralMarker", "resourceDestinationRaw", "resourceDestinationString", 32)(code2);
    }
    function resourceDestinationAfter(code2) {
      return markdownLineEndingOrSpace(code2) ? factoryWhitespace(effects, resourceBetween)(code2) : resourceEnd(code2);
    }
    function resourceDestinationMissing(code2) {
      return nok(code2);
    }
    function resourceBetween(code2) {
      if (code2 === 34 || code2 === 39 || code2 === 40) {
        return factoryTitle(effects, resourceTitleAfter, nok, "resourceTitle", "resourceTitleMarker", "resourceTitleString")(code2);
      }
      return resourceEnd(code2);
    }
    function resourceTitleAfter(code2) {
      return markdownLineEndingOrSpace(code2) ? factoryWhitespace(effects, resourceEnd)(code2) : resourceEnd(code2);
    }
    function resourceEnd(code2) {
      if (code2 === 41) {
        effects.enter("resourceMarker");
        effects.consume(code2);
        effects.exit("resourceMarker");
        effects.exit("resource");
        return ok;
      }
      return nok(code2);
    }
  }
  function tokenizeReferenceFull(effects, ok, nok) {
    const self = this;
    return referenceFull;
    function referenceFull(code2) {
      return factoryLabel2.call(self, effects, referenceFullAfter, referenceFullMissing, "reference", "referenceMarker", "referenceString")(code2);
    }
    function referenceFullAfter(code2) {
      return self.parser.defined.includes(normalizeIdentifier(self.sliceSerialize(self.events[self.events.length - 1][1]).slice(1, -1))) ? ok(code2) : nok(code2);
    }
    function referenceFullMissing(code2) {
      return nok(code2);
    }
  }
  function tokenizeReferenceCollapsed(effects, ok, nok) {
    return referenceCollapsedStart;
    function referenceCollapsedStart(code2) {
      effects.enter("reference");
      effects.enter("referenceMarker");
      effects.consume(code2);
      effects.exit("referenceMarker");
      return referenceCollapsedOpen;
    }
    function referenceCollapsedOpen(code2) {
      if (code2 === 93) {
        effects.enter("referenceMarker");
        effects.consume(code2);
        effects.exit("referenceMarker");
        effects.exit("reference");
        return ok;
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/label-start-image.js
  var labelStartImage = {
    name: "labelStartImage",
    resolveAll: labelEnd.resolveAll,
    tokenize: tokenizeLabelStartImage
  };
  function tokenizeLabelStartImage(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      effects.enter("labelImage");
      effects.enter("labelImageMarker");
      effects.consume(code2);
      effects.exit("labelImageMarker");
      return open;
    }
    function open(code2) {
      if (code2 === 91) {
        effects.enter("labelMarker");
        effects.consume(code2);
        effects.exit("labelMarker");
        effects.exit("labelImage");
        return after;
      }
      return nok(code2);
    }
    function after(code2) {
      return code2 === 94 && "_hiddenFootnoteSupport" in self.parser.constructs ? nok(code2) : ok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/label-start-link.js
  var labelStartLink = {
    name: "labelStartLink",
    resolveAll: labelEnd.resolveAll,
    tokenize: tokenizeLabelStartLink
  };
  function tokenizeLabelStartLink(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      effects.enter("labelLink");
      effects.enter("labelMarker");
      effects.consume(code2);
      effects.exit("labelMarker");
      effects.exit("labelLink");
      return after;
    }
    function after(code2) {
      return code2 === 94 && "_hiddenFootnoteSupport" in self.parser.constructs ? nok(code2) : ok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/line-ending.js
  var lineEnding = {
    name: "lineEnding",
    tokenize: tokenizeLineEnding
  };
  function tokenizeLineEnding(effects, ok) {
    return start;
    function start(code2) {
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return factorySpace(effects, ok, "linePrefix");
    }
  }

  // node_modules/micromark-core-commonmark/lib/thematic-break.js
  var thematicBreak = {
    name: "thematicBreak",
    tokenize: tokenizeThematicBreak
  };
  function tokenizeThematicBreak(effects, ok, nok) {
    let size = 0;
    let marker;
    return start;
    function start(code2) {
      effects.enter("thematicBreak");
      return before(code2);
    }
    function before(code2) {
      marker = code2;
      return atBreak(code2);
    }
    function atBreak(code2) {
      if (code2 === marker) {
        effects.enter("thematicBreakSequence");
        return sequence(code2);
      }
      if (size >= 3 && (code2 === null || markdownLineEnding(code2))) {
        effects.exit("thematicBreak");
        return ok(code2);
      }
      return nok(code2);
    }
    function sequence(code2) {
      if (code2 === marker) {
        effects.consume(code2);
        size++;
        return sequence;
      }
      effects.exit("thematicBreakSequence");
      return markdownSpace(code2) ? factorySpace(effects, atBreak, "whitespace")(code2) : atBreak(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/list.js
  var list = {
    continuation: {
      tokenize: tokenizeListContinuation
    },
    exit: tokenizeListEnd,
    name: "list",
    tokenize: tokenizeListStart
  };
  var listItemPrefixWhitespaceConstruct = {
    partial: true,
    tokenize: tokenizeListItemPrefixWhitespace
  };
  var indentConstruct = {
    partial: true,
    tokenize: tokenizeIndent
  };
  function tokenizeListStart(effects, ok, nok) {
    const self = this;
    const tail = self.events[self.events.length - 1];
    let initialSize = tail && tail[1].type === "linePrefix" ? tail[2].sliceSerialize(tail[1], true).length : 0;
    let size = 0;
    return start;
    function start(code2) {
      const kind = self.containerState.type || (code2 === 42 || code2 === 43 || code2 === 45 ? "listUnordered" : "listOrdered");
      if (kind === "listUnordered" ? !self.containerState.marker || code2 === self.containerState.marker : asciiDigit(code2)) {
        if (!self.containerState.type) {
          self.containerState.type = kind;
          effects.enter(kind, {
            _container: true
          });
        }
        if (kind === "listUnordered") {
          effects.enter("listItemPrefix");
          return code2 === 42 || code2 === 45 ? effects.check(thematicBreak, nok, atMarker)(code2) : atMarker(code2);
        }
        if (!self.interrupt || code2 === 49) {
          effects.enter("listItemPrefix");
          effects.enter("listItemValue");
          return inside(code2);
        }
      }
      return nok(code2);
    }
    function inside(code2) {
      if (asciiDigit(code2) && ++size < 10) {
        effects.consume(code2);
        return inside;
      }
      if ((!self.interrupt || size < 2) && (self.containerState.marker ? code2 === self.containerState.marker : code2 === 41 || code2 === 46)) {
        effects.exit("listItemValue");
        return atMarker(code2);
      }
      return nok(code2);
    }
    function atMarker(code2) {
      effects.enter("listItemMarker");
      effects.consume(code2);
      effects.exit("listItemMarker");
      self.containerState.marker = self.containerState.marker || code2;
      return effects.check(
        blankLine,
        // Can’t be empty when interrupting.
        self.interrupt ? nok : onBlank,
        effects.attempt(listItemPrefixWhitespaceConstruct, endOfPrefix, otherPrefix)
      );
    }
    function onBlank(code2) {
      self.containerState.initialBlankLine = true;
      initialSize++;
      return endOfPrefix(code2);
    }
    function otherPrefix(code2) {
      if (markdownSpace(code2)) {
        effects.enter("listItemPrefixWhitespace");
        effects.consume(code2);
        effects.exit("listItemPrefixWhitespace");
        return endOfPrefix;
      }
      return nok(code2);
    }
    function endOfPrefix(code2) {
      self.containerState.size = initialSize + self.sliceSerialize(effects.exit("listItemPrefix"), true).length;
      return ok(code2);
    }
  }
  function tokenizeListContinuation(effects, ok, nok) {
    const self = this;
    self.containerState._closeFlow = void 0;
    return effects.check(blankLine, onBlank, notBlank);
    function onBlank(code2) {
      self.containerState.furtherBlankLines = self.containerState.furtherBlankLines || self.containerState.initialBlankLine;
      return factorySpace(effects, ok, "listItemIndent", self.containerState.size + 1)(code2);
    }
    function notBlank(code2) {
      if (self.containerState.furtherBlankLines || !markdownSpace(code2)) {
        self.containerState.furtherBlankLines = void 0;
        self.containerState.initialBlankLine = void 0;
        return notInCurrentItem(code2);
      }
      self.containerState.furtherBlankLines = void 0;
      self.containerState.initialBlankLine = void 0;
      return effects.attempt(indentConstruct, ok, notInCurrentItem)(code2);
    }
    function notInCurrentItem(code2) {
      self.containerState._closeFlow = true;
      self.interrupt = void 0;
      return factorySpace(effects, effects.attempt(list, ok, nok), "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4)(code2);
    }
  }
  function tokenizeIndent(effects, ok, nok) {
    const self = this;
    return factorySpace(effects, afterPrefix, "listItemIndent", self.containerState.size + 1);
    function afterPrefix(code2) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === "listItemIndent" && tail[2].sliceSerialize(tail[1], true).length === self.containerState.size ? ok(code2) : nok(code2);
    }
  }
  function tokenizeListEnd(effects) {
    effects.exit(this.containerState.type);
  }
  function tokenizeListItemPrefixWhitespace(effects, ok, nok) {
    const self = this;
    return factorySpace(effects, afterPrefix, "listItemPrefixWhitespace", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4 + 1);
    function afterPrefix(code2) {
      const tail = self.events[self.events.length - 1];
      return !markdownSpace(code2) && tail && tail[1].type === "listItemPrefixWhitespace" ? ok(code2) : nok(code2);
    }
  }

  // node_modules/micromark-core-commonmark/lib/setext-underline.js
  var setextUnderline = {
    name: "setextUnderline",
    resolveTo: resolveToSetextUnderline,
    tokenize: tokenizeSetextUnderline
  };
  function resolveToSetextUnderline(events, context) {
    let index = events.length;
    let content3;
    let text4;
    let definition2;
    while (index--) {
      if (events[index][0] === "enter") {
        if (events[index][1].type === "content") {
          content3 = index;
          break;
        }
        if (events[index][1].type === "paragraph") {
          text4 = index;
        }
      } else {
        if (events[index][1].type === "content") {
          events.splice(index, 1);
        }
        if (!definition2 && events[index][1].type === "definition") {
          definition2 = index;
        }
      }
    }
    const heading = {
      type: "setextHeading",
      start: {
        ...events[content3][1].start
      },
      end: {
        ...events[events.length - 1][1].end
      }
    };
    events[text4][1].type = "setextHeadingText";
    if (definition2) {
      events.splice(text4, 0, ["enter", heading, context]);
      events.splice(definition2 + 1, 0, ["exit", events[content3][1], context]);
      events[content3][1].end = {
        ...events[definition2][1].end
      };
    } else {
      events[content3][1] = heading;
    }
    events.push(["exit", heading, context]);
    return events;
  }
  function tokenizeSetextUnderline(effects, ok, nok) {
    const self = this;
    let marker;
    return start;
    function start(code2) {
      let index = self.events.length;
      let paragraph;
      while (index--) {
        if (self.events[index][1].type !== "lineEnding" && self.events[index][1].type !== "linePrefix" && self.events[index][1].type !== "content") {
          paragraph = self.events[index][1].type === "paragraph";
          break;
        }
      }
      if (!self.parser.lazy[self.now().line] && (self.interrupt || paragraph)) {
        effects.enter("setextHeadingLine");
        marker = code2;
        return before(code2);
      }
      return nok(code2);
    }
    function before(code2) {
      effects.enter("setextHeadingLineSequence");
      return inside(code2);
    }
    function inside(code2) {
      if (code2 === marker) {
        effects.consume(code2);
        return inside;
      }
      effects.exit("setextHeadingLineSequence");
      return markdownSpace(code2) ? factorySpace(effects, after, "lineSuffix")(code2) : after(code2);
    }
    function after(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("setextHeadingLine");
        return ok(code2);
      }
      return nok(code2);
    }
  }

  // node_modules/micromark-extension-gfm-footnote/lib/syntax.js
  var indent = {
    tokenize: tokenizeIndent2,
    partial: true
  };
  function gfmFootnote() {
    return {
      document: {
        [91]: {
          name: "gfmFootnoteDefinition",
          tokenize: tokenizeDefinitionStart,
          continuation: {
            tokenize: tokenizeDefinitionContinuation
          },
          exit: gfmFootnoteDefinitionEnd
        }
      },
      text: {
        [91]: {
          name: "gfmFootnoteCall",
          tokenize: tokenizeGfmFootnoteCall
        },
        [93]: {
          name: "gfmPotentialFootnoteCall",
          add: "after",
          tokenize: tokenizePotentialGfmFootnoteCall,
          resolveTo: resolveToPotentialGfmFootnoteCall
        }
      }
    };
  }
  function tokenizePotentialGfmFootnoteCall(effects, ok, nok) {
    const self = this;
    let index = self.events.length;
    const defined = self.parser.gfmFootnotes || (self.parser.gfmFootnotes = []);
    let labelStart;
    while (index--) {
      const token = self.events[index][1];
      if (token.type === "labelImage") {
        labelStart = token;
        break;
      }
      if (token.type === "gfmFootnoteCall" || token.type === "labelLink" || token.type === "label" || token.type === "image" || token.type === "link") {
        break;
      }
    }
    return start;
    function start(code2) {
      if (!labelStart || !labelStart._balanced) {
        return nok(code2);
      }
      const id = normalizeIdentifier(self.sliceSerialize({
        start: labelStart.end,
        end: self.now()
      }));
      if (id.codePointAt(0) !== 94 || !defined.includes(id.slice(1))) {
        return nok(code2);
      }
      effects.enter("gfmFootnoteCallLabelMarker");
      effects.consume(code2);
      effects.exit("gfmFootnoteCallLabelMarker");
      return ok(code2);
    }
  }
  function resolveToPotentialGfmFootnoteCall(events, context) {
    let index = events.length;
    let labelStart;
    while (index--) {
      if (events[index][1].type === "labelImage" && events[index][0] === "enter") {
        labelStart = events[index][1];
        break;
      }
    }
    events[index + 1][1].type = "data";
    events[index + 3][1].type = "gfmFootnoteCallLabelMarker";
    const call = {
      type: "gfmFootnoteCall",
      start: Object.assign({}, events[index + 3][1].start),
      end: Object.assign({}, events[events.length - 1][1].end)
    };
    const marker = {
      type: "gfmFootnoteCallMarker",
      start: Object.assign({}, events[index + 3][1].end),
      end: Object.assign({}, events[index + 3][1].end)
    };
    marker.end.column++;
    marker.end.offset++;
    marker.end._bufferIndex++;
    const string3 = {
      type: "gfmFootnoteCallString",
      start: Object.assign({}, marker.end),
      end: Object.assign({}, events[events.length - 1][1].start)
    };
    const chunk = {
      type: "chunkString",
      contentType: "string",
      start: Object.assign({}, string3.start),
      end: Object.assign({}, string3.end)
    };
    const replacement = [
      // Take the `labelImageMarker` (now `data`, the `!`)
      events[index + 1],
      events[index + 2],
      ["enter", call, context],
      // The `[`
      events[index + 3],
      events[index + 4],
      // The `^`.
      ["enter", marker, context],
      ["exit", marker, context],
      // Everything in between.
      ["enter", string3, context],
      ["enter", chunk, context],
      ["exit", chunk, context],
      ["exit", string3, context],
      // The ending (`]`, properly parsed and labelled).
      events[events.length - 2],
      events[events.length - 1],
      ["exit", call, context]
    ];
    events.splice(index, events.length - index + 1, ...replacement);
    return events;
  }
  function tokenizeGfmFootnoteCall(effects, ok, nok) {
    const self = this;
    const defined = self.parser.gfmFootnotes || (self.parser.gfmFootnotes = []);
    let size = 0;
    let data;
    return start;
    function start(code2) {
      effects.enter("gfmFootnoteCall");
      effects.enter("gfmFootnoteCallLabelMarker");
      effects.consume(code2);
      effects.exit("gfmFootnoteCallLabelMarker");
      return callStart;
    }
    function callStart(code2) {
      if (code2 !== 94) return nok(code2);
      effects.enter("gfmFootnoteCallMarker");
      effects.consume(code2);
      effects.exit("gfmFootnoteCallMarker");
      effects.enter("gfmFootnoteCallString");
      effects.enter("chunkString").contentType = "string";
      return callData;
    }
    function callData(code2) {
      if (
        // Too long.
        size > 999 || // Closing brace with nothing.
        code2 === 93 && !data || // Space or tab is not supported by GFM for some reason.
        // `\n` and `[` not being supported makes sense.
        code2 === null || code2 === 91 || markdownLineEndingOrSpace(code2)
      ) {
        return nok(code2);
      }
      if (code2 === 93) {
        effects.exit("chunkString");
        const token = effects.exit("gfmFootnoteCallString");
        if (!defined.includes(normalizeIdentifier(self.sliceSerialize(token)))) {
          return nok(code2);
        }
        effects.enter("gfmFootnoteCallLabelMarker");
        effects.consume(code2);
        effects.exit("gfmFootnoteCallLabelMarker");
        effects.exit("gfmFootnoteCall");
        return ok;
      }
      if (!markdownLineEndingOrSpace(code2)) {
        data = true;
      }
      size++;
      effects.consume(code2);
      return code2 === 92 ? callEscape : callData;
    }
    function callEscape(code2) {
      if (code2 === 91 || code2 === 92 || code2 === 93) {
        effects.consume(code2);
        size++;
        return callData;
      }
      return callData(code2);
    }
  }
  function tokenizeDefinitionStart(effects, ok, nok) {
    const self = this;
    const defined = self.parser.gfmFootnotes || (self.parser.gfmFootnotes = []);
    let identifier;
    let size = 0;
    let data;
    return start;
    function start(code2) {
      effects.enter("gfmFootnoteDefinition")._container = true;
      effects.enter("gfmFootnoteDefinitionLabel");
      effects.enter("gfmFootnoteDefinitionLabelMarker");
      effects.consume(code2);
      effects.exit("gfmFootnoteDefinitionLabelMarker");
      return labelAtMarker;
    }
    function labelAtMarker(code2) {
      if (code2 === 94) {
        effects.enter("gfmFootnoteDefinitionMarker");
        effects.consume(code2);
        effects.exit("gfmFootnoteDefinitionMarker");
        effects.enter("gfmFootnoteDefinitionLabelString");
        effects.enter("chunkString").contentType = "string";
        return labelInside;
      }
      return nok(code2);
    }
    function labelInside(code2) {
      if (
        // Too long.
        size > 999 || // Closing brace with nothing.
        code2 === 93 && !data || // Space or tab is not supported by GFM for some reason.
        // `\n` and `[` not being supported makes sense.
        code2 === null || code2 === 91 || markdownLineEndingOrSpace(code2)
      ) {
        return nok(code2);
      }
      if (code2 === 93) {
        effects.exit("chunkString");
        const token = effects.exit("gfmFootnoteDefinitionLabelString");
        identifier = normalizeIdentifier(self.sliceSerialize(token));
        effects.enter("gfmFootnoteDefinitionLabelMarker");
        effects.consume(code2);
        effects.exit("gfmFootnoteDefinitionLabelMarker");
        effects.exit("gfmFootnoteDefinitionLabel");
        return labelAfter;
      }
      if (!markdownLineEndingOrSpace(code2)) {
        data = true;
      }
      size++;
      effects.consume(code2);
      return code2 === 92 ? labelEscape : labelInside;
    }
    function labelEscape(code2) {
      if (code2 === 91 || code2 === 92 || code2 === 93) {
        effects.consume(code2);
        size++;
        return labelInside;
      }
      return labelInside(code2);
    }
    function labelAfter(code2) {
      if (code2 === 58) {
        effects.enter("definitionMarker");
        effects.consume(code2);
        effects.exit("definitionMarker");
        if (!defined.includes(identifier)) {
          defined.push(identifier);
        }
        return factorySpace(effects, whitespaceAfter, "gfmFootnoteDefinitionWhitespace");
      }
      return nok(code2);
    }
    function whitespaceAfter(code2) {
      return ok(code2);
    }
  }
  function tokenizeDefinitionContinuation(effects, ok, nok) {
    return effects.check(blankLine, ok, effects.attempt(indent, ok, nok));
  }
  function gfmFootnoteDefinitionEnd(effects) {
    effects.exit("gfmFootnoteDefinition");
  }
  function tokenizeIndent2(effects, ok, nok) {
    const self = this;
    return factorySpace(effects, afterPrefix, "gfmFootnoteDefinitionIndent", 4 + 1);
    function afterPrefix(code2) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === "gfmFootnoteDefinitionIndent" && tail[2].sliceSerialize(tail[1], true).length === 4 ? ok(code2) : nok(code2);
    }
  }

  // node_modules/micromark-extension-gfm-table/lib/edit-map.js
  var EditMap = class {
    /**
     * Create a new edit map.
     */
    constructor() {
      this.map = [];
    }
    /**
     * Create an edit: a remove and/or add at a certain place.
     *
     * @param {number} index
     * @param {number} remove
     * @param {Array<Event>} add
     * @returns {undefined}
     */
    add(index, remove, add) {
      addImplementation(this, index, remove, add);
    }
    // To do: add this when moving to `micromark`.
    // /**
    //  * Create an edit: but insert `add` before existing additions.
    //  *
    //  * @param {number} index
    //  * @param {number} remove
    //  * @param {Array<Event>} add
    //  * @returns {undefined}
    //  */
    // addBefore(index, remove, add) {
    //   addImplementation(this, index, remove, add, true)
    // }
    /**
     * Done, change the events.
     *
     * @param {Array<Event>} events
     * @returns {undefined}
     */
    consume(events) {
      this.map.sort(function(a, b) {
        return a[0] - b[0];
      });
      if (this.map.length === 0) {
        return;
      }
      let index = this.map.length;
      const vecs = [];
      while (index > 0) {
        index -= 1;
        vecs.push(events.slice(this.map[index][0] + this.map[index][1]), this.map[index][2]);
        events.length = this.map[index][0];
      }
      vecs.push(events.slice());
      events.length = 0;
      let slice = vecs.pop();
      while (slice) {
        for (const element of slice) {
          events.push(element);
        }
        slice = vecs.pop();
      }
      this.map.length = 0;
    }
  };
  function addImplementation(editMap, at, remove, add) {
    let index = 0;
    if (remove === 0 && add.length === 0) {
      return;
    }
    while (index < editMap.map.length) {
      if (editMap.map[index][0] === at) {
        editMap.map[index][1] += remove;
        editMap.map[index][2].push(...add);
        return;
      }
      index += 1;
    }
    editMap.map.push([at, remove, add]);
  }

  // node_modules/micromark-extension-gfm-table/lib/infer.js
  function gfmTableAlign(events, index) {
    let inDelimiterRow = false;
    const align = [];
    while (index < events.length) {
      const event = events[index];
      if (inDelimiterRow) {
        if (event[0] === "enter") {
          if (event[1].type === "tableContent") {
            align.push(events[index + 1][1].type === "tableDelimiterMarker" ? "left" : "none");
          }
        } else if (event[1].type === "tableContent") {
          if (events[index - 1][1].type === "tableDelimiterMarker") {
            const alignIndex = align.length - 1;
            align[alignIndex] = align[alignIndex] === "left" ? "center" : "right";
          }
        } else if (event[1].type === "tableDelimiterRow") {
          break;
        }
      } else if (event[0] === "enter" && event[1].type === "tableDelimiterRow") {
        inDelimiterRow = true;
      }
      index += 1;
    }
    return align;
  }

  // node_modules/micromark-extension-gfm-table/lib/syntax.js
  function gfmTable() {
    return {
      flow: {
        null: {
          name: "table",
          tokenize: tokenizeTable,
          resolveAll: resolveTable
        }
      }
    };
  }
  function tokenizeTable(effects, ok, nok) {
    const self = this;
    let size = 0;
    let sizeB = 0;
    let seen;
    return start;
    function start(code2) {
      let index = self.events.length - 1;
      while (index > -1) {
        const type = self.events[index][1].type;
        if (type === "lineEnding" || // Note: markdown-rs uses `whitespace` instead of `linePrefix`
        type === "linePrefix") index--;
        else break;
      }
      const tail = index > -1 ? self.events[index][1].type : null;
      const next = tail === "tableHead" || tail === "tableRow" ? bodyRowStart : headRowBefore;
      if (next === bodyRowStart && self.parser.lazy[self.now().line]) {
        return nok(code2);
      }
      return next(code2);
    }
    function headRowBefore(code2) {
      effects.enter("tableHead");
      effects.enter("tableRow");
      return headRowStart(code2);
    }
    function headRowStart(code2) {
      if (code2 === 124) {
        return headRowBreak(code2);
      }
      seen = true;
      sizeB += 1;
      return headRowBreak(code2);
    }
    function headRowBreak(code2) {
      if (code2 === null) {
        return nok(code2);
      }
      if (markdownLineEnding(code2)) {
        if (sizeB > 1) {
          sizeB = 0;
          self.interrupt = true;
          effects.exit("tableRow");
          effects.enter("lineEnding");
          effects.consume(code2);
          effects.exit("lineEnding");
          return headDelimiterStart;
        }
        return nok(code2);
      }
      if (markdownSpace(code2)) {
        return factorySpace(effects, headRowBreak, "whitespace")(code2);
      }
      sizeB += 1;
      if (seen) {
        seen = false;
        size += 1;
      }
      if (code2 === 124) {
        effects.enter("tableCellDivider");
        effects.consume(code2);
        effects.exit("tableCellDivider");
        seen = true;
        return headRowBreak;
      }
      effects.enter("data");
      return headRowData(code2);
    }
    function headRowData(code2) {
      if (code2 === null || code2 === 124 || markdownLineEndingOrSpace(code2)) {
        effects.exit("data");
        return headRowBreak(code2);
      }
      effects.consume(code2);
      return code2 === 92 ? headRowEscape : headRowData;
    }
    function headRowEscape(code2) {
      if (code2 === 92 || code2 === 124) {
        effects.consume(code2);
        return headRowData;
      }
      return headRowData(code2);
    }
    function headDelimiterStart(code2) {
      self.interrupt = false;
      if (self.parser.lazy[self.now().line]) {
        return nok(code2);
      }
      effects.enter("tableDelimiterRow");
      seen = false;
      if (markdownSpace(code2)) {
        return factorySpace(effects, headDelimiterBefore, "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4)(code2);
      }
      return headDelimiterBefore(code2);
    }
    function headDelimiterBefore(code2) {
      if (code2 === 45 || code2 === 58) {
        return headDelimiterValueBefore(code2);
      }
      if (code2 === 124) {
        seen = true;
        effects.enter("tableCellDivider");
        effects.consume(code2);
        effects.exit("tableCellDivider");
        return headDelimiterCellBefore;
      }
      return headDelimiterNok(code2);
    }
    function headDelimiterCellBefore(code2) {
      if (markdownSpace(code2)) {
        return factorySpace(effects, headDelimiterValueBefore, "whitespace")(code2);
      }
      return headDelimiterValueBefore(code2);
    }
    function headDelimiterValueBefore(code2) {
      if (code2 === 58) {
        sizeB += 1;
        seen = true;
        effects.enter("tableDelimiterMarker");
        effects.consume(code2);
        effects.exit("tableDelimiterMarker");
        return headDelimiterLeftAlignmentAfter;
      }
      if (code2 === 45) {
        sizeB += 1;
        return headDelimiterLeftAlignmentAfter(code2);
      }
      if (code2 === null || markdownLineEnding(code2)) {
        return headDelimiterCellAfter(code2);
      }
      return headDelimiterNok(code2);
    }
    function headDelimiterLeftAlignmentAfter(code2) {
      if (code2 === 45) {
        effects.enter("tableDelimiterFiller");
        return headDelimiterFiller(code2);
      }
      return headDelimiterNok(code2);
    }
    function headDelimiterFiller(code2) {
      if (code2 === 45) {
        effects.consume(code2);
        return headDelimiterFiller;
      }
      if (code2 === 58) {
        seen = true;
        effects.exit("tableDelimiterFiller");
        effects.enter("tableDelimiterMarker");
        effects.consume(code2);
        effects.exit("tableDelimiterMarker");
        return headDelimiterRightAlignmentAfter;
      }
      effects.exit("tableDelimiterFiller");
      return headDelimiterRightAlignmentAfter(code2);
    }
    function headDelimiterRightAlignmentAfter(code2) {
      if (markdownSpace(code2)) {
        return factorySpace(effects, headDelimiterCellAfter, "whitespace")(code2);
      }
      return headDelimiterCellAfter(code2);
    }
    function headDelimiterCellAfter(code2) {
      if (code2 === 124) {
        return headDelimiterBefore(code2);
      }
      if (code2 === null || markdownLineEnding(code2)) {
        if (!seen || size !== sizeB) {
          return headDelimiterNok(code2);
        }
        effects.exit("tableDelimiterRow");
        effects.exit("tableHead");
        return ok(code2);
      }
      return headDelimiterNok(code2);
    }
    function headDelimiterNok(code2) {
      return nok(code2);
    }
    function bodyRowStart(code2) {
      effects.enter("tableRow");
      return bodyRowBreak(code2);
    }
    function bodyRowBreak(code2) {
      if (code2 === 124) {
        effects.enter("tableCellDivider");
        effects.consume(code2);
        effects.exit("tableCellDivider");
        return bodyRowBreak;
      }
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("tableRow");
        return ok(code2);
      }
      if (markdownSpace(code2)) {
        return factorySpace(effects, bodyRowBreak, "whitespace")(code2);
      }
      effects.enter("data");
      return bodyRowData(code2);
    }
    function bodyRowData(code2) {
      if (code2 === null || code2 === 124 || markdownLineEndingOrSpace(code2)) {
        effects.exit("data");
        return bodyRowBreak(code2);
      }
      effects.consume(code2);
      return code2 === 92 ? bodyRowEscape : bodyRowData;
    }
    function bodyRowEscape(code2) {
      if (code2 === 92 || code2 === 124) {
        effects.consume(code2);
        return bodyRowData;
      }
      return bodyRowData(code2);
    }
  }
  function resolveTable(events, context) {
    let index = -1;
    let inFirstCellAwaitingPipe = true;
    let rowKind = 0;
    let lastCell = [0, 0, 0, 0];
    let cell = [0, 0, 0, 0];
    let afterHeadAwaitingFirstBodyRow = false;
    let lastTableEnd = 0;
    let currentTable;
    let currentBody;
    let currentCell;
    const map2 = new EditMap();
    while (++index < events.length) {
      const event = events[index];
      const token = event[1];
      if (event[0] === "enter") {
        if (token.type === "tableHead") {
          afterHeadAwaitingFirstBodyRow = false;
          if (lastTableEnd !== 0) {
            flushTableEnd(map2, context, lastTableEnd, currentTable, currentBody);
            currentBody = void 0;
            lastTableEnd = 0;
          }
          currentTable = {
            type: "table",
            start: Object.assign({}, token.start),
            // Note: correct end is set later.
            end: Object.assign({}, token.end)
          };
          map2.add(index, 0, [["enter", currentTable, context]]);
        } else if (token.type === "tableRow" || token.type === "tableDelimiterRow") {
          inFirstCellAwaitingPipe = true;
          currentCell = void 0;
          lastCell = [0, 0, 0, 0];
          cell = [0, index + 1, 0, 0];
          if (afterHeadAwaitingFirstBodyRow) {
            afterHeadAwaitingFirstBodyRow = false;
            currentBody = {
              type: "tableBody",
              start: Object.assign({}, token.start),
              // Note: correct end is set later.
              end: Object.assign({}, token.end)
            };
            map2.add(index, 0, [["enter", currentBody, context]]);
          }
          rowKind = token.type === "tableDelimiterRow" ? 2 : currentBody ? 3 : 1;
        } else if (rowKind && (token.type === "data" || token.type === "tableDelimiterMarker" || token.type === "tableDelimiterFiller")) {
          inFirstCellAwaitingPipe = false;
          if (cell[2] === 0) {
            if (lastCell[1] !== 0) {
              cell[0] = cell[1];
              currentCell = flushCell(map2, context, lastCell, rowKind, void 0, currentCell);
              lastCell = [0, 0, 0, 0];
            }
            cell[2] = index;
          }
        } else if (token.type === "tableCellDivider") {
          if (inFirstCellAwaitingPipe) {
            inFirstCellAwaitingPipe = false;
          } else {
            if (lastCell[1] !== 0) {
              cell[0] = cell[1];
              currentCell = flushCell(map2, context, lastCell, rowKind, void 0, currentCell);
            }
            lastCell = cell;
            cell = [lastCell[1], index, 0, 0];
          }
        }
      } else if (token.type === "tableHead") {
        afterHeadAwaitingFirstBodyRow = true;
        lastTableEnd = index;
      } else if (token.type === "tableRow" || token.type === "tableDelimiterRow") {
        lastTableEnd = index;
        if (lastCell[1] !== 0) {
          cell[0] = cell[1];
          currentCell = flushCell(map2, context, lastCell, rowKind, index, currentCell);
        } else if (cell[1] !== 0) {
          currentCell = flushCell(map2, context, cell, rowKind, index, currentCell);
        }
        rowKind = 0;
      } else if (rowKind && (token.type === "data" || token.type === "tableDelimiterMarker" || token.type === "tableDelimiterFiller")) {
        cell[3] = index;
      }
    }
    if (lastTableEnd !== 0) {
      flushTableEnd(map2, context, lastTableEnd, currentTable, currentBody);
    }
    map2.consume(context.events);
    index = -1;
    while (++index < context.events.length) {
      const event = context.events[index];
      if (event[0] === "enter" && event[1].type === "table") {
        event[1]._align = gfmTableAlign(context.events, index);
      }
    }
    return events;
  }
  function flushCell(map2, context, range, rowKind, rowEnd, previousCell) {
    const groupName = rowKind === 1 ? "tableHeader" : rowKind === 2 ? "tableDelimiter" : "tableData";
    const valueName = "tableContent";
    if (range[0] !== 0) {
      previousCell.end = Object.assign({}, getPoint(context.events, range[0]));
      map2.add(range[0], 0, [["exit", previousCell, context]]);
    }
    const now = getPoint(context.events, range[1]);
    previousCell = {
      type: groupName,
      start: Object.assign({}, now),
      // Note: correct end is set later.
      end: Object.assign({}, now)
    };
    map2.add(range[1], 0, [["enter", previousCell, context]]);
    if (range[2] !== 0) {
      const relatedStart = getPoint(context.events, range[2]);
      const relatedEnd = getPoint(context.events, range[3]);
      const valueToken = {
        type: valueName,
        start: Object.assign({}, relatedStart),
        end: Object.assign({}, relatedEnd)
      };
      map2.add(range[2], 0, [["enter", valueToken, context]]);
      if (rowKind !== 2) {
        const start = context.events[range[2]];
        const end = context.events[range[3]];
        start[1].end = Object.assign({}, end[1].end);
        start[1].type = "chunkText";
        start[1].contentType = "text";
        if (range[3] > range[2] + 1) {
          const a = range[2] + 1;
          const b = range[3] - range[2] - 1;
          map2.add(a, b, []);
        }
      }
      map2.add(range[3] + 1, 0, [["exit", valueToken, context]]);
    }
    if (rowEnd !== void 0) {
      previousCell.end = Object.assign({}, getPoint(context.events, rowEnd));
      map2.add(rowEnd, 0, [["exit", previousCell, context]]);
      previousCell = void 0;
    }
    return previousCell;
  }
  function flushTableEnd(map2, context, index, table, tableBody) {
    const exits = [];
    const related = getPoint(context.events, index);
    if (tableBody) {
      tableBody.end = Object.assign({}, related);
      exits.push(["exit", tableBody, context]);
    }
    table.end = Object.assign({}, related);
    exits.push(["exit", table, context]);
    map2.add(index + 1, 0, exits);
  }
  function getPoint(events, index) {
    const event = events[index];
    const side = event[0] === "enter" ? "start" : "end";
    return event[1][side];
  }

  // node_modules/micromark-extension-math/lib/math-flow.js
  var mathFlow = {
    tokenize: tokenizeMathFenced,
    concrete: true,
    name: "mathFlow"
  };
  var nonLazyContinuation2 = {
    tokenize: tokenizeNonLazyContinuation2,
    partial: true
  };
  function tokenizeMathFenced(effects, ok, nok) {
    const self = this;
    const tail = self.events[self.events.length - 1];
    const initialSize = tail && tail[1].type === "linePrefix" ? tail[2].sliceSerialize(tail[1], true).length : 0;
    let sizeOpen = 0;
    return start;
    function start(code2) {
      effects.enter("mathFlow");
      effects.enter("mathFlowFence");
      effects.enter("mathFlowFenceSequence");
      return sequenceOpen(code2);
    }
    function sequenceOpen(code2) {
      if (code2 === 36) {
        effects.consume(code2);
        sizeOpen++;
        return sequenceOpen;
      }
      if (sizeOpen < 2) {
        return nok(code2);
      }
      effects.exit("mathFlowFenceSequence");
      return factorySpace(effects, metaBefore, "whitespace")(code2);
    }
    function metaBefore(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        return metaAfter(code2);
      }
      effects.enter("mathFlowFenceMeta");
      effects.enter("chunkString", {
        contentType: "string"
      });
      return meta(code2);
    }
    function meta(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("chunkString");
        effects.exit("mathFlowFenceMeta");
        return metaAfter(code2);
      }
      if (code2 === 36) {
        return nok(code2);
      }
      effects.consume(code2);
      return meta;
    }
    function metaAfter(code2) {
      effects.exit("mathFlowFence");
      if (self.interrupt) {
        return ok(code2);
      }
      return effects.attempt(nonLazyContinuation2, beforeNonLazyContinuation, after)(code2);
    }
    function beforeNonLazyContinuation(code2) {
      return effects.attempt({
        tokenize: tokenizeClosingFence,
        partial: true
      }, after, contentStart)(code2);
    }
    function contentStart(code2) {
      return (initialSize ? factorySpace(effects, beforeContentChunk, "linePrefix", initialSize + 1) : beforeContentChunk)(code2);
    }
    function beforeContentChunk(code2) {
      if (code2 === null) {
        return after(code2);
      }
      if (markdownLineEnding(code2)) {
        return effects.attempt(nonLazyContinuation2, beforeNonLazyContinuation, after)(code2);
      }
      effects.enter("mathFlowValue");
      return contentChunk(code2);
    }
    function contentChunk(code2) {
      if (code2 === null || markdownLineEnding(code2)) {
        effects.exit("mathFlowValue");
        return beforeContentChunk(code2);
      }
      effects.consume(code2);
      return contentChunk;
    }
    function after(code2) {
      effects.exit("mathFlow");
      return ok(code2);
    }
    function tokenizeClosingFence(effects2, ok2, nok2) {
      let size = 0;
      return factorySpace(effects2, beforeSequenceClose, "linePrefix", self.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4);
      function beforeSequenceClose(code2) {
        effects2.enter("mathFlowFence");
        effects2.enter("mathFlowFenceSequence");
        return sequenceClose(code2);
      }
      function sequenceClose(code2) {
        if (code2 === 36) {
          size++;
          effects2.consume(code2);
          return sequenceClose;
        }
        if (size < sizeOpen) {
          return nok2(code2);
        }
        effects2.exit("mathFlowFenceSequence");
        return factorySpace(effects2, afterSequenceClose, "whitespace")(code2);
      }
      function afterSequenceClose(code2) {
        if (code2 === null || markdownLineEnding(code2)) {
          effects2.exit("mathFlowFence");
          return ok2(code2);
        }
        return nok2(code2);
      }
    }
  }
  function tokenizeNonLazyContinuation2(effects, ok, nok) {
    const self = this;
    return start;
    function start(code2) {
      if (code2 === null) {
        return ok(code2);
      }
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return lineStart;
    }
    function lineStart(code2) {
      return self.parser.lazy[self.now().line] ? nok(code2) : ok(code2);
    }
  }

  // node_modules/micromark-extension-math/lib/math-text.js
  function mathText(options) {
    const options_ = options || {};
    let single = options_.singleDollarTextMath;
    if (single === null || single === void 0) {
      single = true;
    }
    return {
      tokenize: tokenizeMathText,
      resolve: resolveMathText,
      previous: previous3,
      name: "mathText"
    };
    function tokenizeMathText(effects, ok, nok) {
      const self = this;
      let sizeOpen = 0;
      let size;
      let token;
      return start;
      function start(code2) {
        effects.enter("mathText");
        effects.enter("mathTextSequence");
        return sequenceOpen(code2);
      }
      function sequenceOpen(code2) {
        if (code2 === 36) {
          effects.consume(code2);
          sizeOpen++;
          return sequenceOpen;
        }
        if (sizeOpen < 2 && !single) {
          return nok(code2);
        }
        effects.exit("mathTextSequence");
        return between(code2);
      }
      function between(code2) {
        if (code2 === null) {
          return nok(code2);
        }
        if (code2 === 36) {
          token = effects.enter("mathTextSequence");
          size = 0;
          return sequenceClose(code2);
        }
        if (code2 === 32) {
          effects.enter("space");
          effects.consume(code2);
          effects.exit("space");
          return between;
        }
        if (markdownLineEnding(code2)) {
          effects.enter("lineEnding");
          effects.consume(code2);
          effects.exit("lineEnding");
          return between;
        }
        effects.enter("mathTextData");
        return data(code2);
      }
      function data(code2) {
        if (code2 === null || code2 === 32 || code2 === 36 || markdownLineEnding(code2)) {
          effects.exit("mathTextData");
          return between(code2);
        }
        effects.consume(code2);
        return data;
      }
      function sequenceClose(code2) {
        if (code2 === 36) {
          effects.consume(code2);
          size++;
          return sequenceClose;
        }
        if (size === sizeOpen) {
          effects.exit("mathTextSequence");
          effects.exit("mathText");
          return ok(code2);
        }
        token.type = "mathTextData";
        return data(code2);
      }
    }
  }
  function resolveMathText(events) {
    let tailExitIndex = events.length - 4;
    let headEnterIndex = 3;
    let index;
    let enter;
    if ((events[headEnterIndex][1].type === "lineEnding" || events[headEnterIndex][1].type === "space") && (events[tailExitIndex][1].type === "lineEnding" || events[tailExitIndex][1].type === "space")) {
      index = headEnterIndex;
      while (++index < tailExitIndex) {
        if (events[index][1].type === "mathTextData") {
          events[tailExitIndex][1].type = "mathTextPadding";
          events[headEnterIndex][1].type = "mathTextPadding";
          headEnterIndex += 2;
          tailExitIndex -= 2;
          break;
        }
      }
    }
    index = headEnterIndex - 1;
    tailExitIndex++;
    while (++index <= tailExitIndex) {
      if (enter === void 0) {
        if (index !== tailExitIndex && events[index][1].type !== "lineEnding") {
          enter = index;
        }
      } else if (index === tailExitIndex || events[index][1].type === "lineEnding") {
        events[enter][1].type = "mathTextData";
        if (index !== enter + 2) {
          events[enter][1].end = events[index - 1][1].end;
          events.splice(enter + 2, index - enter - 2);
          tailExitIndex -= index - enter - 2;
          index = enter + 2;
        }
        enter = void 0;
      }
    }
    return events;
  }
  function previous3(code2) {
    return code2 !== 36 || this.events[this.events.length - 1][1].type === "characterEscape";
  }

  // node_modules/micromark-extension-math/lib/syntax.js
  function math(options) {
    return {
      flow: {
        [36]: mathFlow
      },
      text: {
        [36]: mathText(options)
      }
    };
  }

  // node_modules/micromark-util-combine-extensions/index.js
  var hasOwnProperty = {}.hasOwnProperty;
  function combineExtensions(extensions) {
    const all = {};
    let index = -1;
    while (++index < extensions.length) {
      syntaxExtension(all, extensions[index]);
    }
    return all;
  }
  function syntaxExtension(all, extension) {
    let hook;
    for (hook in extension) {
      const maybe = hasOwnProperty.call(all, hook) ? all[hook] : void 0;
      const left = maybe || (all[hook] = {});
      const right = extension[hook];
      let code2;
      if (right) {
        for (code2 in right) {
          if (!hasOwnProperty.call(left, code2)) left[code2] = [];
          const value = right[code2];
          constructs(
            // @ts-expect-error Looks like a list.
            left[code2],
            Array.isArray(value) ? value : value ? [value] : []
          );
        }
      }
    }
  }
  function constructs(existing, list2) {
    let index = -1;
    const before = [];
    while (++index < list2.length) {
      ;
      (list2[index].add === "after" ? existing : before).push(list2[index]);
    }
    splice(existing, 0, 0, before);
  }

  // node_modules/micromark/lib/initialize/content.js
  var content2 = {
    tokenize: initializeContent
  };
  function initializeContent(effects) {
    const contentStart = effects.attempt(this.parser.constructs.contentInitial, afterContentStartConstruct, paragraphInitial);
    let previous4;
    return contentStart;
    function afterContentStartConstruct(code2) {
      if (code2 === null) {
        effects.consume(code2);
        return;
      }
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      return factorySpace(effects, contentStart, "linePrefix");
    }
    function paragraphInitial(code2) {
      effects.enter("paragraph");
      return lineStart(code2);
    }
    function lineStart(code2) {
      const token = effects.enter("chunkText", {
        contentType: "text",
        previous: previous4
      });
      if (previous4) {
        previous4.next = token;
      }
      previous4 = token;
      return data(code2);
    }
    function data(code2) {
      if (code2 === null) {
        effects.exit("chunkText");
        effects.exit("paragraph");
        effects.consume(code2);
        return;
      }
      if (markdownLineEnding(code2)) {
        effects.consume(code2);
        effects.exit("chunkText");
        return lineStart;
      }
      effects.consume(code2);
      return data;
    }
  }

  // node_modules/micromark/lib/initialize/document.js
  var document = {
    tokenize: initializeDocument
  };
  var containerConstruct = {
    tokenize: tokenizeContainer
  };
  function initializeDocument(effects) {
    const self = this;
    const stack = [];
    let continued = 0;
    let childFlow;
    let childToken;
    let lineStartOffset;
    return start;
    function start(code2) {
      if (continued < stack.length) {
        const item = stack[continued];
        self.containerState = item[1];
        return effects.attempt(item[0].continuation, documentContinue, checkNewContainers)(code2);
      }
      return checkNewContainers(code2);
    }
    function documentContinue(code2) {
      continued++;
      if (self.containerState._closeFlow) {
        self.containerState._closeFlow = void 0;
        if (childFlow) {
          closeFlow();
        }
        const indexBeforeExits = self.events.length;
        let indexBeforeFlow = indexBeforeExits;
        let point;
        while (indexBeforeFlow--) {
          if (self.events[indexBeforeFlow][0] === "exit" && self.events[indexBeforeFlow][1].type === "chunkFlow") {
            point = self.events[indexBeforeFlow][1].end;
            break;
          }
        }
        exitContainers(continued);
        let index = indexBeforeExits;
        while (index < self.events.length) {
          self.events[index][1].end = {
            ...point
          };
          index++;
        }
        splice(self.events, indexBeforeFlow + 1, 0, self.events.slice(indexBeforeExits));
        self.events.length = index;
        return checkNewContainers(code2);
      }
      return start(code2);
    }
    function checkNewContainers(code2) {
      if (continued === stack.length) {
        if (!childFlow) {
          return documentContinued(code2);
        }
        if (childFlow.currentConstruct && childFlow.currentConstruct.concrete) {
          return flowStart(code2);
        }
        self.interrupt = Boolean(childFlow.currentConstruct && !childFlow._gfmTableDynamicInterruptHack);
      }
      self.containerState = {};
      return effects.check(containerConstruct, thereIsANewContainer, thereIsNoNewContainer)(code2);
    }
    function thereIsANewContainer(code2) {
      if (childFlow) closeFlow();
      exitContainers(continued);
      return documentContinued(code2);
    }
    function thereIsNoNewContainer(code2) {
      self.parser.lazy[self.now().line] = continued !== stack.length;
      lineStartOffset = self.now().offset;
      return flowStart(code2);
    }
    function documentContinued(code2) {
      self.containerState = {};
      return effects.attempt(containerConstruct, containerContinue, flowStart)(code2);
    }
    function containerContinue(code2) {
      continued++;
      stack.push([self.currentConstruct, self.containerState]);
      return documentContinued(code2);
    }
    function flowStart(code2) {
      if (code2 === null) {
        if (childFlow) closeFlow();
        exitContainers(0);
        effects.consume(code2);
        return;
      }
      childFlow = childFlow || self.parser.flow(self.now());
      effects.enter("chunkFlow", {
        _tokenizer: childFlow,
        contentType: "flow",
        previous: childToken
      });
      return flowContinue(code2);
    }
    function flowContinue(code2) {
      if (code2 === null) {
        writeToChild(effects.exit("chunkFlow"), true);
        exitContainers(0);
        effects.consume(code2);
        return;
      }
      if (markdownLineEnding(code2)) {
        effects.consume(code2);
        writeToChild(effects.exit("chunkFlow"));
        continued = 0;
        self.interrupt = void 0;
        return start;
      }
      effects.consume(code2);
      return flowContinue;
    }
    function writeToChild(token, endOfFile) {
      const stream = self.sliceStream(token);
      if (endOfFile) stream.push(null);
      token.previous = childToken;
      if (childToken) childToken.next = token;
      childToken = token;
      childFlow.defineSkip(token.start);
      childFlow.write(stream);
      if (self.parser.lazy[token.start.line]) {
        let index = childFlow.events.length;
        while (index--) {
          if (
            // The token starts before the line ending…
            childFlow.events[index][1].start.offset < lineStartOffset && // …and either is not ended yet…
            (!childFlow.events[index][1].end || // …or ends after it.
            childFlow.events[index][1].end.offset > lineStartOffset)
          ) {
            return;
          }
        }
        const indexBeforeExits = self.events.length;
        let indexBeforeFlow = indexBeforeExits;
        let seen;
        let point;
        while (indexBeforeFlow--) {
          if (self.events[indexBeforeFlow][0] === "exit" && self.events[indexBeforeFlow][1].type === "chunkFlow") {
            if (seen) {
              point = self.events[indexBeforeFlow][1].end;
              break;
            }
            seen = true;
          }
        }
        exitContainers(continued);
        index = indexBeforeExits;
        while (index < self.events.length) {
          self.events[index][1].end = {
            ...point
          };
          index++;
        }
        splice(self.events, indexBeforeFlow + 1, 0, self.events.slice(indexBeforeExits));
        self.events.length = index;
      }
    }
    function exitContainers(size) {
      let index = stack.length;
      while (index-- > size) {
        const entry = stack[index];
        self.containerState = entry[1];
        entry[0].exit.call(self, effects);
      }
      stack.length = size;
    }
    function closeFlow() {
      childFlow.write([null]);
      childToken = void 0;
      childFlow = void 0;
      self.containerState._closeFlow = void 0;
    }
  }
  function tokenizeContainer(effects, ok, nok) {
    return factorySpace(effects, effects.attempt(this.parser.constructs.document, ok, nok), "linePrefix", this.parser.constructs.disable.null.includes("codeIndented") ? void 0 : 4);
  }

  // node_modules/micromark/lib/initialize/flow.js
  var flow = {
    tokenize: initializeFlow
  };
  function initializeFlow(effects) {
    const self = this;
    const initial = effects.attempt(
      // Try to parse a blank line.
      blankLine,
      atBlankEnding,
      // Try to parse initial flow (essentially, only code).
      effects.attempt(this.parser.constructs.flowInitial, afterConstruct, factorySpace(effects, effects.attempt(this.parser.constructs.flow, afterConstruct, effects.attempt(content, afterConstruct)), "linePrefix"))
    );
    return initial;
    function atBlankEnding(code2) {
      if (code2 === null) {
        effects.consume(code2);
        return;
      }
      effects.enter("lineEndingBlank");
      effects.consume(code2);
      effects.exit("lineEndingBlank");
      self.currentConstruct = void 0;
      return initial;
    }
    function afterConstruct(code2) {
      if (code2 === null) {
        effects.consume(code2);
        return;
      }
      effects.enter("lineEnding");
      effects.consume(code2);
      effects.exit("lineEnding");
      self.currentConstruct = void 0;
      return initial;
    }
  }

  // node_modules/micromark/lib/initialize/text.js
  var resolver = {
    resolveAll: createResolver()
  };
  var string = initializeFactory("string");
  var text2 = initializeFactory("text");
  function initializeFactory(field) {
    return {
      resolveAll: createResolver(field === "text" ? resolveAllLineSuffixes : void 0),
      tokenize: initializeText
    };
    function initializeText(effects) {
      const self = this;
      const constructs2 = this.parser.constructs[field];
      const text4 = effects.attempt(constructs2, start, notText);
      return start;
      function start(code2) {
        return atBreak(code2) ? text4(code2) : notText(code2);
      }
      function notText(code2) {
        if (code2 === null) {
          effects.consume(code2);
          return;
        }
        effects.enter("data");
        effects.consume(code2);
        return data;
      }
      function data(code2) {
        if (atBreak(code2)) {
          effects.exit("data");
          return text4(code2);
        }
        effects.consume(code2);
        return data;
      }
      function atBreak(code2) {
        if (code2 === null) {
          return true;
        }
        const list2 = constructs2[code2];
        let index = -1;
        if (list2) {
          while (++index < list2.length) {
            const item = list2[index];
            if (!item.previous || item.previous.call(self, self.previous)) {
              return true;
            }
          }
        }
        return false;
      }
    }
  }
  function createResolver(extraResolver) {
    return resolveAllText;
    function resolveAllText(events, context) {
      let index = -1;
      let enter;
      while (++index <= events.length) {
        if (enter === void 0) {
          if (events[index] && events[index][1].type === "data") {
            enter = index;
            index++;
          }
        } else if (!events[index] || events[index][1].type !== "data") {
          if (index !== enter + 2) {
            events[enter][1].end = events[index - 1][1].end;
            events.splice(enter + 2, index - enter - 2);
            index = enter + 2;
          }
          enter = void 0;
        }
      }
      return extraResolver ? extraResolver(events, context) : events;
    }
  }
  function resolveAllLineSuffixes(events, context) {
    let eventIndex = 0;
    while (++eventIndex <= events.length) {
      if ((eventIndex === events.length || events[eventIndex][1].type === "lineEnding") && events[eventIndex - 1][1].type === "data") {
        const data = events[eventIndex - 1][1];
        const chunks = context.sliceStream(data);
        let index = chunks.length;
        let bufferIndex = -1;
        let size = 0;
        let tabs;
        while (index--) {
          const chunk = chunks[index];
          if (typeof chunk === "string") {
            bufferIndex = chunk.length;
            while (chunk.charCodeAt(bufferIndex - 1) === 32) {
              size++;
              bufferIndex--;
            }
            if (bufferIndex) break;
            bufferIndex = -1;
          } else if (chunk === -2) {
            tabs = true;
            size++;
          } else if (chunk === -1) {
          } else {
            index++;
            break;
          }
        }
        if (context._contentTypeTextTrailing && eventIndex === events.length) {
          size = 0;
        }
        if (size) {
          const token = {
            type: eventIndex === events.length || tabs || size < 2 ? "lineSuffix" : "hardBreakTrailing",
            start: {
              _bufferIndex: index ? bufferIndex : data.start._bufferIndex + bufferIndex,
              _index: data.start._index + index,
              line: data.end.line,
              column: data.end.column - size,
              offset: data.end.offset - size
            },
            end: {
              ...data.end
            }
          };
          data.end = {
            ...token.start
          };
          if (data.start.offset === data.end.offset) {
            Object.assign(data, token);
          } else {
            events.splice(eventIndex, 0, ["enter", token, context], ["exit", token, context]);
            eventIndex += 2;
          }
        }
        eventIndex++;
      }
    }
    return events;
  }

  // node_modules/micromark/lib/constructs.js
  var constructs_exports = {};
  __export(constructs_exports, {
    attentionMarkers: () => attentionMarkers,
    contentInitial: () => contentInitial,
    disable: () => disable,
    document: () => document2,
    flow: () => flow2,
    flowInitial: () => flowInitial,
    insideSpan: () => insideSpan,
    string: () => string2,
    text: () => text3
  });
  var document2 = {
    [42]: list,
    [43]: list,
    [45]: list,
    [48]: list,
    [49]: list,
    [50]: list,
    [51]: list,
    [52]: list,
    [53]: list,
    [54]: list,
    [55]: list,
    [56]: list,
    [57]: list,
    [62]: blockQuote
  };
  var contentInitial = {
    [91]: definition
  };
  var flowInitial = {
    [-2]: codeIndented,
    [-1]: codeIndented,
    [32]: codeIndented
  };
  var flow2 = {
    [35]: headingAtx,
    [42]: thematicBreak,
    [45]: [setextUnderline, thematicBreak],
    [60]: htmlFlow,
    [61]: setextUnderline,
    [95]: thematicBreak,
    [96]: codeFenced,
    [126]: codeFenced
  };
  var string2 = {
    [38]: characterReference,
    [92]: characterEscape
  };
  var text3 = {
    [-5]: lineEnding,
    [-4]: lineEnding,
    [-3]: lineEnding,
    [33]: labelStartImage,
    [38]: characterReference,
    [42]: attention,
    [60]: [autolink, htmlText],
    [91]: labelStartLink,
    [92]: [hardBreakEscape, characterEscape],
    [93]: labelEnd,
    [95]: attention,
    [96]: codeText
  };
  var insideSpan = {
    null: [attention, resolver]
  };
  var attentionMarkers = {
    null: [42, 95]
  };
  var disable = {
    null: []
  };

  // node_modules/micromark/lib/create-tokenizer.js
  function createTokenizer(parser, initialize2, from) {
    let point = {
      _bufferIndex: -1,
      _index: 0,
      line: from && from.line || 1,
      column: from && from.column || 1,
      offset: from && from.offset || 0
    };
    const columnStart = {};
    const resolveAllConstructs = [];
    let chunks = [];
    let stack = [];
    let consumed = true;
    const effects = {
      attempt: constructFactory(onsuccessfulconstruct),
      check: constructFactory(onsuccessfulcheck),
      consume,
      enter,
      exit: exit2,
      interrupt: constructFactory(onsuccessfulcheck, {
        interrupt: true
      })
    };
    const context = {
      code: null,
      containerState: {},
      defineSkip,
      events: [],
      now,
      parser,
      previous: null,
      sliceSerialize,
      sliceStream,
      write
    };
    let state = initialize2.tokenize.call(context, effects);
    let expectedCode;
    if (initialize2.resolveAll) {
      resolveAllConstructs.push(initialize2);
    }
    return context;
    function write(slice) {
      chunks = push(chunks, slice);
      main();
      if (chunks[chunks.length - 1] !== null) {
        return [];
      }
      addResult(initialize2, 0);
      context.events = resolveAll(resolveAllConstructs, context.events, context);
      return context.events;
    }
    function sliceSerialize(token, expandTabs) {
      return serializeChunks(sliceStream(token), expandTabs);
    }
    function sliceStream(token) {
      return sliceChunks(chunks, token);
    }
    function now() {
      const {
        _bufferIndex,
        _index,
        line,
        column,
        offset
      } = point;
      return {
        _bufferIndex,
        _index,
        line,
        column,
        offset
      };
    }
    function defineSkip(value) {
      columnStart[value.line] = value.column;
      accountForPotentialSkip();
    }
    function main() {
      let chunkIndex;
      while (point._index < chunks.length) {
        const chunk = chunks[point._index];
        if (typeof chunk === "string") {
          chunkIndex = point._index;
          if (point._bufferIndex < 0) {
            point._bufferIndex = 0;
          }
          while (point._index === chunkIndex && point._bufferIndex < chunk.length) {
            go(chunk.charCodeAt(point._bufferIndex));
          }
        } else {
          go(chunk);
        }
      }
    }
    function go(code2) {
      consumed = void 0;
      expectedCode = code2;
      state = state(code2);
    }
    function consume(code2) {
      if (markdownLineEnding(code2)) {
        point.line++;
        point.column = 1;
        point.offset += code2 === -3 ? 2 : 1;
        accountForPotentialSkip();
      } else if (code2 !== -1) {
        point.column++;
        point.offset++;
      }
      if (point._bufferIndex < 0) {
        point._index++;
      } else {
        point._bufferIndex++;
        if (point._bufferIndex === // Points w/ non-negative `_bufferIndex` reference
        // strings.
        /** @type {string} */
        chunks[point._index].length) {
          point._bufferIndex = -1;
          point._index++;
        }
      }
      context.previous = code2;
      consumed = true;
    }
    function enter(type, fields) {
      const token = fields || {};
      token.type = type;
      token.start = now();
      context.events.push(["enter", token, context]);
      stack.push(token);
      return token;
    }
    function exit2(type) {
      const token = stack.pop();
      token.end = now();
      context.events.push(["exit", token, context]);
      return token;
    }
    function onsuccessfulconstruct(construct, info) {
      addResult(construct, info.from);
    }
    function onsuccessfulcheck(_, info) {
      info.restore();
    }
    function constructFactory(onreturn, fields) {
      return hook;
      function hook(constructs2, returnState, bogusState) {
        let listOfConstructs;
        let constructIndex;
        let currentConstruct;
        let info;
        return Array.isArray(constructs2) ? (
          /* c8 ignore next 1 */
          handleListOfConstructs(constructs2)
        ) : "tokenize" in constructs2 ? (
          // Looks like a construct.
          handleListOfConstructs([
            /** @type {Construct} */
            constructs2
          ])
        ) : handleMapOfConstructs(constructs2);
        function handleMapOfConstructs(map2) {
          return start;
          function start(code2) {
            const left = code2 !== null && map2[code2];
            const all = code2 !== null && map2.null;
            const list2 = [
              // To do: add more extension tests.
              /* c8 ignore next 2 */
              ...Array.isArray(left) ? left : left ? [left] : [],
              ...Array.isArray(all) ? all : all ? [all] : []
            ];
            return handleListOfConstructs(list2)(code2);
          }
        }
        function handleListOfConstructs(list2) {
          listOfConstructs = list2;
          constructIndex = 0;
          if (list2.length === 0) {
            return bogusState;
          }
          return handleConstruct(list2[constructIndex]);
        }
        function handleConstruct(construct) {
          return start;
          function start(code2) {
            info = store();
            currentConstruct = construct;
            if (!construct.partial) {
              context.currentConstruct = construct;
            }
            if (construct.name && context.parser.constructs.disable.null.includes(construct.name)) {
              return nok(code2);
            }
            return construct.tokenize.call(
              // If we do have fields, create an object w/ `context` as its
              // prototype.
              // This allows a “live binding”, which is needed for `interrupt`.
              fields ? Object.assign(Object.create(context), fields) : context,
              effects,
              ok,
              nok
            )(code2);
          }
        }
        function ok(code2) {
          consumed = true;
          onreturn(currentConstruct, info);
          return returnState;
        }
        function nok(code2) {
          consumed = true;
          info.restore();
          if (++constructIndex < listOfConstructs.length) {
            return handleConstruct(listOfConstructs[constructIndex]);
          }
          return bogusState;
        }
      }
    }
    function addResult(construct, from2) {
      if (construct.resolveAll && !resolveAllConstructs.includes(construct)) {
        resolveAllConstructs.push(construct);
      }
      if (construct.resolve) {
        splice(context.events, from2, context.events.length - from2, construct.resolve(context.events.slice(from2), context));
      }
      if (construct.resolveTo) {
        context.events = construct.resolveTo(context.events, context);
      }
    }
    function store() {
      const startPoint = now();
      const startPrevious = context.previous;
      const startCurrentConstruct = context.currentConstruct;
      const startEventsIndex = context.events.length;
      const startStack = Array.from(stack);
      return {
        from: startEventsIndex,
        restore
      };
      function restore() {
        point = startPoint;
        context.previous = startPrevious;
        context.currentConstruct = startCurrentConstruct;
        context.events.length = startEventsIndex;
        stack = startStack;
        accountForPotentialSkip();
      }
    }
    function accountForPotentialSkip() {
      if (point.line in columnStart && point.column < 2) {
        point.column = columnStart[point.line];
        point.offset += columnStart[point.line] - 1;
      }
    }
  }
  function sliceChunks(chunks, token) {
    const startIndex = token.start._index;
    const startBufferIndex = token.start._bufferIndex;
    const endIndex = token.end._index;
    const endBufferIndex = token.end._bufferIndex;
    let view;
    if (startIndex === endIndex) {
      view = [chunks[startIndex].slice(startBufferIndex, endBufferIndex)];
    } else {
      view = chunks.slice(startIndex, endIndex);
      if (startBufferIndex > -1) {
        const head = view[0];
        if (typeof head === "string") {
          view[0] = head.slice(startBufferIndex);
        } else {
          view.shift();
        }
      }
      if (endBufferIndex > 0) {
        view.push(chunks[endIndex].slice(0, endBufferIndex));
      }
    }
    return view;
  }
  function serializeChunks(chunks, expandTabs) {
    let index = -1;
    const result = [];
    let atTab;
    while (++index < chunks.length) {
      const chunk = chunks[index];
      let value;
      if (typeof chunk === "string") {
        value = chunk;
      } else switch (chunk) {
        case -5: {
          value = "\r";
          break;
        }
        case -4: {
          value = "\n";
          break;
        }
        case -3: {
          value = "\r\n";
          break;
        }
        case -2: {
          value = expandTabs ? " " : "	";
          break;
        }
        case -1: {
          if (!expandTabs && atTab) continue;
          value = " ";
          break;
        }
        default: {
          value = String.fromCharCode(chunk);
        }
      }
      atTab = chunk === -2;
      result.push(value);
    }
    return result.join("");
  }

  // node_modules/micromark/lib/parse.js
  function parse(options) {
    const settings = options || {};
    const constructs2 = (
      /** @type {FullNormalizedExtension} */
      combineExtensions([constructs_exports, ...settings.extensions || []])
    );
    const parser = {
      constructs: constructs2,
      content: create(content2),
      defined: [],
      document: create(document),
      flow: create(flow),
      lazy: {},
      string: create(string),
      text: create(text2)
    };
    return parser;
    function create(initial) {
      return creator;
      function creator(from) {
        return createTokenizer(parser, initial, from);
      }
    }
  }

  // node_modules/micromark/lib/postprocess.js
  function postprocess(events) {
    while (!subtokenize(events)) {
    }
    return events;
  }

  // node_modules/micromark/lib/preprocess.js
  var search = /[\0\t\n\r]/g;
  function preprocess() {
    let column = 1;
    let buffer = "";
    let start = true;
    let atCarriageReturn;
    return preprocessor;
    function preprocessor(value, encoding, end) {
      const chunks = [];
      let match;
      let next;
      let startPosition;
      let endPosition;
      let code2;
      value = buffer + (typeof value === "string" ? value.toString() : new TextDecoder(encoding || void 0).decode(value));
      startPosition = 0;
      buffer = "";
      if (start) {
        if (value.charCodeAt(0) === 65279) {
          startPosition++;
        }
        start = void 0;
      }
      while (startPosition < value.length) {
        search.lastIndex = startPosition;
        match = search.exec(value);
        endPosition = match && match.index !== void 0 ? match.index : value.length;
        code2 = value.charCodeAt(endPosition);
        if (!match) {
          buffer = value.slice(startPosition);
          break;
        }
        if (code2 === 10 && startPosition === endPosition && atCarriageReturn) {
          chunks.push(-3);
          atCarriageReturn = void 0;
        } else {
          if (atCarriageReturn) {
            chunks.push(-5);
            atCarriageReturn = void 0;
          }
          if (startPosition < endPosition) {
            chunks.push(value.slice(startPosition, endPosition));
            column += endPosition - startPosition;
          }
          switch (code2) {
            case 0: {
              chunks.push(65533);
              column++;
              break;
            }
            case 9: {
              next = Math.ceil(column / 4) * 4;
              chunks.push(-2);
              while (column++ < next) chunks.push(-1);
              break;
            }
            case 10: {
              chunks.push(-4);
              column = 1;
              break;
            }
            default: {
              atCarriageReturn = true;
              column = 1;
            }
          }
        }
        startPosition = endPosition + 1;
      }
      if (end) {
        if (atCarriageReturn) chunks.push(-5);
        if (buffer) chunks.push(buffer);
        chunks.push(null);
      }
      return chunks;
    }
  }

  // node_modules/markdownlint/lib/micromark-parse.mjs
  var import_micromark_helpers30 = __toESM(require_micromark_helpers(), 1);
  var import_shared = __toESM(require_shared(), 1);
  function directiveNoInline() {
    const extension = {
      ...directive()
    };
    delete extension.text;
    return extension;
  }
  function getText(markdown, token) {
    return markdown.slice(token.start.offset, token.end.offset);
  }
  function getEvents(markdown, micromarkParseOptions = {}) {
    const extensions = [
      directiveNoInline(),
      gfmAutolinkLiteral(),
      gfmFootnote(),
      gfmTable(),
      math(),
      ...micromarkParseOptions.extensions || []
    ];
    const artificialEventLists = [];
    const tokenizeOriginal = labelEnd.tokenize;
    function tokenizeShim(effects, okOriginal, nokOriginal) {
      const tokenizeContext = this;
      const events = tokenizeContext.events;
      const nokShim = (code2) => {
        let indexStart = events.length;
        while (--indexStart >= 0) {
          const event = events[indexStart];
          const [kind, token] = event;
          if (kind === "enter") {
            const { type } = token;
            if (type === "labelImage" || type === "labelLink") {
              break;
            }
          }
        }
        if (indexStart >= 0) {
          const eventStart = events[indexStart];
          const [, eventStartToken] = eventStart;
          const eventEnd = events[events.length - 1];
          const [, eventEndToken] = eventEnd;
          const undefinedReferenceType = {
            "type": "undefinedReferenceShortcut",
            "start": eventStartToken.start,
            "end": eventEndToken.end
          };
          const undefinedReference = {
            "type": "undefinedReference",
            "start": eventStartToken.start,
            "end": eventEndToken.end
          };
          const eventsToReplicate = events.slice(indexStart).filter((event) => {
            const [, eventToken] = event;
            const { type } = eventToken;
            return type === "data" || type === "lineEnding";
          });
          const previousUndefinedEvent = artificialEventLists.length > 0 && artificialEventLists[artificialEventLists.length - 1][0];
          const previousUndefinedToken = previousUndefinedEvent && previousUndefinedEvent[1];
          if (previousUndefinedToken && previousUndefinedToken.end.line === undefinedReferenceType.start.line && previousUndefinedToken.end.column === undefinedReferenceType.start.column) {
            if (eventsToReplicate.length === 0) {
              previousUndefinedToken.type = "undefinedReferenceCollapsed";
              previousUndefinedToken.end = eventEndToken.end;
            } else {
              undefinedReferenceType.type = "undefinedReferenceFull";
              undefinedReferenceType.start = previousUndefinedToken.start;
              artificialEventLists.pop();
            }
          }
          const text4 = eventsToReplicate.filter((event) => event[0] === "enter").map((event) => getText(markdown, event[1])).join("").trim();
          if (text4.length > 0 && !text4.includes("]")) {
            const artificialEvents = [
              ["enter", undefinedReferenceType, tokenizeContext],
              ["enter", undefinedReference, tokenizeContext]
            ];
            for (const event of eventsToReplicate) {
              const [kind, token] = event;
              artificialEvents.push([kind, { ...token }, tokenizeContext]);
            }
            artificialEvents.push(
              ["exit", undefinedReference, tokenizeContext],
              ["exit", undefinedReferenceType, tokenizeContext]
            );
            artificialEventLists.push(artificialEvents);
          }
        }
        return nokOriginal(code2);
      };
      return tokenizeOriginal.call(tokenizeContext, effects, okOriginal, nokShim);
    }
    try {
      labelEnd.tokenize = tokenizeShim;
      const encoding = void 0;
      const eol = true;
      const parseContext = parse({ ...micromarkParseOptions, extensions });
      const chunks = preprocess()(markdown, encoding, eol);
      const events = postprocess(parseContext.document().write(chunks));
      return events.concat(...artificialEventLists);
    } finally {
      labelEnd.tokenize = tokenizeOriginal;
    }
  }
  function parseInternal(markdown, parseOptions = {}, micromarkParseOptions = {}, lineDelta = 0, ancestor = void 0) {
    const freezeTokens = Boolean(parseOptions.freezeTokens);
    const events = getEvents(markdown, micromarkParseOptions);
    const document3 = [];
    let flatTokens = [];
    const root = {
      "type": "data",
      "startLine": -1,
      "startColumn": -1,
      "endLine": -1,
      "endColumn": -1,
      "text": "ROOT",
      "children": document3,
      "parent": null
    };
    const history = [root];
    let current = root;
    let reparseOptions = null;
    let lines = null;
    let skipHtmlFlowChildren = false;
    for (const event of events) {
      const [kind, token] = event;
      const { type, start, end } = token;
      const { "column": startColumn, "line": startLine } = start;
      const { "column": endColumn, "line": endLine } = end;
      const text4 = getText(markdown, token);
      if (kind === "enter" && !skipHtmlFlowChildren) {
        const previous4 = current;
        history.push(previous4);
        current = {
          type,
          "startLine": startLine + lineDelta,
          startColumn,
          "endLine": endLine + lineDelta,
          endColumn,
          text: text4,
          "children": [],
          "parent": previous4 === root ? ancestor || null : previous4
        };
        if (ancestor) {
          Object.defineProperty(current, import_shared.htmlFlowSymbol, { "value": true });
        }
        previous4.children.push(current);
        flatTokens.push(current);
        if (current.type === "htmlFlow" && !(0, import_micromark_helpers30.isHtmlFlowComment)(current)) {
          skipHtmlFlowChildren = true;
          if (!reparseOptions || !lines) {
            reparseOptions = {
              ...micromarkParseOptions,
              "extensions": [
                {
                  "disable": {
                    "null": ["codeIndented", "htmlFlow"]
                  }
                }
              ]
            };
            lines = markdown.split(import_shared.newlineRe);
          }
          const reparseMarkdown = lines.slice(current.startLine - 1, current.endLine).join("\n");
          const tokens = parseInternal(
            reparseMarkdown,
            parseOptions,
            reparseOptions,
            current.startLine - 1,
            current
          );
          current.children = tokens;
          flatTokens = flatTokens.concat(tokens[import_shared.flatTokensSymbol]);
        }
      } else if (kind === "exit") {
        if (type === "htmlFlow") {
          skipHtmlFlowChildren = false;
        }
        if (!skipHtmlFlowChildren) {
          if (freezeTokens) {
            Object.freeze(current.children);
            Object.freeze(current);
          }
          current = history.pop();
        }
      }
    }
    Object.defineProperty(document3, import_shared.flatTokensSymbol, { "value": flatTokens });
    if (freezeTokens) {
      Object.freeze(document3);
    }
    return document3;
  }
  function parse2(markdown, parseOptions) {
    return parseInternal(markdown, parseOptions);
  }

  // node_modules/markdownlint/lib/md044.mjs
  var ignoredChildTypes = /* @__PURE__ */ new Set(
    ["codeFencedFence", "definition", "reference", "resource"]
  );
  var md044_default = {
    "names": ["MD044", "proper-names"],
    "description": "Proper names should have the correct capitalization",
    "tags": ["spelling"],
    "parser": "micromark",
    "function": function MD044(params2, onError) {
      let names = params2.config.names;
      names = Array.isArray(names) ? names : [];
      names.sort((a, b) => b.length - a.length || a.localeCompare(b));
      if (names.length === 0) {
        return;
      }
      const codeBlocks = params2.config.code_blocks;
      const includeCodeBlocks = codeBlocks === void 0 ? true : !!codeBlocks;
      const htmlElements = params2.config.html_elements;
      const includeHtmlElements = htmlElements === void 0 ? true : !!htmlElements;
      const scannedTypes = /* @__PURE__ */ new Set(["data"]);
      if (includeCodeBlocks) {
        scannedTypes.add("codeFlowValue");
        scannedTypes.add("codeTextData");
      }
      if (includeHtmlElements) {
        scannedTypes.add("htmlFlowData");
        scannedTypes.add("htmlTextData");
      }
      const contentTokens = (0, import_micromark_helpers31.filterByPredicate)(
        params2.parsers.micromark.tokens,
        (token) => scannedTypes.has(token.type),
        (token) => token.children.filter((t) => !ignoredChildTypes.has(t.type))
      );
      const exclusions = [];
      const scannedTokens = /* @__PURE__ */ new Set();
      for (const name of names) {
        const escapedName = (0, import_helpers38.escapeForRegExp)(name);
        const startNamePattern = /^\W/.test(name) ? "" : "\\b_*";
        const endNamePattern = /\W$/.test(name) ? "" : "_*\\b";
        const namePattern = `(${startNamePattern})(${escapedName})${endNamePattern}`;
        const nameRe2 = new RegExp(namePattern, "gi");
        for (const token of contentTokens) {
          let match = null;
          while ((match = nameRe2.exec(token.text)) !== null) {
            const [, leftMatch, nameMatch] = match;
            const column = token.startColumn + match.index + leftMatch.length;
            const length = nameMatch.length;
            const lineNumber = token.startLine;
            const nameRange = {
              "startLine": lineNumber,
              "startColumn": column,
              "endLine": lineNumber,
              "endColumn": column + length - 1
            };
            if (!names.includes(nameMatch) && !exclusions.some((exclusion) => (0, import_helpers38.hasOverlap)(exclusion, nameRange))) {
              let autolinkRanges = [];
              if (!scannedTokens.has(token)) {
                autolinkRanges = (0, import_micromark_helpers31.filterByTypes)(parse2(token.text), ["literalAutolink"]).map((tok) => ({
                  "startLine": lineNumber,
                  "startColumn": token.startColumn + tok.startColumn - 1,
                  "endLine": lineNumber,
                  "endColumn": token.endColumn + tok.endColumn - 1
                }));
                exclusions.push(...autolinkRanges);
                scannedTokens.add(token);
              }
              if (!autolinkRanges.some((autolinkRange) => (0, import_helpers38.hasOverlap)(autolinkRange, nameRange))) {
                (0, import_helpers38.addErrorDetailIf)(
                  onError,
                  token.startLine,
                  name,
                  nameMatch,
                  void 0,
                  void 0,
                  [column, length],
                  {
                    "editColumn": column,
                    "deleteCount": length,
                    "insertText": name
                  }
                );
              }
            }
            exclusions.push(nameRange);
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md045.mjs
  var import_helpers39 = __toESM(require_helpers(), 1);
  var import_micromark_helpers32 = __toESM(require_micromark_helpers(), 1);
  var altRe = (0, import_helpers39.getHtmlAttributeRe)("alt");
  var ariaHiddenRe = (0, import_helpers39.getHtmlAttributeRe)("aria-hidden");
  var md045_default = {
    "names": ["MD045", "no-alt-text"],
    "description": "Images should have alternate text (alt text)",
    "tags": ["accessibility", "images"],
    "parser": "micromark",
    "function": function MD045(params2, onError) {
      const images = filterByTypesCached(["image"]);
      for (const image of images) {
        const labelTexts = (0, import_micromark_helpers32.getDescendantsByType)(image, ["label", "labelText"]);
        if (labelTexts.some((labelText) => labelText.text.length === 0)) {
          const range = image.startLine === image.endLine ? [image.startColumn, image.endColumn - image.startColumn] : void 0;
          (0, import_helpers39.addError)(
            onError,
            image.startLine,
            void 0,
            void 0,
            range
          );
        }
      }
      const htmlTexts = filterByTypesCached(["htmlText"], true);
      for (const htmlText2 of htmlTexts) {
        const { startColumn, startLine, text: text4 } = htmlText2;
        const htmlTagInfo = (0, import_micromark_helpers32.getHtmlTagInfo)(htmlText2);
        if (htmlTagInfo && !htmlTagInfo.close && htmlTagInfo.name.toLowerCase() === "img" && !altRe.test(text4) && ariaHiddenRe.exec(text4)?.[1].toLowerCase() !== "true") {
          const range = [
            startColumn,
            text4.replace(import_helpers39.nextLinesRe, "").length
          ];
          (0, import_helpers39.addError)(
            onError,
            startLine,
            void 0,
            void 0,
            range
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md046.mjs
  var import_helpers40 = __toESM(require_helpers(), 1);
  var tokenTypeToStyle = (tokenType) => tokenType === "codeFenced" ? "fenced" : "indented";
  var md046_default = {
    "names": ["MD046", "code-block-style"],
    "description": "Code block style",
    "tags": ["code"],
    "parser": "micromark",
    "function": function MD046(params2, onError) {
      let expectedStyle = String(params2.config.style || "consistent");
      for (const token of filterByTypesCached(["codeFenced", "codeIndented"])) {
        const { startLine, type } = token;
        if (expectedStyle === "consistent") {
          expectedStyle = tokenTypeToStyle(type);
        }
        (0, import_helpers40.addErrorDetailIf)(
          onError,
          startLine,
          expectedStyle,
          tokenTypeToStyle(type)
        );
      }
    }
  };

  // node_modules/markdownlint/lib/md047.mjs
  var import_helpers41 = __toESM(require_helpers(), 1);
  var md047_default = {
    "names": ["MD047", "single-trailing-newline"],
    "description": "Files should end with a single newline character",
    "tags": ["blank_lines"],
    "parser": "none",
    "function": function MD047(params2, onError) {
      const lastLineNumber = params2.lines.length;
      const lastLine = params2.lines[lastLineNumber - 1];
      if (!(0, import_helpers41.isBlankLine)(lastLine)) {
        (0, import_helpers41.addError)(
          onError,
          lastLineNumber,
          void 0,
          void 0,
          [lastLine.length, 1],
          {
            "insertText": "\n",
            "editColumn": lastLine.length + 1
          }
        );
      }
    }
  };

  // node_modules/markdownlint/lib/md048.mjs
  var import_helpers42 = __toESM(require_helpers(), 1);
  var import_micromark_helpers33 = __toESM(require_micromark_helpers(), 1);
  function fencedCodeBlockStyleFor(markup) {
    switch (markup[0]) {
      case "~":
        return "tilde";
      default:
        return "backtick";
    }
  }
  var md048_default = {
    "names": ["MD048", "code-fence-style"],
    "description": "Code fence style",
    "tags": ["code"],
    "parser": "micromark",
    "function": function MD048(params2, onError) {
      const style = String(params2.config.style || "consistent");
      let expectedStyle = style;
      const codeFenceds = filterByTypesCached(["codeFenced"]);
      for (const codeFenced2 of codeFenceds) {
        const codeFencedFenceSequence = (0, import_micromark_helpers33.getDescendantsByType)(codeFenced2, ["codeFencedFence", "codeFencedFenceSequence"])[0];
        const { startLine, text: text4 } = codeFencedFenceSequence;
        if (expectedStyle === "consistent") {
          expectedStyle = fencedCodeBlockStyleFor(text4);
        }
        (0, import_helpers42.addErrorDetailIf)(
          onError,
          startLine,
          expectedStyle,
          fencedCodeBlockStyleFor(text4)
        );
      }
    }
  };

  // node_modules/markdownlint/lib/md049-md050.mjs
  var import_helpers43 = __toESM(require_helpers(), 1);
  var import_micromark_helpers34 = __toESM(require_micromark_helpers(), 1);
  var intrawordRe = /^\w$/;
  function emphasisOrStrongStyleFor(markup) {
    switch (markup[0]) {
      case "*":
        return "asterisk";
      default:
        return "underscore";
    }
  }
  var impl = (params2, onError, type, typeSequence, asterisk, underline, style = "consistent") => {
    const { lines, parsers } = params2;
    const emphasisTokens = (0, import_micromark_helpers34.filterByPredicate)(
      parsers.micromark.tokens,
      (token) => token.type === type,
      (token) => token.type === "htmlFlow" ? [] : token.children
    );
    for (const token of emphasisTokens) {
      const sequences = (0, import_micromark_helpers34.getDescendantsByType)(token, [typeSequence]);
      const startSequence = sequences[0];
      const endSequence = sequences[sequences.length - 1];
      if (startSequence && endSequence) {
        const markupStyle = emphasisOrStrongStyleFor(startSequence.text);
        if (style === "consistent") {
          style = markupStyle;
        }
        if (style !== markupStyle) {
          const underscoreIntraword = style === "underscore" && (intrawordRe.test(
            lines[startSequence.startLine - 1][startSequence.startColumn - 2]
          ) || intrawordRe.test(
            lines[endSequence.endLine - 1][endSequence.endColumn - 1]
          ));
          if (!underscoreIntraword) {
            for (const sequence of [startSequence, endSequence]) {
              (0, import_helpers43.addError)(
                onError,
                sequence.startLine,
                `Expected: ${style}; Actual: ${markupStyle}`,
                void 0,
                [sequence.startColumn, sequence.text.length],
                {
                  "editColumn": sequence.startColumn,
                  "deleteCount": sequence.text.length,
                  "insertText": style === "asterisk" ? asterisk : underline
                }
              );
            }
          }
        }
      }
    }
  };
  var md049_md050_default = [
    {
      "names": ["MD049", "emphasis-style"],
      "description": "Emphasis style",
      "tags": ["emphasis"],
      "parser": "micromark",
      "function": function MD049(params2, onError) {
        return impl(
          params2,
          onError,
          "emphasis",
          "emphasisSequence",
          "*",
          "_",
          params2.config.style || void 0
        );
      }
    },
    {
      "names": ["MD050", "strong-style"],
      "description": "Strong style",
      "tags": ["emphasis"],
      "parser": "micromark",
      "function": function MD050(params2, onError) {
        return impl(
          params2,
          onError,
          "strong",
          "strongSequence",
          "**",
          "__",
          params2.config.style || void 0
        );
      }
    }
  ];

  // node_modules/markdownlint/lib/md051.mjs
  var import_helpers44 = __toESM(require_helpers(), 1);
  var import_micromark_helpers35 = __toESM(require_micromark_helpers(), 1);
  var idRe = (0, import_helpers44.getHtmlAttributeRe)("id");
  var nameRe = (0, import_helpers44.getHtmlAttributeRe)("name");
  var anchorRe = /\{(#[a-z\d]+(?:[-_][a-z\d]+)*)\}/gu;
  var lineFragmentRe = /^#(?:L\d+(?:C\d+)?-L\d+(?:C\d+)?|L\d+)$/;
  var childrenExclude = /* @__PURE__ */ new Set(["image", "reference", "resource"]);
  var tokensInclude = /* @__PURE__ */ new Set(
    ["characterEscapeValue", "codeTextData", "data", "mathTextData"]
  );
  function convertHeadingToHTMLFragment(headingText) {
    const inlineText = (0, import_micromark_helpers35.filterByPredicate)(
      headingText.children,
      (token) => tokensInclude.has(token.type),
      (token) => childrenExclude.has(token.type) ? [] : token.children
    ).map((token) => token.text).join("");
    return "#" + encodeURIComponent(
      inlineText.toLowerCase().replace(
        /[^\p{Letter}\p{Mark}\p{Number}\p{Connector_Punctuation}\- ]/gu,
        ""
      ).replace(/ /gu, "-").toWellFormed()
    );
  }
  function unescapeStringTokenText(token) {
    return (0, import_micromark_helpers35.filterByTypes)(token.children, ["characterEscapeValue", "data"]).map((child) => child.text).join("");
  }
  var md051_default = {
    "names": ["MD051", "link-fragments"],
    "description": "Link fragments should be valid",
    "tags": ["links"],
    "parser": "micromark",
    "function": function MD051(params2, onError) {
      const ignoreCase = params2.config.ignore_case || false;
      const ignoredPattern = params2.config.ignored_pattern || "";
      const ignoredPatternRe = new RegExp(ignoredPattern || "^$");
      const fragments = /* @__PURE__ */ new Map([["#top", 0]]);
      const headingTexts = filterByTypesCached(["atxHeadingText", "setextHeadingText"]);
      for (const headingText of headingTexts) {
        const fragment = convertHeadingToHTMLFragment(headingText);
        if (fragment !== "#") {
          const count = fragments.get(fragment) || 0;
          if (count) {
            fragments.set(`${fragment}-${count}`, 0);
          }
          fragments.set(fragment, count + 1);
          let match = null;
          while ((match = anchorRe.exec(headingText.text)) !== null) {
            const [, anchor] = match;
            if (!fragments.has(anchor)) {
              fragments.set(anchor, 1);
            }
          }
        }
      }
      for (const token of filterByTypesCached(["htmlText"], true)) {
        const htmlTagInfo = (0, import_micromark_helpers35.getHtmlTagInfo)(token);
        if (htmlTagInfo && !htmlTagInfo.close) {
          const anchorMatch = idRe.exec(token.text) || htmlTagInfo.name.toLowerCase() === "a" && nameRe.exec(token.text);
          if (anchorMatch && anchorMatch.length > 0) {
            fragments.set(`#${anchorMatch[1]}`, 0);
          }
        }
      }
      const parentChilds = [
        ["link", "resourceDestinationString"],
        ["definition", "definitionDestinationString"]
      ];
      for (const [parentType, definitionType] of parentChilds) {
        const links = filterByTypesCached([parentType]).filter(
          (link) => !(link.parent?.type === "atxHeadingText" && (0, import_micromark_helpers35.isDocfxTab)(link.parent.parent))
        );
        for (const link of links) {
          const definitions = (0, import_micromark_helpers35.filterByTypes)(link.children, [definitionType]);
          for (const definition2 of definitions) {
            const { endColumn, startColumn } = definition2;
            const text4 = unescapeStringTokenText(definition2);
            const textSliceOne = text4.slice(1);
            const encodedText = `#${encodeURIComponent(textSliceOne.toWellFormed())}`;
            if (text4.length > 1 && text4.startsWith("#") && !fragments.has(encodedText) && !lineFragmentRe.test(encodedText) && !ignoredPatternRe.test(textSliceOne)) {
              let context = void 0;
              let range = void 0;
              let fixInfo = void 0;
              if (link.startLine === link.endLine) {
                context = link.text;
                range = [link.startColumn, link.endColumn - link.startColumn];
                fixInfo = {
                  "editColumn": startColumn,
                  "deleteCount": endColumn - startColumn
                };
              }
              const textLower = text4.toLowerCase();
              const mixedCaseKey = [...fragments.keys()].find((key) => textLower === key.toLowerCase());
              if (mixedCaseKey) {
                (fixInfo || {}).insertText = mixedCaseKey;
                if (!ignoreCase && mixedCaseKey !== text4) {
                  (0, import_helpers44.addError)(
                    onError,
                    link.startLine,
                    `Expected: ${mixedCaseKey}; Actual: ${text4}`,
                    context,
                    range,
                    fixInfo
                  );
                }
              } else {
                (0, import_helpers44.addError)(
                  onError,
                  link.startLine,
                  void 0,
                  context,
                  range
                );
              }
            }
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md052.mjs
  var import_helpers45 = __toESM(require_helpers(), 1);
  var md052_default = {
    "names": ["MD052", "reference-links-images"],
    "description": "Reference links and images should use a label that is defined",
    "tags": ["images", "links"],
    "parser": "none",
    "function": function MD052(params2, onError) {
      const { config, lines } = params2;
      const shortcutSyntax = config.shortcut_syntax || false;
      const ignoredLabels = new Set(config.ignored_labels || ["x"]);
      const { definitions, references, shortcuts } = getReferenceLinkImageData();
      const entries = shortcutSyntax ? [...references.entries(), ...shortcuts.entries()] : references.entries();
      for (const reference of entries) {
        const [label4, datas] = reference;
        if (!definitions.has(label4) && !ignoredLabels.has(label4)) {
          for (const data of datas) {
            const [lineIndex, index, length] = data;
            const context = lines[lineIndex].slice(index, index + length);
            (0, import_helpers45.addError)(
              onError,
              lineIndex + 1,
              `Missing link or image reference definition: "${label4}"`,
              context,
              [index + 1, context.length]
            );
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md053.mjs
  var import_helpers46 = __toESM(require_helpers(), 1);
  var linkReferenceDefinitionRe = /^ {0,3}\[([^\]]*[^\\])\]:/;
  var md053_default = {
    "names": ["MD053", "link-image-reference-definitions"],
    "description": "Link and image reference definitions should be needed",
    "tags": ["images", "links"],
    "parser": "none",
    "function": function MD053(params2, onError) {
      const ignored = new Set(params2.config.ignored_definitions || ["//"]);
      const lines = params2.lines;
      const { references, shortcuts, definitions, duplicateDefinitions } = getReferenceLinkImageData();
      const singleLineDefinition = (line) => line.replace(linkReferenceDefinitionRe, "").trim().length > 0;
      const deleteFixInfo = {
        "deleteCount": -1
      };
      for (const definition2 of definitions.entries()) {
        const [label4, [lineIndex]] = definition2;
        if (!ignored.has(label4) && !references.has(label4) && !shortcuts.has(label4)) {
          const line = lines[lineIndex];
          (0, import_helpers46.addError)(
            onError,
            lineIndex + 1,
            `Unused link or image reference definition: "${label4}"`,
            (0, import_helpers46.ellipsify)(line),
            [1, line.length],
            singleLineDefinition(line) ? deleteFixInfo : void 0
          );
        }
      }
      for (const duplicateDefinition of duplicateDefinitions) {
        const [label4, lineIndex] = duplicateDefinition;
        if (!ignored.has(label4)) {
          const line = lines[lineIndex];
          (0, import_helpers46.addError)(
            onError,
            lineIndex + 1,
            `Duplicate link or image reference definition: "${label4}"`,
            (0, import_helpers46.ellipsify)(line),
            [1, line.length],
            singleLineDefinition(line) ? deleteFixInfo : void 0
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md054.mjs
  var import_helpers47 = __toESM(require_helpers(), 1);
  var import_micromark_helpers36 = __toESM(require_micromark_helpers(), 1);
  var backslashEscapeRe = /\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g;
  var removeBackslashEscapes = (text4) => text4.replace(backslashEscapeRe, "$1");
  var autolinkDisallowedRe = /[ <>]/;
  var autolinkAble = (destination) => {
    try {
      new URL(destination);
    } catch {
      return false;
    }
    return !autolinkDisallowedRe.test(destination);
  };
  var md054_default = {
    "names": ["MD054", "link-image-style"],
    "description": "Link and image style",
    "tags": ["images", "links"],
    "parser": "micromark",
    "function": (params2, onError) => {
      const config = params2.config;
      const autolink2 = config.autolink === void 0 || !!config.autolink;
      const inline = config.inline === void 0 || !!config.inline;
      const full = config.full === void 0 || !!config.full;
      const collapsed = config.collapsed === void 0 || !!config.collapsed;
      const shortcut = config.shortcut === void 0 || !!config.shortcut;
      const urlInline = config.url_inline === void 0 || !!config.url_inline;
      if (autolink2 && inline && full && collapsed && shortcut && urlInline) {
        return;
      }
      const { definitions } = getReferenceLinkImageData();
      const links = filterByTypesCached(["autolink", "image", "link"]);
      for (const link of links) {
        let label4 = null;
        let destination = null;
        const {
          endColumn,
          endLine,
          startColumn,
          startLine,
          text: text4,
          type
        } = link;
        const image = type === "image";
        let isError = false;
        if (type === "autolink") {
          destination = (0, import_micromark_helpers36.getDescendantsByType)(link, [["autolinkEmail", "autolinkProtocol"]])[0]?.text;
          label4 = destination;
          isError = !autolink2 && Boolean(destination);
        } else {
          label4 = (0, import_micromark_helpers36.getDescendantsByType)(link, ["label", "labelText"])[0].text;
          destination = (0, import_micromark_helpers36.getDescendantsByType)(link, ["resource", "resourceDestination", ["resourceDestinationLiteral", "resourceDestinationRaw"], "resourceDestinationString"])[0]?.text;
          if (destination) {
            const title = (0, import_micromark_helpers36.getDescendantsByType)(link, ["resource", "resourceTitle", "resourceTitleString"])[0]?.text;
            isError = !inline || !urlInline && autolink2 && !image && !title && label4 === destination && autolinkAble(destination);
          } else {
            const isShortcut = (0, import_micromark_helpers36.getDescendantsByType)(link, ["reference"]).length === 0;
            const referenceString = (0, import_micromark_helpers36.getDescendantsByType)(link, ["reference", "referenceString"])[0]?.text;
            const isCollapsed = referenceString === void 0;
            const definition2 = definitions.get(referenceString || label4);
            destination = definition2 && definition2[1] || "";
            isError = Boolean(
              destination && (isShortcut ? !shortcut : isCollapsed ? !collapsed : !full)
            );
          }
        }
        if (isError) {
          let range = void 0;
          let fixInfo = void 0;
          if (startLine === endLine) {
            range = [startColumn, endColumn - startColumn];
            let insertText = null;
            const canInline = inline && label4;
            const canAutolink = autolink2 && !image && autolinkAble(destination);
            if (canInline && (urlInline || !canAutolink)) {
              const prefix = image ? "!" : "";
              const escapedLabel = label4.replace(/[[\]]/g, "\\$&");
              const escapedDestination = destination.replace(/[()]/g, "\\$&");
              insertText = `${prefix}[${escapedLabel}](${escapedDestination})`;
            } else if (canAutolink) {
              insertText = `<${removeBackslashEscapes(destination)}>`;
            }
            if (insertText) {
              fixInfo = {
                "editColumn": range[0],
                insertText,
                "deleteCount": range[1]
              };
            }
          }
          (0, import_helpers47.addErrorContext)(
            onError,
            startLine,
            text4.replace(import_helpers47.nextLinesRe, ""),
            void 0,
            void 0,
            range,
            fixInfo
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md055.mjs
  var import_helpers48 = __toESM(require_helpers(), 1);
  var whitespaceTypes = /* @__PURE__ */ new Set(["linePrefix", "whitespace"]);
  var ignoreWhitespace = (tokens) => tokens.filter(
    (token) => !whitespaceTypes.has(token.type)
  );
  var firstOrNothing = (items) => items[0];
  var lastOrNothing = (items) => items[items.length - 1];
  var makeRange = (start, end) => [start, end - start + 1];
  var md055_default = {
    "names": ["MD055", "table-pipe-style"],
    "description": "Table pipe style",
    "tags": ["table"],
    "parser": "micromark",
    "function": function MD055(params2, onError) {
      const style = String(params2.config.style || "consistent");
      let expectedStyle = style;
      let expectedLeadingPipe = expectedStyle !== "no_leading_or_trailing" && expectedStyle !== "trailing_only";
      let expectedTrailingPipe = expectedStyle !== "no_leading_or_trailing" && expectedStyle !== "leading_only";
      const rows = filterByTypesCached(["tableDelimiterRow", "tableRow"]);
      for (const row of rows) {
        const firstCell = firstOrNothing(row.children);
        const leadingToken = firstOrNothing(ignoreWhitespace(firstCell.children));
        const actualLeadingPipe = leadingToken.type === "tableCellDivider";
        const lastCell = lastOrNothing(row.children);
        const trailingToken = lastOrNothing(ignoreWhitespace(lastCell.children));
        const actualTrailingPipe = trailingToken.type === "tableCellDivider";
        const actualStyle = actualLeadingPipe ? actualTrailingPipe ? "leading_and_trailing" : "leading_only" : actualTrailingPipe ? "trailing_only" : "no_leading_or_trailing";
        if (expectedStyle === "consistent") {
          expectedStyle = actualStyle;
          expectedLeadingPipe = actualLeadingPipe;
          expectedTrailingPipe = actualTrailingPipe;
        }
        if (actualLeadingPipe !== expectedLeadingPipe) {
          (0, import_helpers48.addErrorDetailIf)(
            onError,
            firstCell.startLine,
            expectedStyle,
            actualStyle,
            `${expectedLeadingPipe ? "Missing" : "Unexpected"} leading pipe`,
            void 0,
            makeRange(row.startColumn, firstCell.startColumn)
          );
        }
        if (actualTrailingPipe !== expectedTrailingPipe) {
          (0, import_helpers48.addErrorDetailIf)(
            onError,
            lastCell.endLine,
            expectedStyle,
            actualStyle,
            `${expectedTrailingPipe ? "Missing" : "Unexpected"} trailing pipe`,
            void 0,
            makeRange(lastCell.endColumn - 1, row.endColumn - 1)
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md056.mjs
  var import_helpers49 = __toESM(require_helpers(), 1);
  var import_micromark_helpers37 = __toESM(require_micromark_helpers(), 1);
  var makeRange2 = (start, end) => [start, end - start + 1];
  var md056_default = {
    "names": ["MD056", "table-column-count"],
    "description": "Table column count",
    "tags": ["table"],
    "parser": "micromark",
    "function": function MD056(params2, onError) {
      const rows = filterByTypesCached(["tableDelimiterRow", "tableRow"]);
      let expectedCount = 0;
      let currentTable = null;
      for (const row of rows) {
        const table = (0, import_micromark_helpers37.getParentOfType)(row, ["table"]);
        if (currentTable !== table) {
          expectedCount = 0;
          currentTable = table;
        }
        const cells = row.children.filter((child) => ["tableData", "tableDelimiter", "tableHeader"].includes(child.type));
        const actualCount = cells.length;
        expectedCount || (expectedCount = actualCount);
        let detail = void 0;
        let range = void 0;
        if (actualCount < expectedCount) {
          detail = "Too few cells, row will be missing data";
          range = [row.endColumn - 1, 1];
        } else if (expectedCount < actualCount) {
          detail = "Too many cells, extra data will be missing";
          range = makeRange2(cells[expectedCount].startColumn, row.endColumn - 1);
        }
        (0, import_helpers49.addErrorDetailIf)(
          onError,
          row.endLine,
          expectedCount,
          actualCount,
          detail,
          void 0,
          range
        );
      }
    }
  };

  // node_modules/markdownlint/lib/md058.mjs
  var import_helpers50 = __toESM(require_helpers(), 1);
  var import_micromark_helpers38 = __toESM(require_micromark_helpers(), 1);
  var md058_default = {
    "names": ["MD058", "blanks-around-tables"],
    "description": "Tables should be surrounded by blank lines",
    "tags": ["table"],
    "parser": "micromark",
    "function": function MD058(params2, onError) {
      const { lines } = params2;
      const blockQuotePrefixes = filterByTypesCached(["blockQuotePrefix", "linePrefix"]);
      const tables = filterByTypesCached(["table"]);
      for (const table of tables) {
        const firstLineNumber = table.startLine;
        if (!(0, import_helpers50.isBlankLine)(lines[firstLineNumber - 2])) {
          (0, import_helpers50.addErrorContext)(
            onError,
            firstLineNumber,
            lines[firstLineNumber - 1].trim(),
            void 0,
            void 0,
            void 0,
            {
              "insertText": (0, import_micromark_helpers38.getBlockQuotePrefixText)(blockQuotePrefixes, firstLineNumber)
            }
          );
        }
        const lastLineNumber = table.endLine;
        if (!(0, import_helpers50.isBlankLine)(lines[lastLineNumber])) {
          (0, import_helpers50.addErrorContext)(
            onError,
            lastLineNumber,
            lines[lastLineNumber - 1].trim(),
            void 0,
            void 0,
            void 0,
            {
              "lineNumber": lastLineNumber + 1,
              "insertText": (0, import_micromark_helpers38.getBlockQuotePrefixText)(blockQuotePrefixes, lastLineNumber)
            }
          );
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md059.mjs
  var import_helpers51 = __toESM(require_helpers(), 1);
  var import_micromark_helpers39 = __toESM(require_micromark_helpers(), 1);
  var allowedChildrenTypes = /* @__PURE__ */ new Set([
    "codeText",
    "htmlText"
  ]);
  var defaultProhibitedTexts = [
    "click here",
    "here",
    "link",
    "more"
  ];
  function normalize(str) {
    return str.replace(/[\W_]+/g, " ").replace(/\s+/g, " ").toLowerCase().trim();
  }
  var md059_default = {
    "names": ["MD059", "descriptive-link-text"],
    "description": "Link text should be descriptive",
    "tags": ["accessibility", "links"],
    "parser": "micromark",
    "function": function MD059(params2, onError) {
      const prohibitedTexts = new Set(
        (params2.config.prohibited_texts || defaultProhibitedTexts).map(normalize)
      );
      if (prohibitedTexts.size > 0) {
        const links = filterByTypesCached(["link"]);
        for (const link of links) {
          const labelTexts = (0, import_micromark_helpers39.getDescendantsByType)(link, ["label", "labelText"]);
          for (const labelText of labelTexts) {
            const { children, endColumn, endLine, parent, startColumn, startLine, text: text4 } = labelText;
            if (!children.some((child) => allowedChildrenTypes.has(child.type)) && prohibitedTexts.has(normalize(text4))) {
              const range = startLine === endLine ? [startColumn, endColumn - startColumn] : void 0;
              (0, import_helpers51.addErrorContext)(
                onError,
                startLine,
                // @ts-ignore
                parent.text,
                void 0,
                void 0,
                range
              );
            }
          }
        }
      }
    }
  };

  // node_modules/markdownlint/lib/md060.mjs
  var import_micromark_helpers40 = __toESM(require_micromark_helpers(), 1);

  // node_modules/ansi-regex/index.js
  function ansiRegex({ onlyFirst = false } = {}) {
    const ST = "(?:\\u0007|\\u001B\\u005C|\\u009C)";
    const osc = `(?:\\u001B\\][\\s\\S]*?${ST})`;
    const csi = "[\\u001B\\u009B][[\\]()#;?]*(?:\\d{1,4}(?:[;:]\\d{0,4})*)?[\\dA-PR-TZcf-nq-uy=><~]";
    const pattern = `${osc}|${csi}`;
    return new RegExp(pattern, onlyFirst ? void 0 : "g");
  }

  // node_modules/strip-ansi/index.js
  var regex = ansiRegex();
  function stripAnsi(string3) {
    if (typeof string3 !== "string") {
      throw new TypeError(`Expected a \`string\`, got \`${typeof string3}\``);
    }
    if (!string3.includes("\x1B") && !string3.includes("\x9B")) {
      return string3;
    }
    return string3.replace(regex, "");
  }

  // node_modules/get-east-asian-width/lookup-data.js
  var ambiguousMinimalCodePoint = 161;
  var ambiguousMaximumCodePoint = 1114109;
  var ambiguousRanges = [161, 161, 164, 164, 167, 168, 170, 170, 173, 174, 176, 180, 182, 186, 188, 191, 198, 198, 208, 208, 215, 216, 222, 225, 230, 230, 232, 234, 236, 237, 240, 240, 242, 243, 247, 250, 252, 252, 254, 254, 257, 257, 273, 273, 275, 275, 283, 283, 294, 295, 299, 299, 305, 307, 312, 312, 319, 322, 324, 324, 328, 331, 333, 333, 338, 339, 358, 359, 363, 363, 462, 462, 464, 464, 466, 466, 468, 468, 470, 470, 472, 472, 474, 474, 476, 476, 593, 593, 609, 609, 708, 708, 711, 711, 713, 715, 717, 717, 720, 720, 728, 731, 733, 733, 735, 735, 768, 879, 913, 929, 931, 937, 945, 961, 963, 969, 1025, 1025, 1040, 1103, 1105, 1105, 8208, 8208, 8211, 8214, 8216, 8217, 8220, 8221, 8224, 8226, 8228, 8231, 8240, 8240, 8242, 8243, 8245, 8245, 8251, 8251, 8254, 8254, 8308, 8308, 8319, 8319, 8321, 8324, 8364, 8364, 8451, 8451, 8453, 8453, 8457, 8457, 8467, 8467, 8470, 8470, 8481, 8482, 8486, 8486, 8491, 8491, 8531, 8532, 8539, 8542, 8544, 8555, 8560, 8569, 8585, 8585, 8592, 8601, 8632, 8633, 8658, 8658, 8660, 8660, 8679, 8679, 8704, 8704, 8706, 8707, 8711, 8712, 8715, 8715, 8719, 8719, 8721, 8721, 8725, 8725, 8730, 8730, 8733, 8736, 8739, 8739, 8741, 8741, 8743, 8748, 8750, 8750, 8756, 8759, 8764, 8765, 8776, 8776, 8780, 8780, 8786, 8786, 8800, 8801, 8804, 8807, 8810, 8811, 8814, 8815, 8834, 8835, 8838, 8839, 8853, 8853, 8857, 8857, 8869, 8869, 8895, 8895, 8978, 8978, 9312, 9449, 9451, 9547, 9552, 9587, 9600, 9615, 9618, 9621, 9632, 9633, 9635, 9641, 9650, 9651, 9654, 9655, 9660, 9661, 9664, 9665, 9670, 9672, 9675, 9675, 9678, 9681, 9698, 9701, 9711, 9711, 9733, 9734, 9737, 9737, 9742, 9743, 9756, 9756, 9758, 9758, 9792, 9792, 9794, 9794, 9824, 9825, 9827, 9829, 9831, 9834, 9836, 9837, 9839, 9839, 9886, 9887, 9919, 9919, 9926, 9933, 9935, 9939, 9941, 9953, 9955, 9955, 9960, 9961, 9963, 9969, 9972, 9972, 9974, 9977, 9979, 9980, 9982, 9983, 10045, 10045, 10102, 10111, 11094, 11097, 12872, 12879, 57344, 63743, 65024, 65039, 65533, 65533, 127232, 127242, 127248, 127277, 127280, 127337, 127344, 127373, 127375, 127376, 127387, 127404, 917760, 917999, 983040, 1048573, 1048576, 1114109];
  var fullwidthMinimalCodePoint = 12288;
  var fullwidthMaximumCodePoint = 65510;
  var fullwidthRanges = [12288, 12288, 65281, 65376, 65504, 65510];
  var wideMinimalCodePoint = 4352;
  var wideMaximumCodePoint = 262141;
  var wideRanges = [4352, 4447, 8986, 8987, 9001, 9002, 9193, 9196, 9200, 9200, 9203, 9203, 9725, 9726, 9748, 9749, 9776, 9783, 9800, 9811, 9855, 9855, 9866, 9871, 9875, 9875, 9889, 9889, 9898, 9899, 9917, 9918, 9924, 9925, 9934, 9934, 9940, 9940, 9962, 9962, 9970, 9971, 9973, 9973, 9978, 9978, 9981, 9981, 9989, 9989, 9994, 9995, 10024, 10024, 10060, 10060, 10062, 10062, 10067, 10069, 10071, 10071, 10133, 10135, 10160, 10160, 10175, 10175, 11035, 11036, 11088, 11088, 11093, 11093, 11904, 11929, 11931, 12019, 12032, 12245, 12272, 12287, 12289, 12350, 12353, 12438, 12441, 12543, 12549, 12591, 12593, 12686, 12688, 12773, 12783, 12830, 12832, 12871, 12880, 42124, 42128, 42182, 43360, 43388, 44032, 55203, 63744, 64255, 65040, 65049, 65072, 65106, 65108, 65126, 65128, 65131, 94176, 94180, 94192, 94198, 94208, 101589, 101631, 101662, 101760, 101874, 110576, 110579, 110581, 110587, 110589, 110590, 110592, 110882, 110898, 110898, 110928, 110930, 110933, 110933, 110948, 110951, 110960, 111355, 119552, 119638, 119648, 119670, 126980, 126980, 127183, 127183, 127374, 127374, 127377, 127386, 127488, 127490, 127504, 127547, 127552, 127560, 127568, 127569, 127584, 127589, 127744, 127776, 127789, 127797, 127799, 127868, 127870, 127891, 127904, 127946, 127951, 127955, 127968, 127984, 127988, 127988, 127992, 128062, 128064, 128064, 128066, 128252, 128255, 128317, 128331, 128334, 128336, 128359, 128378, 128378, 128405, 128406, 128420, 128420, 128507, 128591, 128640, 128709, 128716, 128716, 128720, 128722, 128725, 128728, 128732, 128735, 128747, 128748, 128756, 128764, 128992, 129003, 129008, 129008, 129292, 129338, 129340, 129349, 129351, 129535, 129648, 129660, 129664, 129674, 129678, 129734, 129736, 129736, 129741, 129756, 129759, 129770, 129775, 129784, 131072, 196605, 196608, 262141];

  // node_modules/get-east-asian-width/utilities.js
  var isInRange = (ranges, codePoint) => {
    let low = 0;
    let high = Math.floor(ranges.length / 2) - 1;
    while (low <= high) {
      const mid = Math.floor((low + high) / 2);
      const i = mid * 2;
      if (codePoint < ranges[i]) {
        high = mid - 1;
      } else if (codePoint > ranges[i + 1]) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  };

  // node_modules/get-east-asian-width/lookup.js
  var commonCjkCodePoint = 19968;
  var [wideFastPathStart, wideFastPathEnd] = /* @__PURE__ */ findWideFastPathRange(wideRanges);
  function findWideFastPathRange(ranges) {
    let fastPathStart = ranges[0];
    let fastPathEnd = ranges[1];
    for (let index = 0; index < ranges.length; index += 2) {
      const start = ranges[index];
      const end = ranges[index + 1];
      if (commonCjkCodePoint >= start && commonCjkCodePoint <= end) {
        return [start, end];
      }
      if (end - start > fastPathEnd - fastPathStart) {
        fastPathStart = start;
        fastPathEnd = end;
      }
    }
    return [fastPathStart, fastPathEnd];
  }
  var isAmbiguous = (codePoint) => {
    if (codePoint < ambiguousMinimalCodePoint || codePoint > ambiguousMaximumCodePoint) {
      return false;
    }
    return isInRange(ambiguousRanges, codePoint);
  };
  var isFullWidth = (codePoint) => {
    if (codePoint < fullwidthMinimalCodePoint || codePoint > fullwidthMaximumCodePoint) {
      return false;
    }
    return isInRange(fullwidthRanges, codePoint);
  };
  var isWide = (codePoint) => {
    if (codePoint >= wideFastPathStart && codePoint <= wideFastPathEnd) {
      return true;
    }
    if (codePoint < wideMinimalCodePoint || codePoint > wideMaximumCodePoint) {
      return false;
    }
    return isInRange(wideRanges, codePoint);
  };

  // node_modules/get-east-asian-width/index.js
  function validate(codePoint) {
    if (!Number.isSafeInteger(codePoint)) {
      throw new TypeError(`Expected a code point, got \`${typeof codePoint}\`.`);
    }
  }
  function eastAsianWidth(codePoint, { ambiguousAsWide = false } = {}) {
    validate(codePoint);
    if (isFullWidth(codePoint) || isWide(codePoint) || ambiguousAsWide && isAmbiguous(codePoint)) {
      return 2;
    }
    return 1;
  }

  // node_modules/string-width/index.js
  var segmenter = new Intl.Segmenter();
  var zeroWidthClusterRegex = new RegExp("^(?:\\p{Default_Ignorable_Code_Point}|\\p{Control}|\\p{Format}|\\p{Mark}|\\p{Surrogate})+$", "v");
  var leadingNonPrintingRegex = new RegExp("^[\\p{Default_Ignorable_Code_Point}\\p{Control}\\p{Format}\\p{Mark}\\p{Surrogate}]+", "v");
  var rgiEmojiRegex = new RegExp("^\\p{RGI_Emoji}$", "v");
  var unqualifiedKeycapRegex = /^[\d#*]\u20E3$/;
  var extendedPictographicRegex = /\p{Extended_Pictographic}/gu;
  function isDoubleWidthNonRgiEmojiSequence(segment) {
    if (segment.length > 50) {
      return false;
    }
    if (unqualifiedKeycapRegex.test(segment)) {
      return true;
    }
    if (segment.includes("\u200D")) {
      const pictographics = segment.match(extendedPictographicRegex);
      return pictographics !== null && pictographics.length >= 2;
    }
    return false;
  }
  function baseVisible(segment) {
    return segment.replace(leadingNonPrintingRegex, "");
  }
  function isZeroWidthCluster(segment) {
    return zeroWidthClusterRegex.test(segment);
  }
  function isHangulLeadingJamo(codePoint) {
    return codePoint >= 4352 && codePoint <= 4447 || codePoint >= 43360 && codePoint <= 43388;
  }
  function isHangulVowelJamo(codePoint) {
    return codePoint >= 4448 && codePoint <= 4519 || codePoint >= 55216 && codePoint <= 55238;
  }
  function isHangulTrailingJamo(codePoint) {
    return codePoint >= 4520 && codePoint <= 4607 || codePoint >= 55243 && codePoint <= 55291;
  }
  function isHangulJamo(codePoint) {
    return isHangulLeadingJamo(codePoint) || isHangulVowelJamo(codePoint) || isHangulTrailingJamo(codePoint);
  }
  function hangulClusterWidth(visibleSegment, eastAsianWidthOptions) {
    const codePoints = [];
    for (const character of visibleSegment) {
      if (zeroWidthClusterRegex.test(character)) {
        continue;
      }
      codePoints.push(character.codePointAt(0));
    }
    if (codePoints.length === 0) {
      return void 0;
    }
    let width = 0;
    for (let index = 0; index < codePoints.length; index++) {
      const codePoint = codePoints[index];
      if (!isHangulJamo(codePoint)) {
        if (width === 0) {
          return void 0;
        }
        for (let remaining = index; remaining < codePoints.length; remaining++) {
          width += eastAsianWidth(codePoints[remaining], eastAsianWidthOptions);
        }
        return width;
      }
      if (isHangulLeadingJamo(codePoint) && isHangulVowelJamo(codePoints[index + 1])) {
        width += 2;
        index += isHangulTrailingJamo(codePoints[index + 2]) ? 2 : 1;
        continue;
      }
      width += eastAsianWidth(codePoint, eastAsianWidthOptions);
    }
    return width;
  }
  function trailingHalfwidthWidth(visibleSegment, eastAsianWidthOptions) {
    let extra = 0;
    let first = true;
    for (const character of visibleSegment) {
      if (first) {
        first = false;
        continue;
      }
      if (character >= "\uFF00" && character <= "\uFFEF") {
        extra += eastAsianWidth(character.codePointAt(0), eastAsianWidthOptions);
      }
    }
    return extra;
  }
  function stringWidth(input, options = {}) {
    if (typeof input !== "string" || input.length === 0) {
      return 0;
    }
    const {
      ambiguousIsNarrow = true,
      countAnsiEscapeCodes = false
    } = options;
    let string3 = input;
    if (!countAnsiEscapeCodes && (string3.includes("\x1B") || string3.includes("\x9B"))) {
      string3 = stripAnsi(string3);
    }
    if (string3.length === 0) {
      return 0;
    }
    if (/^[\u0020-\u007E]*$/.test(string3)) {
      return string3.length;
    }
    let width = 0;
    const eastAsianWidthOptions = { ambiguousAsWide: !ambiguousIsNarrow };
    for (const { segment } of segmenter.segment(string3)) {
      if (isZeroWidthCluster(segment)) {
        continue;
      }
      if (rgiEmojiRegex.test(segment) || isDoubleWidthNonRgiEmojiSequence(segment)) {
        width += 2;
        continue;
      }
      const visibleSegment = baseVisible(segment);
      const hangulWidth = hangulClusterWidth(visibleSegment, eastAsianWidthOptions);
      if (hangulWidth !== void 0) {
        width += hangulWidth;
        continue;
      }
      const codePoint = visibleSegment.codePointAt(0);
      width += eastAsianWidth(codePoint, eastAsianWidthOptions);
      width += trailingHalfwidthWidth(visibleSegment, eastAsianWidthOptions);
    }
    return width;
  }

  // node_modules/markdownlint/lib/md060.mjs
  function addError17(errors, lineNumber, column, detail, fixInfo) {
    errors.push({
      lineNumber,
      detail,
      "range": [column, 1],
      fixInfo
    });
  }
  function getTableDividerColumns(lines, row) {
    return (0, import_micromark_helpers40.filterByTypes)(
      row.children,
      ["tableCellDivider"]
    ).map(
      (divider) => ({
        "actual": divider.startColumn,
        "effective": stringWidth(lines[row.startLine - 1].slice(0, divider.startColumn - 1))
      })
    );
  }
  function checkStyleAligned(lines, rows, detail) {
    const errorInfos = [];
    const headerRow = rows[0];
    const headerDividerColumns = getTableDividerColumns(lines, headerRow);
    for (const row of rows.slice(1)) {
      const remainingHeaderDividerColumns = new Set(headerDividerColumns.map((column) => column.effective));
      const rowDividerColumns = getTableDividerColumns(lines, row);
      for (const dividerColumn of rowDividerColumns) {
        if (remainingHeaderDividerColumns.size > 0 && !remainingHeaderDividerColumns.delete(dividerColumn.effective)) {
          addError17(errorInfos, row.startLine, dividerColumn.actual, detail);
        }
      }
    }
    return errorInfos;
  }
  var md060_default = {
    "names": ["MD060", "table-column-style"],
    "description": "Table column style",
    "tags": ["table"],
    "parser": "micromark",
    "function": function MD060(params2, onError) {
      const style = String(params2.config.style || "any");
      const styleAlignedAllowed = style === "any" || style === "aligned";
      const styleCompactAllowed = style === "any" || style === "compact";
      const styleTightAllowed = style === "any" || style === "tight";
      const alignedDelimiter = !!params2.config.aligned_delimiter;
      const lines = params2.lines;
      const tables = filterByTypesCached(["table"]);
      for (const table of tables) {
        const rows = (0, import_micromark_helpers40.filterByTypes)(table.children, ["tableDelimiterRow", "tableRow"]);
        const errorsIfAligned = [];
        if (styleAlignedAllowed) {
          errorsIfAligned.push(...checkStyleAligned(lines, rows, 'Table pipe does not align with header for style "aligned"'));
        }
        const errorsIfCompact = [];
        const errorsIfTight = [];
        if ((styleCompactAllowed || styleTightAllowed) && !(styleAlignedAllowed && errorsIfAligned.length === 0)) {
          if (alignedDelimiter) {
            const errorInfos2 = checkStyleAligned(lines, rows.slice(0, 2), 'Table pipe does not align with header for option "aligned_delimiter"');
            errorsIfCompact.push(...errorInfos2);
            errorsIfTight.push(...errorInfos2);
          }
          for (const row of rows) {
            const tokensOfInterest = (0, import_micromark_helpers40.filterByTypes)(row.children, ["tableCellDivider", "tableContent", "whitespace"]);
            for (let i = 0; i < tokensOfInterest.length; i++) {
              const { startColumn, startLine, type } = tokensOfInterest[i];
              if (type === "tableCellDivider") {
                const previous4 = tokensOfInterest[i - 1];
                if (previous4) {
                  if (previous4.type === "whitespace") {
                    if (previous4.text.length !== 1) {
                      addError17(
                        errorsIfCompact,
                        startLine,
                        startColumn,
                        'Table pipe has extra space to the left for style "compact"',
                        { "editColumn": previous4.startColumn, "deleteCount": previous4.text.length - 1 }
                      );
                    }
                    addError17(
                      errorsIfTight,
                      startLine,
                      startColumn,
                      'Table pipe has space to the left for style "tight"',
                      { "editColumn": previous4.startColumn, "deleteCount": previous4.text.length }
                    );
                  } else {
                    addError17(
                      errorsIfCompact,
                      startLine,
                      startColumn,
                      'Table pipe is missing space to the left for style "compact"',
                      { "editColumn": previous4.endColumn, "insertText": " " }
                    );
                  }
                }
                const next = tokensOfInterest[i + 1];
                if (next) {
                  if (next.type === "whitespace") {
                    if (next.endColumn !== row.endColumn) {
                      if (next.text.length !== 1) {
                        addError17(
                          errorsIfCompact,
                          startLine,
                          startColumn,
                          'Table pipe has extra space to the right for style "compact"',
                          { "editColumn": next.startColumn, "deleteCount": next.text.length - 1 }
                        );
                      }
                      addError17(
                        errorsIfTight,
                        startLine,
                        startColumn,
                        'Table pipe has space to the right for style "tight"',
                        { "editColumn": next.startColumn, "deleteCount": next.text.length }
                      );
                    }
                  } else {
                    addError17(
                      errorsIfCompact,
                      startLine,
                      startColumn,
                      'Table pipe is missing space to the right for style "compact"',
                      { "editColumn": next.startColumn, "insertText": " " }
                    );
                  }
                }
              }
            }
          }
        }
        let errorInfos = errorsIfAligned;
        if (styleCompactAllowed && (errorsIfCompact.length < errorInfos.length || !styleAlignedAllowed)) {
          errorInfos = errorsIfCompact;
        }
        if (styleTightAllowed && (errorsIfTight.length < errorInfos.length || !styleAlignedAllowed && !styleCompactAllowed)) {
          errorInfos = errorsIfTight;
        }
        for (const errorInfo of errorInfos) {
          onError(errorInfo);
        }
      }
    }
  };

  // node_modules/markdownlint/lib/rules.mjs
  var [md019, md021] = md019_md021_default;
  var [md049, md050] = md049_md050_default;
  var rules = [
    md001_default,
    // md002: Deprecated and removed
    md003_default,
    md004_default,
    md005_default,
    // md006: Deprecated and removed
    md007_default,
    md009_default,
    md010_default,
    md011_default,
    md012_default,
    md013_default,
    md014_default,
    md018_default,
    md019,
    md020_default,
    md021,
    md022_default,
    md023_default,
    md024_default,
    md025_default,
    md026_default,
    md027_default,
    md028_default,
    md029_default,
    md030_default,
    md031_default,
    md032_default,
    md033_default,
    md034_default,
    md035_default,
    md036_default,
    md037_default,
    md038_default,
    md039_default,
    md040_default,
    md041_default,
    md042_default,
    md043_default,
    md044_default,
    md045_default,
    md046_default,
    md047_default,
    md048_default,
    md049,
    md050,
    md051_default,
    md052_default,
    md053_default,
    md054_default,
    md055_default,
    md056_default,
    // md057: See https://github.com/markdownlint/markdownlint
    md058_default,
    md059_default,
    md060_default
  ];
  for (const rule of rules) {
    const name = rule.names[0].toLowerCase();
    rule["information"] = new URL(`${homepage}/blob/v${version}/doc/${name}.md`);
  }
  var rules_default = rules;

  // node_modules/markdownlint/lib/parse-configuration.mjs
  function parseConfiguration(name, content3, parsers) {
    let config = null;
    let message = null;
    const errors = [];
    let index = 0;
    const failed = (parsers || [JSON.parse]).every((parser) => {
      try {
        const result = parser(content3);
        config = result && typeof result === "object" && !Array.isArray(result) ? result : {};
        return false;
      } catch (error) {
        errors.push(`Parser ${index++}: ${error?.message}`);
      }
      return true;
    });
    if (failed) {
      errors.unshift(`Unable to parse '${name}'`);
      message = errors.join("; ");
    }
    return {
      config,
      message
    };
  }

  // node_modules/markdownlint/lib/markdownlint.mjs
  var helpers = __toESM(require_helpers(), 1);
  function validateRuleList(ruleList, synchronous) {
    let result = null;
    if (ruleList.length === rules_default.length) {
      return result;
    }
    const allIds = {};
    for (const [index, rule] of ruleList.entries()) {
      let newError = function(property, value) {
        return new Error(
          `Property '${property}' of custom rule at index ${customIndex} is incorrect: '${value}'.`
        );
      };
      const customIndex = index - rules_default.length;
      for (const property of ["names", "tags"]) {
        const value = rule[property];
        if (!result && (!value || !Array.isArray(value) || value.length === 0 || !value.every(helpers.isString) || value.some(helpers.isEmptyString))) {
          result = newError(property, value);
        }
      }
      for (const propertyInfo of [
        ["description", "string"],
        ["function", "function"]
      ]) {
        const property = propertyInfo[0];
        const value = rule[property];
        if (!result && (!value || typeof value !== propertyInfo[1])) {
          result = newError(property, value);
        }
      }
      if (!result && rule.parser !== void 0 && rule.parser !== "markdownit" && rule.parser !== "micromark" && rule.parser !== "none") {
        result = newError("parser", rule.parser);
      }
      if (!result && rule.information && !helpers.isUrl(rule.information)) {
        result = newError("information", rule.information);
      }
      if (!result && rule.asynchronous !== void 0 && typeof rule.asynchronous !== "boolean") {
        result = newError("asynchronous", rule.asynchronous);
      }
      if (!result && rule.asynchronous && synchronous) {
        result = new Error(
          "Custom rule " + rule.names.join("/") + " at index " + customIndex + " is asynchronous and can not be used in a synchronous context."
        );
      }
      if (!result) {
        for (const name of rule.names) {
          const nameUpper = name.toUpperCase();
          if (!result && allIds[nameUpper] !== void 0) {
            result = new Error("Name '" + name + "' of custom rule at index " + customIndex + " is already used as a name or tag.");
          }
          allIds[nameUpper] = true;
        }
        for (const tag of rule.tags) {
          const tagUpper = tag.toUpperCase();
          if (!result && allIds[tagUpper]) {
            result = new Error("Tag '" + tag + "' of custom rule at index " + customIndex + " is already used as a name.");
          }
          allIds[tagUpper] = false;
        }
      }
    }
    return result;
  }
  function removeFrontMatter(content3, frontMatter) {
    let frontMatterLines = [];
    if (frontMatter) {
      const frontMatterMatch = content3.match(frontMatter);
      if (frontMatterMatch && !frontMatterMatch.index) {
        const contentMatched = frontMatterMatch[0];
        content3 = content3.slice(contentMatched.length);
        frontMatterLines = contentMatched.split(helpers.newLineRe);
        if (frontMatterLines.length > 0 && frontMatterLines[frontMatterLines.length - 1] === "") {
          frontMatterLines.length--;
        }
      }
    }
    return {
      "content": content3,
      "frontMatterLines": frontMatterLines
    };
  }
  function mapAliasToRuleNames(ruleList) {
    const aliasToRuleNames = {};
    for (const rule of ruleList) {
      const ruleName = rule.names[0].toUpperCase();
      for (const name of rule.names) {
        const nameUpper = name.toUpperCase();
        aliasToRuleNames[nameUpper] = [ruleName];
      }
      for (const tag of rule.tags) {
        const tagUpper = tag.toUpperCase();
        const ruleNames = aliasToRuleNames[tagUpper] || [];
        ruleNames.push(ruleName);
        aliasToRuleNames[tagUpper] = ruleNames;
      }
    }
    return aliasToRuleNames;
  }
  function getEffectiveConfig(ruleList, config, aliasToRuleNames) {
    let ruleDefaultEnable = true;
    let ruleDefaultSeverity = "error";
    Object.entries(config).every(([key, value]) => {
      if (key.toUpperCase() === "DEFAULT") {
        ruleDefaultEnable = !!value;
        if (value === "warning") {
          ruleDefaultSeverity = "warning";
        }
        return false;
      }
      return true;
    });
    const effectiveConfig = {};
    const rulesEnabled = /* @__PURE__ */ new Map();
    const rulesSeverity = /* @__PURE__ */ new Map();
    const emptyObject = Object.freeze({});
    for (const ruleName of ruleList.map((rule) => rule.names[0].toUpperCase())) {
      effectiveConfig[ruleName] = emptyObject;
      rulesEnabled.set(ruleName, ruleDefaultEnable);
      rulesSeverity.set(ruleName, ruleDefaultSeverity);
    }
    for (const [key, value] of Object.entries(config)) {
      const keyUpper = key.toUpperCase();
      let enabled = false;
      let severity = "error";
      let effectiveValue = {};
      if (value) {
        if (value instanceof Object) {
          const valueObject = value;
          enabled = valueObject.enabled === void 0 ? true : !!valueObject.enabled;
          severity = valueObject.severity === "warning" ? "warning" : "error";
          effectiveValue = Object.fromEntries(
            Object.entries(value).filter(
              ([k]) => k !== "enabled" && k !== "severity"
            )
          );
        } else {
          enabled = true;
          severity = value === "warning" ? "warning" : "error";
        }
      }
      for (const ruleName of aliasToRuleNames[keyUpper] || []) {
        Object.freeze(effectiveValue);
        effectiveConfig[ruleName] = effectiveValue;
        rulesEnabled.set(ruleName, enabled);
        rulesSeverity.set(ruleName, severity);
      }
    }
    return {
      effectiveConfig,
      rulesEnabled,
      rulesSeverity
    };
  }
  function getEnabledRulesPerLineNumber(ruleList, lines, frontMatterLines, noInlineConfig, config, configParsers, aliasToRuleNames) {
    let enabledRules = /* @__PURE__ */ new Map();
    let capturedRules = enabledRules;
    const enabledRulesPerLineNumber = new Array(1 + frontMatterLines.length);
    function handleInlineConfig(input, forEachMatch, forEachLine = void 0) {
      for (const [lineIndex, line] of input.entries()) {
        if (!noInlineConfig) {
          let match = null;
          while (match = helpers.inlineCommentStartRe.exec(line)) {
            const action = match[2].toUpperCase();
            const startIndex = match.index + match[1].length;
            const endIndex = line.indexOf("-->", startIndex);
            if (endIndex === -1) {
              break;
            }
            const parameter = line.slice(startIndex, endIndex);
            forEachMatch(action, parameter, lineIndex + 1);
          }
        }
        if (forEachLine) {
          forEachLine();
        }
      }
    }
    function configureFile(action, parameter) {
      if (action === "CONFIGURE-FILE") {
        const { "config": parsed } = parseConfiguration(
          "CONFIGURE-FILE",
          parameter,
          configParsers
        );
        if (parsed) {
          config = {
            ...config,
            ...parsed
          };
        }
      }
    }
    function applyEnableDisable(action, parameter, state) {
      state = new Map(state);
      const enabled = action.startsWith("ENABLE");
      const trimmed = parameter && parameter.trim();
      const items = trimmed ? trimmed.toUpperCase().split(/\s+/) : allRuleNames;
      for (const nameUpper of items) {
        for (const ruleName of aliasToRuleNames[nameUpper] || []) {
          state.set(ruleName, enabled);
        }
      }
      return state;
    }
    function enableDisableFile(action, parameter) {
      if (action === "ENABLE-FILE" || action === "DISABLE-FILE") {
        enabledRules = applyEnableDisable(action, parameter, enabledRules);
      }
    }
    function captureRestoreEnableDisable(action, parameter) {
      if (action === "CAPTURE") {
        capturedRules = enabledRules;
      } else if (action === "RESTORE") {
        enabledRules = capturedRules;
      } else if (action === "ENABLE" || action === "DISABLE") {
        enabledRules = applyEnableDisable(action, parameter, enabledRules);
      }
    }
    function updateLineState() {
      enabledRulesPerLineNumber.push(enabledRules);
    }
    function disableLineNextLine(action, parameter, lineNumber) {
      const disableLine = action === "DISABLE-LINE";
      const disableNextLine = action === "DISABLE-NEXT-LINE";
      if (disableLine || disableNextLine) {
        const nextLineNumber = frontMatterLines.length + lineNumber + (disableNextLine ? 1 : 0);
        enabledRulesPerLineNumber[nextLineNumber] = applyEnableDisable(
          action,
          parameter,
          enabledRulesPerLineNumber[nextLineNumber]
        );
      }
    }
    handleInlineConfig([lines.join("\n")], configureFile);
    const { effectiveConfig, rulesEnabled, rulesSeverity } = getEffectiveConfig(ruleList, config, aliasToRuleNames);
    const allRuleNames = [...rulesEnabled.keys()];
    enabledRules = new Map(rulesEnabled);
    capturedRules = enabledRules;
    handleInlineConfig(lines, enableDisableFile);
    handleInlineConfig(lines, captureRestoreEnableDisable, updateLineState);
    handleInlineConfig(lines, disableLineNextLine);
    const enabledRuleList = ruleList.filter((rule) => {
      const ruleName = rule.names[0].toUpperCase();
      return enabledRulesPerLineNumber.some((enabledRulesForLine) => enabledRulesForLine.get(ruleName));
    });
    return {
      effectiveConfig,
      enabledRulesPerLineNumber,
      enabledRuleList,
      rulesSeverity
    };
  }
  function lintContent(ruleList, aliasToRuleNames, name, content3, markdownItFactory, config, configParsers, frontMatter, handleRuleFailures, noInlineConfig, synchronous, callback) {
    const callbackError = (error) => callback(error instanceof Error ? error : new Error(error));
    content3 = content3.replace(/^\uFEFF/, "");
    const removeFrontMatterResult = removeFrontMatter(content3, frontMatter);
    const { frontMatterLines } = removeFrontMatterResult;
    content3 = removeFrontMatterResult.content;
    const { effectiveConfig, enabledRulesPerLineNumber, enabledRuleList, rulesSeverity } = getEnabledRulesPerLineNumber(
      ruleList,
      content3.split(helpers.newLineRe),
      frontMatterLines,
      noInlineConfig,
      config,
      configParsers,
      aliasToRuleNames
    );
    const needMarkdownItTokens = enabledRuleList.some(
      (rule) => rule.parser === "markdownit" || rule.parser === void 0
    );
    const needMicromarkTokens = enabledRuleList.some(
      (rule) => rule.parser === "micromark"
    );
    const customRulesPresent = ruleList.length !== rules_default.length;
    const micromarkTokens2 = needMicromarkTokens ? parse2(content3, { "freezeTokens": customRulesPresent }) : [];
    const preClearedContent = content3;
    content3 = helpers.clearHtmlCommentText(content3);
    const lines = content3.split(helpers.newLineRe);
    const lintContentInternal = (markdownitTokens) => {
      const parsersMarkdownIt = Object.freeze({
        "markdownit": Object.freeze({
          "tokens": markdownitTokens
        })
      });
      const parsersMicromark = Object.freeze({
        "micromark": Object.freeze({
          "tokens": micromarkTokens2
        })
      });
      const parsersNone = Object.freeze({});
      const paramsBase = {
        name,
        version,
        "lines": Object.freeze(lines),
        "frontMatterLines": Object.freeze(frontMatterLines)
      };
      initialize({
        ...paramsBase,
        "parsers": parsersMicromark,
        "config": {}
      });
      const results = [];
      const forRule = (rule) => {
        const ruleName = rule.names[0].toUpperCase();
        const tokens = {};
        let parsers = parsersNone;
        if (rule.parser === void 0) {
          tokens.tokens = markdownitTokens;
          parsers = parsersMarkdownIt;
        } else if (rule.parser === "markdownit") {
          parsers = parsersMarkdownIt;
        } else if (rule.parser === "micromark") {
          parsers = parsersMicromark;
        }
        const params2 = Object.freeze({
          ...paramsBase,
          ...tokens,
          parsers,
          /** @type {RuleConfiguration} */
          // @ts-ignore
          "config": effectiveConfig[ruleName]
        });
        function throwError(property) {
          throw new Error(
            `Value of '${property}' passed to onError by '${ruleName}' is incorrect for '${name}'.`
          );
        }
        function onError(errorInfo) {
          if (!errorInfo || !helpers.isNumber(errorInfo.lineNumber) || errorInfo.lineNumber < 1 || errorInfo.lineNumber > lines.length) {
            throwError("lineNumber");
          }
          const lineNumber = errorInfo.lineNumber + frontMatterLines.length;
          if (!enabledRulesPerLineNumber[lineNumber].get(ruleName)) {
            return;
          }
          if (errorInfo.detail && !helpers.isString(errorInfo.detail)) {
            throwError("detail");
          }
          if (errorInfo.context && !helpers.isString(errorInfo.context)) {
            throwError("context");
          }
          if (errorInfo.information && !helpers.isUrl(errorInfo.information)) {
            throwError("information");
          }
          if (errorInfo.range && (!Array.isArray(errorInfo.range) || errorInfo.range.length !== 2 || !helpers.isNumber(errorInfo.range[0]) || errorInfo.range[0] < 1 || !helpers.isNumber(errorInfo.range[1]) || errorInfo.range[1] < 1 || errorInfo.range[0] + errorInfo.range[1] - 1 > lines[errorInfo.lineNumber - 1].length)) {
            throwError("range");
          }
          const fixInfo = errorInfo.fixInfo;
          const cleanFixInfo = {};
          if (fixInfo) {
            if (!helpers.isObject(fixInfo)) {
              throwError("fixInfo");
            }
            if (fixInfo.lineNumber !== void 0) {
              if (!helpers.isNumber(fixInfo.lineNumber) || fixInfo.lineNumber < 1 || fixInfo.lineNumber > lines.length) {
                throwError("fixInfo.lineNumber");
              }
              cleanFixInfo.lineNumber = fixInfo.lineNumber + frontMatterLines.length;
            }
            const effectiveLineNumber = fixInfo.lineNumber || errorInfo.lineNumber;
            if (fixInfo.editColumn !== void 0) {
              if (!helpers.isNumber(fixInfo.editColumn) || fixInfo.editColumn < 1 || fixInfo.editColumn > lines[effectiveLineNumber - 1].length + 1) {
                throwError("fixInfo.editColumn");
              }
              cleanFixInfo.editColumn = fixInfo.editColumn;
            }
            if (fixInfo.deleteCount !== void 0) {
              if (!helpers.isNumber(fixInfo.deleteCount) || fixInfo.deleteCount < -1 || fixInfo.deleteCount > lines[effectiveLineNumber - 1].length) {
                throwError("fixInfo.deleteCount");
              }
              cleanFixInfo.deleteCount = fixInfo.deleteCount;
            }
            if (fixInfo.insertText !== void 0) {
              if (!helpers.isString(fixInfo.insertText)) {
                throwError("fixInfo.insertText");
              }
              cleanFixInfo.insertText = fixInfo.insertText;
            }
          }
          const information = errorInfo.information || rule.information;
          results.push({
            lineNumber,
            "ruleNames": rule.names,
            "ruleDescription": rule.description,
            "ruleInformation": information ? information.href : null,
            "errorDetail": errorInfo.detail?.replace(helpers.newLineRe, " ") || null,
            "errorContext": errorInfo.context?.replace(helpers.newLineRe, " ") || null,
            "errorRange": errorInfo.range ? [...errorInfo.range] : null,
            "fixInfo": fixInfo ? cleanFixInfo : null,
            // @ts-ignore
            "severity": rulesSeverity.get(ruleName)
          });
        }
        const catchCallsOnError = (error) => onError({
          "lineNumber": 1,
          "detail": `This rule threw an exception: ${error.message || error}`
        });
        const invokeRuleFunction = () => rule.function(params2, onError);
        if (rule.asynchronous) {
          const ruleFunctionPromise = Promise.resolve().then(invokeRuleFunction);
          return handleRuleFailures ? ruleFunctionPromise.catch(catchCallsOnError) : ruleFunctionPromise;
        }
        try {
          invokeRuleFunction();
        } catch (error) {
          if (handleRuleFailures) {
            catchCallsOnError(error);
          } else {
            throw error;
          }
        }
        return null;
      };
      const formatResults = () => {
        results.sort((a, b) => a.ruleNames[0].localeCompare(b.ruleNames[0]) || a.lineNumber - b.lineNumber);
        return results;
      };
      const ruleListAsync = enabledRuleList.filter((rule) => rule.asynchronous);
      const ruleListSync = enabledRuleList.filter((rule) => !rule.asynchronous);
      const ruleListAsyncFirst = [
        ...ruleListAsync,
        ...ruleListSync
      ];
      const callbackSuccess = () => callback(null, formatResults());
      try {
        const ruleResults = ruleListAsyncFirst.map(forRule);
        if (ruleListAsync.length > 0) {
          Promise.all(ruleResults.slice(0, ruleListAsync.length)).then(callbackSuccess).catch(callbackError);
        } else {
          callbackSuccess();
        }
      } catch (error) {
        callbackError(error);
      } finally {
        initialize();
      }
    };
    if (!needMarkdownItTokens || synchronous) {
      const markdownItTokens = needMarkdownItTokens ? (0, import_defer_require.requireMarkdownItCjs)().getMarkdownItTokens(markdownItFactory(), preClearedContent, lines) : [];
      lintContentInternal(markdownItTokens);
    } else {
      Promise.all([
        // eslint-disable-next-line no-inline-comments
        Promise.resolve().then(() => __toESM(require_markdownit(), 1)),
        // eslint-disable-next-line no-promise-executor-return
        new Promise((resolve) => resolve(markdownItFactory()))
      ]).then(([markdownitCjs, markdownIt]) => {
        const markdownItTokens = markdownitCjs.getMarkdownItTokens(markdownIt, preClearedContent, lines);
        lintContentInternal(markdownItTokens);
      }).catch(callbackError);
    }
  }
  function lintFile(ruleList, aliasToRuleNames, file, markdownItFactory, config, configParsers, frontMatter, handleRuleFailures, noInlineConfig, fs2, synchronous, callback) {
    function lintContentWrapper(err, content3) {
      if (err) {
        return callback(err);
      }
      return lintContent(
        ruleList,
        aliasToRuleNames,
        file,
        content3,
        markdownItFactory,
        config,
        configParsers,
        frontMatter,
        handleRuleFailures,
        noInlineConfig,
        synchronous,
        callback
      );
    }
    if (synchronous) {
      lintContentWrapper(null, fs2.readFileSync(file, "utf8"));
    } else {
      fs2.readFile(file, "utf8", lintContentWrapper);
    }
  }
  function lintInput(options, synchronous, callback) {
    options = options || {};
    callback = callback || function noop() {
    };
    const customRuleList = [options.customRules || []].flat().map((rule) => ({
      "names": helpers.cloneIfArray(rule.names),
      "description": rule.description,
      "information": helpers.cloneIfUrl(rule.information),
      "tags": helpers.cloneIfArray(rule.tags),
      "parser": rule.parser,
      "asynchronous": rule.asynchronous,
      "function": rule.function
    }));
    const ruleList = rules_default.concat(customRuleList);
    const ruleErr = validateRuleList(ruleList, synchronous);
    if (ruleErr) {
      callback(ruleErr);
      return;
    }
    let files = [];
    if (Array.isArray(options.files)) {
      files = [...options.files];
    } else if (options.files) {
      files = [String(options.files)];
    }
    const strings = options.strings || {};
    const stringsKeys = Object.keys(strings);
    const config = options.config || { "default": true };
    const configParsers = options.configParsers || void 0;
    const frontMatter = options.frontMatter === void 0 ? helpers.frontMatterRe : options.frontMatter;
    const handleRuleFailures = !!options.handleRuleFailures;
    const noInlineConfig = !!options.noInlineConfig;
    const markdownItFactory = options.markdownItFactory || (() => {
      throw new Error("The option 'markdownItFactory' was required (due to the option 'customRules' including a rule requiring the 'markdown-it' parser), but 'markdownItFactory' was not set.");
    });
    const fs2 = options.fs || fs;
    const aliasToRuleNames = mapAliasToRuleNames(ruleList);
    const results = {};
    let done = false;
    let concurrency = 0;
    function lintWorker() {
      let currentItem = void 0;
      function lintWorkerCallback(err, result) {
        concurrency--;
        if (err) {
          done = true;
          return callback(err);
        }
        results[currentItem] = result;
        if (!synchronous) {
          lintWorker();
        }
        return null;
      }
      if (done) {
      } else if (currentItem = files.shift()) {
        concurrency++;
        lintFile(
          ruleList,
          aliasToRuleNames,
          currentItem,
          markdownItFactory,
          config,
          configParsers,
          frontMatter,
          handleRuleFailures,
          noInlineConfig,
          fs2,
          synchronous,
          lintWorkerCallback
        );
      } else if (currentItem = stringsKeys.shift()) {
        concurrency++;
        lintContent(
          ruleList,
          aliasToRuleNames,
          currentItem,
          strings[currentItem] || "",
          markdownItFactory,
          config,
          configParsers,
          frontMatter,
          handleRuleFailures,
          noInlineConfig,
          synchronous,
          lintWorkerCallback
        );
      } else if (concurrency === 0) {
        done = true;
        const sortedEntries = Object.entries(results);
        sortedEntries.sort(([a], [b]) => a.localeCompare(b));
        const sortedResults = Object.fromEntries(sortedEntries);
        return callback(null, sortedResults);
      }
      return null;
    }
    if (synchronous) {
      while (!done) {
        lintWorker();
      }
    } else {
      lintWorker();
      lintWorker();
      lintWorker();
      lintWorker();
      lintWorker();
      lintWorker();
      lintWorker();
      lintWorker();
    }
  }
  function lintSync(options) {
    let results = null;
    lintInput(options, true, function callback(error, res) {
      if (error) {
        throw error;
      }
      results = res;
    });
    return results;
  }
  function normalizeFixInfo(fixInfo, lineNumber = 0) {
    return {
      "lineNumber": fixInfo.lineNumber || lineNumber,
      "editColumn": fixInfo.editColumn || 1,
      "deleteCount": fixInfo.deleteCount || 0,
      "insertText": fixInfo.insertText || ""
    };
  }
  function applyFix(line, fixInfo, lineEnding2 = "\n") {
    const { editColumn, deleteCount, insertText } = normalizeFixInfo(fixInfo);
    const editIndex = editColumn - 1;
    return deleteCount === -1 ? null : line.slice(0, editIndex) + insertText.replace(/\n/g, lineEnding2) + line.slice(editIndex + deleteCount);
  }
  function applyFixes(input, errors) {
    const lineEnding2 = helpers.getPreferredLineEnding(input, os);
    const lines = input.split(helpers.newLineRe);
    let fixInfos = errors.filter((error) => error.fixInfo).map((error) => normalizeFixInfo(error.fixInfo, error.lineNumber));
    fixInfos.sort((a, b) => {
      const aDeletingLine = a.deleteCount === -1;
      const bDeletingLine = b.deleteCount === -1;
      return b.lineNumber - a.lineNumber || (aDeletingLine ? 1 : bDeletingLine ? -1 : 0) || b.editColumn - a.editColumn || b.insertText.length - a.insertText.length;
    });
    let lastFixInfo = {};
    fixInfos = fixInfos.filter((fixInfo) => {
      const unique = fixInfo.lineNumber !== lastFixInfo.lineNumber || fixInfo.editColumn !== lastFixInfo.editColumn || fixInfo.deleteCount !== lastFixInfo.deleteCount || fixInfo.insertText !== lastFixInfo.insertText;
      lastFixInfo = fixInfo;
      return unique;
    });
    lastFixInfo = {
      "lineNumber": -1
    };
    for (const fixInfo of fixInfos) {
      if (fixInfo.lineNumber === lastFixInfo.lineNumber && fixInfo.editColumn === lastFixInfo.editColumn && !fixInfo.insertText && fixInfo.deleteCount > 0 && lastFixInfo.insertText && !lastFixInfo.deleteCount) {
        fixInfo.insertText = lastFixInfo.insertText;
        lastFixInfo.lineNumber = 0;
      }
      lastFixInfo = fixInfo;
    }
    fixInfos = fixInfos.filter((fixInfo) => fixInfo.lineNumber);
    let lastLineIndex = -1;
    let lastEditIndex = -1;
    for (const fixInfo of fixInfos) {
      const { lineNumber, editColumn, deleteCount } = fixInfo;
      const lineIndex = lineNumber - 1;
      const editIndex = editColumn - 1;
      if (lineIndex !== lastLineIndex || deleteCount === -1 || editIndex + deleteCount <= lastEditIndex - (deleteCount > 0 ? 0 : 1)) {
        lines[lineIndex] = applyFix(lines[lineIndex], fixInfo, lineEnding2);
      }
      lastLineIndex = lineIndex;
      lastEditIndex = editIndex;
    }
    return lines.filter((line) => line !== null).join(lineEnding2);
  }

  // node_modules/markdownlint/lib/exports.mjs
  var import_resolve_module2 = __toESM(require_resolve_module(), 1);
  return __toCommonJS(entry_exports);
})();
