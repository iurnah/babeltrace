/*
 * trace-collection.c
 *
 * Babeltrace Library
 *
 * Copyright 2012 EfficiOS Inc. and Linux Foundation
 *
 * Author: Mathieu Desnoyers <mathieu.desnoyers@efficios.com>
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
#include <babeltrace/babeltrace.h>
#include <babeltrace/format.h>
#include <babeltrace/context.h>
#include <babeltrace/ctf/types.h>
#include <babeltrace/ctf-text/types.h>
#include <babeltrace/trace-collection.h>
#include <babeltrace/ctf-ir/metadata.h>	/* for clocks */

#include <inttypes.h>

struct clock_match {
	GHashTable *clocks;
	struct ctf_clock *clock_match;
	struct trace_collection *tc;
};

static void check_clock_match(gpointer key, gpointer value, gpointer user_data)
{
	struct clock_match *match = user_data;
	struct ctf_clock *clock_a = value, *clock_b;

	if (clock_a->uuid != 0) {
		/*
		 * Lookup the the trace clocks into the collection
		 * clocks.
		 */
		clock_b = g_hash_table_lookup(match->clocks,
			(gpointer) (unsigned long) clock_a->uuid);
		if (clock_b) {
			match->clock_match = clock_b;
			return;
		}
	} else if (clock_a->absolute) {
		/*
		 * Absolute time references, such as NTP, are looked up
		 * by clock name.
		 */
		clock_b = g_hash_table_lookup(match->clocks,
			(gpointer) (unsigned long) clock_a->name);
		if (clock_b) {
			match->clock_match = clock_b;
			return;
		}
	}
}

static void clock_add(gpointer key, gpointer value, gpointer user_data)
{
	struct clock_match *clock_match = user_data;
	GHashTable *tc_clocks = clock_match->clocks;
	struct ctf_clock *t_clock = value;
	GQuark v;

	if (t_clock->absolute)
		v = t_clock->name;
	else
		v = t_clock->uuid;
	if (v) {
		struct ctf_clock *tc_clock;

		tc_clock = g_hash_table_lookup(tc_clocks,
				(gpointer) (unsigned long) v);
		if (!tc_clock) {
			/*
			 * For now, we only support CTF that has one
			 * single clock uuid or name (absolute ref).
			 */
			if (g_hash_table_size(tc_clocks) > 0) {
				fprintf(stderr, "[error] Only CTF traces with a single clock description are supported by this babeltrace version.\n");
			}
			if (!clock_match->tc->offset_nr) {
				clock_match->tc->offset_first =
					(t_clock->offset_s * 1000000000ULL) + t_clock->offset;
				clock_match->tc->delta_offset_first_sum = 0;
				clock_match->tc->offset_nr++;
				clock_match->tc->single_clock_offset_avg =
					clock_match->tc->offset_first;
			}
			g_hash_table_insert(tc_clocks,
				(gpointer) (unsigned long) v,
				value);
		} else {
			int64_t diff_ns;

			/*
			 * Check that the offsets match. If not, warn
			 * the user that we do an arbitrary choice.
			 */
			diff_ns = tc_clock->offset_s;
			diff_ns -= t_clock->offset_s;
			diff_ns *= 1000000000ULL;
			diff_ns += tc_clock->offset;
			diff_ns -= t_clock->offset;
			printf_debug("Clock \"%s\" offset between traces has a delta of %" PRIu64 " ns.",
				g_quark_to_string(tc_clock->name),
				diff_ns < 0 ? -diff_ns : diff_ns);
			if (diff_ns > 10000) {
				fprintf(stderr, "[warning] Clock \"%s\" offset differs between traces (delta %" PRIu64 " ns). Using average.\n",
					g_quark_to_string(tc_clock->name),
					diff_ns < 0 ? -diff_ns : diff_ns);
			}
			/* Compute average */
			clock_match->tc->delta_offset_first_sum +=
				(t_clock->offset_s * 1000000000ULL) + t_clock->offset
				- clock_match->tc->offset_first;
			clock_match->tc->offset_nr++;
			clock_match->tc->single_clock_offset_avg =
				clock_match->tc->offset_first
				+ (clock_match->tc->delta_offset_first_sum / clock_match->tc->offset_nr);
		}
	}
}

/*
 * Whenever we add a trace to the trace collection, check that we can
 * correlate this trace with at least one other clock in the trace.
 */
int trace_collection_add(struct trace_collection *tc,
				struct trace_descriptor *td)
{
	struct ctf_trace *trace = container_of(td, struct ctf_trace, parent);

	g_ptr_array_add(tc->array, td);
	trace->collection = tc;

	if (tc->array->len > 1) {
		struct clock_match clock_match = {
			.clocks = tc->clocks,
			.clock_match = NULL,
			.tc = NULL,
		};

		/*
		 * With two or more traces, we need correlation info
		 * avalable.
		 */
		g_hash_table_foreach(trace->clocks,
				check_clock_match,
				&clock_match);
		if (!clock_match.clock_match) {
			fprintf(stderr, "[error] No clocks can be correlated and multiple traces are added to the collection.\n");
			goto error;
		}
	}

	{
		struct clock_match clock_match = {
			.clocks = tc->clocks,
			.clock_match = NULL,
			.tc = tc,
		};

		/*
		 * Add each clock from the trace clocks into the trace
		 * collection clocks.
		 */
		g_hash_table_foreach(trace->clocks,
				clock_add,
				&clock_match);
	}
	return 0;
error:
	return -EPERM;
}

int trace_collection_remove(struct trace_collection *tc,
			    struct trace_descriptor *td)
{
	if (g_ptr_array_remove(tc->array, td)) {
		return 0;
	} else {
		return -1;
	}

}

void init_trace_collection(struct trace_collection *tc)
{
	tc->array = g_ptr_array_new();
	tc->clocks = g_hash_table_new(g_direct_hash, g_direct_equal);
	tc->single_clock_offset_avg = 0;
	tc->offset_first = 0;
	tc->delta_offset_first_sum = 0;
	tc->offset_nr = 0;
}

/*
 * finalize_trace_collection() closes the opened traces for read
 * and free the memory allocated for trace collection
 */
void finalize_trace_collection(struct trace_collection *tc)
{
	g_ptr_array_free(tc->array, TRUE);
	g_hash_table_destroy(tc->clocks);
}