// The grammars' query files, compiled in with #embed (from Vendor/, scripts/fetch-grammars.sh).
#include <string.h>
#include "TreeSitterGrammars.h"

static const char q0[] = {
#embed "../../Vendor/bash/queries/highlights.scm"
, 0};
static const char q1[] = {
#embed "../../Vendor/c/queries/highlights.scm"
, 0};
static const char q2[] = {
#embed "../../Vendor/cpp/queries/highlights.scm"
, 0};
static const char q3[] = {
#embed "../../Vendor/cpp/queries/injections.scm"
, 0};
static const char q4[] = {
#embed "../../Vendor/css/queries/highlights.scm"
, 0};
static const char q5[] = {
#embed "../../Vendor/go/queries/highlights.scm"
, 0};
static const char q6[] = {
#embed "../../Vendor/html/queries/highlights.scm"
, 0};
static const char q7[] = {
#embed "../../Vendor/html/queries/injections.scm"
, 0};
static const char q8[] = {
#embed "../../Vendor/javascript/queries/highlights.scm"
, 0};
static const char q9[] = {
#embed "../../Vendor/javascript/queries/highlights-jsx.scm"
, 0};
static const char q10[] = {
#embed "../../Vendor/javascript/queries/injections.scm"
, 0};
static const char q11[] = {
#embed "../../Vendor/json/queries/highlights.scm"
, 0};
static const char q12[] = {
#embed "../../Vendor/markdown/tree-sitter-markdown/queries/highlights.scm"
, 0};
static const char q13[] = {
#embed "../../Vendor/markdown/tree-sitter-markdown/queries/injections.scm"
, 0};
static const char q14[] = {
#embed "../../Vendor/markdown/tree-sitter-markdown-inline/queries/highlights.scm"
, 0};
static const char q15[] = {
#embed "../../Vendor/markdown/tree-sitter-markdown-inline/queries/injections.scm"
, 0};
static const char q16[] = {
#embed "../../Vendor/python/queries/highlights.scm"
, 0};
static const char q17[] = {
#embed "../../Vendor/rust/queries/highlights.scm"
, 0};
static const char q18[] = {
#embed "../../Vendor/rust/queries/injections.scm"
, 0};
static const char q19[] = {
#embed "../../Vendor/swift/queries/highlights.scm"
, 0};
static const char q20[] = {
#embed "../../Vendor/swift/queries/injections.scm"
, 0};
static const char q21[] = {
#embed "../../Vendor/toml/queries/highlights.scm"
, 0};
static const char q22[] = {
#embed "../../Vendor/typescript/queries/highlights.scm"
, 0};
static const char q23[] = {
#embed "../../Vendor/yaml/queries/highlights.scm"
, 0};

static const struct { const char *path; const char *text; } files[] = {
    {"bash/highlights.scm", q0},
    {"c/highlights.scm", q1},
    {"cpp/highlights.scm", q2},
    {"cpp/injections.scm", q3},
    {"css/highlights.scm", q4},
    {"go/highlights.scm", q5},
    {"html/highlights.scm", q6},
    {"html/injections.scm", q7},
    {"javascript/highlights.scm", q8},
    {"javascript/highlights-jsx.scm", q9},
    {"javascript/injections.scm", q10},
    {"json/highlights.scm", q11},
    {"markdown/highlights.scm", q12},
    {"markdown/injections.scm", q13},
    {"markdown_inline/highlights.scm", q14},
    {"markdown_inline/injections.scm", q15},
    {"python/highlights.scm", q16},
    {"rust/highlights.scm", q17},
    {"rust/injections.scm", q18},
    {"swift/highlights.scm", q19},
    {"swift/injections.scm", q20},
    {"toml/highlights.scm", q21},
    {"typescript/highlights.scm", q22},
    {"yaml/highlights.scm", q23},
};

const char *vie_query_file(const char *path) {
    for (size_t i = 0; i < sizeof files / sizeof files[0]; i++) {
        if (strcmp(files[i].path, path) == 0) return files[i].text;
    }
    return NULL;
}
