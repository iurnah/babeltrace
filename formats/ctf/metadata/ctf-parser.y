%{
/*
 * ctf-parser.y
 *
 * Common Trace Format Metadata Grammar.
 *
 * Copyright 2010 - Mathieu Desnoyers <mathieu.desnoyers@efficios.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 */

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include <helpers/list.h>
#include <glib.h>
#include <errno.h>
#include "ctf-scanner.h"
#include "ctf-parser.h"
#include "ctf-ast.h"

#define printf_dbg(fmt, args...)	fprintf(stderr, "%s: " fmt, __func__, ## args)

int yyparse(struct ctf_scanner *scanner);
int yylex(union YYSTYPE *yyval, struct ctf_scanner *scanner);
int yylex_init_extra(struct ctf_scanner *scanner, yyscan_t * ptr_yy_globals);
int yylex_destroy(yyscan_t yyscanner) ;
void yyset_in(FILE * in_str, yyscan_t scanner);

int yydebug;

struct gc_string {
	struct cds_list_head gc;
	size_t alloclen;
	char s[];
};

static struct gc_string *gc_string_alloc(struct ctf_scanner *scanner,
					 size_t len)
{
	struct gc_string *gstr;
	size_t alloclen;

	/* TODO: could be faster with find first bit or glib Gstring */
	/* sizeof long to account for malloc header (int or long ?) */
	for (alloclen = 8; alloclen < sizeof(long) + sizeof(*gstr) + len;
	     alloclen *= 2);

	gstr = malloc(alloclen);
	cds_list_add(&gstr->gc, &scanner->allocated_strings);
	gstr->alloclen = alloclen;
	return gstr;
}

/*
 * note: never use gc_string_append on a string that has external references.
 * gsrc will be garbage collected immediately, and gstr might be.
 * Should only be used to append characters to a string literal or constant.
 */
struct gc_string *gc_string_append(struct ctf_scanner *scanner,
				   struct gc_string *gstr,
				   struct gc_string *gsrc)
{
	size_t newlen = strlen(gsrc->s) + strlen(gstr->s) + 1;
	size_t alloclen;

	/* TODO: could be faster with find first bit or glib Gstring */
	/* sizeof long to account for malloc header (int or long ?) */
	for (alloclen = 8; alloclen < sizeof(long) + sizeof(*gstr) + newlen;
	     alloclen *= 2);

	if (alloclen > gstr->alloclen) {
		struct gc_string *newgstr;

		newgstr = gc_string_alloc(scanner, newlen);
		strcpy(newgstr->s, gstr->s);
		strcat(newgstr->s, gsrc->s);
		cds_list_del(&gstr->gc);
		free(gstr);
		gstr = newgstr;
	} else {
		strcat(gstr->s, gsrc->s);
	}
	cds_list_del(&gsrc->gc);
	free(gsrc);
	return gstr;
}

void setstring(struct ctf_scanner *scanner, YYSTYPE *lvalp, const char *src)
{
	lvalp->gs = gc_string_alloc(scanner, strlen(src) + 1);
	strcpy(lvalp->gs->s, src);
}

static void init_scope(struct ctf_scanner_scope *scope,
		       struct ctf_scanner_scope *parent)
{
	scope->parent = parent;
	scope->types = g_hash_table_new_full(g_str_hash, g_str_equal,
					     NULL, NULL);
}

static void finalize_scope(struct ctf_scanner_scope *scope)
{
	g_hash_table_destroy(scope->types);
}

static void push_scope(struct ctf_scanner *scanner)
{
	struct ctf_scanner_scope *ns;

	printf_dbg("push scope\n");
	ns = malloc(sizeof(struct ctf_scanner_scope));
	init_scope(ns, scanner->cs);
	scanner->cs = ns;
}

static void pop_scope(struct ctf_scanner *scanner)
{
	struct ctf_scanner_scope *os;

	printf_dbg("pop scope\n");
	os = scanner->cs;
	scanner->cs = os->parent;
	finalize_scope(os);
	free(os);
}

static int lookup_type(struct ctf_scanner_scope *s, const char *id)
{
	int ret;

	ret = (int) g_hash_table_lookup(s->types, id);
	printf_dbg("lookup %p %s %d\n", s, id, ret);
	return ret;
}

int is_type(struct ctf_scanner *scanner, const char *id)
{
	struct ctf_scanner_scope *it;
	int ret = 0;

	for (it = scanner->cs; it != NULL; it = it->parent) {
		if (lookup_type(it, id)) {
			ret = 1;
			break;
		}
	}
	printf_dbg("is type %s %d\n", id, ret);
	return ret;
}

static void add_type(struct ctf_scanner *scanner, struct gc_string *id)
{
	printf_dbg("add type %s\n", id->s);
	if (lookup_type(scanner->cs, id->s))
		return;
	g_hash_table_insert(scanner->cs->types, id->s, id->s);
}

static struct ctf_node *make_node(struct ctf_scanner *scanner,
				  enum node_type type)
{
	struct ctf_ast *ast = ctf_scanner_get_ast(scanner);
	struct ctf_node *node;

	node = malloc(sizeof(*node));
	if (!node)
		return NULL;
	memset(node, 0, sizeof(*node));
	node->type = type;
	CDS_INIT_LIST_HEAD(&node->siblings);
	cds_list_add(&node->gc, &ast->allocated_nodes);

	switch (type) {
	case NODE_ROOT:
		fprintf(stderr, "[error] %s: trying to create root node\n", __func__);
		break;

	case NODE_EVENT:
		CDS_INIT_LIST_HEAD(&node->u.event.declaration_list);
		break;
	case NODE_STREAM:
		CDS_INIT_LIST_HEAD(&node->u.stream.declaration_list);
		break;
	case NODE_TRACE:
		CDS_INIT_LIST_HEAD(&node->u.trace.declaration_list);
		break;

	case NODE_CTF_EXPRESSION:
		break;
	case NODE_UNARY_EXPRESSION:
		break;

	case NODE_TYPEDEF:
		CDS_INIT_LIST_HEAD(&node->u._typedef.declaration_specifier);
		CDS_INIT_LIST_HEAD(&node->u._typedef.type_declarators);
		break;
	case NODE_TYPEALIAS_TARGET:
		CDS_INIT_LIST_HEAD(&node->u.typealias_target.declaration_specifier);
		CDS_INIT_LIST_HEAD(&node->u.typealias_target.type_declarators);
		break;
	case NODE_TYPEALIAS_ALIAS:
		CDS_INIT_LIST_HEAD(&node->u.typealias_alias.declaration_specifier);
		CDS_INIT_LIST_HEAD(&node->u.typealias_alias.type_declarators);
		break;
	case NODE_TYPEALIAS:
		break;

	case NODE_TYPE_SPECIFIER:
		break;
	case NODE_POINTER:
		break;
	case NODE_TYPE_DECLARATOR:
		CDS_INIT_LIST_HEAD(&node->u.type_declarator.pointers);
		break;

	case NODE_FLOATING_POINT:
		CDS_INIT_LIST_HEAD(&node->u.floating_point.expressions);
		break;
	case NODE_INTEGER:
		CDS_INIT_LIST_HEAD(&node->u.integer.expressions);
		break;
	case NODE_STRING:
		CDS_INIT_LIST_HEAD(&node->u.string.expressions);
		break;
	case NODE_ENUMERATOR:
		break;
	case NODE_ENUM:
		CDS_INIT_LIST_HEAD(&node->u._enum.enumerator_list);
		break;
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
		CDS_INIT_LIST_HEAD(&node->u.struct_or_variant_declaration.declaration_specifier);
		CDS_INIT_LIST_HEAD(&node->u.struct_or_variant_declaration.type_declarators);
		break;
	case NODE_VARIANT:
		CDS_INIT_LIST_HEAD(&node->u.variant.declaration_list);
		break;
	case NODE_STRUCT:
		CDS_INIT_LIST_HEAD(&node->u._struct.declaration_list);
		break;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) type);
		break;
	}

	return node;
}

static int reparent_ctf_expression(struct ctf_node *node,
				   struct ctf_node *parent)
{
	switch (parent->type) {
	case NODE_EVENT:
		cds_list_add(&node->siblings, &parent->u.event.declaration_list);
		break;
	case NODE_STREAM:
		cds_list_add(&node->siblings, &parent->u.stream.declaration_list);
		break;
	case NODE_TRACE:
		cds_list_add(&node->siblings, &parent->u.trace.declaration_list);
		break;
	case NODE_FLOATING_POINT:
		cds_list_add(&node->siblings, &parent->u.floating_point.expressions);
		break;
	case NODE_INTEGER:
		cds_list_add(&node->siblings, &parent->u.integer.expressions);
		break;
	case NODE_STRING:
		cds_list_add(&node->siblings, &parent->u.string.expressions);
		break;

	case NODE_ROOT:
	case NODE_CTF_EXPRESSION:
	case NODE_TYPEDEF:
	case NODE_TYPEALIAS_TARGET:
	case NODE_TYPEALIAS_ALIAS:
	case NODE_TYPEALIAS:
	case NODE_TYPE_SPECIFIER:
	case NODE_POINTER:
	case NODE_TYPE_DECLARATOR:
	case NODE_ENUMERATOR:
	case NODE_ENUM:
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
	case NODE_VARIANT:
	case NODE_STRUCT:
	case NODE_UNARY_EXPRESSION:
		return -EPERM;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) parent->type);
		return -EINVAL;
	}
	return 0;
}

static int reparent_typedef(struct ctf_node *node, struct ctf_node *parent)
{
	switch (parent->type) {
	case NODE_ROOT:
		cds_list_add(&node->siblings, &parent->u.root._typedef);
		break;
	case NODE_EVENT:
		cds_list_add(&node->siblings, &parent->u.event.declaration_list);
		break;
	case NODE_STREAM:
		cds_list_add(&node->siblings, &parent->u.stream.declaration_list);
		break;
	case NODE_TRACE:
		cds_list_add(&node->siblings, &parent->u.trace.declaration_list);
		break;
	case NODE_VARIANT:
		cds_list_add(&node->siblings, &parent->u.variant.declaration_list);
		break;
	case NODE_STRUCT:
		cds_list_add(&node->siblings, &parent->u._struct.declaration_list);
		break;

	case NODE_FLOATING_POINT:
	case NODE_INTEGER:
	case NODE_STRING:
	case NODE_CTF_EXPRESSION:
	case NODE_TYPEDEF:
	case NODE_TYPEALIAS_TARGET:
	case NODE_TYPEALIAS_ALIAS:
	case NODE_TYPEALIAS:
	case NODE_TYPE_SPECIFIER:
	case NODE_POINTER:
	case NODE_TYPE_DECLARATOR:
	case NODE_ENUMERATOR:
	case NODE_ENUM:
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
	case NODE_UNARY_EXPRESSION:
		return -EPERM;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) parent->type);
		return -EINVAL;
	}
	return 0;
}

static int reparent_typealias(struct ctf_node *node, struct ctf_node *parent)
{
	switch (parent->type) {
	case NODE_ROOT:
		cds_list_add(&node->siblings, &parent->u.root.typealias);
		break;
	case NODE_EVENT:
		cds_list_add(&node->siblings, &parent->u.event.declaration_list);
		break;
	case NODE_STREAM:
		cds_list_add(&node->siblings, &parent->u.stream.declaration_list);
		break;
	case NODE_TRACE:
		cds_list_add(&node->siblings, &parent->u.trace.declaration_list);
		break;
	case NODE_VARIANT:
		cds_list_add(&node->siblings, &parent->u.variant.declaration_list);
		break;
	case NODE_STRUCT:
		cds_list_add(&node->siblings, &parent->u._struct.declaration_list);
		break;

	case NODE_FLOATING_POINT:
	case NODE_INTEGER:
	case NODE_STRING:
	case NODE_CTF_EXPRESSION:
	case NODE_TYPEDEF:
	case NODE_TYPEALIAS_TARGET:
	case NODE_TYPEALIAS_ALIAS:
	case NODE_TYPEALIAS:
	case NODE_TYPE_SPECIFIER:
	case NODE_POINTER:
	case NODE_TYPE_DECLARATOR:
	case NODE_ENUMERATOR:
	case NODE_ENUM:
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
	case NODE_UNARY_EXPRESSION:
		return -EPERM;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) parent->type);
		return -EINVAL;
	}
	return 0;
}

static int reparent_type_specifier(struct ctf_node *node,
				   struct ctf_node *parent)
{
	switch (parent->type) {
	case NODE_ROOT:
		cds_list_add(&node->siblings, &parent->u.root.declaration_specifier);
		break;
	case NODE_EVENT:
		cds_list_add(&node->siblings, &parent->u.event.declaration_list);
		break;
	case NODE_STREAM:
		cds_list_add(&node->siblings, &parent->u.stream.declaration_list);
		break;
	case NODE_TRACE:
		cds_list_add(&node->siblings, &parent->u.trace.declaration_list);
		break;
	case NODE_VARIANT:
		cds_list_add(&node->siblings, &parent->u.variant.declaration_list);
		break;
	case NODE_STRUCT:
		cds_list_add(&node->siblings, &parent->u._struct.declaration_list);
		break;
	case NODE_TYPEDEF:
		cds_list_add(&node->siblings, &parent->u._typedef.declaration_specifier);
		break;
	case NODE_TYPEALIAS_TARGET:
		cds_list_add(&node->siblings, &parent->u.typealias_target.declaration_specifier);
		break;
	case NODE_TYPEALIAS_ALIAS:
		cds_list_add(&node->siblings, &parent->u.typealias_alias.declaration_specifier);
		break;
	case NODE_TYPE_DECLARATOR:
		parent->u.type_declarator.type = TYPEDEC_NESTED;
		parent->u.type_declarator.u.nested.length = node;
		break;
	case NODE_ENUM:
		parent->u._enum.container_type = node;
		break;
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
		cds_list_add(&node->siblings, &parent->u.struct_or_variant_declaration.declaration_specifier);
		break;
	case NODE_TYPEALIAS:
	case NODE_FLOATING_POINT:
	case NODE_INTEGER:
	case NODE_STRING:
	case NODE_CTF_EXPRESSION:
	case NODE_TYPE_SPECIFIER:
	case NODE_POINTER:
	case NODE_ENUMERATOR:
	case NODE_UNARY_EXPRESSION:
		return -EPERM;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) parent->type);
		return -EINVAL;
	}
	return 0;
}

static int reparent_type_declarator(struct ctf_node *node,
				    struct ctf_node *parent)
{
	switch (parent->type) {
	case NODE_TYPE_DECLARATOR:
		parent->u.type_declarator.type = TYPEDEC_NESTED;
		parent->u.type_declarator.u.nested.type_declarator = node;
		break;
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
		cds_list_add(&node->siblings, &parent->u.struct_or_variant_declaration.type_declarators);
		break;
	case NODE_TYPEDEF:
		cds_list_add(&node->siblings, &parent->u._typedef.type_declarators);
		break;
	case NODE_TYPEALIAS_TARGET:
		cds_list_add(&node->siblings, &parent->u.typealias_target.type_declarators);
		break;
	case NODE_TYPEALIAS_ALIAS:
		cds_list_add(&node->siblings, &parent->u.typealias_alias.type_declarators);
		break;

	case NODE_ROOT:
	case NODE_EVENT:
	case NODE_STREAM:
	case NODE_TRACE:
	case NODE_VARIANT:
	case NODE_STRUCT:
	case NODE_TYPEALIAS:
	case NODE_ENUM:
	case NODE_FLOATING_POINT:
	case NODE_INTEGER:
	case NODE_STRING:
	case NODE_CTF_EXPRESSION:
	case NODE_TYPE_SPECIFIER:
	case NODE_POINTER:
	case NODE_ENUMERATOR:
	case NODE_UNARY_EXPRESSION:
		return -EPERM;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) parent->type);
		return -EINVAL;
	}
	return 0;
}

/*
 * reparent node
 *
 * Relink node to new parent. Returns 0 on success, -EPERM if it is not
 * permitted to create the link declared by the input, -ENOENT if node or parent
 * is NULL, -EINVAL if there is an internal structure problem.
 */
static int reparent_node(struct ctf_node *node,
			 struct ctf_node *parent)
{
	if (!node || !parent)
		return -ENOENT;

	/* Unlink from old parent */
	cds_list_del(&node->siblings);

	/* Note: Linking to parent will be done only by an external visitor */

	switch (node->type) {
	case NODE_ROOT:
		fprintf(stderr, "[error] %s: trying to reparent root node\n", __func__);
		return -EINVAL;

	case NODE_EVENT:
		if (parent->type == NODE_ROOT)
			cds_list_add_tail(&node->siblings, &parent->u.root.event);
		else
			return -EPERM;
		break;
	case NODE_STREAM:
		if (parent->type == NODE_ROOT)
			cds_list_add_tail(&node->siblings, &parent->u.root.stream);
		else
			return -EPERM;
		break;
	case NODE_TRACE:
		if (parent->type == NODE_ROOT)
			cds_list_add_tail(&node->siblings, &parent->u.root.trace);
		else
			return -EPERM;
		break;

	case NODE_CTF_EXPRESSION:
		return reparent_ctf_expression(node, parent);
	case NODE_UNARY_EXPRESSION:
		if (parent->type == NODE_TYPE_DECLARATOR)
			parent->u.type_declarator.bitfield_len = node;
		else
			return -EPERM;
		break;

	case NODE_TYPEDEF:
		return reparent_typedef(node, parent);
	case NODE_TYPEALIAS_TARGET:
		if (parent->type == NODE_TYPEALIAS)
			parent->u.typealias.target = node;
		else
			return -EINVAL;
	case NODE_TYPEALIAS_ALIAS:
		if (parent->type == NODE_TYPEALIAS)
			parent->u.typealias.alias = node;
		else
			return -EINVAL;
	case NODE_TYPEALIAS:
		return reparent_typealias(node, parent);

	case NODE_POINTER:
		if (parent->type == NODE_TYPE_DECLARATOR)
			cds_list_add_tail(&node->siblings, &parent->u.type_declarator.pointers);
		else
			return -EPERM;
		break;
	case NODE_TYPE_DECLARATOR:
		return reparent_type_declarator(node, parent);

	case NODE_TYPE_SPECIFIER:
	case NODE_FLOATING_POINT:
	case NODE_INTEGER:
	case NODE_STRING:
	case NODE_ENUM:
	case NODE_VARIANT:
	case NODE_STRUCT:
		return reparent_type_specifier(node, parent);

	case NODE_ENUMERATOR:
		if (parent->type == NODE_ENUM)
			cds_list_add_tail(&node->siblings, &parent->u._enum.enumerator_list);
		else
			return -EPERM;
		break;
	case NODE_STRUCT_OR_VARIANT_DECLARATION:
		switch (parent->type) {
		case NODE_STRUCT:
			cds_list_add_tail(&node->siblings, &parent->u.variant.declaration_list);
			break;
		case NODE_VARIANT:
			cds_list_add_tail(&node->siblings, &parent->u._struct.declaration_list);
			break;
		default:
			return -EINVAL;
		}
		break;

	case NODE_UNKNOWN:
	default:
		fprintf(stderr, "[error] %s: unknown node type %d\n", __func__,
			(int) parent->type);
		return -EINVAL;
	}
	return 0;
}

void yyerror(struct ctf_scanner *scanner, const char *str)
{
	fprintf(stderr, "error %s\n", str);
}
 
int yywrap(void)
{
	return 1;
} 

#define reparent_error(scanner, str)				\
do {								\
	yyerror(scanner, YY_("reparent_error: " str "\n"));	\
	YYERROR;						\
} while (0)

static void free_strings(struct cds_list_head *list)
{
	struct gc_string *gstr, *tmp;

	cds_list_for_each_entry_safe(gstr, tmp, list, gc)
		free(gstr);
}

static struct ctf_ast *ctf_ast_alloc(void)
{
	struct ctf_ast *ast;

	ast = malloc(sizeof(*ast));
	if (!ast)
		return NULL;
	memset(ast, 0, sizeof(*ast));
	CDS_INIT_LIST_HEAD(&ast->allocated_nodes);
	ast->root.type = NODE_ROOT;
	CDS_INIT_LIST_HEAD(&ast->root.siblings);
	CDS_INIT_LIST_HEAD(&ast->root.u.root._typedef);
	CDS_INIT_LIST_HEAD(&ast->root.u.root.typealias);
	CDS_INIT_LIST_HEAD(&ast->root.u.root.declaration_specifier);
	CDS_INIT_LIST_HEAD(&ast->root.u.root.trace);
	CDS_INIT_LIST_HEAD(&ast->root.u.root.stream);
	CDS_INIT_LIST_HEAD(&ast->root.u.root.event);
	return ast;
}

static void ctf_ast_free(struct ctf_ast *ast)
{
	struct ctf_node *node, *tmp;

	cds_list_for_each_entry_safe(node, tmp, &ast->allocated_nodes, gc)
		free(node);
}

int ctf_scanner_append_ast(struct ctf_scanner *scanner)
{
	return yyparse(scanner);
}

struct ctf_scanner *ctf_scanner_alloc(FILE *input)
{
	struct ctf_scanner *scanner;
	int ret;

	scanner = malloc(sizeof(*scanner));
	if (!scanner)
		return NULL;
	memset(scanner, 0, sizeof(*scanner));

	ret = yylex_init_extra(scanner, &scanner->scanner);
	if (ret) {
		fprintf(stderr, "yylex_init error\n");
		goto cleanup_scanner;
	}
	yyset_in(input, scanner);

	scanner->ast = ctf_ast_alloc();
	if (!scanner->ast)
		goto cleanup_lexer;
	init_scope(&scanner->root_scope, NULL);
	scanner->cs = &scanner->root_scope;
	CDS_INIT_LIST_HEAD(&scanner->allocated_strings);

	return scanner;

cleanup_lexer:
	ret = yylex_destroy(scanner->scanner);
	if (!ret)
		fprintf(stderr, "yylex_destroy error\n");
cleanup_scanner:
	free(scanner);
	return NULL;
}

void ctf_scanner_free(struct ctf_scanner *scanner)
{
	int ret;

	finalize_scope(&scanner->root_scope);
	free_strings(&scanner->allocated_strings);
	ctf_ast_free(scanner->ast);
	ret = yylex_destroy(scanner->scanner);
	if (ret)
		fprintf(stderr, "yylex_destroy error\n");
	free(scanner);
}

%}

%define api.pure
	/* %locations */
%parse-param {struct ctf_scanner *scanner}
%lex-param {struct ctf_scanner *scanner}
%start file
%token CHARACTER_CONSTANT_START SQUOTE STRING_LITERAL_START DQUOTE ESCSEQ CHAR_STRING_TOKEN LSBRAC RSBRAC LPAREN RPAREN LBRAC RBRAC RARROW STAR PLUS MINUS LT GT TYPEASSIGN COLON SEMICOLON DOTDOTDOT DOT EQUAL COMMA CONST CHAR DOUBLE ENUM EVENT FLOATING_POINT FLOAT INTEGER INT LONG SHORT SIGNED STREAM STRING STRUCT TRACE TYPEALIAS TYPEDEF UNSIGNED VARIANT VOID _BOOL _COMPLEX _IMAGINARY DECIMAL_CONSTANT OCTAL_CONSTANT HEXADECIMAL_CONSTANT
%token <gs> IDENTIFIER ID_TYPE
%token ERROR
%union
{
	long long ll;
	char c;
	struct gc_string *gs;
	struct ctf_node *n;
}

%type <gs> keywords
%type <gs> s_char s_char_sequence c_char c_char_sequence

%type <n> postfix_expression unary_expression unary_expression_or_range

%type <n> declaration
%type <n> event_declaration
%type <n> stream_declaration
%type <n> trace_declaration
%type <n> declaration_specifiers

%type <n> type_declarator_list
%type <n> abstract_type_declarator_list
%type <n> type_specifier
%type <n> struct_type_specifier
%type <n> variant_type_specifier
%type <n> type_specifier_or_integer_constant
%type <n> enum_type_specifier
%type <n> struct_or_variant_declaration_list
%type <n> struct_or_variant_declaration
%type <n> specifier_qualifier_list
%type <n> struct_or_variant_declarator_list
%type <n> struct_or_variant_declarator
%type <n> enumerator_list
%type <n> enumerator
%type <n> abstract_declarator_list
%type <n> abstract_declarator
%type <n> direct_abstract_declarator
%type <n> declarator
%type <n> direct_declarator
%type <n> type_declarator
%type <n> direct_type_declarator
%type <n> abstract_type_declarator
%type <n> direct_abstract_type_declarator
%type <n> pointer	
%type <n> ctf_assignment_expression_list
%type <n> ctf_assignment_expression

%%

file:
		declaration
		{
			if (reparent_node($1, &ctf_scanner_get_ast(scanner)->root))
				reparent_error(scanner, "error reparenting to root");
		}
	|	file declaration
		{
			if (reparent_node($2, &ctf_scanner_get_ast(scanner)->root))
				reparent_error(scanner, "error reparenting to root");
		}
	;

keywords:
		VOID
		{	$$ = yylval.gs;		}
	|	CHAR
		{	$$ = yylval.gs;		}
	|	SHORT
		{	$$ = yylval.gs;		}
	|	INT
		{	$$ = yylval.gs;		}
	|	LONG
		{	$$ = yylval.gs;		}
	|	FLOAT
		{	$$ = yylval.gs;		}
	|	DOUBLE
		{	$$ = yylval.gs;		}
	|	SIGNED
		{	$$ = yylval.gs;		}
	|	UNSIGNED
		{	$$ = yylval.gs;		}
	|	_BOOL
		{	$$ = yylval.gs;		}
	|	_COMPLEX
		{	$$ = yylval.gs;		}
	|	FLOATING_POINT
		{	$$ = yylval.gs;		}
	|	INTEGER
		{	$$ = yylval.gs;		}
	|	STRING
		{	$$ = yylval.gs;		}
	|	ENUM
		{	$$ = yylval.gs;		}
	|	VARIANT
		{	$$ = yylval.gs;		}
	|	STRUCT
		{	$$ = yylval.gs;		}
	|	CONST
		{	$$ = yylval.gs;		}
	|	TYPEDEF
		{	$$ = yylval.gs;		}
	|	EVENT
		{	$$ = yylval.gs;		}
	|	STREAM
		{	$$ = yylval.gs;		}
	|	TRACE
		{	$$ = yylval.gs;		}
	;

/* 1.5 Constants */

c_char_sequence:
		c_char
		{	$$ = $1;					}
	|	c_char_sequence c_char
		{	$$ = gc_string_append(scanner, $1, $2);		}
	;

c_char:
		CHAR_STRING_TOKEN
		{	$$ = yylval.gs;					}
	|	ESCSEQ
		{
			reparent_error(scanner, "escape sequences not supported yet");
		}
	;

/* 1.6 String literals */

s_char_sequence:
		s_char
		{	$$ = $1;					}
	|	s_char_sequence s_char
		{	$$ = gc_string_append(scanner, $1, $2);		}
	;

s_char:
		CHAR_STRING_TOKEN
		{	$$ = yylval.gs;					}
	|	ESCSEQ
		{
			reparent_error(scanner, "escape sequences not supported yet");
		}
	;

/* 2: Phrase structure grammar */

postfix_expression:
		IDENTIFIER
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
		}
	|	ID_TYPE
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
		}

	|	keywords
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
		}

	|	DECIMAL_CONSTANT
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_UNSIGNED_CONSTANT;
			sscanf(yylval.gs->s, "%llu",
			       &$$->u.unary_expression.u.unsigned_constant);
		}
	|	OCTAL_CONSTANT
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_UNSIGNED_CONSTANT;
			sscanf(yylval.gs->s, "0%llo",
			       &$$->u.unary_expression.u.unsigned_constant);
		}
	|	HEXADECIMAL_CONSTANT
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_UNSIGNED_CONSTANT;
			sscanf(yylval.gs->s, "0x%llx",
			       &$$->u.unary_expression.u.unsigned_constant);
		}
	|	STRING_LITERAL_START DQUOTE
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = "";
		}
	|	STRING_LITERAL_START s_char_sequence DQUOTE
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = $2->s;
		}
	|	CHARACTER_CONSTANT_START c_char_sequence SQUOTE
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = $2->s;
		}
	|	LPAREN unary_expression RPAREN
		{
			$$ = $2;
		}
	|	postfix_expression LSBRAC unary_expression RSBRAC
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_SBRAC;
			$$->u.unary_expression.u.sbrac_exp = $3;
			cds_list_add(&($$)->siblings, &($1)->siblings);
		}
	|	postfix_expression DOT IDENTIFIER
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
			$$->u.unary_expression.link = UNARY_DOTLINK;
			cds_list_add(&($$)->siblings, &($1)->siblings);
		}
	|	postfix_expression DOT ID_TYPE
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
			$$->u.unary_expression.link = UNARY_DOTLINK;
			cds_list_add(&($$)->siblings, &($1)->siblings);
		}
	|	postfix_expression RARROW IDENTIFIER
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
			$$->u.unary_expression.link = UNARY_ARROWLINK;
			cds_list_add(&($$)->siblings, &($1)->siblings);
		}
	|	postfix_expression RARROW ID_TYPE
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_STRING;
			$$->u.unary_expression.u.string = yylval.gs->s;
			$$->u.unary_expression.link = UNARY_ARROWLINK;
			cds_list_add(&($$)->siblings, &($1)->siblings);
		}
	;

unary_expression:
		postfix_expression
		{	$$ = $1;				}
	|	PLUS postfix_expression
		{	$$ = $2;				}
	|	MINUS postfix_expression
		{
			$$ = $2;
			if ($$->u.unary_expression.type != UNARY_SIGNED_CONSTANT
				&& $$->u.unary_expression.type != UNARY_UNSIGNED_CONSTANT)
				reparent_error(scanner, "expecting numeric constant");

			if ($$->u.unary_expression.type == UNARY_UNSIGNED_CONSTANT) {
				$$->u.unary_expression.type = UNARY_SIGNED_CONSTANT;
				$$->u.unary_expression.u.signed_constant =
					-($$->u.unary_expression.u.unsigned_constant);
			} else {
				$$->u.unary_expression.u.signed_constant =
					-($$->u.unary_expression.u.signed_constant);
			}
		}
	;

unary_expression_or_range:
		unary_expression DOTDOTDOT unary_expression
		{
			$$ = $1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	|	unary_expression
		{	$$ = $1;		}
	;

/* 2.2: Declarations */

declaration:
		declaration_specifiers SEMICOLON
		{	$$ = $1;	}
	|	event_declaration
		{	$$ = $1;	}
	|	stream_declaration
		{	$$ = $1;	}
	|	trace_declaration
		{	$$ = $1;	}
	|	declaration_specifiers TYPEDEF declaration_specifiers type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($1)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($4)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	TYPEDEF declaration_specifiers type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($2)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	declaration_specifiers TYPEDEF type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($1)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	TYPEALIAS declaration_specifiers abstract_declarator_list COLON declaration_specifiers abstract_type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEALIAS);
			$$->u.typealias.target = make_node(scanner, NODE_TYPEALIAS_TARGET);
			$$->u.typealias.alias = make_node(scanner, NODE_TYPEALIAS_ALIAS);
			cds_list_add(&($2)->siblings, &($$)->u.typealias.target->u.typealias_target.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u.typealias.target->u.typealias_target.type_declarators);
			cds_list_add(&($5)->siblings, &($$)->u.typealias.alias->u.typealias_alias.declaration_specifier);
			cds_list_add(&($6)->siblings, &($$)->u.typealias.alias->u.typealias_alias.type_declarators);
		}
	|	TYPEALIAS declaration_specifiers abstract_declarator_list COLON type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEALIAS);
			$$->u.typealias.target = make_node(scanner, NODE_TYPEALIAS_TARGET);
			$$->u.typealias.alias = make_node(scanner, NODE_TYPEALIAS_ALIAS);
			cds_list_add(&($2)->siblings, &($$)->u.typealias.target->u.typealias_target.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u.typealias.target->u.typealias_target.type_declarators);
			cds_list_add(&($5)->siblings, &($$)->u.typealias.alias->u.typealias_alias.type_declarators);
		}
	;

event_declaration:
		event_declaration_begin event_declaration_end
		{	$$ = make_node(scanner, NODE_EVENT);	}
	|	event_declaration_begin ctf_assignment_expression_list event_declaration_end
		{
			$$ = make_node(scanner, NODE_EVENT);
			if (reparent_node($2, $$))
				reparent_error(scanner, "event_declaration");
		}
	;

event_declaration_begin:
		EVENT LBRAC
		{	push_scope(scanner);	}
	;

event_declaration_end:
		RBRAC SEMICOLON
		{	pop_scope(scanner);	}
	;


stream_declaration:
		stream_declaration_begin stream_declaration_end
		{	$$ = make_node(scanner, NODE_STREAM);	}
	|	stream_declaration_begin ctf_assignment_expression_list stream_declaration_end
		{
			$$ = make_node(scanner, NODE_STREAM);
			if (reparent_node($2, $$))
				reparent_error(scanner, "stream_declaration");
		}
	;

stream_declaration_begin:
		STREAM LBRAC
		{	push_scope(scanner);	}
	;

stream_declaration_end:
		RBRAC SEMICOLON
		{	pop_scope(scanner);	}
	;


trace_declaration:
		trace_declaration_begin trace_declaration_end
		{	$$ = make_node(scanner, NODE_TRACE);	}
	|	trace_declaration_begin ctf_assignment_expression_list trace_declaration_end
		{
			$$ = make_node(scanner, NODE_TRACE);
			if (reparent_node($2, $$))
				reparent_error(scanner, "trace_declaration");
		}
	;

trace_declaration_begin:
		TRACE LBRAC
		{	push_scope(scanner);	}
	;

trace_declaration_end:
		RBRAC SEMICOLON
		{	pop_scope(scanner);	}
	;

declaration_specifiers:
		CONST
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_CONST;
		}
	|	type_specifier
		{	$$ = $1;		}
	|	declaration_specifiers CONST
		{
			struct ctf_node *node;

			node = make_node(scanner, NODE_TYPE_SPECIFIER);
			node->u.type_specifier.type = TYPESPEC_CONST;
			cds_list_add(&node->siblings, &($1)->siblings);
			$$ = $1;
		}
	|	declaration_specifiers type_specifier
		{
			$$ = $1;
			cds_list_add(&($2)->siblings, &($1)->siblings);
		}
	;

type_declarator_list:
		type_declarator
		{	$$ = $1;	}
	|	type_declarator_list COMMA type_declarator
		{
			$$ = $1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	;

abstract_type_declarator_list:
		abstract_type_declarator
		{	$$ = $1;	}
	|	abstract_type_declarator_list COMMA abstract_type_declarator
		{
			$$ = $1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	;

type_specifier:
		VOID
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_VOID;
		}
	|	CHAR
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_CHAR;
		}
	|	SHORT
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_SHORT;
		}
	|	INT
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_INT;
		}
	|	LONG
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_LONG;
		}
	|	FLOAT
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_FLOAT;
		}
	|	DOUBLE
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_DOUBLE;
		}
	|	SIGNED
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_SIGNED;
		}
	|	UNSIGNED
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_UNSIGNED;
		}
	|	_BOOL
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_BOOL;
		}
	|	_COMPLEX
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_COMPLEX;
		}
	|	ID_TYPE
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_ID_TYPE;
			$$->u.type_specifier.id_type = yylval.gs->s;
		}
	|	FLOATING_POINT LBRAC RBRAC
		{
			$$ = make_node(scanner, NODE_FLOATING_POINT);
		}
	|	FLOATING_POINT LBRAC ctf_assignment_expression_list RBRAC
		{
			$$ = make_node(scanner, NODE_FLOATING_POINT);
			if (reparent_node($3, $$))
				reparent_error(scanner, "floating point reparent error");
		}
	|	INTEGER LBRAC RBRAC
		{
			$$ = make_node(scanner, NODE_INTEGER);
		}
	|	INTEGER LBRAC ctf_assignment_expression_list RBRAC
		{
			$$ = make_node(scanner, NODE_INTEGER);
			if (reparent_node($3, $$))
				reparent_error(scanner, "integer reparent error");
		}
	|	STRING LBRAC RBRAC
		{
			$$ = make_node(scanner, NODE_STRING);
		}
	|	STRING LBRAC ctf_assignment_expression_list RBRAC
		{
			$$ = make_node(scanner, NODE_STRING);
			if (reparent_node($3, $$))
				reparent_error(scanner, "string reparent error");
		}
	|	ENUM enum_type_specifier
		{	$$ = $2;		}
	|	VARIANT variant_type_specifier
		{	$$ = $2;		}
	|	STRUCT struct_type_specifier
		{	$$ = $2;		}
	;

struct_type_specifier:
		struct_declaration_begin struct_or_variant_declaration_list struct_declaration_end
		{
			$$ = make_node(scanner, NODE_STRUCT);
			if (reparent_node($2, $$))
				reparent_error(scanner, "struct reparent error");
		}
	|	IDENTIFIER struct_declaration_begin struct_or_variant_declaration_list struct_declaration_end
		{
			$$ = make_node(scanner, NODE_STRUCT);
			$$->u._struct.name = $1->s;
			if (reparent_node($3, $$))
				reparent_error(scanner, "struct reparent error");
		}
	|	ID_TYPE struct_declaration_begin struct_or_variant_declaration_list struct_declaration_end
		{
			$$ = make_node(scanner, NODE_STRUCT);
			$$->u._struct.name = $1->s;
			if (reparent_node($3, $$))
				reparent_error(scanner, "struct reparent error");
		}
	|	IDENTIFIER
		{
			$$ = make_node(scanner, NODE_STRUCT);
			$$->u._struct.name = $1->s;
		}
	|	ID_TYPE
		{
			$$ = make_node(scanner, NODE_STRUCT);
			$$->u._struct.name = $1->s;
		}
	;

struct_declaration_begin:
		LBRAC
		{	push_scope(scanner);	}
	;

struct_declaration_end:
		RBRAC
		{	pop_scope(scanner);	}
	;

variant_type_specifier:
		variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			if (reparent_node($2, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	LT IDENTIFIER GT variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.choice = $2->s;
			if (reparent_node($5, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	LT ID_TYPE GT variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.choice = $2->s;
			if (reparent_node($5, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	IDENTIFIER variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			if (reparent_node($3, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	IDENTIFIER LT IDENTIFIER GT variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
			if (reparent_node($6, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	IDENTIFIER LT IDENTIFIER GT
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
		}
	|	IDENTIFIER LT ID_TYPE GT variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
			if (reparent_node($6, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	IDENTIFIER LT ID_TYPE GT
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
		}
	|	ID_TYPE variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			if (reparent_node($3, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	ID_TYPE LT IDENTIFIER GT variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
			if (reparent_node($6, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	ID_TYPE LT IDENTIFIER GT
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
		}
	|	ID_TYPE LT ID_TYPE GT variant_declaration_begin struct_or_variant_declaration_list variant_declaration_end
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
			if (reparent_node($6, $$))
				reparent_error(scanner, "variant reparent error");
		}
	|	ID_TYPE LT ID_TYPE GT
		{
			$$ = make_node(scanner, NODE_VARIANT);
			$$->u.variant.name = $1->s;
			$$->u.variant.choice = $3->s;
		}
	;

variant_declaration_begin:
		LBRAC
		{	push_scope(scanner);	}
	;

variant_declaration_end:
		RBRAC
		{	pop_scope(scanner);	}
	;

type_specifier_or_integer_constant:
		declaration_specifiers
		{	$$ = $1;		}
	|	DECIMAL_CONSTANT
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_UNSIGNED_CONSTANT;
			sscanf(yylval.gs->s, "%llu",
			       &$$->u.unary_expression.u.unsigned_constant);
		}
	|	OCTAL_CONSTANT
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_UNSIGNED_CONSTANT;
			sscanf(yylval.gs->s, "0%llo",
			       &$$->u.unary_expression.u.unsigned_constant);
		}
	|	HEXADECIMAL_CONSTANT
		{
			$$ = make_node(scanner, NODE_UNARY_EXPRESSION);
			$$->u.unary_expression.type = UNARY_UNSIGNED_CONSTANT;
			sscanf(yylval.gs->s, "0x%llx",
			       &$$->u.unary_expression.u.unsigned_constant);
		}
	;

enum_type_specifier:
		LBRAC enumerator_list RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			cds_list_add(&($2)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	LT type_specifier_or_integer_constant GT LBRAC enumerator_list RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.container_type = $2;
			cds_list_add(&($5)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	IDENTIFIER LBRAC enumerator_list RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			cds_list_add(&($3)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	IDENTIFIER LT type_specifier_or_integer_constant GT LBRAC enumerator_list RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			$$->u._enum.container_type = $3;
			cds_list_add(&($6)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	ID_TYPE LBRAC enumerator_list RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			cds_list_add(&($3)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	ID_TYPE LT type_specifier_or_integer_constant GT LBRAC enumerator_list RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			$$->u._enum.container_type = $3;
			cds_list_add(&($6)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	LBRAC enumerator_list COMMA RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			cds_list_add(&($2)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	LT type_specifier_or_integer_constant GT LBRAC enumerator_list COMMA RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.container_type = $2;
			cds_list_add(&($5)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	IDENTIFIER LBRAC enumerator_list COMMA RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			cds_list_add(&($3)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	IDENTIFIER LT type_specifier_or_integer_constant GT LBRAC enumerator_list COMMA RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			$$->u._enum.container_type = $3;
			cds_list_add(&($6)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	IDENTIFIER
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
		}
	|	IDENTIFIER LT type_specifier_or_integer_constant GT
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			$$->u._enum.container_type = $3;
		}
	|	ID_TYPE LBRAC enumerator_list COMMA RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			cds_list_add(&($3)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	ID_TYPE LT type_specifier_or_integer_constant GT LBRAC enumerator_list COMMA RBRAC
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			$$->u._enum.container_type = $3;
			cds_list_add(&($6)->siblings, &($$)->u._enum.enumerator_list);
		}
	|	ID_TYPE
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
		}
	|	ID_TYPE LT type_specifier_or_integer_constant GT
		{
			$$ = make_node(scanner, NODE_ENUM);
			$$->u._enum.enum_id = $1->s;
			$$->u._enum.container_type = $3;
		}
	;

struct_or_variant_declaration_list:
		/* empty */
		{	$$ = NULL;	}
	|	struct_or_variant_declaration_list struct_or_variant_declaration
		{
			if ($1) {
				$$ = $1;
				cds_list_add(&($2)->siblings, &($1)->siblings);
			} else {
				$$ = $2;
			}
		}
	;

struct_or_variant_declaration:
		specifier_qualifier_list struct_or_variant_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_STRUCT_OR_VARIANT_DECLARATION);
			cds_list_add(&($1)->siblings, &($$)->u.struct_or_variant_declaration.declaration_specifier);
			cds_list_add(&($2)->siblings, &($$)->u.struct_or_variant_declaration.type_declarators);
		}
	|	specifier_qualifier_list TYPEDEF specifier_qualifier_list type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($1)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($4)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	TYPEDEF specifier_qualifier_list type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($2)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	specifier_qualifier_list TYPEDEF type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($1)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	TYPEALIAS specifier_qualifier_list abstract_declarator_list COLON specifier_qualifier_list abstract_type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEALIAS);
			$$->u.typealias.target = make_node(scanner, NODE_TYPEALIAS_TARGET);
			$$->u.typealias.alias = make_node(scanner, NODE_TYPEALIAS_ALIAS);
			cds_list_add(&($2)->siblings, &($$)->u.typealias.target->u.typealias_target.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u.typealias.target->u.typealias_target.type_declarators);
			cds_list_add(&($5)->siblings, &($$)->u.typealias.alias->u.typealias_alias.declaration_specifier);
			cds_list_add(&($6)->siblings, &($$)->u.typealias.alias->u.typealias_alias.type_declarators);
		}
	|	TYPEALIAS specifier_qualifier_list abstract_declarator_list COLON type_declarator_list SEMICOLON
		{
			$$ = make_node(scanner, NODE_TYPEALIAS);
			$$->u.typealias.target = make_node(scanner, NODE_TYPEALIAS_TARGET);
			$$->u.typealias.alias = make_node(scanner, NODE_TYPEALIAS_ALIAS);
			cds_list_add(&($2)->siblings, &($$)->u.typealias.target->u.typealias_target.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u.typealias.target->u.typealias_target.type_declarators);
			cds_list_add(&($5)->siblings, &($$)->u.typealias.alias->u.typealias_alias.type_declarators);
		}
	;

specifier_qualifier_list:
		CONST
		{
			$$ = make_node(scanner, NODE_TYPE_SPECIFIER);
			$$->u.type_specifier.type = TYPESPEC_CONST;
		}
	|	type_specifier
		{	$$ = $1;	}
	|	specifier_qualifier_list CONST
		{
			struct ctf_node *node;

			$$ = $1;
			node = make_node(scanner, NODE_TYPE_SPECIFIER);
			node->u.type_specifier.type = TYPESPEC_CONST;
			cds_list_add(&node->siblings, &($$)->siblings);
		}
	|	specifier_qualifier_list type_specifier
		{
			$$ = $1;
			cds_list_add(&($2)->siblings, &($$)->siblings);
		}
	;

struct_or_variant_declarator_list:
		struct_or_variant_declarator
		{	$$ = $1;	}
	|	struct_or_variant_declarator_list COMMA struct_or_variant_declarator
		{
			$$ = $1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	;

struct_or_variant_declarator:
		declarator
		{	$$ = $1;	}
	|	COLON unary_expression
		{	$$ = $2;	}
	|	declarator COLON unary_expression
		{
			$$ = $1;
			if (reparent_node($3, $1))
				reparent_error(scanner, "struct_or_variant_declarator");
		}
	;

enumerator_list:
		enumerator
		{	$$ = $1;	}
	|	enumerator_list COMMA enumerator
		{
			$$ = $1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	;

enumerator:
		IDENTIFIER
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $1->s;
		}
	|	ID_TYPE
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $1->s;
		}
	|	keywords
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $1->s;
		}
	|	STRING_LITERAL_START DQUOTE
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = "";
		}
	|	STRING_LITERAL_START s_char_sequence DQUOTE
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $2->s;
		}
	|	IDENTIFIER EQUAL unary_expression_or_range
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $1->s;
			$$->u.enumerator.values = $3;
		}
	|	ID_TYPE EQUAL unary_expression_or_range
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $1->s;
			$$->u.enumerator.values = $3;
		}
	|	keywords EQUAL unary_expression_or_range
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $1->s;
			$$->u.enumerator.values = $3;
		}
	|	STRING_LITERAL_START DQUOTE EQUAL unary_expression_or_range
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = "";
			$$->u.enumerator.values = $4;
		}
	|	STRING_LITERAL_START s_char_sequence DQUOTE EQUAL unary_expression_or_range
		{
			$$ = make_node(scanner, NODE_ENUMERATOR);
			$$->u.enumerator.id = $2->s;
			$$->u.enumerator.values = $5;
		}
	;

abstract_declarator_list:
		abstract_declarator
		{	$$ = $1;	}
	|	abstract_declarator_list COMMA abstract_declarator
		{
			$$ = $1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	;

abstract_declarator:
		direct_abstract_declarator
		{	$$ = $1;	}
	|	pointer direct_abstract_declarator
		{
			$$ = $2;
			cds_list_add(&($1)->siblings, &($$)->u.type_declarator.pointers);
		}
	;

direct_abstract_declarator:
		/* empty */
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
                        $$->u.type_declarator.type = TYPEDEC_ID;
			/* id is NULL */
		}
	|	IDENTIFIER
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_ID;
			$$->u.type_declarator.u.id = $1->s;
		}
	|	LPAREN abstract_declarator RPAREN
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $2;
		}
	|	direct_abstract_declarator LSBRAC type_specifier_or_integer_constant RSBRAC
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $1;
			$$->u.type_declarator.u.nested.length = $3;
		}
	|	direct_abstract_declarator LSBRAC RSBRAC
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $1;
			$$->u.type_declarator.u.nested.abstract_array = 1;
		}
	;

declarator:
		direct_declarator
		{	$$ = $1;	}
	|	pointer direct_declarator
		{
			$$ = $2;
			cds_list_add(&($1)->siblings, &($$)->u.type_declarator.pointers);
		}
	;

direct_declarator:
		IDENTIFIER
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_ID;
			$$->u.type_declarator.u.id = $1->s;
		}
	|	LPAREN declarator RPAREN
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $2;
		}
	|	direct_declarator LSBRAC type_specifier_or_integer_constant RSBRAC
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $1;
			$$->u.type_declarator.u.nested.length = $3;
		}
	;

type_declarator:
		direct_type_declarator
		{	$$ = $1;	}
	|	pointer direct_type_declarator
		{
			$$ = $2;
			cds_list_add(&($1)->siblings, &($$)->u.type_declarator.pointers);
		}
	;

direct_type_declarator:
		IDENTIFIER
		{
			add_type(scanner, $1);
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_ID;
			$$->u.type_declarator.u.id = $1->s;
		}
	|	LPAREN type_declarator RPAREN
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $2;
		}
	|	direct_type_declarator LSBRAC type_specifier_or_integer_constant RSBRAC
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $1;
			$$->u.type_declarator.u.nested.length = $3;
		}
	;

abstract_type_declarator:
		direct_abstract_type_declarator
		{	$$ = $1;	}
	|	pointer direct_abstract_type_declarator
		{
			$$ = $2;
			cds_list_add(&($1)->siblings, &($$)->u.type_declarator.pointers);
		}
	;

direct_abstract_type_declarator:
		/* empty */
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
                        $$->u.type_declarator.type = TYPEDEC_ID;
			/* id is NULL */
		}
	|	IDENTIFIER
		{
			add_type(scanner, $1);
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_ID;
			$$->u.type_declarator.u.id = $1->s;
		}
	|	LPAREN abstract_type_declarator RPAREN
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $2;
		}
	|	direct_abstract_type_declarator LSBRAC type_specifier_or_integer_constant RSBRAC
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $1;
			$$->u.type_declarator.u.nested.length = $3;
		}
	|	direct_abstract_type_declarator LSBRAC RSBRAC
		{
			$$ = make_node(scanner, NODE_TYPE_DECLARATOR);
			$$->u.type_declarator.type = TYPEDEC_NESTED;
			$$->u.type_declarator.u.nested.type_declarator = $1;
			$$->u.type_declarator.u.nested.abstract_array = 1;
		}
	;

pointer:	
		STAR
		{	$$ = make_node(scanner, NODE_POINTER);		}
	|	STAR pointer
		{
			$$ = make_node(scanner, NODE_POINTER);
			cds_list_add(&($2)->siblings, &($$)->siblings);
		}
	|	STAR type_qualifier_list pointer
		{
			$$ = make_node(scanner, NODE_POINTER);
			$$->u.pointer.const_qualifier = 1;
			cds_list_add(&($3)->siblings, &($$)->siblings);
		}
	;

type_qualifier_list:
		/* pointer assumes only const type qualifier */
		CONST
	|	type_qualifier_list CONST
	;

/* 2.3: CTF-specific declarations */

ctf_assignment_expression_list:
		ctf_assignment_expression SEMICOLON
		{	$$ = $1;	}
	|	ctf_assignment_expression_list ctf_assignment_expression SEMICOLON
		{
			$$ = $1;
			cds_list_add(&($2)->siblings, &($1)->siblings);
		}
	;

ctf_assignment_expression:
		unary_expression EQUAL unary_expression
		{
			/*
			 * Because we have left and right, cannot use
			 * reparent_node.
			 */
			$$ = make_node(scanner, NODE_CTF_EXPRESSION);
			$$->u.ctf_expression.left = $1;
			if ($1->u.unary_expression.type != UNARY_STRING)
				reparent_error(scanner, "ctf_assignment_expression left expects string");
			$$->u.ctf_expression.right = $3;
		}
	|	unary_expression TYPEASSIGN type_specifier
		{
			/*
			 * Because we have left and right, cannot use
			 * reparent_node.
			 */
			$$ = make_node(scanner, NODE_CTF_EXPRESSION);
			$$->u.ctf_expression.left = $1;
			if ($1->u.unary_expression.type != UNARY_STRING)
				reparent_error(scanner, "ctf_assignment_expression left expects string");
			$$->u.ctf_expression.right = $3;
		}
	|	declaration_specifiers TYPEDEF declaration_specifiers type_declarator_list
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($1)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($4)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	TYPEDEF declaration_specifiers type_declarator_list
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($2)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	declaration_specifiers TYPEDEF type_declarator_list
		{
			$$ = make_node(scanner, NODE_TYPEDEF);
			cds_list_add(&($1)->siblings, &($$)->u._typedef.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u._typedef.type_declarators);
		}
	|	TYPEALIAS declaration_specifiers abstract_declarator_list COLON declaration_specifiers abstract_type_declarator_list
		{
			$$ = make_node(scanner, NODE_TYPEALIAS);
			$$->u.typealias.target = make_node(scanner, NODE_TYPEALIAS_TARGET);
			$$->u.typealias.alias = make_node(scanner, NODE_TYPEALIAS_ALIAS);
			cds_list_add(&($2)->siblings, &($$)->u.typealias.target->u.typealias_target.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u.typealias.target->u.typealias_target.type_declarators);
			cds_list_add(&($5)->siblings, &($$)->u.typealias.alias->u.typealias_alias.declaration_specifier);
			cds_list_add(&($6)->siblings, &($$)->u.typealias.alias->u.typealias_alias.type_declarators);
		}
	|	TYPEALIAS declaration_specifiers abstract_declarator_list COLON type_declarator_list
		{
			$$ = make_node(scanner, NODE_TYPEALIAS);
			$$->u.typealias.target = make_node(scanner, NODE_TYPEALIAS_TARGET);
			$$->u.typealias.alias = make_node(scanner, NODE_TYPEALIAS_ALIAS);
			cds_list_add(&($2)->siblings, &($$)->u.typealias.target->u.typealias_target.declaration_specifier);
			cds_list_add(&($3)->siblings, &($$)->u.typealias.target->u.typealias_target.type_declarators);
			cds_list_add(&($5)->siblings, &($$)->u.typealias.alias->u.typealias_alias.type_declarators);
		}
	;
