var __merval = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
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
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // node_modules/@aj-archipelago/merval/dist/index.js
  var index_exports = {};
  __export(index_exports, {
    TokenType: () => TokenType,
    getDiagramType: () => getDiagramType,
    getMermaidVersionInfo: () => getMermaidVersionInfo,
    isMermaidVersionSupported: () => isMermaidVersionSupported,
    isValidMermaid: () => isValidMermaid,
    validateMermaid: () => validateMermaid
  });

  // node_modules/@aj-archipelago/merval/dist/lexer/index.js
  var TokenType;
  (function(TokenType2) {
    TokenType2["GRAPH"] = "GRAPH";
    TokenType2["FLOWCHART"] = "FLOWCHART";
    TokenType2["SEQUENCE_DIAGRAM"] = "SEQUENCE_DIAGRAM";
    TokenType2["CLASS_DIAGRAM"] = "CLASS_DIAGRAM";
    TokenType2["STATE_DIAGRAM"] = "STATE_DIAGRAM";
    TokenType2["STATE_DIAGRAM_V2"] = "STATE_DIAGRAM_V2";
    TokenType2["ER_DIAGRAM"] = "ER_DIAGRAM";
    TokenType2["JOURNEY"] = "JOURNEY";
    TokenType2["GANTT"] = "GANTT";
    TokenType2["PIE"] = "PIE";
    TokenType2["GITGRAPH"] = "GITGRAPH";
    TokenType2["MINDMAP"] = "MINDMAP";
    TokenType2["TIMELINE"] = "TIMELINE";
    TokenType2["XYCHART_BETA"] = "XYCHART_BETA";
    TokenType2["BLOCK_BETA"] = "BLOCK_BETA";
    TokenType2["ARROW"] = "ARROW";
    TokenType2["DOTTED_ARROW"] = "DOTTED_ARROW";
    TokenType2["THICK_ARROW"] = "THICK_ARROW";
    TokenType2["SUBGRAPH"] = "SUBGRAPH";
    TokenType2["SUBGRAPH_END"] = "SUBGRAPH_END";
    TokenType2["PARTICIPANT"] = "PARTICIPANT";
    TokenType2["ACTIVATION"] = "ACTIVATION";
    TokenType2["DEACTIVATION"] = "DEACTIVATION";
    TokenType2["NOTE"] = "NOTE";
    TokenType2["SEQUENCE_ARROW"] = "SEQUENCE_ARROW";
    TokenType2["IDENTIFIER"] = "IDENTIFIER";
    TokenType2["STRING"] = "STRING";
    TokenType2["NUMBER"] = "NUMBER";
    TokenType2["BRACKET_OPEN"] = "BRACKET_OPEN";
    TokenType2["BRACKET_CLOSE"] = "BRACKET_CLOSE";
    TokenType2["PAREN_OPEN"] = "PAREN_OPEN";
    TokenType2["PAREN_CLOSE"] = "PAREN_CLOSE";
    TokenType2["DOUBLE_PAREN_OPEN"] = "DOUBLE_PAREN_OPEN";
    TokenType2["DOUBLE_PAREN_CLOSE"] = "DOUBLE_PAREN_CLOSE";
    TokenType2["BRACE_OPEN"] = "BRACE_OPEN";
    TokenType2["BRACE_CLOSE"] = "BRACE_CLOSE";
    TokenType2["COMMA"] = "COMMA";
    TokenType2["SEMICOLON"] = "SEMICOLON";
    TokenType2["COLON"] = "COLON";
    TokenType2["PIPE"] = "PIPE";
    TokenType2["EQUALS"] = "EQUALS";
    TokenType2["NEWLINE"] = "NEWLINE";
    TokenType2["WHITESPACE"] = "WHITESPACE";
    TokenType2["COMMENT"] = "COMMENT";
    TokenType2["DIRECTIVE"] = "DIRECTIVE";
    TokenType2["EOF"] = "EOF";
  })(TokenType || (TokenType = {}));
  var Lexer = class {
    input;
    position = 0;
    line = 1;
    column = 1;
    constructor(input) {
      this.input = input;
    }
    tokenize() {
      this.position = 0;
      this.line = 1;
      this.column = 1;
      const tokens = [];
      let token;
      while ((token = this.nextToken()) !== null && token.type !== TokenType.EOF) {
        tokens.push(token);
      }
      tokens.push({
        type: TokenType.EOF,
        value: "",
        line: this.line,
        column: this.column,
        position: this.position
      });
      return tokens;
    }
    nextToken() {
      if (this.position >= this.input.length) {
        return null;
      }
      const char = this.input[this.position];
      if (/\s/.test(char)) {
        if (char === "\n") {
          this.line++;
          this.column = 1;
        } else {
          this.column++;
        }
        this.position++;
        return this.nextToken();
      }
      if (char === "%" && this.position + 1 < this.input.length && this.input[this.position + 1] === "%") {
        if (this.position + 2 < this.input.length && this.input[this.position + 2] === "{") {
          return this.readDirective();
        } else {
          return this.readComment();
        }
      }
      if (char === "(" && this.position + 1 < this.input.length && this.input[this.position + 1] === "(") {
        this.position += 2;
        this.column += 2;
        return {
          type: TokenType.DOUBLE_PAREN_OPEN,
          value: "((",
          line: this.line,
          column: this.column - 2,
          position: this.position - 2
        };
      }
      if (char === ")" && this.position + 1 < this.input.length && this.input[this.position + 1] === ")") {
        this.position += 2;
        this.column += 2;
        return {
          type: TokenType.DOUBLE_PAREN_CLOSE,
          value: "))",
          line: this.line,
          column: this.column - 2,
          position: this.position - 2
        };
      }
      const singleCharTokens = {
        "[": TokenType.BRACKET_OPEN,
        "]": TokenType.BRACKET_CLOSE,
        "(": TokenType.PAREN_OPEN,
        ")": TokenType.PAREN_CLOSE,
        "{": TokenType.BRACE_OPEN,
        "}": TokenType.BRACE_CLOSE,
        ",": TokenType.COMMA,
        ";": TokenType.SEMICOLON,
        ":": TokenType.COLON,
        "|": TokenType.PIPE
      };
      if (char === "=") {
        if (this.position + 2 < this.input.length && this.input[this.position + 1] === "=" && this.input[this.position + 2] === ">") {
          if (this.position + 3 < this.input.length && this.input[this.position + 3] === ">") {
            const token2 = {
              type: TokenType.EQUALS,
              value: char,
              line: this.line,
              column: this.column,
              position: this.position
            };
            this.position++;
            this.column++;
            return token2;
          } else {
            const arrowValue = "==>";
            this.position += 3;
            this.column += 3;
            return {
              type: TokenType.THICK_ARROW,
              value: arrowValue,
              line: this.line,
              column: this.column - arrowValue.length + 1,
              position: this.position - arrowValue.length
            };
          }
        } else {
          const token2 = {
            type: TokenType.EQUALS,
            value: char,
            line: this.line,
            column: this.column,
            position: this.position
          };
          this.position++;
          this.column++;
          return token2;
        }
      }
      if (singleCharTokens[char]) {
        const token2 = {
          type: singleCharTokens[char],
          value: char,
          line: this.line,
          column: this.column,
          position: this.position
        };
        this.position++;
        this.column++;
        return token2;
      }
      if (char === "-" && this.position + 3 < this.input.length && this.input[this.position + 1] === "." && this.input[this.position + 2] === "-" && this.input[this.position + 3] === ">") {
        let arrowValue = "-.->";
        let arrowType = TokenType.DOTTED_ARROW;
        if (this.position + 4 < this.input.length && this.input[this.position + 4] === ">") {
          arrowValue = "-.->>";
          this.position += 5;
          this.column += 5;
        } else {
          this.position += 4;
          this.column += 4;
        }
        return {
          type: arrowType,
          value: arrowValue,
          line: this.line,
          column: this.column - arrowValue.length + 1,
          position: this.position - arrowValue.length
        };
      }
      if (char === "-" && this.position + 2 < this.input.length && this.input[this.position + 1] === "-" && this.input[this.position + 2] === ">") {
        let arrowValue = "-->";
        let arrowType = TokenType.ARROW;
        if (this.position + 3 < this.input.length && this.input[this.position + 3] === ">") {
          arrowValue = "-->>";
          this.position += 4;
          this.column += 4;
        } else {
          this.position += 3;
          this.column += 3;
        }
        return {
          type: arrowType,
          value: arrowValue,
          line: this.line,
          column: this.column - arrowValue.length + 1,
          position: this.position - arrowValue.length
        };
      }
      if (char === "-" && this.position + 1 < this.input.length && this.input[this.position + 1] === ">") {
        let arrowValue = "->";
        let arrowType = TokenType.SEQUENCE_ARROW;
        if (this.position + 2 < this.input.length && this.input[this.position + 2] === ">") {
          arrowValue = "->>";
          this.position += 3;
          this.column += 3;
        } else {
          this.position += 2;
          this.column += 2;
        }
        return {
          type: arrowType,
          value: arrowValue,
          line: this.line,
          column: this.column - arrowValue.length + 1,
          position: this.position - arrowValue.length
        };
      }
      if (char === '"' || char === "'") {
        return this.readString();
      }
      if (/\d/.test(char)) {
        return this.readNumber();
      }
      if (/[a-zA-Z_]/.test(char)) {
        return this.readIdentifier();
      }
      const codePoint = this.input.codePointAt(this.position);
      if (codePoint === void 0) {
        return null;
      }
      const charValue = String.fromCodePoint(codePoint);
      const charLength = charValue.length;
      const token = {
        type: TokenType.IDENTIFIER,
        value: charValue,
        line: this.line,
        column: this.column,
        position: this.position
      };
      this.position += charLength;
      this.column++;
      return token;
    }
    readComment() {
      const start = this.position;
      const startLine = this.line;
      const startColumn = this.column;
      this.position += 2;
      this.column += 2;
      while (this.position < this.input.length && this.input[this.position] !== "\n") {
        this.position++;
        this.column++;
      }
      if (this.position < this.input.length && this.input[this.position] === "\n") {
        this.position++;
        this.line++;
        this.column = 1;
      }
      return {
        type: TokenType.COMMENT,
        value: this.input.slice(start, this.position),
        line: startLine,
        column: startColumn,
        position: start
      };
    }
    readDirective() {
      const start = this.position;
      this.position += 3;
      this.column += 3;
      let braceCount = 1;
      while (this.position < this.input.length) {
        const char = this.input[this.position];
        if (char === "%" && this.position + 1 < this.input.length && this.input[this.position + 1] === "%") {
          this.position += 2;
          this.column += 2;
          break;
        }
        if (char === "{") {
          braceCount++;
        } else if (char === "}") {
          braceCount--;
          if (braceCount === 0) {
          }
        } else if (char === "\n") {
          this.line++;
          this.column = 1;
        } else {
          this.column++;
        }
        this.position++;
      }
      return {
        type: TokenType.DIRECTIVE,
        value: this.input.slice(start, this.position),
        line: this.line,
        column: this.column,
        position: start
      };
    }
    readString() {
      const quote = this.input[this.position];
      const start = this.position;
      this.position++;
      this.column++;
      while (this.position < this.input.length && this.input[this.position] !== quote) {
        if (this.input[this.position] === "\n") {
          this.line++;
          this.column = 1;
        } else {
          this.column++;
        }
        this.position++;
      }
      if (this.position < this.input.length) {
        this.position++;
        this.column++;
      }
      return {
        type: TokenType.STRING,
        value: this.input.slice(start, this.position),
        line: this.line,
        column: this.column,
        position: start
      };
    }
    readNumber() {
      const start = this.position;
      while (this.position < this.input.length && /\d/.test(this.input[this.position])) {
        this.position++;
        this.column++;
      }
      return {
        type: TokenType.NUMBER,
        value: this.input.slice(start, this.position),
        line: this.line,
        column: this.column,
        position: start
      };
    }
    readIdentifier() {
      const start = this.position;
      while (this.position < this.input.length && /[a-zA-Z0-9_'-]/.test(this.input[this.position])) {
        if (this.input[this.position] === "-" && this.position + 1 < this.input.length && this.input[this.position + 1] === ">") {
          break;
        }
        if (this.input[this.position] === "-" && this.position + 2 < this.input.length && this.input[this.position + 1] === "-" && this.input[this.position + 2] === ">") {
          break;
        }
        this.position++;
        this.column++;
      }
      const value = this.input.slice(start, this.position);
      const keywords = {
        "graph": TokenType.GRAPH,
        "flowchart": TokenType.FLOWCHART,
        "sequencediagram": TokenType.SEQUENCE_DIAGRAM,
        "classdiagram": TokenType.CLASS_DIAGRAM,
        "statediagram": TokenType.STATE_DIAGRAM,
        "statediagram-v2": TokenType.STATE_DIAGRAM_V2,
        "erdiagram": TokenType.ER_DIAGRAM,
        "journey": TokenType.JOURNEY,
        "gantt": TokenType.GANTT,
        "pie": TokenType.PIE,
        "gitgraph": TokenType.GITGRAPH,
        "mindmap": TokenType.MINDMAP,
        "timeline": TokenType.TIMELINE,
        "xychart-beta": TokenType.XYCHART_BETA,
        "block-beta": TokenType.BLOCK_BETA,
        "participant": TokenType.PARTICIPANT,
        "activate": TokenType.ACTIVATION,
        "deactivate": TokenType.DEACTIVATION,
        "note": TokenType.IDENTIFIER,
        // Keep as identifier for special handling
        "subgraph": TokenType.SUBGRAPH,
        "classdef": TokenType.IDENTIFIER,
        // Keep as identifier for special handling
        "class": TokenType.IDENTIFIER,
        // Keep as identifier for special handling
        "linkstyle": TokenType.IDENTIFIER,
        // Keep as identifier for special handling
        "style": TokenType.IDENTIFIER
        // Keep as identifier for special handling
        // Note: 'end' removed from general keywords to avoid conflicts with identifiers
      };
      const type = keywords[value.toLowerCase()] || TokenType.IDENTIFIER;
      return {
        type,
        value,
        // Keep original case for all tokens
        line: this.line,
        column: this.column,
        position: start
      };
    }
  };

  // node_modules/@aj-archipelago/merval/dist/parser/index.js
  var Parser = class {
    tokens;
    position = 0;
    errors = [];
    linkCount = 0;
    gitgraphBranches = /* @__PURE__ */ new Set();
    gitgraphCurrentBranch = null;
    gitgraphHasCommits = false;
    currentDiagramType = "unknown";
    implicitParticipants = /* @__PURE__ */ new Set();
    constructor(input) {
      const lexer = new Lexer(input);
      this.tokens = lexer.tokenize();
    }
    parse() {
      this.errors = [];
      this.position = 0;
      this.linkCount = 0;
      this.gitgraphBranches = /* @__PURE__ */ new Set();
      this.gitgraphCurrentBranch = null;
      this.gitgraphHasCommits = false;
      this.currentDiagramType = "unknown";
      this.implicitParticipants = /* @__PURE__ */ new Set();
      try {
        const ast = this.parseDiagram();
        this.validateSingleDiagramType();
        return {
          isValid: this.errors.length === 0,
          diagramType: this.getDiagramType(),
          errors: this.errors,
          ast
        };
      } catch (error) {
        this.addError(this.currentToken(), `Parse error: ${error instanceof Error ? error.message : String(error)}`);
        return {
          isValid: false,
          diagramType: "unknown",
          errors: this.errors
        };
      }
    }
    parseDiagram() {
      while (!this.isAtEnd() && this.currentToken().type === TokenType.DIRECTIVE) {
        this.advance();
      }
      const token = this.currentToken();
      const tokenValue = token.value;
      const isFlowchart = token.type === TokenType.FLOWCHART && tokenValue === "flowchart" || token.type === TokenType.GRAPH && tokenValue === "graph";
      const isSequence = token.type === TokenType.SEQUENCE_DIAGRAM && tokenValue === "sequenceDiagram";
      const isClass = token.type === TokenType.CLASS_DIAGRAM && tokenValue === "classDiagram";
      const isState = token.type === TokenType.STATE_DIAGRAM && tokenValue === "stateDiagram" || token.type === TokenType.STATE_DIAGRAM_V2 && tokenValue === "stateDiagram-v2";
      const isPie = token.type === TokenType.PIE && tokenValue === "pie";
      const isJourney = token.type === TokenType.JOURNEY && tokenValue === "journey";
      const isXYChart = token.type === TokenType.XYCHART_BETA && tokenValue === "xychart-beta";
      const isGitgraph = token.type === TokenType.GITGRAPH && (tokenValue === "gitGraph" || tokenValue === "gitgraph");
      const isMindmap = token.type === TokenType.MINDMAP && tokenValue === "mindmap";
      const isTimeline = token.type === TokenType.TIMELINE && tokenValue === "timeline";
      const isGantt = token.type === TokenType.GANTT && tokenValue === "gantt";
      const isER = token.type === TokenType.ER_DIAGRAM && tokenValue === "erDiagram";
      const isBlock = token.type === TokenType.BLOCK_BETA && tokenValue === "block-beta";
      if (isFlowchart) {
        this.currentDiagramType = "flowchart";
        return this.parseFlowchart();
      } else if (isSequence) {
        this.currentDiagramType = "sequence";
        return this.parseSequenceDiagram();
      } else if (isClass) {
        this.currentDiagramType = "class";
        return this.parseClassDiagram();
      } else if (isState) {
        this.currentDiagramType = "state";
        return this.parseStateDiagram();
      } else if (isPie) {
        return this.parsePieChart();
      } else if (isJourney) {
        return this.parseJourney();
      } else if (isXYChart) {
        return this.parseXYChart();
      } else if (isGitgraph) {
        return this.parseGitgraph();
      } else if (isMindmap) {
        return this.parseMindmap();
      } else if (isTimeline) {
        return this.parseTimeline();
      } else if (isGantt) {
        return this.parseGantt();
      } else if (isER) {
        return this.parseERDiagram();
      } else if (isBlock) {
        return this.parseBlockDiagram();
      } else if (token.type === TokenType.FLOWCHART || token.type === TokenType.GRAPH || token.type === TokenType.SEQUENCE_DIAGRAM || token.type === TokenType.CLASS_DIAGRAM || token.type === TokenType.STATE_DIAGRAM || token.type === TokenType.STATE_DIAGRAM_V2) {
        const correctCase = this.getCorrectCase(token.type);
        if (token.value !== correctCase) {
          this.addError(token, `Diagram type "${token.value}" has incorrect case. Mermaid CLI is case-sensitive.`, "CASE_SENSITIVE_DIAGRAM_TYPE", `Use correct case: "${correctCase}"`);
        }
        if (token.type === TokenType.FLOWCHART || token.type === TokenType.GRAPH) {
          this.currentDiagramType = "flowchart";
          return this.parseFlowchart();
        } else if (token.type === TokenType.SEQUENCE_DIAGRAM) {
          this.currentDiagramType = "sequence";
          return this.parseSequenceDiagram();
        } else if (token.type === TokenType.CLASS_DIAGRAM) {
          this.currentDiagramType = "class";
          return this.parseClassDiagram();
        } else if (token.type === TokenType.STATE_DIAGRAM || token.type === TokenType.STATE_DIAGRAM_V2) {
          this.currentDiagramType = "state";
          return this.parseStateDiagram();
        }
        return { type: "unknown", line: token.line, column: token.column };
      } else {
        this.addError(token, `Unsupported diagram type: ${token.value}`);
        return { type: "unknown", line: token.line, column: token.column };
      }
    }
    getCorrectCase(tokenType) {
      const cases = {
        [TokenType.FLOWCHART]: "flowchart",
        [TokenType.GRAPH]: "graph",
        [TokenType.SEQUENCE_DIAGRAM]: "sequenceDiagram",
        [TokenType.CLASS_DIAGRAM]: "classDiagram",
        [TokenType.STATE_DIAGRAM]: "stateDiagram",
        [TokenType.STATE_DIAGRAM_V2]: "stateDiagram-v2",
        [TokenType.PIE]: "pie",
        [TokenType.JOURNEY]: "journey",
        [TokenType.XYCHART_BETA]: "xychart-beta",
        [TokenType.GITGRAPH]: "gitGraph",
        [TokenType.MINDMAP]: "mindmap",
        [TokenType.TIMELINE]: "timeline",
        [TokenType.GANTT]: "gantt",
        [TokenType.ER_DIAGRAM]: "erDiagram",
        [TokenType.BLOCK_BETA]: "block-beta"
      };
      return cases[tokenType] || "unknown";
    }
    parseFlowchart() {
      const startToken = this.currentToken();
      this.advance();
      this.linkCount = 0;
      let direction;
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        direction = this.currentToken().value;
        const validDirections = ["TD", "LR", "BT", "RL"];
        if (!validDirections.includes(direction.toUpperCase())) {
          this.addError(this.currentToken(), `Invalid flowchart direction: ${direction}`, "INVALID_DIRECTION", `Direction must be one of: TD, LR, BT, RL`);
        }
        this.advance();
      }
      const nodes = [];
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        const diagramTypes = [
          TokenType.SEQUENCE_DIAGRAM,
          TokenType.CLASS_DIAGRAM,
          TokenType.STATE_DIAGRAM,
          TokenType.STATE_DIAGRAM_V2,
          TokenType.ER_DIAGRAM,
          TokenType.JOURNEY,
          TokenType.GANTT,
          TokenType.PIE,
          TokenType.GITGRAPH,
          TokenType.MINDMAP,
          TokenType.TIMELINE,
          TokenType.XYCHART_BETA
        ];
        if (diagramTypes.includes(token.type)) {
          break;
        }
        const node = this.parseFlowchartElement();
        if (node) {
          if (node.type === "processed") {
          } else {
            nodes.push(node);
          }
        } else {
          this.advance();
        }
      }
      this.validateFlowchartConnections(nodes);
      return {
        type: "flowchart",
        line: startToken.line,
        column: startToken.column,
        direction,
        nodes
      };
    }
    parseFlowchartElement() {
      const token = this.currentToken();
      if (token.type === TokenType.IDENTIFIER && token.value.toLowerCase() === "end") {
        this.addError(token, 'Unexpected "end" keyword - found end without matching subgraph', "UNMATCHED_END", "Remove the end keyword or add a corresponding subgraph");
        this.advance();
        return { type: "processed", line: token.line, column: token.column };
      }
      if (token.value === "classDef") {
        this.parseClassDef();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "class") {
        this.parseClassAssignment();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "linkStyle") {
        this.parseLinkStyle();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "style") {
        this.parseStyle();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "click") {
        this.parseClickStatement();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "note") {
        this.parseNoteStatement();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "direction") {
        this.parseDirectionStatement();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.value === "title") {
        this.addError(token, "Title directive is not supported in flowcharts", "UNSUPPORTED_TITLE_DIRECTIVE", "Remove the title directive - flowcharts do not support titles");
        this.skipTitleDirective();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.type === TokenType.IDENTIFIER && token.value === "<") {
        const nextToken = this.peekToken();
        if (nextToken && (nextToken.type === TokenType.ARROW || nextToken.type === TokenType.DOTTED_ARROW)) {
          return this.parseBidirectionalArrow();
        }
        return this.parseNode();
      } else if (token.type === TokenType.IDENTIFIER) {
        const nextToken = this.peekToken();
        if (nextToken && (nextToken.type === TokenType.BRACKET_OPEN || nextToken.type === TokenType.PAREN_OPEN || nextToken.type === TokenType.BRACE_OPEN)) {
          return this.parseNode();
        } else {
          return this.parseNode();
        }
      } else if (token.type === TokenType.ARROW || token.type === TokenType.DOTTED_ARROW || token.type === TokenType.THICK_ARROW) {
        return this.parseArrow();
      } else if (token.type === TokenType.SUBGRAPH) {
        return this.parseSubgraph();
      } else if (token.type === TokenType.COMMENT) {
        if (this.isInlineComment(token)) {
          this.addError(token, "Inline comments are not supported", "INLINE_COMMENT_NOT_SUPPORTED", "Move comment to its own line");
        }
        this.advance();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.type === TokenType.DIRECTIVE) {
        this.advance();
        return { type: "processed", line: token.line, column: token.column };
      } else if (token.type === TokenType.SEMICOLON) {
        this.advance();
        return null;
      } else if (token.type === TokenType.COLON) {
        this.advance();
        return null;
      } else if (token.type === TokenType.COMMA) {
        this.advance();
        return null;
      } else if (token.type === TokenType.EQUALS) {
        this.advance();
        return null;
      } else if (token.type === TokenType.PIPE) {
        this.advance();
        return null;
      } else if (token.type === TokenType.NUMBER) {
        this.advance();
        return null;
      } else if (token.type === TokenType.STRING) {
        this.advance();
        return null;
      } else if (token.type === TokenType.BRACKET_OPEN || token.type === TokenType.BRACKET_CLOSE || token.type === TokenType.PAREN_OPEN || token.type === TokenType.PAREN_CLOSE || token.type === TokenType.BRACE_OPEN || token.type === TokenType.BRACE_CLOSE) {
        this.advance();
        return null;
      }
      return null;
    }
    peekToken(offset = 1) {
      if (this.position + offset >= this.tokens.length) {
        return null;
      }
      return this.tokens[this.position + offset];
    }
    parseNode() {
      const idToken = this.currentToken();
      if (idToken.type === TokenType.EOF) {
        this.addError(idToken, "Expected node identifier", "MISSING_NODE", "Add a node identifier");
        return {
          type: "node",
          line: idToken.line,
          column: idToken.column,
          id: "",
          shape: "rect"
        };
      }
      const id = idToken.value;
      const emojiRegex = /[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]/u;
      if (emojiRegex.test(id)) {
        this.addError(idToken, `Node ID "${id}" contains emojis or unsupported unicode characters`, "INVALID_NODE_ID", "Use alphanumeric characters, underscores, and basic punctuation only");
      }
      this.advance();
      let label;
      let shape = "rect";
      if (this.currentToken().type === TokenType.BRACKET_OPEN) {
        this.advance();
        if (this.currentToken().type === TokenType.STRING) {
          label = this.currentToken().value.slice(1, -1);
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
          label = this.collectIdentifiersAsLabel(true);
        }
        if (this.currentToken().type === TokenType.BRACKET_CLOSE && (!label || label.trim() === "")) {
          this.addError(this.currentToken(), "Empty node labels are not allowed", "EMPTY_NODE_LABEL", "Add a label inside the brackets or remove the brackets");
        }
        if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
          this.advance();
        } else {
          this.addError(this.currentToken(), "Expected closing bracket ]");
          while (!this.isAtEnd() && this.currentToken().type !== TokenType.BRACKET_CLOSE && this.currentToken().type !== TokenType.ARROW && this.currentToken().type !== TokenType.DOTTED_ARROW && this.currentToken().type !== TokenType.EOF) {
            this.advance();
          }
          if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
            this.advance();
          }
        }
      } else if (this.currentToken().type === TokenType.PAREN_OPEN) {
        this.advance();
        shape = "round";
        if (this.currentToken().type === TokenType.STRING) {
          label = this.currentToken().value.slice(1, -1);
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER) {
          const labelParts = [];
          while (this.currentToken().type === TokenType.IDENTIFIER) {
            labelParts.push(this.currentToken().value);
            this.advance();
          }
          label = labelParts.join(" ");
        }
        if (this.currentToken().type === TokenType.PAREN_CLOSE) {
          this.advance();
        } else {
          this.addError(this.currentToken(), "Expected closing parenthesis )");
          while (!this.isAtEnd() && this.currentToken().type !== TokenType.PAREN_CLOSE && this.currentToken().type !== TokenType.ARROW && this.currentToken().type !== TokenType.DOTTED_ARROW && this.currentToken().type !== TokenType.EOF) {
            this.advance();
          }
          if (this.currentToken().type === TokenType.PAREN_CLOSE) {
            this.advance();
          }
        }
      } else if (this.currentToken().type === TokenType.DOUBLE_PAREN_OPEN) {
        this.advance();
        shape = "circle";
        if (this.currentToken().type === TokenType.STRING) {
          label = this.currentToken().value.slice(1, -1);
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER) {
          const labelParts = [];
          while (this.currentToken().type === TokenType.IDENTIFIER) {
            labelParts.push(this.currentToken().value);
            this.advance();
          }
          label = labelParts.join(" ");
        }
        if (this.currentToken().type === TokenType.DOUBLE_PAREN_CLOSE) {
          this.advance();
        } else {
          this.addError(this.currentToken(), "Expected closing double parenthesis ))");
          while (!this.isAtEnd() && this.currentToken().type !== TokenType.DOUBLE_PAREN_CLOSE && this.currentToken().type !== TokenType.ARROW && this.currentToken().type !== TokenType.DOTTED_ARROW && this.currentToken().type !== TokenType.EOF) {
            this.advance();
          }
          if (this.currentToken().type === TokenType.DOUBLE_PAREN_CLOSE) {
            this.advance();
          }
        }
      } else if (this.currentToken().type === TokenType.BRACE_OPEN) {
        this.advance();
        shape = "diamond";
        if (this.currentToken().type === TokenType.STRING) {
          label = this.currentToken().value.slice(1, -1);
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER) {
          const labelParts = [];
          while (this.currentToken().type === TokenType.IDENTIFIER) {
            labelParts.push(this.currentToken().value);
            this.advance();
          }
          label = labelParts.join(" ");
        }
        if (this.currentToken().type === TokenType.BRACE_CLOSE) {
          this.advance();
        } else {
          this.addError(this.currentToken(), "Expected closing brace }");
          while (!this.isAtEnd() && this.currentToken().type !== TokenType.BRACE_CLOSE && this.currentToken().type !== TokenType.ARROW && this.currentToken().type !== TokenType.DOTTED_ARROW && this.currentToken().type !== TokenType.EOF) {
            this.advance();
          }
          if (this.currentToken().type === TokenType.BRACE_CLOSE) {
            this.advance();
          }
        }
      }
      return {
        type: "node",
        line: idToken.line,
        column: idToken.column,
        id,
        label,
        shape
      };
    }
    parseBidirectionalArrow() {
      const arrowStartToken = this.currentToken();
      this.advance();
      const arrowToken = this.currentToken();
      this.advance();
      this.linkCount++;
      let label;
      if (this.currentToken().type === TokenType.PIPE) {
        this.advance();
        if (this.currentToken().type === TokenType.STRING) {
          label = this.currentToken().value.slice(1, -1);
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
          const labelParts = [];
          while (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
            labelParts.push(this.currentToken().value);
            this.advance();
          }
          label = labelParts.join(" ");
        }
        if (this.currentToken().type === TokenType.PIPE) {
          this.advance();
        } else {
          this.addError(this.currentToken(), "Expected closing pipe |");
        }
      }
      if (this.isAtEnd() || this.currentToken().type === TokenType.EOF) {
        this.addError(arrowToken, "Arrow must have a destination node", "INCOMPLETE_ARROW", "Add a node after the arrow");
        return {
          type: "arrow",
          line: arrowStartToken.line,
          column: arrowStartToken.column,
          label,
          to: void 0
        };
      }
      const toNode = this.parseNode();
      if (!this.isAtEnd() && this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value === "<") {
        this.advance();
      } else {
      }
      return {
        type: "arrow",
        line: arrowStartToken.line,
        column: arrowStartToken.column,
        label,
        to: toNode.id || toNode.type
      };
    }
    parseArrow() {
      const arrowToken = this.currentToken();
      this.advance();
      this.linkCount++;
      let label;
      if (this.currentToken().type === TokenType.PIPE) {
        this.advance();
        if (this.currentToken().type === TokenType.STRING) {
          label = this.currentToken().value.slice(1, -1);
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
          const labelParts = [];
          while (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
            labelParts.push(this.currentToken().value);
            this.advance();
          }
          label = labelParts.join(" ");
        }
        if (this.currentToken().type === TokenType.PIPE) {
          this.advance();
        } else {
          this.addError(this.currentToken(), "Expected closing pipe |");
        }
      }
      if (this.isAtEnd() || this.currentToken().type === TokenType.EOF) {
        this.addError(arrowToken, "Arrow must have a destination node", "INCOMPLETE_ARROW", "Add a node after the arrow");
        return {
          type: "arrow",
          line: arrowToken.line,
          column: arrowToken.column,
          label,
          to: void 0
        };
      }
      const toNode = this.parseNode();
      return {
        type: "arrow",
        line: arrowToken.line,
        column: arrowToken.column,
        label,
        to: toNode.id
      };
    }
    parseSequenceDiagram() {
      const startToken = this.currentToken();
      this.advance();
      const participants = [];
      const messages = [];
      const controlStack = [];
      this.implicitParticipants = /* @__PURE__ */ new Set();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        if (token.type === TokenType.PARTICIPANT) {
          participants.push(this.parseParticipant());
        } else if (token.type === TokenType.DIRECTIVE) {
          this.advance();
        } else if (token.value === "Note") {
          this.parseSequenceNote();
        } else if (token.value === "loop" || token.value === "alt" || token.value === "opt" || token.value === "par" || token.value === "critical" || token.value === "break") {
          controlStack.push({ type: token.value, line: token.line, column: token.column });
          this.advance();
          while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF && this.currentToken().line === token.line && this.currentToken().type !== TokenType.NEWLINE) {
            this.advance();
          }
        } else if (token.value === "end") {
          if (controlStack.length === 0) {
            this.addError(token, 'Unexpected "end" without matching control structure', "UNMATCHED_END", 'Remove this "end" or add a matching control structure');
          } else {
            controlStack.pop();
          }
          this.advance();
        } else if (token.value === "activate") {
          this.advance();
          const participantToken = this.currentToken();
          if (participantToken.type === TokenType.IDENTIFIER || participantToken.type === TokenType.STRING) {
            const participantName = participantToken.type === TokenType.STRING ? participantToken.value.slice(1, -1) : participantToken.value;
            const participantExists = participants.some((p) => p.name === participantName || p.alias === participantName) || this.implicitParticipants.has(participantName);
            this.advance();
          } else {
            this.addError(token, "activate must specify a participant", "MISSING_PARTICIPANT", "Add a participant name after activate");
          }
        } else if (token.value === "deactivate") {
          this.advance();
          if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.STRING) {
            this.advance();
          }
        } else if (token.value === "classDef" || token.value === "class" || token.value === "linkStyle" || token.value === "style" || token.value === "click") {
          this.addError(token, `${token.value} directive is not supported in sequence diagrams`, "UNSUPPORTED_STYLING_DIRECTIVE", "Styling directives are not supported in sequence diagrams");
          this.skipUntilSemicolon();
        } else if (token.type === TokenType.IDENTIFIER || token.type === TokenType.STRING) {
          if (token.value.includes("--") && !token.value.includes("-->") && !token.value.includes("-->>") && !token.value.includes("--x")) {
            const parts = token.value.split("--");
            if (parts.length === 2 && parts[0] && parts[1]) {
              this.addError(token, "Invalid sequence arrow syntax. Dotted arrows must end with > (use -->> or --x)", "INVALID_SEQUENCE_ARROW", "Use -->> for dotted arrow or --x for dotted cross arrow");
            }
          }
          const nextToken = this.peekToken();
          if (nextToken && (nextToken.type === TokenType.SEQUENCE_ARROW || nextToken.type === TokenType.ARROW)) {
            if (nextToken.type === TokenType.ARROW && nextToken.value === "-->") {
              this.addError(nextToken, "Flowchart arrow (-->) cannot be used in sequence diagrams. Use sequence arrows (->>, -->>, ->, --)", "INVALID_ARROW_TYPE", "Use sequence diagram arrows: ->>, -->>, ->, or --");
            }
            messages.push(this.parseMessageLine());
          } else if (nextToken && nextToken.type === TokenType.IDENTIFIER && nextToken.value === "-") {
            const afterDash = this.peekToken(2);
            if (afterDash && (afterDash.type === TokenType.IDENTIFIER || afterDash.type === TokenType.STRING)) {
              this.addError(token, "Malformed arrow syntax. Use proper sequence arrows: ->>, -->>, ->, or --", "MALFORMED_ARROW", "Use sequence diagram arrows: ->>, -->>, ->, or --");
              this.advance();
              this.advance();
              this.advance();
            } else {
              this.advance();
            }
          } else {
            this.advance();
          }
        } else {
          this.advance();
        }
      }
      this.validateSequenceDiagram(participants, messages);
      if (controlStack.length > 0) {
        const unclosed = controlStack[controlStack.length - 1];
        this.addError({ line: unclosed.line, column: unclosed.column, type: TokenType.IDENTIFIER, value: unclosed.type }, `Control structure "${unclosed.type}" is missing matching "end"`, "UNCLOSED_CONTROL_STRUCTURE", `Add "end" to close the "${unclosed.type}" block`);
      }
      return {
        type: "sequence",
        line: startToken.line,
        column: startToken.column,
        participants,
        messages
      };
    }
    parseParticipant() {
      const startToken = this.currentToken();
      this.advance();
      const nameToken = this.currentToken();
      if (nameToken.type === TokenType.EOF || this.isAtEnd() || nameToken.type !== TokenType.IDENTIFIER && nameToken.type !== TokenType.STRING) {
        this.addError(startToken, "Participant declaration must have a name", "MISSING_PARTICIPANT_NAME", "Add a participant name after the participant keyword");
        return {
          type: "participant",
          line: startToken.line,
          column: startToken.column,
          name: "",
          alias: void 0
        };
      }
      const name = nameToken.type === TokenType.STRING ? nameToken.value.slice(1, -1) : nameToken.value;
      this.advance();
      let alias;
      if (this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value === "as") {
        this.advance();
        if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.STRING) {
          alias = this.currentToken().type === TokenType.STRING ? this.currentToken().value.slice(1, -1) : this.currentToken().value;
          this.advance();
        }
      }
      return {
        type: "participant",
        line: startToken.line,
        column: startToken.column,
        name,
        alias
      };
    }
    parseMessageLine() {
      const fromToken = this.currentToken();
      let from = fromToken.type === TokenType.STRING ? fromToken.value.slice(1, -1) : fromToken.value;
      this.implicitParticipants.add(from);
      if (from.includes("--") && !from.includes("-->") && !from.includes("-->>") && !from.includes("--x")) {
        const parts = from.split("--");
        if (parts.length === 2 && parts[0] && parts[1]) {
          this.addError(fromToken, "Invalid sequence arrow syntax. Dotted arrows must end with > (use -->> or --x)", "INVALID_SEQUENCE_ARROW", "Use -->> for dotted arrow or --x for dotted cross arrow");
          from = parts[0];
          this.advance();
        } else {
          this.advance();
        }
      } else {
        this.advance();
      }
      let arrowType = "solid";
      const arrowToken = this.currentToken();
      if (arrowToken.type === TokenType.SEQUENCE_ARROW || arrowToken.type === TokenType.ARROW) {
        const arrowValue = arrowToken.value;
        if (arrowValue === "->>") {
          arrowType = "solid";
        } else if (arrowValue === "-->>") {
          arrowType = "dotted";
        } else if (arrowValue === "->") {
          arrowType = "solid";
        } else if (arrowValue === "-->") {
          arrowType = "solid";
        }
        this.advance();
      } else if (fromToken.value.includes("--") && !fromToken.value.includes("-->")) {
      }
      const toToken = this.currentToken();
      if (toToken.type === TokenType.EOF || this.isAtEnd()) {
        this.addError(arrowToken, "Incomplete message: arrow must have a destination participant", "INCOMPLETE_MESSAGE", "Add a destination participant after the arrow");
        return {
          type: "message",
          line: fromToken.line,
          column: fromToken.column,
          from,
          to: "",
          message: "",
          arrowType
        };
      }
      const to = toToken.type === TokenType.STRING ? toToken.value.slice(1, -1) : toToken.value;
      this.implicitParticipants.add(to);
      this.advance();
      if (this.currentToken().type === TokenType.COLON) {
        this.advance();
      }
      let message = "";
      const startLine = this.currentToken().line;
      const messageParts = [];
      while (!this.isAtEnd() && this.currentToken().line === startLine && this.currentToken().type !== TokenType.EOF) {
        if (this.currentToken().type === TokenType.STRING) {
          messageParts.push(this.currentToken().value.slice(1, -1));
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
          messageParts.push(this.currentToken().value);
          this.advance();
        } else if (this.currentToken().type === TokenType.WHITESPACE || this.currentToken().type === TokenType.NEWLINE) {
          this.advance();
        } else if (this.currentToken().type === TokenType.COMMA || this.currentToken().type === TokenType.COLON) {
          messageParts.push(this.currentToken().value);
          this.advance();
        } else {
          messageParts.push(this.currentToken().value);
          this.advance();
        }
      }
      message = messageParts.join(" ").trim();
      return {
        type: "message",
        line: fromToken.line,
        column: fromToken.column,
        from,
        to,
        message,
        arrowType
      };
    }
    parseMessage() {
      const fromToken = this.currentToken();
      const from = fromToken.value;
      this.advance();
      let arrowType = "solid";
      if (this.currentToken().type === TokenType.SEQUENCE_ARROW || this.currentToken().type === TokenType.ARROW) {
        const arrowValue = this.currentToken().value;
        if (arrowValue === "->>") {
          arrowType = "solid";
        } else if (arrowValue === "-->>") {
          arrowType = "dotted";
        } else if (arrowValue === "->") {
          arrowType = "solid";
        } else if (arrowValue === "-->") {
          arrowType = "solid";
        }
        this.advance();
      }
      const toToken = this.currentToken();
      const to = toToken.value;
      this.advance();
      if (this.currentToken().type === TokenType.COLON) {
        this.advance();
      }
      let message = "";
      const startLine = this.currentToken().line;
      const messageParts = [];
      while (!this.isAtEnd() && this.currentToken().line === startLine && this.currentToken().type !== TokenType.EOF) {
        if (this.currentToken().type === TokenType.STRING) {
          messageParts.push(this.currentToken().value.slice(1, -1));
          this.advance();
        } else if (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.NUMBER) {
          messageParts.push(this.currentToken().value);
          this.advance();
        } else if (this.currentToken().type === TokenType.WHITESPACE || this.currentToken().type === TokenType.NEWLINE) {
          this.advance();
        } else if (this.currentToken().type === TokenType.COMMA || this.currentToken().type === TokenType.COLON) {
          messageParts.push(this.currentToken().value);
          this.advance();
        } else {
          messageParts.push(this.currentToken().value);
          this.advance();
        }
      }
      message = messageParts.join(" ").trim();
      return {
        type: "message",
        line: fromToken.line,
        column: fromToken.column,
        from,
        to,
        message,
        arrowType
      };
    }
    /**
     * Validates if an identifier contains special characters that require quoting
     * @param identifier - The identifier to validate
     * @param context - The parsing context (e.g., 'xychart-axis', 'flowchart-label')
     * @returns true if the identifier is valid, false if it needs quoting
     */
    isValidIdentifier(identifier, context) {
      const specialChars = /['"&<>(){}[\]|\\\/\s]/;
      switch (context) {
        case "xychart-axis":
          return !specialChars.test(identifier);
        case "flowchart-label":
          return true;
        // Flowcharts handle special chars better
        case "sequence-participant":
          return !specialChars.test(identifier);
        default:
          return !specialChars.test(identifier);
      }
    }
    parseXYChart() {
      const startToken = this.currentToken();
      this.advance();
      let title;
      const xAxis = [];
      let yAxis;
      const data = [];
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        if (token.type === TokenType.DIRECTIVE) {
          this.advance();
        } else if (token.value === "title") {
          this.advance();
          if (this.currentToken().type === TokenType.STRING) {
            title = this.currentToken().value.slice(1, -1);
            this.advance();
          }
        } else if (token.value === "x-axis") {
          this.advance();
          if (this.currentToken().type === TokenType.BRACKET_OPEN) {
            const bracketToken = this.currentToken();
            this.advance();
            while (this.currentToken().type === TokenType.WHITESPACE) {
              this.advance();
            }
            if (this.currentToken().line > bracketToken.line) {
              this.addError(this.currentToken(), "x-axis array cannot span multiple lines. The opening bracket must be followed by values on the same line.", "INVALID_XYCHART_SYNTAX", 'Use format: x-axis ["Label1", "Label2", "Label3"] on a single line.');
            }
            if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
              this.addError(bracketToken, "x-axis array cannot be empty", "INVALID_XYCHART_SYNTAX", "x-axis must contain at least one label.");
              this.advance();
            } else {
              let lastCommaToken = null;
              while (this.currentToken().type !== TokenType.BRACKET_CLOSE) {
                if (this.currentToken().type === TokenType.STRING) {
                  xAxis.push(this.currentToken().value.slice(1, -1));
                  lastCommaToken = null;
                } else if (this.currentToken().type === TokenType.IDENTIFIER) {
                  const identifier = this.currentToken().value;
                  if (!this.isValidIdentifier(identifier, "xychart-axis")) {
                    this.addError(this.currentToken(), `Identifier '${identifier}' contains special characters and should be quoted`, "INVALID_IDENTIFIER", `Use "${identifier}" instead of ${identifier}`);
                  }
                  xAxis.push(identifier);
                  lastCommaToken = null;
                }
                this.advance();
                if (this.currentToken().type === TokenType.COMMA) {
                  lastCommaToken = this.currentToken();
                  this.advance();
                  while (this.currentToken().type === TokenType.WHITESPACE) {
                    this.advance();
                  }
                  if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
                    this.addError(lastCommaToken, "Trailing commas are not allowed in x-axis arrays", "INVALID_XYCHART_SYNTAX", "Remove the trailing comma before the closing bracket.");
                    break;
                  }
                }
              }
              this.advance();
            }
          } else {
            this.addError(this.currentToken(), "x-axis must be followed by a bracketed list of labels", "INVALID_X_AXIS_SYNTAX", 'Use x-axis ["Label1", "Label2", "Label3"] format');
          }
        } else if (token.value === "y-axis") {
          this.advance();
          if (this.currentToken().type === TokenType.STRING) {
            const label = this.currentToken().value.slice(1, -1);
            this.advance();
            if (this.currentToken().type === TokenType.BRACKET_OPEN) {
              this.addError(this.currentToken(), 'y-axis cannot have a list after the label. y-axis must use format: y-axis "label" minValue --> maxValue', "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue. Lists are only supported for x-axis.');
              this.advance();
              while (!this.isAtEnd() && this.currentToken().type !== TokenType.BRACKET_CLOSE && this.currentToken().type !== TokenType.EOF) {
                this.advance();
              }
              if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
                this.advance();
              }
            } else if (this.currentToken().value === "min") {
              this.addError(this.currentToken(), 'y-axis syntax does not support "min" keyword', "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue');
              this.advance();
            } else if (this.currentToken().type === TokenType.NUMBER) {
              const min = parseInt(this.currentToken().value);
              this.advance();
              if (this.currentToken().value === "-->") {
                this.advance();
                if (this.currentToken().type === TokenType.NUMBER) {
                  const max = parseInt(this.currentToken().value);
                  yAxis = { label, min, max };
                  this.advance();
                } else {
                  this.addError(this.currentToken(), "y-axis arrow must be followed by a maximum value", "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue');
                }
              } else if (this.currentToken().type === TokenType.NUMBER) {
                this.addError(this.currentToken(), "y-axis requires an arrow (-->) between min and max values", "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue');
                this.advance();
              } else {
                this.addError(this.currentToken(), "y-axis must include arrow (-->) and maximum value after the minimum value", "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue');
              }
            }
          } else if (this.currentToken().type === TokenType.BRACKET_OPEN) {
            this.addError(this.currentToken(), "y-axis must be followed by a string label and numeric range, not a list", "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue. Lists are only supported for x-axis.');
            this.advance();
            while (!this.isAtEnd() && this.currentToken().type !== TokenType.BRACKET_CLOSE && this.currentToken().type !== TokenType.EOF) {
              this.advance();
            }
            if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
              this.advance();
            }
          } else {
            this.addError(this.currentToken(), "y-axis must be followed by a string label", "INVALID_Y_AXIS_SYNTAX", 'Use format: y-axis "label" minValue --> maxValue');
          }
        } else if (token.value === "bar" || token.value === "line") {
          const type = token.value;
          this.advance();
          if (this.currentToken().type === TokenType.BRACKET_OPEN) {
            const bracketToken = this.currentToken();
            this.advance();
            while (this.currentToken().type === TokenType.WHITESPACE) {
              this.advance();
            }
            if (this.currentToken().line > bracketToken.line) {
              this.addError(this.currentToken(), `${type} array cannot span multiple lines. The opening bracket must be followed by values on the same line.`, "INVALID_XYCHART_SYNTAX", `Use format: ${type} [value1, value2, value3] on a single line, or ${type} [value1, value2, value3] with values on the same line as the bracket.`);
            }
            if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
              this.addError(bracketToken, `${type} array cannot be empty`, "INVALID_XYCHART_SYNTAX", `${type} must contain at least one value.`);
              this.advance();
            } else {
              const values = [];
              let lastCommaToken = null;
              while (this.currentToken().type !== TokenType.BRACKET_CLOSE) {
                if (this.currentToken().type === TokenType.NUMBER) {
                  values.push(parseInt(this.currentToken().value));
                  lastCommaToken = null;
                }
                this.advance();
                if (this.currentToken().type === TokenType.COMMA) {
                  lastCommaToken = this.currentToken();
                  this.advance();
                  while (this.currentToken().type === TokenType.WHITESPACE) {
                    this.advance();
                  }
                  if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
                    this.addError(lastCommaToken, `Trailing commas are not allowed in ${type} arrays`, "INVALID_XYCHART_SYNTAX", `Remove the trailing comma before the closing bracket.`);
                    break;
                  }
                }
              }
              data.push({ type, values });
              this.advance();
            }
          }
        } else if (token.value === "area" || token.value === "scatter") {
          this.addError(token, `Chart type '${token.value}' is not supported by Mermaid CLI`, "UNSUPPORTED_CHART_TYPE", "Use bar or line chart types instead");
          this.advance();
        } else if (token.value === "series") {
          this.addError(token, `'series' syntax is not supported by Mermaid CLI`, "UNSUPPORTED_SERIES_SYNTAX", 'Use bar or line directly instead of series "name" type chart');
          this.advance();
        } else if (token.value === "x-axis-label" || token.value === "y-axis-label") {
          this.addError(token, `'${token.value}' is not supported by Mermaid CLI`, "UNSUPPORTED_XYCHART_SYNTAX", "xychart-beta does not support axis labels. Use x-axis and y-axis with proper format instead.");
          this.advance();
          if (this.currentToken().type === TokenType.STRING) {
            this.advance();
          }
        } else if (token.value === "orientation") {
          this.addError(token, `'orientation' is not supported by Mermaid CLI`, "UNSUPPORTED_XYCHART_SYNTAX", "xychart-beta does not support orientation. Use y-axis with a list for horizontal charts.");
          this.advance();
          if (this.currentToken().type === TokenType.IDENTIFIER) {
            this.advance();
          }
        } else if (token.type === TokenType.IDENTIFIER && token.value) {
          this.addError(token, `Unknown keyword '${token.value}' in xychart-beta. This syntax is not supported by Mermaid CLI.`, "UNSUPPORTED_XYCHART_SYNTAX", "xychart-beta only supports: title, x-axis, y-axis, bar, and line.");
          this.advance();
        } else {
          this.advance();
        }
      }
      this.validateXYChart(title || "", xAxis, yAxis || { label: "", min: 0, max: 100 }, data);
      return {
        type: "xychart",
        line: startToken.line,
        column: startToken.column,
        title,
        xAxis,
        yAxis: yAxis || { label: "", min: 0, max: 100 },
        data
      };
    }
    parseSubgraph() {
      const startToken = this.currentToken();
      this.advance();
      const id = this.currentToken().value;
      this.advance();
      if (this.currentToken().type === TokenType.BRACKET_OPEN) {
        this.advance();
        if (this.currentToken().type === TokenType.STRING) {
          this.advance();
        }
        if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
          this.advance();
        }
      }
      const children = [];
      while (!this.isAtEnd() && !(this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value.toLowerCase() === "end")) {
        const child = this.parseFlowchartElement();
        if (child) {
          children.push(child);
        }
      }
      if (this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value.toLowerCase() === "end") {
        this.advance();
      } else {
        this.addError(this.currentToken(), 'Expected "end" to close subgraph', "MISSING_SUBGRAPH_END", 'Add "end" keyword to close the subgraph');
      }
      this.validateFlowchartConnections(children);
      return {
        type: "subgraph",
        line: startToken.line,
        column: startToken.column,
        id,
        children
      };
    }
    getDiagramType() {
      if (this.tokens.length === 0)
        return "unknown";
      let firstDiagramToken = null;
      for (let i = 0; i < this.tokens.length; i++) {
        if (this.tokens[i].type !== TokenType.DIRECTIVE) {
          firstDiagramToken = this.tokens[i];
          break;
        }
      }
      if (!firstDiagramToken)
        return "unknown";
      switch (firstDiagramToken.type) {
        case TokenType.GRAPH:
        case TokenType.FLOWCHART:
          return "flowchart";
        case TokenType.SEQUENCE_DIAGRAM:
          return "sequence";
        case TokenType.CLASS_DIAGRAM:
          return "class";
        case TokenType.STATE_DIAGRAM:
        case TokenType.STATE_DIAGRAM_V2:
          return "state";
        case TokenType.ER_DIAGRAM:
          return "er";
        case TokenType.JOURNEY:
          return "journey";
        case TokenType.GANTT:
          return "gantt";
        case TokenType.PIE:
          return "pie";
        case TokenType.GITGRAPH:
          return "gitgraph";
        case TokenType.MINDMAP:
          return "mindmap";
        case TokenType.TIMELINE:
          return "timeline";
        case TokenType.XYCHART_BETA:
          return "xychart";
        case TokenType.BLOCK_BETA:
          return "block";
        default:
          return "unknown";
      }
    }
    currentToken() {
      if (this.position >= this.tokens.length) {
        return this.tokens[this.tokens.length - 1];
      }
      return this.tokens[this.position];
    }
    advance() {
      if (this.position < this.tokens.length) {
        this.position++;
      }
    }
    isAtEnd() {
      return this.position >= this.tokens.length || this.currentToken().type === TokenType.EOF;
    }
    validateFlowchartConnections(nodes) {
      for (let i = 0; i < nodes.length - 1; i++) {
        const currentNode = nodes[i];
        const nextNode = nodes[i + 1];
        if (currentNode.type === "node" && nextNode.type === "node" && currentNode.line === nextNode.line) {
          this.addError({ type: TokenType.IDENTIFIER, value: nextNode.id || "", line: nextNode.line, column: nextNode.column, position: 0 }, `Adjacent nodes '${currentNode.id}' and '${nextNode.id}' on same line without arrow connection`, "MISSING_ARROW", "Add an arrow (-->) between the nodes or place them on separate lines");
        }
      }
    }
    validateSequenceDiagram(participants, messages) {
    }
    validateXYChart(title, xAxis, yAxis, data) {
      if (data.length === 0) {
        this.addError({ type: TokenType.IDENTIFIER, value: "data", line: 1, column: 1, position: 0 }, "No data provided for chart", "MISSING_DATA", "Add bar, line, or other data series to the chart");
      }
    }
    parseClassDiagram() {
      const startToken = this.currentToken();
      this.advance();
      let hasContent = false;
      let braceDepth = 0;
      let lastBraceOpenToken = null;
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        if (token.type === TokenType.BRACE_OPEN) {
          braceDepth++;
          lastBraceOpenToken = token;
        } else if (token.type === TokenType.BRACE_CLOSE) {
          braceDepth--;
        }
        if (token.type === TokenType.DIRECTIVE) {
          this.advance();
        } else if (token.value === "classDef") {
          hasContent = true;
          this.parseClassDef();
        } else if (token.value === "class") {
          hasContent = true;
          this.advance();
          if (this.currentToken().type === TokenType.IDENTIFIER) {
            this.advance();
          }
          if (this.currentToken().type === TokenType.IDENTIFIER) {
            this.advance();
          }
        } else if (token.value === "linkStyle") {
          hasContent = true;
          this.parseLinkStyle();
        } else if (token.value === "style" || token.value === "click" || token.value === "note") {
          this.addError(token, `${token.value} directive is not supported in class diagrams`, "UNSUPPORTED_STYLING_DIRECTIVE", "Only classDef, class, and linkStyle directives are supported in class diagrams");
          this.skipUntilSemicolon();
        } else if (token.type === TokenType.DOUBLE_PAREN_OPEN || token.type === TokenType.DOUBLE_PAREN_CLOSE) {
          this.addError(token, "Double-parentheses syntax ((text)) is not supported in class diagrams", "UNSUPPORTED_NODE_SHAPE", "Use standard class syntax instead");
          this.advance();
        } else {
          if (token.type !== TokenType.NEWLINE && token.type !== TokenType.WHITESPACE) {
            hasContent = true;
          }
          this.advance();
        }
      }
      if (!hasContent) {
        this.addError(startToken, "Class diagram must contain at least one class definition", "EMPTY_CLASS_DIAGRAM", "Add at least one class definition to the diagram");
      }
      if (braceDepth > 0 && lastBraceOpenToken) {
        this.addError(lastBraceOpenToken, "Unclosed class definition - missing closing brace", "UNCLOSED_CLASS", "Add a closing brace } to complete the class definition");
      }
      return {
        type: "class",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseStateDiagram() {
      const startToken = this.currentToken();
      this.advance();
      let braceDepth = 0;
      let lastBraceOpenToken = null;
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        if (token.type === TokenType.BRACE_OPEN) {
          braceDepth++;
          lastBraceOpenToken = token;
        } else if (token.type === TokenType.BRACE_CLOSE) {
          braceDepth--;
        }
        if (token.type === TokenType.ARROW || token.type === TokenType.DOTTED_ARROW || token.type === TokenType.THICK_ARROW) {
          const arrowToken = token;
          this.advance();
          const nextToken = this.currentToken();
          const peekToken = this.peekToken(1);
          if (nextToken.type === TokenType.EOF || nextToken.type === TokenType.NEWLINE && (!peekToken || peekToken.type === TokenType.EOF) || nextToken.type !== TokenType.IDENTIFIER && nextToken.type !== TokenType.BRACKET_OPEN && nextToken.value !== "[*]" && nextToken.value !== "[*") {
            this.addError(arrowToken, "Incomplete state transition - missing target state", "INCOMPLETE_TRANSITION", "Add a target state after the arrow (e.g., State1 --> State2)");
            continue;
          }
          continue;
        }
        if (token.type === TokenType.DIRECTIVE) {
          this.advance();
        } else if (token.value === "classDef") {
          this.parseClassDef();
        } else if (token.value === "class") {
          this.parseClassAssignment();
        } else if (token.value === "Note") {
          this.parseStateNote();
        } else if (token.value === "linkStyle") {
          this.parseLinkStyle();
        } else if (token.value === "style" || token.value === "click") {
          this.addError(token, `${token.value} directive is not supported in state diagrams`, "UNSUPPORTED_STYLING_DIRECTIVE", "Only classDef, class, Note, and linkStyle directives are supported in state diagrams");
          this.skipUntilSemicolon();
        } else {
          this.advance();
        }
      }
      if (braceDepth > 0 && lastBraceOpenToken) {
        this.addError(lastBraceOpenToken, "Unclosed state definition - missing closing brace", "UNCLOSED_STATE", "Add a closing brace } to complete the state definition");
      }
      return {
        type: "state",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseStateNote() {
      const noteToken = this.currentToken();
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        const position = this.currentToken().value.toLowerCase();
        if (position === "right" || position === "left" || position === "over") {
          this.advance();
          if (position === "right" || position === "left") {
            if (this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value.toLowerCase() === "of") {
              this.advance();
            }
          }
        }
      }
      while (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.STRING) {
        this.advance();
        if (this.currentToken().type === TokenType.COMMA) {
          this.advance();
        } else {
          break;
        }
      }
      if (this.currentToken().type === TokenType.COLON) {
        this.advance();
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF && this.currentToken().line === noteToken.line) {
        this.advance();
      }
    }
    skipUntilSemicolon() {
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parsePieChart() {
      const startToken = this.currentToken();
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      return {
        type: "pie",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseJourney() {
      const startToken = this.currentToken();
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      return {
        type: "journey",
        line: startToken.line,
        column: startToken.column
      };
    }
    collectIdentifiersAsLabel(includeNumbers = false) {
      const parts = [];
      while ((this.currentToken().type === TokenType.IDENTIFIER || includeNumbers && this.currentToken().type === TokenType.NUMBER) && !this.isAtEnd()) {
        parts.push(this.currentToken().value);
        this.advance();
      }
      return parts.join(" ");
    }
    collectIdentifiersOnSameLine() {
      const parts = [];
      const startLine = this.currentToken().line;
      while (this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().line === startLine && !this.isAtEnd()) {
        parts.push(this.currentToken().value);
        this.advance();
      }
      return parts.join(" ");
    }
    isInlineComment(commentToken) {
      const currentLine = commentToken.line;
      let commentIndex = -1;
      for (let i = 0; i < this.tokens.length; i++) {
        if (this.tokens[i] === commentToken) {
          commentIndex = i;
          break;
        }
      }
      if (commentIndex === -1)
        return false;
      for (let i = commentIndex - 1; i >= 0; i--) {
        const token = this.tokens[i];
        if (token.line < currentLine) {
          break;
        }
        if (token.line === currentLine && token.type !== TokenType.WHITESPACE && token.type !== TokenType.NEWLINE) {
          return true;
        }
      }
      return false;
    }
    parseClassDef() {
      const classDefToken = this.currentToken();
      this.advance();
      let hasEqualsSyntax = false;
      let currentPos = this.position;
      while (currentPos < this.tokens.length && this.tokens[currentPos].type !== TokenType.SEMICOLON && this.tokens[currentPos].type !== TokenType.EOF) {
        if (this.tokens[currentPos].value === "=") {
          hasEqualsSyntax = true;
          break;
        }
        currentPos++;
      }
      if (hasEqualsSyntax) {
        this.addError(classDefToken, "classDef with equals syntax is not supported in flowcharts", "UNSUPPORTED_CLASSDEF_EQUALS_SYNTAX", "Use colon syntax instead (e.g., fill:#f9f instead of fill=lightblue)");
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseClassAssignment() {
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        this.advance();
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseLinkStyle() {
      const linkStyleToken = this.currentToken();
      this.advance();
      let linkIndex = null;
      let isNegative = false;
      if (this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value === "-") {
        isNegative = true;
        this.advance();
      }
      if (this.currentToken().type === TokenType.NUMBER) {
        linkIndex = parseInt(this.currentToken().value);
        if (isNegative) {
          linkIndex = -linkIndex;
        }
        this.advance();
        if (linkIndex < 0) {
          this.addError(linkStyleToken, `linkStyle index ${linkIndex} is invalid (negative indices are not allowed)`, "INVALID_LINKSTYLE_INDEX", "Use a non-negative link index");
        } else if (linkIndex >= this.linkCount) {
          if (this.currentDiagramType === "flowchart") {
            this.addError(linkStyleToken, `linkStyle index ${linkIndex} is out of bounds (only ${this.linkCount} link(s) defined)`, "INVALID_LINKSTYLE_INDEX", `Use a link index between 0 and ${Math.max(0, this.linkCount - 1)}`);
          }
        }
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseStyle() {
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseClickStatement() {
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseSequenceNote() {
      const noteToken = this.currentToken();
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        const position = this.currentToken().value.toLowerCase();
        if (position === "right" || position === "left" || position === "over") {
          this.advance();
          if (position === "right" || position === "left") {
            if (this.currentToken().type === TokenType.IDENTIFIER && this.currentToken().value.toLowerCase() === "of") {
              this.advance();
            } else {
              this.addError(this.currentToken(), `Note ${position} requires "of" keyword`, "INVALID_NOTE_SYNTAX", `Use "Note ${position} of <participant>:" instead`);
            }
          }
        } else {
          this.addError(this.currentToken(), 'Invalid Note syntax. Must use "right of", "left of", or "over"', "INVALID_NOTE_SYNTAX", 'Use "Note right of <participant>:", "Note left of <participant>:", or "Note over <participant>:"');
        }
      } else {
        this.addError(this.currentToken(), 'Note must specify position: "right of", "left of", or "over"', "INVALID_NOTE_SYNTAX", 'Use "Note right of <participant>:", "Note left of <participant>:", or "Note over <participant>:"');
      }
      while (this.currentToken().type === TokenType.IDENTIFIER || this.currentToken().type === TokenType.STRING) {
        this.advance();
        if (this.currentToken().type === TokenType.COMMA) {
          this.advance();
        } else {
          break;
        }
      }
      if (this.currentToken().type === TokenType.COLON) {
        this.advance();
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF && this.currentToken().line === noteToken.line) {
        this.advance();
      }
    }
    parseNoteStatement() {
      this.advance();
      const nextToken = this.peekToken();
      if (nextToken && (nextToken.value === "for" || nextToken.type === TokenType.IDENTIFIER)) {
        this.addError(this.currentToken(), "Standalone note statements are not supported in flowcharts", "INVALID_NOTE_SYNTAX", "Use note arrows instead: A -.->|note text| B");
        return;
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseDirectionStatement() {
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        this.advance();
      }
    }
    skipTitleDirective() {
      this.advance();
      if (this.currentToken().type === TokenType.STRING) {
        this.advance();
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.SEMICOLON && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      if (this.currentToken().type === TokenType.SEMICOLON) {
        this.advance();
      }
    }
    parseGitgraph() {
      const startToken = this.currentToken();
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        const diagramTypes = [
          TokenType.SEQUENCE_DIAGRAM,
          TokenType.CLASS_DIAGRAM,
          TokenType.STATE_DIAGRAM,
          TokenType.STATE_DIAGRAM_V2,
          TokenType.ER_DIAGRAM,
          TokenType.JOURNEY,
          TokenType.GANTT,
          TokenType.PIE,
          TokenType.GITGRAPH,
          TokenType.MINDMAP,
          TokenType.TIMELINE,
          TokenType.XYCHART_BETA
        ];
        if (diagramTypes.includes(token.type)) {
          break;
        }
        if (token.type === TokenType.COMMENT) {
          this.advance();
          continue;
        }
        if (token.type === TokenType.DIRECTIVE) {
          this.advance();
          continue;
        }
        if (token.type === TokenType.WHITESPACE || token.type === TokenType.NEWLINE) {
          this.advance();
          continue;
        }
        if (token.type === TokenType.IDENTIFIER) {
          const command = token.value.toLowerCase();
          if (command === "commit") {
            this.parseGitgraphCommit();
          } else if (command === "branch") {
            this.parseGitgraphBranch();
          } else if (command === "checkout") {
            this.parseGitgraphCheckout();
          } else if (command === "merge") {
            this.parseGitgraphMerge();
          } else {
            this.advance();
          }
        } else {
          this.advance();
        }
      }
      return {
        type: "gitgraph",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseGitgraphCommit() {
      const token = this.currentToken();
      this.advance();
      this.gitgraphHasCommits = true;
      if (this.gitgraphBranches.size === 0) {
        this.gitgraphBranches.add("main");
        this.gitgraphCurrentBranch = "main";
      }
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const current = this.currentToken();
        if (current.type === TokenType.IDENTIFIER) {
          const nextCommand = current.value.toLowerCase();
          if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
            break;
          }
        }
        if (current.type === TokenType.IDENTIFIER) {
          const paramName = current.value.toLowerCase();
          this.advance();
          if (this.currentToken().type === TokenType.COLON) {
            this.advance();
            while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF && this.currentToken().type !== TokenType.IDENTIFIER && this.currentToken().type !== TokenType.COLON) {
              this.advance();
            }
          }
        } else {
          this.advance();
        }
      }
    }
    parseGitgraphBranch() {
      const token = this.currentToken();
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        let branchName = this.currentToken().value;
        this.advance();
        while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
          const current = this.currentToken();
          if (current.type === TokenType.IDENTIFIER) {
            const nextCommand = current.value.toLowerCase();
            if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
              break;
            }
            branchName += " " + current.value;
            this.advance();
          } else if (current.type === TokenType.WHITESPACE) {
            branchName += " ";
            this.advance();
          } else {
            break;
          }
        }
        const branchExists = this.gitgraphBranches.has(branchName) || branchName === "main" && this.gitgraphHasCommits;
        if (branchExists) {
          this.addError(token, `Trying to create an existing branch. (Help: Either use a new name if you want create a new branch or try using "checkout ${branchName}")`, "DUPLICATE_BRANCH", `Branch "${branchName}" already exists. Use "checkout ${branchName}" to switch to it instead.`);
        } else {
          this.gitgraphBranches.add(branchName);
          this.gitgraphCurrentBranch = branchName;
        }
        while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
          const current = this.currentToken();
          if (current.type === TokenType.IDENTIFIER) {
            const nextCommand = current.value.toLowerCase();
            if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
              break;
            }
          }
          this.advance();
        }
      } else {
      }
    }
    parseGitgraphCheckout() {
      const token = this.currentToken();
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        let branchName = this.currentToken().value;
        this.advance();
        while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
          const current = this.currentToken();
          if (current.type === TokenType.IDENTIFIER) {
            const nextCommand = current.value.toLowerCase();
            if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
              break;
            }
            branchName += " " + current.value;
            this.advance();
          } else if (current.type === TokenType.WHITESPACE) {
            branchName += " ";
            this.advance();
          } else {
            break;
          }
        }
        const branchExists = this.gitgraphBranches.has(branchName) || branchName === "main" && this.gitgraphHasCommits;
        if (!branchExists && branchName !== "main") {
          this.addError(token, `Trying to checkout branch which is not yet created. (Help try using "branch ${branchName}")`, "CHECKOUT_NONEXISTENT_BRANCH", `Branch "${branchName}" must be created with "branch" command before it can be checked out`);
        } else if (branchName === "main" && !this.gitgraphBranches.has("main")) {
          this.gitgraphBranches.add("main");
        }
        this.gitgraphCurrentBranch = branchName;
        while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
          const current = this.currentToken();
          if (current.type === TokenType.IDENTIFIER) {
            const nextCommand = current.value.toLowerCase();
            if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
              break;
            }
          }
          this.advance();
        }
      } else {
      }
    }
    parseGitgraphMerge() {
      const token = this.currentToken();
      this.advance();
      if (this.currentToken().type === TokenType.IDENTIFIER) {
        let branchName = this.currentToken().value;
        this.advance();
        while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
          const current = this.currentToken();
          if (current.type === TokenType.COLON) {
            break;
          } else if (current.type === TokenType.IDENTIFIER) {
            const nextCommand = current.value.toLowerCase();
            if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
              break;
            }
            const peek = this.peekToken();
            if (peek && peek.type === TokenType.COLON) {
              break;
            }
            branchName += " " + current.value;
            this.advance();
          } else if (current.type === TokenType.WHITESPACE) {
            branchName += " ";
            this.advance();
          } else {
            break;
          }
        }
        const branchExists = this.gitgraphBranches.has(branchName) || branchName === "main" && this.gitgraphHasCommits;
        if (!branchExists) {
          this.addError(token, `Cannot merge branch "${branchName}" - branch does not exist`, "MERGE_NONEXISTENT_BRANCH", `Branch "${branchName}" must be created before it can be merged`);
        }
        while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
          const current = this.currentToken();
          if (current.type === TokenType.IDENTIFIER) {
            const nextCommand = current.value.toLowerCase();
            if (nextCommand === "branch" || nextCommand === "checkout" || nextCommand === "merge" || nextCommand === "commit") {
              break;
            }
            const paramName = current.value.toLowerCase();
            this.advance();
            if (this.currentToken().type === TokenType.COLON) {
              this.advance();
              while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF && this.currentToken().type !== TokenType.IDENTIFIER && this.currentToken().type !== TokenType.COLON) {
                this.advance();
              }
            }
          } else {
            this.advance();
          }
        }
      } else {
      }
    }
    parseMindmap() {
      const startToken = this.currentToken();
      this.advance();
      let hasContent = false;
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        if (token.type !== TokenType.NEWLINE && token.type !== TokenType.WHITESPACE) {
          hasContent = true;
        }
        this.advance();
      }
      if (!hasContent) {
        this.addError(startToken, "Mindmap diagram must contain at least one node", "EMPTY_MINDMAP", "Add at least one node to the mindmap");
      }
      return {
        type: "mindmap",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseTimeline() {
      const startToken = this.currentToken();
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      return {
        type: "timeline",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseGantt() {
      const startToken = this.currentToken();
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      return {
        type: "gantt",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseERDiagram() {
      const startToken = this.currentToken();
      this.advance();
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        this.advance();
      }
      return {
        type: "er",
        line: startToken.line,
        column: startToken.column
      };
    }
    parseBlockDiagram() {
      const startToken = this.currentToken();
      this.advance();
      let columns;
      const blocks = [];
      let hasContent = false;
      while (!this.isAtEnd() && this.currentToken().type !== TokenType.EOF) {
        const token = this.currentToken();
        if (token.value === "columns") {
          hasContent = true;
          this.advance();
          if (this.currentToken().type === TokenType.NUMBER) {
            columns = parseInt(this.currentToken().value);
            this.advance();
          }
        } else if (token.type === TokenType.IDENTIFIER) {
          hasContent = true;
          const id = token.value;
          this.advance();
          if (this.currentToken().type === TokenType.BRACKET_OPEN) {
            this.advance();
            let label = "";
            if (this.currentToken().type === TokenType.STRING) {
              label = this.currentToken().value.slice(1, -1);
              this.advance();
            } else if (this.currentToken().type === TokenType.IDENTIFIER) {
              label = this.currentToken().value;
              this.advance();
            }
            if (this.currentToken().type === TokenType.BRACKET_CLOSE) {
              this.advance();
            }
            blocks.push({
              type: "block",
              line: token.line,
              column: token.column,
              id,
              label
            });
          }
        } else {
          this.advance();
        }
      }
      if (!hasContent) {
        this.addError(startToken, "Block diagram must contain at least one block", "EMPTY_BLOCK_DIAGRAM", "Add at least one block to the diagram");
      }
      return {
        type: "block",
        line: startToken.line,
        column: startToken.column,
        columns,
        blocks
      };
    }
    validateSingleDiagramType() {
      const diagramTypes = [];
      let firstDiagramIndex = -1;
      for (let i = 0; i < this.tokens.length; i++) {
        const token = this.tokens[i];
        if (token.type !== TokenType.DIRECTIVE && token.type !== TokenType.COMMENT && token.type !== TokenType.WHITESPACE && token.type !== TokenType.NEWLINE) {
          firstDiagramIndex = i;
          break;
        }
      }
      if (firstDiagramIndex === -1)
        return;
      for (let i = firstDiagramIndex; i < this.tokens.length; i++) {
        const token = this.tokens[i];
        const diagramTypeTokens = [
          TokenType.FLOWCHART,
          TokenType.GRAPH,
          TokenType.SEQUENCE_DIAGRAM,
          TokenType.CLASS_DIAGRAM,
          TokenType.STATE_DIAGRAM,
          TokenType.STATE_DIAGRAM_V2,
          TokenType.PIE,
          TokenType.JOURNEY,
          TokenType.XYCHART_BETA,
          TokenType.GITGRAPH,
          TokenType.MINDMAP,
          TokenType.TIMELINE,
          TokenType.GANTT,
          TokenType.ER_DIAGRAM,
          TokenType.BLOCK_BETA
        ];
        if (diagramTypeTokens.includes(token.type)) {
          const prevToken = i > 0 ? this.tokens[i - 1] : null;
          const isAtLineStart = !prevToken || prevToken.type === TokenType.NEWLINE || prevToken.line < token.line || prevToken.type === TokenType.WHITESPACE && (i === 1 || this.tokens[i - 2].type === TokenType.NEWLINE || this.tokens[i - 2].line < token.line);
          const nextToken = i + 1 < this.tokens.length ? this.tokens[i + 1] : null;
          const looksLikeDeclaration = !nextToken || nextToken.type === TokenType.NEWLINE || nextToken.type === TokenType.WHITESPACE || nextToken.type === TokenType.IDENTIFIER || nextToken.line > token.line;
          if (isAtLineStart && looksLikeDeclaration) {
            diagramTypes.push({
              type: token.value,
              line: token.line,
              column: token.column
            });
          }
        }
      }
      if (diagramTypes.length > 1) {
        const firstType = diagramTypes[0].type.toLowerCase();
        const secondType = diagramTypes[1].type.toLowerCase();
        const isFlowchartFirst = firstType === "flowchart" || firstType === "graph";
        const isSequenceSecond = secondType === "sequencediagram";
        if (!(isFlowchartFirst && isSequenceSecond)) {
          const secondDiagram = diagramTypes[1];
          this.addError({ line: secondDiagram.line, column: secondDiagram.column, type: TokenType.IDENTIFIER, value: secondDiagram.type, position: 0 }, `Multiple diagram declarations are not allowed. Found "${diagramTypes[0].type}" and "${secondDiagram.type}"`, "MULTIPLE_DIAGRAM_TYPES", "Use only one diagram type per input");
        }
      }
    }
    addError(token, message, code = "PARSE_ERROR", suggestion) {
      this.errors.push({
        line: token.line,
        column: token.column,
        message,
        code,
        suggestion
      });
    }
  };

  // node_modules/@aj-archipelago/merval/dist/version.js
  var MERMAID_VERSION_INFO = {
    validatedAgainst: "11.12.0",
    lastValidated: "2024-10-15",
    cliVersion: "@mermaid-js/mermaid-cli@11.12.0"
  };

  // node_modules/@aj-archipelago/merval/dist/index.js
  function getMermaidVersionInfo() {
    return MERMAID_VERSION_INFO;
  }
  function validateMermaid(mermaidCode, targetMermaidVersion) {
    if (typeof mermaidCode !== "string") {
      return {
        isValid: false,
        diagramType: "unknown",
        errors: [{
          line: 1,
          column: 1,
          message: "Input must be a string",
          code: "INVALID_INPUT_TYPE"
        }]
      };
    }
    if (!mermaidCode || mermaidCode.trim().length === 0) {
      return {
        isValid: false,
        diagramType: "unknown",
        errors: [{
          line: 1,
          column: 1,
          message: "Empty mermaid code",
          code: "EMPTY_INPUT"
        }]
      };
    }
    try {
      const parser = new Parser(mermaidCode);
      const result = parser.parse();
      if (targetMermaidVersion && !isMermaidVersionSupported(targetMermaidVersion)) {
        result.errors.push({
          line: 1,
          column: 1,
          message: `This validator was tested against Mermaid ${getMermaidVersionInfo().validatedAgainst}, but you're requesting validation for version ${targetMermaidVersion}. Compatibility cannot be guaranteed.`,
          code: "VERSION_MISMATCH",
          suggestion: `Use Mermaid version ${getMermaidVersionInfo().validatedAgainst} or update this validator to support version ${targetMermaidVersion}`
        });
        result.isValid = false;
      }
      return result;
    } catch (error) {
      const errorResult = {
        isValid: false,
        diagramType: "unknown",
        errors: [{
          line: 1,
          column: 1,
          message: `Validation error: ${error instanceof Error ? error.message : String(error)}`,
          code: "VALIDATION_ERROR"
        }]
      };
      return errorResult;
    }
  }
  function isValidMermaid(mermaidCode) {
    return validateMermaid(mermaidCode).isValid;
  }
  function getDiagramType(mermaidCode) {
    return validateMermaid(mermaidCode).diagramType;
  }
  function isMermaidVersionSupported(version) {
    const supportedVersion = getMermaidVersionInfo().validatedAgainst;
    return version === supportedVersion;
  }
  return __toCommonJS(index_exports);
})();
