// pattern: Functional Core
#ifndef C_TREE_SITTER_HIGHLIGHTING_H
#define C_TREE_SITTER_HIGHLIGHTING_H

#include <stddef.h>
#include <stdint.h>

typedef enum WikiTreeSitterLanguage {
  WikiTreeSitterLanguageJava = 1,
  WikiTreeSitterLanguageScala = 2,
  WikiTreeSitterLanguageHTML = 3,
  WikiTreeSitterLanguageSwift = 4,
  WikiTreeSitterLanguageJSON = 5,
} WikiTreeSitterLanguage;

typedef struct WikiTreeSitterToken {
  uint32_t start_byte;
  uint32_t end_byte;
  uint8_t category;
} WikiTreeSitterToken;

typedef struct WikiTreeSitterTiming {
  uint64_t setup_nanoseconds;
  uint64_t parser_nanoseconds;
  uint64_t query_nanoseconds;
  uint32_t capture_count;
  uint32_t emitted_token_count;
} WikiTreeSitterTiming;

typedef struct WikiTreeSitterHighlightResult WikiTreeSitterHighlightResult;

WikiTreeSitterHighlightResult *wiki_tree_sitter_highlight(
    uint8_t language,
    const char *input,
    uint32_t input_length);
size_t wiki_tree_sitter_highlight_result_count(
    const WikiTreeSitterHighlightResult *result);
const WikiTreeSitterToken *wiki_tree_sitter_highlight_result_tokens(
    const WikiTreeSitterHighlightResult *result);
WikiTreeSitterTiming wiki_tree_sitter_highlight_result_timing(
    const WikiTreeSitterHighlightResult *result);
void wiki_tree_sitter_highlight_result_delete(
    WikiTreeSitterHighlightResult *result);

#endif
