// pattern: Mixed (unavoidable)
// Reason: this FFI boundary owns C parser allocation while it converts parser
// captures into value tokens. Every mutable Tree-sitter object stays in one call.
#include "CTreeSitterHighlighting/CTreeSitterHighlighting.h"
#include "tree_sitter/api.h"

#include "Queries/java_highlights.h"
#include "Queries/scala_highlights.h"
#include "Queries/html_highlights.h"
#include "Queries/swift_highlights.h"
#include "Queries/json_highlights.h"

#include <stdbool.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern const TSLanguage *tree_sitter_java(void);
extern const TSLanguage *tree_sitter_scala(void);
extern const TSLanguage *tree_sitter_html(void);
extern const TSLanguage *tree_sitter_swift(void);
extern const TSLanguage *tree_sitter_json(void);

struct WikiTreeSitterHighlightResult {
  WikiTreeSitterToken *tokens;
  size_t count;
  size_t capacity;
  WikiTreeSitterTiming timing;
};

static uint64_t monotonic_nanoseconds(void) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return 0;
  return (uint64_t)time.tv_sec * UINT64_C(1000000000) + (uint64_t)time.tv_nsec;
}

typedef struct HighlightDefinition {
  const TSLanguage *language;
  const TSQuery *query;
} HighlightDefinition;

typedef struct CachedDefinition {
  const TSLanguage *language;
  const char *query_source;
  uint32_t query_length;
  TSQuery *query;
  pthread_once_t once;
} CachedDefinition;

enum TokenCategory {
  TokenCategoryIgnored = 0,
  TokenCategoryKeyword = 1,
  TokenCategoryString = 2,
  TokenCategoryComment = 3,
  TokenCategoryType = 4,
  TokenCategoryFunction = 5,
  TokenCategoryProperty = 6,
  TokenCategoryNumber = 7,
  TokenCategoryOperator = 8,
  TokenCategoryPunctuation = 9,
  TokenCategoryConstant = 10,
};

static uint8_t category_for_capture(const char *name, uint32_t length);
static void disable_ignored_capture_names(TSQuery *query);

static CachedDefinition java_definition = {NULL, (const char *)wiki_ts_query_java, sizeof(wiki_ts_query_java), NULL, PTHREAD_ONCE_INIT};
static CachedDefinition scala_definition = {NULL, (const char *)wiki_ts_query_scala, sizeof(wiki_ts_query_scala), NULL, PTHREAD_ONCE_INIT};
static CachedDefinition html_definition = {NULL, (const char *)wiki_ts_query_html, sizeof(wiki_ts_query_html), NULL, PTHREAD_ONCE_INIT};
static CachedDefinition swift_definition = {NULL, (const char *)wiki_ts_query_swift, sizeof(wiki_ts_query_swift), NULL, PTHREAD_ONCE_INIT};
static CachedDefinition json_definition = {NULL, (const char *)wiki_ts_query_json, sizeof(wiki_ts_query_json), NULL, PTHREAD_ONCE_INIT};

static void initialize_definition(CachedDefinition *definition, const TSLanguage *language) {
  definition->language = language;
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  definition->query = ts_query_new(language, definition->query_source, definition->query_length, &error_offset, &error_type);
  if (definition->query != NULL) disable_ignored_capture_names(definition->query);
}

static void initialize_java_definition(void) { initialize_definition(&java_definition, tree_sitter_java()); }
static void initialize_scala_definition(void) { initialize_definition(&scala_definition, tree_sitter_scala()); }
static void initialize_html_definition(void) { initialize_definition(&html_definition, tree_sitter_html()); }
static void initialize_swift_definition(void) { initialize_definition(&swift_definition, tree_sitter_swift()); }
static void initialize_json_definition(void) { initialize_definition(&json_definition, tree_sitter_json()); }

static HighlightDefinition definition_for(WikiTreeSitterLanguage language) {
  CachedDefinition *definition = NULL;
  switch (language) {
    case WikiTreeSitterLanguageJava:
      pthread_once(&java_definition.once, initialize_java_definition);
      definition = &java_definition;
      break;
    case WikiTreeSitterLanguageScala:
      pthread_once(&scala_definition.once, initialize_scala_definition);
      definition = &scala_definition;
      break;
    case WikiTreeSitterLanguageHTML:
      pthread_once(&html_definition.once, initialize_html_definition);
      definition = &html_definition;
      break;
    case WikiTreeSitterLanguageSwift:
      pthread_once(&swift_definition.once, initialize_swift_definition);
      definition = &swift_definition;
      break;
    case WikiTreeSitterLanguageJSON:
      pthread_once(&json_definition.once, initialize_json_definition);
      definition = &json_definition;
      break;
  }
  return definition == NULL ? (HighlightDefinition){NULL, NULL} : (HighlightDefinition){definition->language, definition->query};
}

static bool name_starts_with(const char *name, uint32_t length, const char *prefix) {
  size_t prefix_length = strlen(prefix);
  return length >= prefix_length && memcmp(name, prefix, prefix_length) == 0;
}

static uint8_t category_for_capture(const char *name, uint32_t length) {
  if (name_starts_with(name, length, "keyword")) return TokenCategoryKeyword;
  if (name_starts_with(name, length, "string") || name_starts_with(name, length, "escape")) return TokenCategoryString;
  if (name_starts_with(name, length, "comment")) return TokenCategoryComment;
  if (name_starts_with(name, length, "type") || name_starts_with(name, length, "tag")) return TokenCategoryType;
  if (name_starts_with(name, length, "function") || name_starts_with(name, length, "method") || name_starts_with(name, length, "constructor")) return TokenCategoryFunction;
  if (name_starts_with(name, length, "property") || name_starts_with(name, length, "field") || name_starts_with(name, length, "attribute")) return TokenCategoryProperty;
  if (name_starts_with(name, length, "number") || name_starts_with(name, length, "float")) return TokenCategoryNumber;
  if (name_starts_with(name, length, "operator")) return TokenCategoryOperator;
  if (name_starts_with(name, length, "punctuation")) return TokenCategoryPunctuation;
  if (name_starts_with(name, length, "constant") || name_starts_with(name, length, "boolean")) return TokenCategoryConstant;
  return TokenCategoryIgnored;
}

// The closed palette intentionally renders no span for these names. Disable
// them before pthread_once publishes the immutable shared TSQuery so cursors
// never enumerate captures that the host would discard.
static void disable_ignored_capture_names(TSQuery *query) {
  uint32_t capture_count = ts_query_capture_count(query);
  for (uint32_t capture_index = 0; capture_index < capture_count; capture_index += 1) {
    uint32_t capture_name_length = 0;
    const char *capture_name = ts_query_capture_name_for_id(query, capture_index, &capture_name_length);
    if (category_for_capture(capture_name, capture_name_length) == TokenCategoryIgnored) {
      ts_query_disable_capture(query, capture_name, capture_name_length);
    }
  }
}

static bool append_token(WikiTreeSitterHighlightResult *result, WikiTreeSitterToken token) {
  if (result->count == result->capacity) {
    size_t next_capacity = result->capacity == 0 ? 64 : result->capacity * 2;
    if (next_capacity < result->capacity || next_capacity > SIZE_MAX / sizeof(WikiTreeSitterToken)) return false;
    WikiTreeSitterToken *tokens = realloc(result->tokens, next_capacity * sizeof(WikiTreeSitterToken));
    if (tokens == NULL) return false;
    result->tokens = tokens;
    result->capacity = next_capacity;
  }
  result->tokens[result->count++] = token;
  return true;
}

WikiTreeSitterHighlightResult *wiki_tree_sitter_highlight(
    uint8_t language_code,
    const char *input,
    uint32_t input_length) {
  if (input == NULL) return NULL;
  HighlightDefinition definition = definition_for((WikiTreeSitterLanguage)language_code);
  if (definition.language == NULL || definition.query == NULL) return NULL;

  uint64_t setup_started = monotonic_nanoseconds();
  TSParser *parser = ts_parser_new();
  if (parser == NULL) return NULL;
  if (!ts_parser_set_language(parser, definition.language)) {
    ts_parser_delete(parser);
    return NULL;
  }
  uint64_t setup_finished = monotonic_nanoseconds();

  uint64_t parser_started = monotonic_nanoseconds();
  TSTree *tree = ts_parser_parse_string(parser, NULL, input, input_length);
  uint64_t parser_finished = monotonic_nanoseconds();
  if (tree == NULL) {
    ts_parser_delete(parser);
    return NULL;
  }
  TSQueryCursor *cursor = ts_query_cursor_new();
  WikiTreeSitterHighlightResult *result = calloc(1, sizeof(WikiTreeSitterHighlightResult));
  if (cursor == NULL || result == NULL) {
    free(result);
    if (cursor != NULL) ts_query_cursor_delete(cursor);
    ts_tree_delete(tree);
    ts_parser_delete(parser);
    return NULL;
  }
  result->timing.setup_nanoseconds = setup_finished >= setup_started ? setup_finished - setup_started : 0;
  result->timing.parser_nanoseconds = parser_finished >= parser_started ? parser_finished - parser_started : 0;

  uint64_t query_started = monotonic_nanoseconds();
  ts_query_cursor_exec(cursor, definition.query, ts_tree_root_node(tree));
  TSQueryMatch match;
  uint32_t capture_index = 0;
  bool success = true;
  while (ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
    result->timing.capture_count += 1;
    TSQueryCapture capture = match.captures[capture_index];
    uint32_t capture_name_length = 0;
    const char *capture_name = ts_query_capture_name_for_id(definition.query, capture.index, &capture_name_length);
    uint8_t category = category_for_capture(capture_name, capture_name_length);
    uint32_t start_byte = ts_node_start_byte(capture.node);
    uint32_t end_byte = ts_node_end_byte(capture.node);
    if (category != TokenCategoryIgnored && start_byte < end_byte) {
      success = append_token(result, (WikiTreeSitterToken){start_byte, end_byte, category});
      if (!success) break;
    }
  }
  uint64_t query_finished = monotonic_nanoseconds();
  result->timing.query_nanoseconds = query_finished >= query_started ? query_finished - query_started : 0;
  result->timing.emitted_token_count = (uint32_t)(result->count > UINT32_MAX ? UINT32_MAX : result->count);

  ts_query_cursor_delete(cursor);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  if (!success) {
    wiki_tree_sitter_highlight_result_delete(result);
    return NULL;
  }
  return result;
}

size_t wiki_tree_sitter_highlight_result_count(const WikiTreeSitterHighlightResult *result) {
  return result == NULL ? 0 : result->count;
}

const WikiTreeSitterToken *wiki_tree_sitter_highlight_result_tokens(const WikiTreeSitterHighlightResult *result) {
  return result == NULL ? NULL : result->tokens;
}

WikiTreeSitterTiming wiki_tree_sitter_highlight_result_timing(const WikiTreeSitterHighlightResult *result) {
  return result == NULL ? (WikiTreeSitterTiming){0} : result->timing;
}

void wiki_tree_sitter_highlight_result_delete(WikiTreeSitterHighlightResult *result) {
  if (result == NULL) return;
  free(result->tokens);
  free(result);
}
