#!/usr/bin/env node
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.readStdin = readStdin;
exports.parseSource = parseSource;
exports.createProgram = createProgram;
const commander_1 = require("commander");
const node_1 = require("./node");
const promises_1 = require("fs/promises");
const path_1 = require("path");
const linkedom_compat_1 = require("./utils/linkedom-compat");
const utils_1 = require("./utils");
const frontmatter_1 = require("./frontmatter");
const fetch_1 = require("./fetch");
// ANSI color helpers (avoids chalk dependency which is ESM-only)
const useColor = process.stdout.isTTY ?? false;
const ansi = {
    red: (s) => useColor ? `\x1b[31m${s}\x1b[39m` : s,
    green: (s) => useColor ? `\x1b[32m${s}\x1b[39m` : s,
};
// Read version from package.json
const version = require('../package.json').version;
async function readStdin(input = process.stdin) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        input.setEncoding('utf8');
        input.on('data', (chunk) => {
            chunks.push(chunk);
        });
        input.on('end', () => resolve(chunks.join('')));
        input.on('error', reject);
    });
}
async function parseSource(source, options, input = process.stdin) {
    // Handle --md alias
    if (options.md) {
        options.markdown = true;
    }
    const defuddleOpts = {
        debug: options.debug,
        markdown: options.markdown,
        separateMarkdown: options.markdown || options.json,
        language: options.lang,
    };
    let html;
    let url;
    const usesStdin = !source || source === '-';
    const isUrl = !usesStdin && (source.startsWith('http://') || source.startsWith('https://'));
    if (usesStdin) {
        if (input.isTTY) {
            throw new Error('No input source provided. Pass a file path or URL, or pipe HTML to stdin.');
        }
        html = await readStdin(input);
    }
    else if (isUrl) {
        url = source;
        const initialUA = options.userAgent || (0, fetch_1.getInitialUA)(source);
        html = await (0, fetch_1.fetchPage)(source, initialUA, options.lang);
    }
    else {
        const filePath = (0, path_1.resolve)(process.cwd(), source);
        html = await (0, promises_1.readFile)(filePath, 'utf-8');
    }
    const doc = (0, linkedom_compat_1.parseLinkedomHTML)(html);
    let result = await (0, node_1.Defuddle)(doc, url, defuddleOpts);
    // If no content was extracted from a URL, retry with bot UA.
    // Some sites (e.g. Obsidian Publish) serve pre-rendered content to bots.
    // Skipped when the user set a UA explicitly — respect their choice.
    if (isUrl && result.wordCount === 0 && !options.userAgent) {
        try {
            const botHtml = await (0, fetch_1.fetchPage)(source, fetch_1.BOT_UA, options.lang);
            // Check for raw markdown before DOM parsing destroys whitespace
            const rawMarkdown = (0, fetch_1.extractRawMarkdown)(botHtml);
            if (rawMarkdown) {
                const botDoc = (0, linkedom_compat_1.parseLinkedomHTML)(botHtml);
                const botResult = await (0, node_1.Defuddle)(botDoc, url, defuddleOpts);
                botResult.content = (0, fetch_1.cleanMarkdownContent)(rawMarkdown);
                botResult.wordCount = (0, utils_1.countWords)(botResult.content);
                result = botResult;
            }
            else {
                const botDoc = (0, linkedom_compat_1.parseLinkedomHTML)(botHtml);
                const botResult = await (0, node_1.Defuddle)(botDoc, url, defuddleOpts);
                if (botResult.wordCount > 0) {
                    result = botResult;
                }
            }
        }
        catch {
            // Bot UA may be blocked — use original result
        }
    }
    // Check if parsing produced meaningful content
    const textContent = (0, linkedom_compat_1.parseLinkedomHTML)(`<!DOCTYPE html><html><body>${result.content}</body></html>`)
        .body.textContent?.trim() || '';
    if (!textContent) {
        throw new Error(`No content could be extracted from ${usesStdin ? 'stdin' : source}`);
    }
    // Format output
    let output;
    if (options.property) {
        const property = options.property;
        if (property in result) {
            output = result[property]?.toString() || '';
        }
        else {
            throw new Error(`Property "${property}" not found in response`);
        }
    }
    else if (options.json) {
        output = JSON.stringify({
            content: result.content,
            title: result.title,
            description: result.description,
            domain: result.domain,
            favicon: result.favicon,
            image: result.image,
            language: result.language,
            metaTags: result.metaTags,
            parseTime: result.parseTime,
            published: result.published,
            author: result.author,
            site: result.site,
            schemaOrgData: result.schemaOrgData,
            wordCount: result.wordCount,
            ...(result.contentMarkdown ? { contentMarkdown: result.contentMarkdown } : {}),
            ...(result.variables ? { variables: result.variables } : {}),
        }, null, 2);
    }
    else {
        output = options.frontmatter ? (0, frontmatter_1.buildFrontmatter)(result, url) + result.content : result.content;
    }
    return { output };
}
function createProgram() {
    const program = new commander_1.Command();
    program
        .name('defuddle')
        .description('Extract article content from web pages')
        .version(version);
    program
        .command('parse')
        .description('Parse HTML content from a file, URL, or stdin')
        .argument('[source]', 'HTML file path, URL, or "-" to read from stdin')
        .option('-o, --output <file>', 'Output file path (default: stdout)')
        .option('-m, --markdown', 'Convert content to markdown format')
        .option('--md', 'Alias for --markdown')
        .option('-j, --json', 'Output as JSON with metadata and content')
        .option('-f, --frontmatter', 'Prepend YAML frontmatter (title, author, source, etc.) to the output')
        .option('-p, --property <name>', 'Extract a specific property (e.g., title, description, domain)')
        .option('--debug', 'Enable debug mode')
        .option('-l, --lang <code>', 'Preferred language (BCP 47, e.g. en, fr, ja)')
        .option('-u, --user-agent <string>', 'Custom User-Agent header for HTTP requests (helps with 403/FORBIDDEN responses)')
        .action(async (source, options) => {
        try {
            const { output } = await parseSource(source, options);
            // Handle output
            if (options.output) {
                const outputPath = (0, path_1.resolve)(process.cwd(), options.output);
                await (0, promises_1.writeFile)(outputPath, output, 'utf-8');
                console.log(ansi.green(`Output written to ${options.output}`));
            }
            else {
                console.log(output);
            }
        }
        catch (error) {
            console.error(ansi.red('Error:'), error instanceof Error ? error.message : 'Unknown error occurred');
            process.exit(1);
        }
    });
    return program;
}
const program = createProgram();
if (require.main === module) {
    program.parse();
}
//# sourceMappingURL=cli.js.map