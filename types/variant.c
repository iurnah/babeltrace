/*
 * variant.c
 *
 * BabelTrace - Variant Type Converter
 *
 * Copyright 2011 - Mathieu Desnoyers <mathieu.desnoyers@efficios.com>
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

#include <babeltrace/compiler.h>
#include <babeltrace/format.h>
#include <errno.h>

static
struct definition *_variant_definition_new(struct declaration *declaration,
				struct definition_scope *parent_scope,
				GQuark field_name, int index);
static
void _variant_definition_free(struct definition *definition);

void variant_copy(struct stream_pos *dest, const struct format *fdest, 
		  struct stream_pos *src, const struct format *fsrc,
		  struct definition *definition)
{
	struct definition_variant *variant =
		container_of(definition, struct definition_variant, p);
	struct declaration_variant *variant_declaration = variant->declaration;
	struct field *field;
	struct declaration *field_declaration;

	fsrc->variant_begin(src, variant_declaration);
	if (fdest)
		fdest->variant_begin(dest, variant_declaration);

	field = variant_get_current_field(variant);
	field_declaration = field->definition->declaration;
	field_declaration->copy(dest, fdest, src, fsrc, field->definition);

	fsrc->variant_end(src, variant_declaration);
	if (fdest)
		fdest->variant_end(dest, variant_declaration);
}

static
void _untagged_variant_declaration_free(struct declaration *declaration)
{
	struct declaration_untagged_variant *untagged_variant_declaration =
		container_of(declaration, struct declaration_untagged_variant, p);
	unsigned long i;

	free_declaration_scope(untagged_variant_declaration->scope);
	g_hash_table_destroy(untagged_variant_declaration->fields_by_tag);

	for (i = 0; i < untagged_variant_declaration->fields->len; i++) {
		struct declaration_field *declaration_field =
			&g_array_index(untagged_variant_declaration->fields,
				       struct declaration_field, i);
		declaration_unref(declaration_field->declaration);
	}
	g_array_free(untagged_variant_declaration->fields, true);
	g_free(untagged_variant_declaration);
}

struct declaration_untagged_variant *untagged_variant_declaration_new(
				      struct declaration_scope *parent_scope)
{
	struct declaration_untagged_variant *untagged_variant_declaration;
	struct declaration *declaration;

	untagged_variant_declaration = g_new(struct declaration_untagged_variant, 1);
	declaration = &untagged_variant_declaration->p;
	untagged_variant_declaration->fields_by_tag = g_hash_table_new(g_direct_hash,
						       g_direct_equal);
	untagged_variant_declaration->fields = g_array_sized_new(FALSE, TRUE,
						 sizeof(struct declaration_field),
						 DEFAULT_NR_STRUCT_FIELDS);
	untagged_variant_declaration->scope = new_declaration_scope(parent_scope);
	declaration->id = CTF_TYPE_UNTAGGED_VARIANT;
	declaration->alignment = 1;
	declaration->copy = NULL;
	declaration->declaration_free = _untagged_variant_declaration_free;
	declaration->definition_new = NULL;
	declaration->definition_free = NULL;
	declaration->ref = 1;
	return untagged_variant_declaration;
}

static
void _variant_declaration_free(struct declaration *declaration)
{
	struct declaration_variant *variant_declaration =
		container_of(declaration, struct declaration_variant, p);

	_untagged_variant_declaration_free(&variant_declaration->untagged_variant->p);
	g_array_free(variant_declaration->tag_name, TRUE);
}

struct declaration_variant *
	variant_declaration_new(struct declaration_untagged_variant *untagged_variant, const char *tag)
{
	struct declaration_variant *variant_declaration;
	struct declaration *declaration;

	variant_declaration = g_new(struct declaration_variant, 1);
	declaration = &variant_declaration->p;
	variant_declaration->untagged_variant = untagged_variant;
	variant_declaration->tag_name = g_array_new(FALSE, TRUE, sizeof(GQuark));
	append_scope_path(tag, variant_declaration->tag_name);
	declaration->id = CTF_TYPE_VARIANT;
	declaration->alignment = 1;
	declaration->copy = variant_copy;
	declaration->declaration_free = _variant_declaration_free;
	declaration->definition_new = _variant_definition_new;
	declaration->definition_free = _variant_definition_free;
	declaration->ref = 1;
	return variant_declaration;
}

/*
 * tag_instance is assumed to be an enumeration.
 * Returns 0 if OK, < 0 if error.
 */
static
int check_enum_tag(struct definition_variant *variant,
		   struct definition *enum_tag)
{
	struct definition_enum *_enum =
		container_of(enum_tag, struct definition_enum, p);
	struct declaration_enum *enum_declaration = _enum->declaration;
	int missing_field = 0;
	unsigned long i;

	/*
	 * Strictly speaking, each enumerator must map to a field of the
	 * variant. However, we are even stricter here by requiring that each
	 * variant choice map to an enumerator too. We then validate that the
	 * number of enumerators equals the number of variant choices.
	 */
	if (variant->declaration->untagged_variant->fields->len != enum_get_nr_enumerators(enum_declaration))
		return -EPERM;

	for (i = 0; i < variant->declaration->untagged_variant->fields->len; i++) {
		struct declaration_field *field_declaration =
			&g_array_index(variant->declaration->untagged_variant->fields,
				       struct declaration_field, i);
		if (!enum_quark_to_range_set(enum_declaration, field_declaration->name)) {
			missing_field = 1;
			break;
		}
	}
	if (missing_field)
		return -EPERM;

	/*
	 * Check the enumeration: it must map each value to one and only one
	 * enumerator tag.
	 * TODO: we should also check that each range map to one and only one
	 * tag. For the moment, we will simply check this dynamically in
	 * variant_declaration_get_current_field().
	 */
	return 0;
}



static
struct definition *
	_variant_definition_new(struct declaration *declaration,
				struct definition_scope *parent_scope,
				GQuark field_name, int index)
{
	struct declaration_variant *variant_declaration =
		container_of(declaration, struct declaration_variant, p);
	struct definition_variant *variant;
	unsigned long i;

	variant = g_new(struct definition_variant, 1);
	declaration_ref(&variant_declaration->p);
	variant->p.declaration = declaration;
	variant->declaration = variant_declaration;
	variant->p.ref = 1;
	variant->p.index = index;
	variant->scope = new_definition_scope(parent_scope, field_name);
	variant->enum_tag = lookup_definition(variant->scope->scope_path,
					      variant_declaration->tag_name,
					      parent_scope);
					      
	if (!variant->enum_tag
	    || check_enum_tag(variant, variant->enum_tag) < 0)
		goto error;
	definition_ref(variant->enum_tag);
	variant->fields = g_array_sized_new(FALSE, TRUE,
					    sizeof(struct field),
					    variant_declaration->untagged_variant->fields->len);
	g_array_set_size(variant->fields, variant_declaration->untagged_variant->fields->len);
	for (i = 0; i < variant_declaration->untagged_variant->fields->len; i++) {
		struct declaration_field *declaration_field =
			&g_array_index(variant_declaration->untagged_variant->fields,
				       struct declaration_field, i);
		struct field *field = &g_array_index(variant->fields,
						     struct field, i);

		field->name = declaration_field->name;
		/*
		 * All child definition are at index 0, because they are
		 * various choices of the same field.
		 */
		field->definition =
			declaration_field->declaration->definition_new(declaration_field->declaration,
							  variant->scope,
							  field->name, 0);
	}
	variant->current_field = NULL;
	return &variant->p;
error:
	free_definition_scope(variant->scope);
	declaration_unref(&variant_declaration->p);
	g_free(variant);
	return NULL;
}

static
void _variant_definition_free(struct definition *definition)
{
	struct definition_variant *variant =
		container_of(definition, struct definition_variant, p);
	unsigned long i;

	assert(variant->fields->len == variant->declaration->untagged_variant->fields->len);
	for (i = 0; i < variant->fields->len; i++) {
		struct field *field = &g_array_index(variant->fields,
						     struct field, i);
		definition_unref(field->definition);
	}
	definition_unref(variant->enum_tag);
	free_definition_scope(variant->scope);
	declaration_unref(variant->p.declaration);
	g_free(variant);
}

void untagged_variant_declaration_add_field(struct declaration_untagged_variant *untagged_variant_declaration,
			    const char *field_name,
			    struct declaration *field_declaration)
{
	struct declaration_field *field;
	unsigned long index;

	g_array_set_size(untagged_variant_declaration->fields, untagged_variant_declaration->fields->len + 1);
	index = untagged_variant_declaration->fields->len - 1;	/* last field (new) */
	field = &g_array_index(untagged_variant_declaration->fields, struct declaration_field, index);
	field->name = g_quark_from_string(field_name);
	declaration_ref(field_declaration);
	field->declaration = field_declaration;
	/* Keep index in hash rather than pointer, because array can relocate */
	g_hash_table_insert(untagged_variant_declaration->fields_by_tag,
			    (gpointer) (unsigned long) field->name,
			    (gpointer) index);
	/*
	 * Alignment of variant is based on the alignment of its currently
	 * selected choice, so we leave variant alignment as-is (statically
	 * speaking).
	 */
}

struct declaration_field *
untagged_variant_declaration_get_field_from_tag(struct declaration_untagged_variant *untagged_variant_declaration, GQuark tag)
{
	unsigned long index;

	index = (unsigned long) g_hash_table_lookup(untagged_variant_declaration->fields_by_tag,
						    (gconstpointer) (unsigned long) tag);
	return &g_array_index(untagged_variant_declaration->fields, struct declaration_field, index);
}

/*
 * field returned only valid as long as the field structure is not appended to.
 */
struct field *variant_get_current_field(struct definition_variant *variant)
{
	struct definition_enum *_enum =
		container_of(variant->enum_tag, struct definition_enum, p);
	struct declaration_variant *variant_declaration = variant->declaration;
	unsigned long index;
	GArray *tag_array;
	GQuark tag;

	tag_array = _enum->value;
	/*
	 * The 1 to 1 mapping from enumeration to value should have been already
	 * checked. (see TODO above)
	 */
	assert(tag_array->len == 1);
	tag = g_array_index(tag_array, GQuark, 0);
	index = (unsigned long) g_hash_table_lookup(variant_declaration->untagged_variant->fields_by_tag,
						    (gconstpointer) (unsigned long) tag);
	variant->current_field = &g_array_index(variant->fields, struct field, index);
	return variant->current_field;
}