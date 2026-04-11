/*
 * RubySyntax: Ruby syntax analysis using Prism lexer and AST.
 *
 * RubySyntax.analyze(source) -> RubySyntax::Result
 *   Parses Ruby source code and returns an analysis result containing
 *   both highlight categories and indentation levels.
 *
 * RubySyntax::Result#highlight_map -> String
 *   Returns a byte string the same length as source, where each byte
 *   represents the highlight category for the corresponding source byte.
 *
 * RubySyntax::Result#indent_level(line) -> Integer
 *   Returns the indentation depth for the given 0-based line number.
 *
 * Highlight categories:
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
#include <mruby/variable.h>
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

#define MAX_SOURCE_SIZE 8192
#define MAX_LINES       256
#define MAX_INDENT      32

typedef struct {
    uint8_t        *highlight_map;
    size_t          source_size;
    const uint8_t  *source;
    uint8_t        *indent_levels;
    size_t          line_count;
    pm_parser_t    *parser;
    uint8_t         depth;
} syntax_data_t;

static struct RClass *class_Result;

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
highlight_region(syntax_data_t *sd, const uint8_t *loc_start,
                 const uint8_t *loc_end, uint8_t category)
{
    if (loc_start == NULL || loc_end == NULL || loc_start >= loc_end) return;

    size_t start = (size_t)(loc_start - sd->source);
    size_t end   = (size_t)(loc_end   - sd->source);
    if (end > sd->source_size) end = sd->source_size;
    for (size_t i = start; i < end; i++) {
        sd->highlight_map[i] = category;
    }
}

/*
 * Convert a source pointer to a 0-based line number using the parser's
 * newline list.
 */
static size_t
source_to_line(syntax_data_t *sd, const uint8_t *ptr)
{
    int32_t line = pm_newline_list_line(
        &sd->parser->newline_list, ptr, sd->parser->start_line
    );
    int32_t zero_based = line - sd->parser->start_line;
    if (zero_based < 0) zero_based = 0;
    return (size_t)zero_based;
}

/*
 * Set the indent level for lines in range [start_line, end_line) to at least
 * the given depth. Uses max to avoid overwriting deeper indentation from
 * inner nodes.
 */
static void
indent_range(syntax_data_t *sd, size_t start_line, size_t end_line, uint8_t depth)
{
    if (depth > MAX_INDENT) depth = MAX_INDENT;
    if (end_line > sd->line_count) end_line = sd->line_count;
    for (size_t i = start_line; i < end_line; i++) {
        if (depth > sd->indent_levels[i]) {
            sd->indent_levels[i] = depth;
        }
    }
}

/*
 * AST visitor callback for highlighting and indentation.
 *
 * Returns false because we manage child traversal ourselves (to track depth).
 */
static bool
visit_node(const pm_node_t *node, void *data)
{
    syntax_data_t *sd = (syntax_data_t *)data;

    /* Highlight-specific processing */
    switch (PM_NODE_TYPE(node)) {
    case PM_CALL_NODE: {
        const pm_call_node_t *call = (const pm_call_node_t *)node;
        if (!(call->base.flags & PM_CALL_NODE_FLAGS_VARIABLE_CALL)) {
            highlight_region(sd, call->message_loc.start, call->message_loc.end,
                             HIGHLIGHT_METHOD);
        }
        break;
    }
    case PM_DEF_NODE: {
        const pm_def_node_t *def = (const pm_def_node_t *)node;
        highlight_region(sd, def->name_loc.start, def->name_loc.end,
                         HIGHLIGHT_METHOD);
        break;
    }
    case PM_SYMBOL_NODE: {
        const pm_symbol_node_t *sym = (const pm_symbol_node_t *)node;
        const uint8_t *start = sym->opening_loc.start;
        const uint8_t *end   = sym->value_loc.end;
        if (sym->closing_loc.end != NULL && sym->closing_loc.end > end) {
            end = sym->closing_loc.end;
        }
        if (start == NULL) start = sym->value_loc.start;
        highlight_region(sd, start, end, HIGHLIGHT_SYMBOL);
        break;
    }
    default:
        break;
    }

    /* Indent-specific processing */
    bool opens_block = false;
    bool is_clause = false;  /* intermediate clause (when, elsif, else, rescue, ensure) */

    switch (PM_NODE_TYPE(node)) {
    case PM_CLASS_NODE:
    case PM_MODULE_NODE:
    case PM_SINGLETON_CLASS_NODE:
    case PM_DEF_NODE:
    case PM_UNLESS_NODE:
    case PM_WHILE_NODE:
    case PM_UNTIL_NODE:
    case PM_FOR_NODE:
    case PM_CASE_NODE:
    case PM_CASE_MATCH_NODE:
    case PM_BEGIN_NODE:
    case PM_BLOCK_NODE:
    case PM_LAMBDA_NODE:
        opens_block = true;
        break;
    case PM_IF_NODE: {
        /* elsif is represented as a nested PM_IF_NODE. Detect it by
         * checking the keyword length: "if" = 2, "elsif" = 5. */
        const pm_if_node_t *if_node = (const pm_if_node_t *)node;
        opens_block = true;
        if (if_node->if_keyword_loc.end - if_node->if_keyword_loc.start > 2) {
            is_clause = true;
        }
        break;
    }
    case PM_RESCUE_NODE:
    case PM_ENSURE_NODE:
    case PM_ELSE_NODE:
    case PM_WHEN_NODE:
        opens_block = true;
        is_clause = true;
        break;
    default:
        break;
    }

    if (opens_block) {
        size_t node_start = source_to_line(sd, node->location.start);
        size_t node_end   = source_to_line(sd, node->location.end);
        uint8_t child_depth = sd->depth + 1;

        /* Determine if the closing keyword (end, }, etc.) actually exists
         * in the source, or was inserted by Prism's error recovery.
         * A missing keyword has a zero-length location (start == end). */
        pm_location_t closing = { .start = NULL, .end = NULL };
        switch (PM_NODE_TYPE(node)) {
        case PM_CLASS_NODE:
            closing = ((pm_class_node_t *)node)->end_keyword_loc; break;
        case PM_MODULE_NODE:
            closing = ((pm_module_node_t *)node)->end_keyword_loc; break;
        case PM_SINGLETON_CLASS_NODE:
            closing = ((pm_singleton_class_node_t *)node)->end_keyword_loc; break;
        case PM_DEF_NODE:
            closing = ((pm_def_node_t *)node)->end_keyword_loc; break;
        case PM_IF_NODE:
            closing = ((pm_if_node_t *)node)->end_keyword_loc; break;
        case PM_UNLESS_NODE:
            closing = ((pm_unless_node_t *)node)->end_keyword_loc; break;
        case PM_WHILE_NODE:
            closing = ((pm_while_node_t *)node)->closing_loc; break;
        case PM_UNTIL_NODE:
            closing = ((pm_until_node_t *)node)->closing_loc; break;
        case PM_FOR_NODE:
            closing = ((pm_for_node_t *)node)->end_keyword_loc; break;
        case PM_CASE_NODE:
            closing = ((pm_case_node_t *)node)->end_keyword_loc; break;
        case PM_CASE_MATCH_NODE:
            closing = ((pm_case_match_node_t *)node)->end_keyword_loc; break;
        case PM_BEGIN_NODE:
            closing = ((pm_begin_node_t *)node)->end_keyword_loc; break;
        case PM_BLOCK_NODE:
            closing = ((pm_block_node_t *)node)->closing_loc; break;
        case PM_LAMBDA_NODE:
            closing = ((pm_lambda_node_t *)node)->closing_loc; break;
        default:
            /* rescue, ensure, else, when: no own closing keyword */
            break;
        }

        bool has_real_closing = (closing.start != NULL && closing.start < closing.end);

        if (is_clause) {
            /* Intermediate clause (when, elsif, else, rescue, ensure):
             * only fix the keyword line to the parent's depth. Body
             * indentation is already handled by the parent block's
             * indent_range, so no body range is needed here. */
            uint8_t clause_depth = sd->depth > 0 ? sd->depth - 1 : 0;
            if (node_start < sd->line_count) {
                sd->indent_levels[node_start] = clause_depth;
            }
        } else if (has_real_closing) {
            /* Complete block: indent body lines, exclude closing keyword line */
            if (node_start < node_end) {
                indent_range(sd, node_start + 1, node_end, child_depth);
            }
        } else {
            /* Incomplete block (missing end): indent from the line after
             * the keyword. When the missing end is on the same line as
             * the keyword (e.g. "begin\n"), node_start == node_end, so
             * we ensure at least the next line gets indented. */
            size_t body_start = node_start + 1;
            size_t body_end = (node_end > node_start)
                ? node_end + 1
                : node_start + 2;
            indent_range(sd, body_start, body_end, child_depth);
        }

        uint8_t saved_depth = sd->depth;
        if (!is_clause) {
            sd->depth++;
        }
        pm_visit_child_nodes(node, visit_node, data);
        sd->depth = saved_depth;
    } else {
        pm_visit_child_nodes(node, visit_node, data);
    }

    return false;
}

static void
highlight_callback(void *data, pm_parser_t *parser, pm_token_t *token)
{
    syntax_data_t *sd = (syntax_data_t *)data;
    uint8_t category = token_type_to_category(token->type);
    if (category == HIGHLIGHT_DEFAULT) return;

    size_t start = (size_t)(token->start - parser->start);
    size_t end   = (size_t)(token->end   - parser->start);
    if (start > sd->source_size) return;
    if (end > sd->source_size) end = sd->source_size;

    for (size_t i = start; i < end; i++) {
        sd->highlight_map[i] = category;
    }
}

/*
 * Count lines in source (number of '\n' + 1).
 */
static size_t
count_lines(const char *source, size_t len)
{
    size_t count = 1;
    for (size_t i = 0; i < len; i++) {
        if (source[i] == '\n') count++;
    }
    return count;
}

/*
 * RubySyntax::Result#highlight_map -> String
 */
static mrb_value
mrb_result_highlight_map(mrb_state *mrb, mrb_value self)
{
    return mrb_iv_get(mrb, self, MRB_SYM(highlight_map));
}

/*
 * RubySyntax::Result#indent_level(line) -> Integer
 *
 * Returns the indentation depth for the given 0-based line number.
 * Returns 0 if the line number is out of range.
 */
static mrb_value
mrb_result_indent_level(mrb_state *mrb, mrb_value self)
{
    mrb_int line;
    mrb_get_args(mrb, "i", &line);

    mrb_value indent_str = mrb_iv_get(mrb, self, MRB_SYM(indent_levels));
    if (mrb_nil_p(indent_str)) return mrb_fixnum_value(0);

    mrb_int len = RSTRING_LEN(indent_str);
    if (line < 0 || line >= len) return mrb_fixnum_value(0);

    uint8_t level = (uint8_t)RSTRING_PTR(indent_str)[line];
    return mrb_fixnum_value(level);
}

/*
 * RubySyntax.analyze(source) -> RubySyntax::Result
 *
 * Parses Ruby source code and returns an analysis result.
 * Returns nil if source exceeds the maximum size.
 */
static mrb_value
mrb_ruby_syntax_analyze(mrb_state *mrb, mrb_value klass)
{
    const char *source;
    mrb_int source_len;
    mrb_get_args(mrb, "s", &source, &source_len);

    /* Create Result object */
    mrb_value result = mrb_obj_new(mrb, class_Result, 0, NULL);

    if (source_len <= 0) {
        mrb_iv_set(mrb, result, MRB_SYM(highlight_map),
                   mrb_str_new(mrb, "", 0));
        mrb_iv_set(mrb, result, MRB_SYM(indent_levels),
                   mrb_str_new(mrb, "", 0));
        return result;
    }
    if (source_len > MAX_SOURCE_SIZE) {
        return mrb_nil_value();
    }

    /* Allocate working buffers */
    uint8_t *map = (uint8_t *)mrb_malloc(mrb, (size_t)source_len);
    memset(map, 0, (size_t)source_len);

    size_t lines = count_lines(source, (size_t)source_len);
    if (lines > MAX_LINES) lines = MAX_LINES;
    uint8_t *indent = (uint8_t *)mrb_malloc(mrb, lines);
    memset(indent, 0, lines);

    syntax_data_t sd = {
        .highlight_map = map,
        .source_size = (size_t)source_len,
        .source = (const uint8_t *)source,
        .indent_levels = indent,
        .line_count = lines,
        .parser = NULL,
        .depth = 0,
    };

    /* Set up Prism parser with lex callback */
    pm_parser_t parser;
    pm_parser_init(&parser, (const uint8_t *)source, (size_t)source_len, NULL);
    sd.parser = &parser;

    pm_lex_callback_t lex_cb = {
        .data = &sd,
        .callback = highlight_callback,
    };
    parser.lex_callback = &lex_cb;

    /* Parse (tokens are collected via callback) */
    pm_node_t *root = pm_parse(&parser);

    /* Walk AST for highlighting and indentation */
    pm_visit_node(root, visit_node, &sd);

    /* Clean up parser and AST */
    pm_node_destroy(&parser, root);
    sd.parser = NULL;
    pm_parser_free(&parser);

    /* Store results as instance variables */
    mrb_iv_set(mrb, result, MRB_SYM(highlight_map),
               mrb_str_new(mrb, (const char *)map, (size_t)source_len));
    mrb_iv_set(mrb, result, MRB_SYM(indent_levels),
               mrb_str_new(mrb, (const char *)indent, lines));

    mrb_free(mrb, map);
    mrb_free(mrb, indent);

    return result;
}

void
mrb_picoruby_ruby_syntax_gem_init(mrb_state *mrb)
{
    struct RClass *mod = mrb_define_module_id(mrb, MRB_SYM(RubySyntax));
    mrb_define_module_function_id(mrb, mod, MRB_SYM(analyze),
                                  mrb_ruby_syntax_analyze, MRB_ARGS_REQ(1));

    class_Result = mrb_define_class_under_id(mrb, mod, MRB_SYM(Result),
                                             mrb->object_class);
    mrb_define_method_id(mrb, class_Result, MRB_SYM(highlight_map),
                         mrb_result_highlight_map, MRB_ARGS_NONE());
    mrb_define_method_id(mrb, class_Result, MRB_SYM(indent_level),
                         mrb_result_indent_level, MRB_ARGS_REQ(1));
}

void
mrb_picoruby_ruby_syntax_gem_final(mrb_state *mrb)
{
    (void)mrb;
}
