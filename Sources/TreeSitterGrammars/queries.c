// The grammars' query files, compiled in with #embed (from Vendor/, scripts/fetch-grammars.sh).
#include <string.h>
#include "TreeSitterGrammars.h"

static const char q0[] = {
#embed "../../Vendor/bash/queries/highlights.scm"
, 0};
static const char q1[] = {
#embed "../../Vendor/bibtex/queries/highlights.scm"
, 0};
static const char q2[] = {
#embed "../../Vendor/c/queries/highlights.scm"
, 0};
static const char q3[] = {
#embed "../../Vendor/cpp/queries/highlights.scm"
, 0};
static const char q4[] = {
#embed "../../Vendor/cpp/queries/injections.scm"
, 0};
static const char q5[] = {
#embed "../../Vendor/css/queries/highlights.scm"
, 0};
static const char q6[] = {
#embed "../../Vendor/go/queries/highlights.scm"
, 0};
static const char q7[] = {
#embed "../../Vendor/html/queries/highlights.scm"
, 0};
static const char q8[] = {
#embed "../../Vendor/html/queries/injections.scm"
, 0};
static const char q9[] = {
#embed "../../Vendor/javascript/queries/highlights-jsx.scm"
, 0};
static const char q10[] = {
#embed "../../Vendor/javascript/queries/highlights.scm"
, 0};
static const char q11[] = {
#embed "../../Vendor/javascript/queries/injections.scm"
, 0};
static const char q12[] = {
#embed "../../Vendor/json/queries/highlights.scm"
, 0};
static const char q13[] = {
#embed "../../Vendor/latex/queries/highlights.scm"
, 0};
static const char q14[] = {
#embed "../../Vendor/latex/queries/injections.scm"
, 0};
static const char q15[] = {
#embed "queries/markdown-highlights.scm"
, 0};
static const char q16[] = {
#embed "../../Vendor/nvim-treesitter/queries/markdown/highlights.scm"
, 0};
static const char q17[] = {
#embed "../../Vendor/markdown/tree-sitter-markdown/queries/injections.scm"
, 0};
static const char q18[] = {
#embed "../../Vendor/nvim-treesitter/queries/markdown_inline/highlights.scm"
, 0};
static const char q19[] = {
#embed "../../Vendor/markdown/tree-sitter-markdown-inline/queries/injections.scm"
, 0};
static const char q20[] = {
#embed "../../Vendor/python/queries/highlights.scm"
, 0};
static const char q21[] = {
#embed "../../Vendor/rust/queries/highlights.scm"
, 0};
static const char q22[] = {
#embed "../../Vendor/rust/queries/injections.scm"
, 0};
static const char q23[] = {
#embed "../../Vendor/swift/queries/highlights.scm"
, 0};
static const char q24[] = {
#embed "../../Vendor/swift/queries/injections.scm"
, 0};
static const char q25[] = {
#embed "../../Vendor/toml/queries/highlights.scm"
, 0};
static const char q26[] = {
#embed "../../Vendor/typescript/queries/highlights.scm"
, 0};
static const char q27[] = {
#embed "../../Vendor/yaml/queries/highlights.scm"
, 0};

static const struct { const char *path; const char *text; } files[] = {
    {"bash/highlights.scm", q0},
    {"bibtex/highlights.scm", q1},
    {"c/highlights.scm", q2},
    {"cpp/highlights.scm", q3},
    {"cpp/injections.scm", q4},
    {"css/highlights.scm", q5},
    {"go/highlights.scm", q6},
    {"html/highlights.scm", q7},
    {"html/injections.scm", q8},
    {"javascript/highlights-jsx.scm", q9},
    {"javascript/highlights.scm", q10},
    {"javascript/injections.scm", q11},
    {"json/highlights.scm", q12},
    {"latex/highlights.scm", q13},
    {"latex/injections.scm", q14},
    {"markdown/highlights-vie.scm", q15},
    {"markdown/highlights.scm", q16},
    {"markdown/injections.scm", q17},
    {"markdown_inline/highlights.scm", q18},
    {"markdown_inline/injections.scm", q19},
    {"python/highlights.scm", q20},
    {"rust/highlights.scm", q21},
    {"rust/injections.scm", q22},
    {"swift/highlights.scm", q23},
    {"swift/injections.scm", q24},
    {"toml/highlights.scm", q25},
    {"typescript/highlights.scm", q26},
    {"yaml/highlights.scm", q27},
};

const char *vie_query_file(const char *path) {
    for (size_t i = 0; i < sizeof files / sizeof files[0]; i++) {
        if (strcmp(files[i].path, path) == 0) return files[i].text;
    }
    return NULL;
}
