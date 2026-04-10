/*
 * SyntaxHighlight: Ruby syntax tokenization using Prism lexer and AST.
 *
 * SyntaxHighlight.tokenize(source) -> String
 *   Returns a byte string the same length as source, where each byte
 *   represents the highlight category for the corresponding source byte.
 *
 * Categories:
 *   0 = default (identifiers, punctuation, operators)
 *   1 = keyword (def, end, class, if, ...)
 *   2 = string / heredoc / character literal
 *   3 = comment
 *   4 = number (integer, float)
 *   5 = symbol (:name)
 *   6 = constant (ClassName, CONST)
 *   7 = variable (@ivar, @@cvar, $gvar)
 *   8 = method call (foo.bar, puts, each)
 */

#include <string.h>

#include <mruby.h>
#include <mruby/string.h>
#include <mruby/presym.h>

#include "prism.h"

#define HIGHLIGHT_DEFAULT   0
#define HIGHLIGHT_KEYWORD   1
#define HIGHLIGHT_STRING    2
#define HIGHLIGHT_COMMENT   3
#define HIGHLIGHT_NUMBER    4
#define HIGHLIGHT_SYMBOL    5
#define HIGHLIGHT_CONSTANT  6
#define HIGHLIGHT_VARIABLE  7
#define HIGHLIGHT_METHOD    8

#define HIGHLIGHT_MAX_SOURCE_SIZE 8192

typedef struct {
    uint8_t        *map;
    size_t          size;
    const uint8_t  *source;
} highlight_data_t;

static uint8_t
token_type_to_category(pm_token_type_t type)
{
    switch (type) {
    /* Keywords */
    case PM_TOKEN_KEYWORD_ALIAS:
    case PM_TOKEN_KEYWORD_AND:
    case PM_TOKEN_KEYWORD_BEGIN:
    case PM_TOKEN_KEYWORD_BEGIN_UPCASE:
    case PM_TOKEN_KEYWORD_BREAK:
    case PM_TOKEN_KEYWORD_CASE:
    case PM_TOKEN_KEYWORD_CLASS:
    case PM_TOKEN_KEYWORD_DEF:
    case PM_TOKEN_KEYWORD_DEFINED:
    case PM_TOKEN_KEYWORD_DO:
    case PM_TOKEN_KEYWORD_DO_LOOP:
    case PM_TOKEN_KEYWORD_ELSE:
    case PM_TOKEN_KEYWORD_ELSIF:
    case PM_TOKEN_KEYWORD_END:
    case PM_TOKEN_KEYWORD_END_UPCASE:
    case PM_TOKEN_KEYWORD_ENSURE:
    case PM_TOKEN_KEYWORD_FALSE:
    case PM_TOKEN_KEYWORD_FOR:
    case PM_TOKEN_KEYWORD_IF:
    case PM_TOKEN_KEYWORD_IF_MODIFIER:
    case PM_TOKEN_KEYWORD_IN:
    case PM_TOKEN_KEYWORD_MODULE:
    case PM_TOKEN_KEYWORD_NEXT:
    case PM_TOKEN_KEYWORD_NIL:
    case PM_TOKEN_KEYWORD_NOT:
    case PM_TOKEN_KEYWORD_OR:
    case PM_TOKEN_KEYWORD_REDO:
    case PM_TOKEN_KEYWORD_RESCUE:
    case PM_TOKEN_KEYWORD_RESCUE_MODIFIER:
    case PM_TOKEN_KEYWORD_RETRY:
    case PM_TOKEN_KEYWORD_RETURN:
    case PM_TOKEN_KEYWORD_SELF:
    case PM_TOKEN_KEYWORD_SUPER:
    case PM_TOKEN_KEYWORD_THEN:
    case PM_TOKEN_KEYWORD_TRUE:
    case PM_TOKEN_KEYWORD_UNDEF:
    case PM_TOKEN_KEYWORD_UNLESS:
    case PM_TOKEN_KEYWORD_UNLESS_MODIFIER:
    case PM_TOKEN_KEYWORD_UNTIL:
    case PM_TOKEN_KEYWORD_UNTIL_MODIFIER:
    case PM_TOKEN_KEYWORD_WHEN:
    case PM_TOKEN_KEYWORD_WHILE:
    case PM_TOKEN_KEYWORD_WHILE_MODIFIER:
    case PM_TOKEN_KEYWORD_YIELD:
    case PM_TOKEN_KEYWORD___ENCODING__:
    case PM_TOKEN_KEYWORD___FILE__:
    case PM_TOKEN_KEYWORD___LINE__:
        return HIGHLIGHT_KEYWORD;

    /* Strings and string-like literals */
    case PM_TOKEN_STRING_BEGIN:
    case PM_TOKEN_STRING_CONTENT:
    case PM_TOKEN_STRING_END:
    case PM_TOKEN_HEREDOC_START:
    case PM_TOKEN_HEREDOC_END:
    case PM_TOKEN_CHARACTER_LITERAL:
    case PM_TOKEN_BACKTICK:
    case PM_TOKEN_PERCENT_LOWER_W:
    case PM_TOKEN_PERCENT_UPPER_W:
    case PM_TOKEN_PERCENT_LOWER_I:
    case PM_TOKEN_PERCENT_UPPER_I:
    case PM_TOKEN_PERCENT_LOWER_X:
    case PM_TOKEN_WORDS_SEP:
    case PM_TOKEN_EMBEXPR_BEGIN:
    case PM_TOKEN_EMBEXPR_END:
    case PM_TOKEN_EMBVAR:
        return HIGHLIGHT_STRING;

    /* Comments */
    case PM_TOKEN_COMMENT:
    case PM_TOKEN_EMBDOC_BEGIN:
    case PM_TOKEN_EMBDOC_LINE:
    case PM_TOKEN_EMBDOC_END:
        return HIGHLIGHT_COMMENT;

    /* Numbers */
    case PM_TOKEN_INTEGER:
    case PM_TOKEN_INTEGER_IMAGINARY:
    case PM_TOKEN_INTEGER_RATIONAL:
    case PM_TOKEN_INTEGER_RATIONAL_IMAGINARY:
    case PM_TOKEN_FLOAT:
    case PM_TOKEN_FLOAT_IMAGINARY:
    case PM_TOKEN_FLOAT_RATIONAL:
    case PM_TOKEN_FLOAT_RATIONAL_IMAGINARY:
        return HIGHLIGHT_NUMBER;

    /* Symbols */
    case PM_TOKEN_SYMBOL_BEGIN:
        return HIGHLIGHT_SYMBOL;

    /* Constants */
    case PM_TOKEN_CONSTANT:
        return HIGHLIGHT_CONSTANT;

    /* Variables */
    case PM_TOKEN_INSTANCE_VARIABLE:
    case PM_TOKEN_CLASS_VARIABLE:
    case PM_TOKEN_GLOBAL_VARIABLE:
        return HIGHLIGHT_VARIABLE;

    /* Regexp */
    case PM_TOKEN_REGEXP_BEGIN:
    case PM_TOKEN_REGEXP_END:
        return HIGHLIGHT_STRING;

    default:
        return HIGHLIGHT_DEFAULT;
    }
}

/* Fill a region of the highlight map with a given category. */
static void
highlight_region(highlight_data_t *hd, const uint8_t *loc_start,
                 const uint8_t *loc_end, uint8_t category)
{
    if (loc_start == NULL || loc_end == NULL || loc_start >= loc_end) return;

    size_t start = (size_t)(loc_start - hd->source);
    size_t end   = (size_t)(loc_end   - hd->source);
    if (end > hd->size) end = hd->size;
    for (size_t i = start; i < end; i++) {
        hd->map[i] = category;
    }
}

/*
 * AST visitor callback: supplement lexer-based highlighting with
 * AST-level information.
 *
 * - PM_CALL_NODE:   highlight the method name (message_loc)
 * - PM_DEF_NODE:    highlight the method definition name (name_loc)
 * - PM_SYMBOL_NODE: highlight the entire symbol (opening + value + closing)
 */
static bool
highlight_visit_node(const pm_node_t *node, void *data)
{
    highlight_data_t *hd = (highlight_data_t *)data;

    switch (PM_NODE_TYPE(node)) {
    case PM_CALL_NODE: {
        const pm_call_node_t *call = (const pm_call_node_t *)node;
        /* Skip variable-style calls (bare identifier without receiver or parens) */
        if (call->base.flags & PM_CALL_NODE_FLAGS_VARIABLE_CALL) break;
        highlight_region(hd, call->message_loc.start, call->message_loc.end,
                         HIGHLIGHT_METHOD);
        break;
    }
    case PM_DEF_NODE: {
        const pm_def_node_t *def = (const pm_def_node_t *)node;
        highlight_region(hd, def->name_loc.start, def->name_loc.end,
                         HIGHLIGHT_METHOD);
        break;
    }
    case PM_SYMBOL_NODE: {
        const pm_symbol_node_t *sym = (const pm_symbol_node_t *)node;
        /* Cover the entire symbol: opening (`:`) through value and closing */
        const uint8_t *start = sym->opening_loc.start;
        const uint8_t *end   = sym->value_loc.end;
        if (sym->closing_loc.end != NULL && sym->closing_loc.end > end) {
            end = sym->closing_loc.end;
        }
        if (start == NULL) start = sym->value_loc.start;
        highlight_region(hd, start, end, HIGHLIGHT_SYMBOL);
        break;
    }
    default:
        break;
    }

    return true;
}

static void
highlight_callback(void *data, pm_parser_t *parser, pm_token_t *token)
{
    highlight_data_t *hd = (highlight_data_t *)data;
    uint8_t category = token_type_to_category(token->type);
    if (category == HIGHLIGHT_DEFAULT) return;

    size_t start = (size_t)(token->start - parser->start);
    size_t end   = (size_t)(token->end   - parser->start);
    if (start > hd->size) return;
    if (end > hd->size) end = hd->size;

    for (size_t i = start; i < end; i++) {
        hd->map[i] = category;
    }
}

/*
 * SyntaxHighlight.tokenize(source) -> String
 *
 * Tokenize Ruby source code and return a category map.
 * Each byte in the returned string corresponds to a byte in the source,
 * with its value indicating the highlight category (0-8).
 * Returns nil if source exceeds the maximum size.
 */
static mrb_value
mrb_syntax_highlight_tokenize(mrb_state *mrb, mrb_value klass)
{
    const char *source;
    mrb_int source_len;
    mrb_get_args(mrb, "s", &source, &source_len);

    if (source_len <= 0) {
        return mrb_str_new(mrb, "", 0);
    }
    if (source_len > HIGHLIGHT_MAX_SOURCE_SIZE) {
        return mrb_nil_value();
    }

    /* Allocate category map */
    uint8_t *map = (uint8_t *)mrb_malloc(mrb, (size_t)source_len);
    memset(map, 0, (size_t)source_len);

    highlight_data_t hd = {
        .map = map,
        .size = (size_t)source_len,
        .source = (const uint8_t *)source,
    };

    /* Set up Prism parser with lex callback */
    pm_parser_t parser;
    pm_parser_init(&parser, (const uint8_t *)source, (size_t)source_len, NULL);

    pm_lex_callback_t lex_cb = {
        .data = &hd,
        .callback = highlight_callback,
    };
    parser.lex_callback = &lex_cb;

    /* Parse (tokens are collected via callback) */
    pm_node_t *root = pm_parse(&parser);

    /* Walk AST to highlight method call names */
    pm_visit_node(root, highlight_visit_node, &hd);

    /* Clean up parser and AST */
    pm_node_destroy(&parser, root);
    pm_parser_free(&parser);

    /* Wrap map as mruby string */
    mrb_value result = mrb_str_new(mrb, (const char *)map, (size_t)source_len);
    mrb_free(mrb, map);
    return result;
}

void
mrb_picoruby_syntax_highlight_gem_init(mrb_state *mrb)
{
    struct RClass *mod = mrb_define_module_id(mrb, MRB_SYM(SyntaxHighlight));
    mrb_define_module_function_id(mrb, mod, MRB_SYM(tokenize),
                                  mrb_syntax_highlight_tokenize, MRB_ARGS_REQ(1));
}

void
mrb_picoruby_syntax_highlight_gem_final(mrb_state *mrb)
{
    (void)mrb;
}
