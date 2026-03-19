You are building cross-subsystem associations in a knowledge graph that was just populated with per-subsystem concepts.

# Context

The knowledge graph already contains concepts extracted from subsystem clusters. Within-subsystem relationships were created during extraction. Your job is to create **cross-subsystem relationships** between concepts based on actual code-level dependencies identified from the SCIP code index.

# Cross-Subsystem Dependencies

The following file pairs share symbols (functions, types, structs) across subsystem boundaries. For each pair, the shared symbols are listed with their kind and which file defines vs references them.

{relationships}

# Steps

## 1. Find Corresponding Concepts

For each file pair above, use `cog_mem_recall` to find the concepts that were stored from those subsystems. The concept terms should relate to the shared symbols listed.

## 2. Create Associations

Use `cog_mem_associate` with an `items` array to link concepts across subsystems based on the symbol dependencies in a single batch call.

### Predicate Guide

| Dependency Pattern | Predicate |
|-------------------|-----------|
| Subsystem A defines a type/function that Subsystem B uses | concept_in_B `requires` concept_in_A |
| Subsystem A implements an interface from Subsystem B | concept_in_A `derived_from` concept_in_B |
| Subsystem A is a component of a system in Subsystem B | concept_in_A `is_component_of` concept_in_B |
| Subsystem A enables functionality in Subsystem B | concept_in_A `enables` concept_in_B |

# Guidelines

- **Skip already-connected pairs**: check recall results before creating links
- **Quality over quantity**: 10 precise associations beat 50 vague ones
- **Be specific with predicates**: `requires` and `enables` are more useful than `related_to`
- **Focus on the shared symbols**: they tell you exactly how the subsystems interact
