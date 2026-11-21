// The bundled tree-sitter grammars (sources in Vendor/, fetched by scripts/fetch-grammars.sh).
#ifndef VIE_TREE_SITTER_GRAMMARS_H
#define VIE_TREE_SITTER_GRAMMARS_H

#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_html(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_markdown(void);
const TSLanguage *tree_sitter_markdown_inline(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_toml(void);
const TSLanguage *tree_sitter_tsx(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_yaml(void);

/// A bundled query file by grammar and name, such as "javascript/highlights.scm"; NULL if there
/// is none.
const char *vie_query_file(const char *path);

#endif
